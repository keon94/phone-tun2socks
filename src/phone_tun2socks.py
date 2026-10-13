#!/usr/bin/env python3
"""NetworkManager-triggered tun2socks service. Linux/Fedora, Python 3 + PyYAML."""

from __future__ import annotations

import argparse
from dataclasses import dataclass
import ipaddress
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
from urllib.parse import urlsplit

import yaml

CONFIG_FILE = Path('/etc/phone-tun2socks/config.yaml')
STATE_FILE = Path('/run/phone-tun2socks/state.json')
ROUTE_PROTOCOL = '199'  # Marks our temporary IPv4 routes for safe removal.
OVERRIDE_ROUTES = ('0.0.0.0/1', '128.0.0.0/1')


class TunnelError(Exception):
    pass


class ShutdownRequested(Exception):
    pass


@dataclass(frozen=True)
class Config:
    ssid: str
    wifi_interface: str
    proxy_url: str
    proxy_ip: str
    tun_interface: str
    tun_address: str
    tun2socks_binary: str


def require(mapping, key, label):
    value = mapping.get(key)
    if not isinstance(value, str) or not value.strip():
        raise TunnelError(f'{label}.{key} must be a non-empty string')
    return value


def load_config(path: Path = CONFIG_FILE) -> Config:
    try:
        data = yaml.safe_load(path.read_text(encoding='utf-8'))
    except (OSError, yaml.YAMLError) as exc:
        raise TunnelError(f'Cannot read {path}: {exc}') from exc
    if not isinstance(data, dict):
        raise TunnelError('YAML root must be a mapping')

    sections = {}
    for name in ('network', 'proxy', 'tunnel'):
        section = data.get(name)
        if not isinstance(section, dict):
            raise TunnelError(f'Missing YAML mapping: {name}')
        sections[name] = section
    network, proxy, tunnel = sections['network'], sections['proxy'], sections['tunnel']
    ssid = require(network, 'ssid', 'network')
    wifi_interface = require(network, 'interface', 'network')
    proxy_url = require(proxy, 'url', 'proxy')
    tun_interface = require(tunnel, 'interface', 'tunnel')
    tun_address = require(tunnel, 'address', 'tunnel')
    binary = require(tunnel, 'executable', 'tunnel')

    try:
        parsed = urlsplit(proxy_url)
        if parsed.scheme not in ('socks5', 'socks5h', 'http') or not parsed.port:
            raise ValueError('proxy URL must use socks5://, socks5h:// or http:// with a port')
        proxy_ip = str(ipaddress.IPv4Address(parsed.hostname or ''))
        ipaddress.IPv4Interface(tun_address)
    except ValueError as exc:
        raise TunnelError(f'Invalid proxy URL or tunnel address: {exc}') from exc
    if wifi_interface == tun_interface or '/' in wifi_interface or '/' in tun_interface:
        raise TunnelError('Wi-Fi and tunnel interfaces must be different valid device names')
    if not Path(binary).is_absolute():
        raise TunnelError('tunnel.executable must be an absolute path')

    return Config(ssid, wifi_interface, proxy_url, proxy_ip,
                  tun_interface, tun_address, binary)


def run_cmd(*args: str, check: bool = True) -> subprocess.CompletedProcess:
    return subprocess.run(args, text=True, capture_output=True, check=check)


def connection_ssid(uuid: str) -> str | None:
    result = run_cmd('nmcli', '-e', 'no', '-g', '802-11-wireless.ssid',
                     'connection', 'show', uuid, check=False)
    return result.stdout.strip() if result.returncode == 0 else None


def active_connection_uuid(interface: str) -> str | None:
    result = run_cmd('nmcli', '-t', '-f', 'UUID,DEVICE',
                     'connection', 'show', '--active')
    for line in result.stdout.splitlines():
        fields = line.split(':', 1)  # UUID and device name never contain colons.
        if len(fields) == 2 and fields[1] == interface:
            return fields[0]
    return None


def is_phone_connected(config: Config) -> bool:
    uuid = active_connection_uuid(config.wifi_interface)
    return bool(uuid and connection_ssid(uuid) == config.ssid)


def proxy_route(config: Config) -> dict:
    result = run_cmd('ip', '-j', '-4', 'route', 'get', config.proxy_ip)
    routes = json.loads(result.stdout)
    if not routes or routes[0].get('dev') != config.wifi_interface:
        raise TunnelError(f'Proxy {config.proxy_ip} does not route over '
                          f'{config.wifi_interface}; refusing to redirect traffic')
    return routes[0]


def preflight(config: Config):
    if not is_phone_connected(config):
        raise TunnelError(f'SSID {config.ssid!r} is not active on {config.wifi_interface}')
    if not Path(config.tun2socks_binary).is_file() or not os.access(config.tun2socks_binary, os.X_OK):
        raise TunnelError(f'tun2socks executable missing or not executable: {config.tun2socks_binary}')
    proxy_route(config)


def route_exists(prefix: str, interface: str | None = None, protocol: str | None = None) -> bool:
    result = run_cmd('ip', '-j', '-4', 'route', 'show', 'exact', prefix)
    for route in json.loads(result.stdout):
        if (route.get('dst', 'default') in (prefix, 'default')
            and (interface is None or route.get('dev') == interface)
            and (protocol is None or str(route.get('protocol')) == protocol)):
            return True
    return False


