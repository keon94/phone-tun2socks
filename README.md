# Phone Wi-Fi tun2socks

Event-driven NetworkManager → systemd → tun2socks routing on Fedora/Linux. Connecting to a configured phone SSID starts the tunnel; disconnecting stops it and removes the routes. No periodic polling.

## Requirements

- NetworkManager and systemd
- Python 3 with PyYAML (`sudo dnf install python3-pyyaml` on Fedora)
- `tun2socks` installed and on the systemd service's PATH (`command -v tun2socks`)
- Root privileges for TUN and route operations
- A saved NetworkManager Wi-Fi connection for your phone's SSID

## Install

```bash
sudo dnf install python3-pyyaml
sudo ./install.sh
sudoedit /etc/phone-tun2socks/config.yaml
```

Example YAML:

```yaml
ssid: TetherFi
interface: wlo1
proxy_url: socks5://192.168.49.1:8228
tun_interface: tun0
tun_address: 10.0.0.1/24
```

Set `ssid` to the exact phone SSID, and adjust the interface and proxy URL. SOCKS5 is the default, matching the working TetherFi setup; `http://host:port` is also supported by compatible tun2socks builds.

Connect to the phone's Wi-Fi via NetworkManager. The dispatcher starts the service when the matching profile goes `up`, and stops it on `down`. **Do not enable the systemd service at boot.**

If already connected during installation, disconnect and reconnect once, or manually start with `sudo systemctl start phone-tun2socks.service`.

## Check

```bash
systemctl status phone-tun2socks
journalctl -u phone-tun2socks -f
ip -4 route get 1.1.1.1
ip -4 route get 192.168.49.1
```

When active, ordinary IPv4 destinations should use `tun0`; the proxy address should use `wlo1`.

## How routing works

The script keeps NetworkManager's default route untouched and adds two `/1` routes via the TUN interface. A `/32` on-link route to the phone proxy prevents routing the proxy's own TCP connection into the tunnel. On service stop or failure, it removes only routes it added and deletes its TUN interface. The normal default route is therefore still present. Existing more-specific LAN, Docker, and VM routes take precedence.

## Limitations and safety

- The proxy must be **directly reachable over the configured Wi-Fi interface**, as with a typical phone hotspot. This implementation does not support a proxy routed through a separate gateway.
- No IPv6 tunneling or kill switch: IPv6 and other non-tunneled traffic can bypass the proxy, and traffic falls back to the normal route after shutdown.
- DNS behavior depends on local resolver settings; verify DNS if avoiding leaks matters.
- Dispatcher events reflect connection state, not mere SSID visibility. NetworkManager handles Wi-Fi reconnects.
- A live Wi-Fi connection with a dead proxy is not automatically detected; this intentionally avoids polling. Stop the service or disconnect the SSID in that situation.
- The `tun0` name and route prefixes must not be owned by another application.
- After editing YAML, restart the service or reconnect Wi-Fi to apply changes.

## Uninstall

```bash
sudo systemctl stop phone-tun2socks.service
sudo rm -f /etc/NetworkManager/dispatcher.d/90-phone-tun2socks
sudo rm -f /etc/systemd/system/phone-tun2socks.service
sudo rm -f /usr/local/libexec/phone-tun2socks
sudo systemctl daemon-reload
# Optional: sudo rm -rf /etc/phone-tun2socks
```
