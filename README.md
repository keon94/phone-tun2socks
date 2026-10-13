# Phone Wi-Fi tun2socks

A minimal, **event-driven** NetworkManager dispatcher script. Connecting to your phone's configured Wi-Fi SSID starts a `tun2socks` tunnel; disconnecting stops it and restores the normal route.

## Contents

- `90-phone-tun2socks`: NetworkManager dispatcher shell script and tunnel setup/cleanup logic.
- `90-phone-tun2socks.yaml`: configuration alongside the script.

The script uses `systemd-run` to keep the tunnel alive in a *transient* systemd unit after the short-lived dispatcher event finishes. `systemctl stop` sends SIGTERM to the wrapper, which cleans up `tun0` and the associated routes. This avoids orphaning a background process inside NetworkManager's dispatcher service.

## Requirements

Fedora/Linux with NetworkManager, systemd (`systemd-run`), `iproute2`, `yq`, and a `tun2socks` binary on the system service PATH. Root access is required for installation and route changes. No PyYAML dependency; the config accepts a **flat subset of YAML scalar strings** (not nested YAML). The example uses SOCKS5, matching TetherFi's SOCKS proxy option.

## Install

```sh
sudo install -o root -g root -m 755 90-phone-tun2socks /etc/NetworkManager/dispatcher.d/90-phone-tun2socks
sudo install -o root -g root -m 644 90-phone-tun2socks.yaml /etc/phone-tun2socks/config.yaml
sudoedit /etc/NetworkManager/dispatcher.d/90-phone-tun2socks.yaml
```

Edit the YAML to match your SSID, wireless interface and proxy. Both files must remain side by side; the YAML is not executable. No service `enable` or `daemon-reload` is necessary. If already connected to the phone, reconnect once to trigger an `up` event. The dispatcher only reacts to **connection state**, not SSID visibility.

**Check your tun2socks path:** The transient systemd unit must find `tun2socks` on its PATH (`command -v tun2socks`). If your binary is in a user-only location, install it into `/usr/local/bin` or use an absolute path in the script.

## Check

```sh
systemctl status phone-tun2socks.service
journalctl -u phone-tun2socks.service -f
ip -4 route get 1.1.1.1          # should go through tun0 while connected
ip -4 route get 192.168.49.1     # should go directly via wlo1
```

To manually stop an active tunnel without disconnecting Wi-Fi:

```sh
sudo systemctl stop phone-tun2socks.service
```

Reconnecting Wi-Fi starts it again. An explicit `systemctl start` does **not** work because the transient unit is created by `systemd-run` on the `up` event.

## Routing behavior

On connection, the script creates `tun0`, assigns `10.0.0.1/24`, and adds two IPv4 routes (`0.0.0.0/1` and `128.0.0.0/1`) through it. This leaves NetworkManager's default route untouched; the original default route remains available. More-specific routes (including the directly connected phone proxy) win over the `/1` routes.

On disconnect, it stops the transient unit, which terminates `tun2socks` and deletes the TUN interface. Deleting that interface automatically removes both `/1` routes. No gateway backup/restore is required.

## Limitations

- Assumes the proxy is an **IPv4 literal directly reachable** via the configured Wi-Fi interface, and is in the connected phone subnet.
- No IPv6 tunneling, DNS leak protection, or kill switch. IPv4 traffic falls back to the standard route when the TUN is removed; IPv6 may bypass the proxy even while active.
- The script handles normal stop and tun2socks process exits, not `SIGKILL` or power loss. If needed, manually remove a stale `tun0` with `sudo ip link del tun0`.
- This deliberately does not monitor proxy health. A dead proxy with an active Wi-Fi connection will not trigger a disconnect event.
- Keep the shell script root-owned and not writable by unprivileged users. Configuration must be treated as trusted administrative input.

## Uninstall

```sh
sudo systemctl stop phone-tun2socks.service 2>/dev/null || true
sudo rm -f /etc/NetworkManager/dispatcher.d/90-phone-tun2socks \
  /etc/NetworkManager/dispatcher.d/90-phone-tun2socks.yaml
```