def add_proxy_exemption(config: Config, route: dict):
    # Only add a host route when none exists. The host route remains more
    # specific than both /1 tunnel routes, even if the proxy is reached via
    # a gateway. Also useful when the phone IP is directly connected.
    prefix = f'{config.proxy_ip}/32'
    if route_exists(prefix):
        return
    args = ['ip', '-4', 'route', 'add', prefix]
    if route.get('gateway'):
        args.extend(('via', route['gateway']))
    args.extend(('dev', config.wifi_interface, 'proto', ROUTE_PROTOCOL))
    run_cmd(*args)


def write_state(config: Config):
    STATE_FILE.parent.mkdir(parents=True, exist_ok=True)
    temp = STATE_FILE.with_suffix('.tmp')
    temp.write_text(json.dumps({'tun_interface': config.tun_interface,
                                'proxy_ip': config.proxy_ip}) + '\n')
    temp.replace(STATE_FILE)


def setup_routes(config: Config):
    route = proxy_route(config)
    # A pre-existing tun interface is never adopted or deleted.
    run_cmd('ip', 'tuntap', 'add', 'dev', config.tun_interface, 'mode', 'tun')
    write_state(config)
    run_cmd('ip', 'address', 'add', config.tun_address, 'dev', config.tun_interface)
    run_cmd('ip', 'link', 'set', 'dev', config.tun_interface, 'up')
    add_proxy_exemption(config, route)
    for prefix in OVERRIDE_ROUTES:
        run_cmd('ip', '-4', 'route', 'add', prefix, 'dev', config.tun_interface,
                'proto', ROUTE_PROTOCOL)
    print(f'Tunnel routes installed on {config.tun_interface}', flush=True)


def cleanup():
    if not STATE_FILE.exists():
        return
    try:
        state = json.loads(STATE_FILE.read_text())
        iface = state['tun_interface']
        proxy_ip = str(ipaddress.IPv4Address(state['proxy_ip']))
        # Avoid trusting a modified state file to build arbitrary interface arguments.
        if not isinstance(iface, str) or not iface or '/' in iface:
            raise ValueError('Invalid interface in state file')
        for prefix in (*OVERRIDE_ROUTES, f'{proxy_ip}/32'):
            if route_exists(prefix, protocol=ROUTE_PROTOCOL):
                result = run_cmd('ip', '-4', 'route', 'show', 'exact', prefix)
                # Delete only routes using this service's tunnel interface,
                # or its recorded proxy host route.
                expected = iface if prefix in OVERRIDE_ROUTES else None
                if route_exists(prefix, interface=expected, protocol=ROUTE_PROTOCOL):
                    run_cmd('ip', '-4', 'route', 'del', prefix, 'proto', ROUTE_PROTOCOL,
                            *(['dev', iface] if expected else []), check=False)
        run_cmd('ip', 'link', 'del', 'dev', iface, check=False)
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError) as exc:
        print(f'Cleanup warning: {exc}', file=sys.stderr, flush=True)
        return
    STATE_FILE.unlink(missing_ok=True)
    print('Tunnel routes and interface cleaned up', flush=True)


def sigterm(_signum, _frame):
    raise ShutdownRequested()


def run_tunnel(config: Config) -> int:
    preflight(config)
    child = None
    signal.signal(signal.SIGTERM, sigterm)
    signal.signal(signal.SIGINT, sigterm)
    try:
        setup_routes(config)
        child = subprocess.Popen([
            config.tun2socks_binary,
            '--device', f'tun://{config.tun_interface}',
            '--proxy', config.proxy_url,
            '--interface', config.wifi_interface,
        ])
        print(f'Started tun2socks (PID {child.pid}) for SSID {config.ssid!r}', flush=True)
        return child.wait()
    except ShutdownRequested:
        return 0
    finally:
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        signal.signal(signal.SIGINT, signal.SIG_IGN)
        if child is not None and child.poll() is None:
            child.terminate()
            try:
                child.wait(timeout=5)
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait()
        cleanup()


def dispatch(config: Config, interface: str, action: str):
    if interface != config.wifi_interface or action not in ('up', 'down'):
        return
    uuid = os.environ.get('CONNECTION_UUID', '')
    # Check the SSID of the saved connection profile, including during down
    # when the device is no longer associated.
    if not uuid or connection_ssid(uuid) != config.ssid:
        return
    command = 'start' if action == 'up' else 'stop'
    run_cmd('systemctl', '--no-block', command, 'phone-tun2socks.service')
    print(f'{action}: requested service {command} for SSID {config.ssid!r}', flush=True)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', type=Path, default=CONFIG_FILE)
    sub = parser.add_subparsers(dest='action', required=True)
    sub.add_parser('check', help='Verify target Wi-Fi connection and route')
    sub.add_parser('run', help='Set up tunnel; clean up on exit')
    sub.add_parser('cleanup', help='Idempotent emergency cleanup')
    dispatcher = sub.add_parser('dispatch', help='NetworkManager dispatcher entrypoint')
    dispatcher.add_argument('interface')
    dispatcher.add_argument('event', choices=('up', 'down', 'other'))
    args = parser.parse_args()
    try:
        if args.action == 'cleanup':
            cleanup()
            return 0
        config = load_config(args.config)
        if args.action == 'check':
            preflight(config)
            return 0
        if args.action == 'run':
            return run_tunnel(config)
        if args.action == 'dispatch':
            dispatch(config, args.interface, args.event)
            return 0
    except (TunnelError, subprocess.CalledProcessError, OSError, ValueError) as exc:
        print(f'phone-tun2socks: {exc}', file=sys.stderr, flush=True)
        return 1
    return 2


if __name__ == '__main__':
    sys.exit(main())
