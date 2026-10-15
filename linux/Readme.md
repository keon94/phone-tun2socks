# Linux Implementation

A minimal, **event-driven** NetworkManager dispatcher setup. Connecting to a configured phone Wi-Fi SSID starts a SOCKS5 tunnel; disconnecting stops it. There is no polling loop or permanently installed systemd service.

## Files

- `90-tun2socks` — NetworkManager dispatcher script; also handles tunnel setup and cleanup.
- `90-tun2socks.yaml` — example configuration, installed as `/etc/tun2socks-hotspot/config.yaml`.
- `linux/fix-selinux.sh` — (for Fedora users) self-contained Fedora SELinux policy installer; generates and compiles its own policy.

The dispatcher uses `systemd-run` to create a **transient** `tun2socks-hotspot.service` so that `tun2socks` can stay running after NetworkManager's short-lived connection event handler exits. A stop event terminates the transient unit and cleans up `tun0` and its routes.

## Requirements

- Linux with NetworkManager, systemd, `iproute2`, `yq`, and a working `tun2socks` binary (for example `/usr/local/bin/tun2socks`).
- Root access for installation, TUN configuration, routing, and SELinux policy installation.
- A phone Wi-Fi network exposing a SOCKS5 proxy reachable directly through the Wi-Fi interface. The Android app `TetherFuseNet` has been tested. You can find it [here](https://github.com/pyamsoft/tetherfusenet).

On Linux, install the networking prerequisites if needed. On Fedora:

```sh
sudo dnf install yq iproute
```

Install the `tun2socks` binary separately [from here](https://github.com/xjasonlyu/tun2socks). The binary must be available on the system service PATH (not user PATH!).
## Configuration

Example `90-tun2socks.yaml`:

```yaml
ssid: TetherFi
interface: wlo1
proxy_url: socks5://192.168.49.1:8228
tun_interface: tun0
tun_address: 10.0.0.1/24
```

Change the SSID and interface name to match your setup. The proxy URL must specify an IPv4 address directly reachable over that Wi-Fi connection.

## Installation

Run the following:

```sh
sudo install -d -m 755 /etc/tun2socks-hotspot
sudo install -o root -g root -m 755 90-tun2socks \
  /etc/NetworkManager/dispatcher.d/90-tun2socks
sudo install -o root -g root -m 644 90-tun2socks.yaml \
  /etc/tun2socks-hotspot/config.yaml
sudoedit /etc/tun2socks-hotspot/config.yaml
```

There is no service to `enable` and no need for `systemctl daemon-reload`. If already connected to the phone, disconnect and reconnect once to trigger the `up` event. 
SSID *visibility* alone does not trigger the tunnel - the events are captured upon connect or disconnect from the configured SSID.

### Fedora SELinux

Fedora may block custom `tun2socks` binaries from accessing the SOCKS5 proxy port or `/dev/net/tun`. On systems using SELinux, apply the fix below **before testing in enforcing mode**:

```sh
sudo ./fix-selinux.sh
```

The helper installs missing Fedora policy utilities if necessary, restores default labels, installs an SELinux policy module, and labels the TCP port read from the YAML file. See [SELinux details](#selinux-details-fedora) for permissions, verification, and removal.

### DNS for the phone Wi-Fi connection

The phone hotspot might advertise its own IP (for example `192.168.49.1`) as a DNS server but reply with `REFUSED`. If `dig @1.1.1.1 google.com` works but normal application name resolution fails, set external DNS servers **only for the phone's NetworkManager connection profile**:

```sh
UUID=$(nmcli -g GENERAL.CON-UUID device show wlo1)
sudo nmcli connection modify "$UUID" \
  ipv4.ignore-auto-dns yes \
  ipv4.dns "1.1.1.1 9.9.9.9"
sudo nmcli device reapply wlo1
sudo resolvectl flush-caches
resolvectl query google.com
```

Run this only while the phone connection is active, or specify its saved connection name/UUID explicitly. This is a persistent setting on that **connection profile**, not a global DNS override. VPN clients (e.g. Tailscale) may apply separate DNS routing rules.

## Operation and checks

While connected to the phone:

```sh
systemctl status tun2socks-hotspot.service
journalctl -u tun2socks-hotspot.service -f
ip -4 route get 1.1.1.1       # should use tun0
ip -4 route get 192.168.49.1  # should use wlo1, not tun0
curl -4 https://example.com
```

Manually stop the currently running tunnel:

```sh
sudo systemctl stop tun2socks-hotspot.service
```

Disconnect/reconnect the phone Wi-Fi network to start it again. `systemctl start tun2socks-hotspot.service` is not normally available because the unit is created by `systemd-run` when NetworkManager fires `up`; it may be unloaded when stopped.

To diagnose dispatcher failures:

```sh
journalctl -b -u NetworkManager-dispatcher.service -n 100 --no-pager
journalctl -b -u tun2socks-hotspot.service -n 100 --no-pager
```

## Routing behavior

On connection, the script creates `tun0`, assigns `10.0.0.1/24`, and adds `0.0.0.0/1` and `128.0.0.0/1` routes through it. This keeps the NetworkManager default route intact, but the two more-specific routes take priority for general IPv4 Internet traffic.

The directly connected `192.168.49.0/24` phone network continues to use `wlo1` because its route is more specific. This keeps the SOCKS5 control connection from feeding into its own tunnel.

On disconnect, the transient unit is stopped. Its cleanup deletes `tun0`, which removes the associated `/1` routes; NetworkManager continues managing the default gateway. There is no gateway backup/restore.

## Limitations

- The phone SOCKS5 proxy must be an IPv4 literal reachable directly over the configured Wi-Fi interface.
- This handles **IPv4** only; IPv6 may bypass the proxy.
- If the proxy fails while Wi-Fi remains connected, no disconnection event occurs. Proxy health is intentionally not polled.
- Normal process shutdown cleans up the interface; uncatchable termination or power loss can leave stale state until reboot. Manually remove a stale interface with `sudo ip link del tun0` if necessary.
- Tailscale and other VPNs use their own routing and DNS policy. Test interoperability rather than assuming all VPN traffic uses the phone proxy.

## SELinux details (Fedora)

### Why the policy is needed

On Fedora setups, `tun2socks` may trigger SELinux to block certain system calls. The supplied shell script `fix-selinux.sh` handles creating the policies that add the appropriate permissions.

In short, it does these:

1. Installs missing packages (`yq`, `checkpolicy`, `policycoreutils`, `policycoreutils-python-utils`) using `dnf`.
2. Restores SELinux file labels on `tun2socks`, the dispatcher script, and `/dev/net/tun` if present.
3. Generates, compiles, and installs the `tun2socks_hotspot` policy module.
4. Registers the **TCP** proxy port found in `proxy_url` as `phone_proxy_port_t`, unless already correctly registered. If another explicit port mapping conflicts, it fails instead of silently overwriting it.

### Verify under enforcing mode

```sh
getenforce                          # ideally Enforcing
sudo semodule -l | grep tun2socks_hotspot
sudo semanage port -l | grep phone_proxy_port_t
ls -Z /usr/local/bin/tun2socks /dev/net/tun
sudo ausearch -m AVC,USER_AVC -ts recent
```
### Change the proxy port

Edit `proxy_url` in `/etc/tun2socks-hotspot/config.yaml`, then rerun `sudo ./fix-selinux.sh`. If the old proxy port was previously labeled, its local mapping must be removed explicitly when it is no longer needed:

```sh
sudo semanage port -d -p tcp OLD_PORT
```

Only delete the old mapping if it was created specifically for this project.

### Remove the SELinux policy

If you used the default TCP port `8228` and the mapping belongs to this project:

```sh
sudo semanage port -d -p tcp 8228
sudo semodule -r tun2socks_hotspot
```

Use your configured TCP port if different. Neither operation changes SELinux enforcement mode.

## Uninstall

```sh
sudo systemctl stop tun2socks-hotspot.service 2>/dev/null || true
sudo rm -f /etc/NetworkManager/dispatcher.d/90-tun2socks
sudo rm -f /etc/tun2socks-hotspot/config.yaml
sudo rmdir /etc/tun2socks-hotspot 2>/dev/null || true
```

To uninstall the SELinux customization as well, follow [Remove the SELinux policy](#remove-the-selinux-policy). The per-profile DNS override, if configured, is also separate and must be reverted using `nmcli connection modify` on that profile.
