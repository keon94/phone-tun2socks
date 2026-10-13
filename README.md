# Phone Wi-Fi tun2socks

A minimal, **event-driven** NetworkManager dispatcher setup. Connecting to a configured phone Wi-Fi SSID starts a SOCKS5 tunnel; disconnecting stops it. There is no polling loop or permanently installed systemd service.

## Files

- `90-phone-tun2socks` — NetworkManager dispatcher script; also handles tunnel setup and cleanup.
- `90-phone-tun2socks.yaml` — example configuration, installed as `/etc/phone-tun2socks/config.yaml`.
- `fix-selinux.sh` — self-contained Fedora SELinux policy installer; generates and compiles its own policy.

The dispatcher uses `systemd-run` to create a **transient** `phone-tun2socks.service` so that `tun2socks` can stay running after NetworkManager's short-lived connection event handler exits. A stop event terminates the transient unit and cleans up `tun0` and its routes.

## Requirements

- Fedora/Linux with NetworkManager, systemd, `iproute2`, `yq`, and a working `tun2socks` binary (for example `/usr/local/bin/tun2socks`).
- Root access for installation, TUN configuration, routing, and SELinux policy installation.
- A phone Wi-Fi network exposing a SOCKS5 proxy reachable directly through the Wi-Fi interface.

The configuration uses flat YAML scalar values. `yq` reads the configuration; **do not source YAML as a shell script**.

On Fedora, install the networking prerequisites if needed:

```sh
sudo dnf install yq iproute
```

Install the `tun2socks` binary separately. The binary must be available on the system service PATH; a binary in a user-only directory may not be found by `systemd-run`.

## Configuration

Example `90-phone-tun2socks.yaml`:

```yaml
ssid: TetherFi
interface: wlo1
proxy_url: socks5://192.168.49.1:8228
tun_interface: tun0
tun_address: 10.0.0.1/24
```

Change the SSID and interface name to match your setup. The proxy URL must specify an IPv4 address directly reachable over that Wi-Fi connection.

## Installation

Install only the executable script inside NetworkManager's dispatcher directory. **Do not put the YAML file there:** NetworkManager tries to inspect every file in `dispatcher.d` as a possible executable and emits warnings for non-executable YAML files.

```sh
sudo install -d -m 755 /etc/phone-tun2socks
sudo install -o root -g root -m 755 90-phone-tun2socks \
  /etc/NetworkManager/dispatcher.d/90-phone-tun2socks
sudo install -o root -g root -m 644 90-phone-tun2socks.yaml \
  /etc/phone-tun2socks/config.yaml
sudoedit /etc/phone-tun2socks/config.yaml
```

Ensure that the dispatcher reads the installed file:

```sh
CONFIG=/etc/phone-tun2socks/config.yaml
```

If your copy of `90-phone-tun2socks` still contains `CONFIG="${0}.yaml"`, change that line to the path above. **Editing the README or moving the YAML does not automatically update the script.**

There is no service to `enable` and no need for `systemctl daemon-reload`. If already connected to the phone, disconnect and reconnect once to trigger the `up` event. SSID *visibility* alone does not trigger the tunnel.

### Fedora SELinux

Fedora may block custom `tun2socks` binaries from accessing the SOCKS5 proxy port or `/dev/net/tun`. On systems using SELinux, apply the fix below **before testing in enforcing mode**:

```sh
sudo ./fix-selinux.sh
```

The helper installs missing Fedora policy utilities if necessary, restores default labels, installs an SELinux policy module, and labels the TCP port read from the YAML file. See [SELinux details](#selinux-details-fedora) for permissions, verification, and removal.

### DNS for the phone Wi-Fi connection

Some phone hotspots advertise their own IP (for example `192.168.49.1`) as a DNS server but reply with `REFUSED`. If `dig @1.1.1.1 google.com` works but normal application name resolution fails, set external DNS servers **only for the phone's NetworkManager connection profile**:

```sh
UUID=$(nmcli -g GENERAL.CON-UUID device show wlo1)
sudo nmcli connection modify "$UUID" \
  ipv4.ignore-auto-dns yes \
  ipv4.dns "1.1.1.1 9.9.9.9"
sudo nmcli device reapply wlo1
sudo resolvectl flush-caches
resolvectl query google.com
```

Run this only while the phone connection is active, or specify its saved connection name/UUID explicitly. This is a persistent setting on that **connection profile**, not a global DNS override. Tailscale and other VPN clients may apply separate DNS routing rules.

## Operation and checks

While connected to the phone:

```sh
systemctl status phone-tun2socks.service
journalctl -u phone-tun2socks.service -f
ip -4 route get 1.1.1.1       # should use tun0
ip -4 route get 192.168.49.1  # should use wlo1, not tun0
curl -4 https://example.com
```

Manually stop the currently running tunnel:

```sh
sudo systemctl stop phone-tun2socks.service
```

Disconnect/reconnect the phone Wi-Fi network to start it again. `systemctl start phone-tun2socks.service` is not normally available because the unit is created by `systemd-run` when NetworkManager fires `up`; it may be unloaded when stopped.

To diagnose dispatcher failures:

```sh
journalctl -b -u NetworkManager-dispatcher.service -n 100 --no-pager
journalctl -b -u phone-tun2socks.service -n 100 --no-pager
```

## Routing behavior

On connection, the script creates `tun0`, assigns `10.0.0.1/24`, and adds `0.0.0.0/1` and `128.0.0.0/1` routes through it. This keeps the NetworkManager default route intact, but the two more-specific routes take priority for general IPv4 Internet traffic.

The directly connected `192.168.49.0/24` phone network continues to use `wlo1` because its route is more specific. This keeps the SOCKS5 control connection from feeding into its own tunnel.

On disconnect, the transient unit is stopped. Its cleanup deletes `tun0`, which removes the associated `/1` routes; NetworkManager continues managing the default gateway. There is no gateway backup/restore.

## Limitations

- The phone SOCKS5 proxy must be an IPv4 literal reachable directly over the configured Wi-Fi interface.
- This handles **IPv4** only; IPv6 may bypass the proxy. No kill switch or DNS leak protection is provided.
- If the proxy fails while Wi-Fi remains connected, no disconnection event occurs. Proxy health is intentionally not polled.
- Normal process shutdown cleans up the interface; uncatchable termination or power loss can leave stale state until reboot. Manually remove a stale interface with `sudo ip link del tun0` if necessary.
- Tailscale and other VPNs use their own routing and DNS policy. Test interoperability rather than assuming all VPN traffic uses the phone proxy.
- Keep both the dispatcher and YAML config root-owned and not writable by ordinary users.

## SELinux details (Fedora)

### Why the policy is needed

On the tested Fedora setup, `tun2socks` ran in SELinux's `init_t` domain when started through the transient systemd unit. With SELinux enforcing, the following operations were denied:

| Resource | SELinux target | Permissions |
|---|---|---|
| SOCKS5 TCP port (default `8228`) | `phone_proxy_port_t` (custom port label) | `tcp_socket name_connect` |
| `/dev/net/tun` | `tun_tap_device_t` | `chr_file { read write open ioctl }` |

`fix-selinux.sh` **embeds and generates** the policy module below. No separate `.te` file is necessary:

```selinux
module phone_tun2socks 1.0;

require {
    type init_t;
    type tun_tap_device_t;
    attribute port_type;
    class tcp_socket name_connect;
    class chr_file { read write open ioctl };
}

type phone_proxy_port_t;
typeattribute phone_proxy_port_t port_type;

allow init_t phone_proxy_port_t:tcp_socket name_connect;
allow init_t tun_tap_device_t:chr_file { read write open ioctl };
```

The helper automatically:

1. Installs missing packages (`yq`, `checkpolicy`, `policycoreutils`, `policycoreutils-python-utils`) using `dnf`.
2. Restores SELinux file labels on `tun2socks`, the dispatcher script, and `/dev/net/tun` if present.
3. Generates, compiles, and installs the `phone_tun2socks` policy module.
4. Registers the **TCP** proxy port found in `proxy_url` as `phone_proxy_port_t`, unless already correctly registered. If another explicit port mapping conflicts, it fails instead of silently overwriting it.

It does not switch SELinux into permissive mode. Re-running it with the same config and port is supported.

**Security scope:** These rules grant permissions to **all processes in `init_t`**, not only the `tun2socks` binary. A dedicated `tun2socks_t` domain would provide better isolation. The port mapping controls TCP `name_connect`; UDP allowances are not granted proactively.

### Verify under enforcing mode

```sh
getenforce                          # ideally Enforcing
sudo semodule -l | grep phone_tun2socks
sudo semanage port -l | grep phone_proxy_port_t
ls -Z /usr/local/bin/tun2socks /dev/net/tun
sudo ausearch -m AVC,USER_AVC -ts recent
```

Test a **new Wi-Fi connection** under enforcing mode (if you were running permissive, `sudo setenforce 1` first). Old AVC messages remain in the audit log and do not mean the new policy failed.

An observed `ioctl` denial against the dispatcher script file itself (`NetworkManager_dispatcher_script_t`) was left unchanged because the tunnel operated successfully under enforcing mode. Do not automatically allow or suppress every AVC or blindly apply `audit2allow` recommendations.

### Change the proxy port

Edit `proxy_url` in `/etc/phone-tun2socks/config.yaml`, then rerun `sudo ./fix-selinux.sh`. If the old proxy port was previously labeled, its local mapping must be removed explicitly when it is no longer needed:

```sh
sudo semanage port -d -p tcp OLD_PORT
```

Only delete the old mapping if it was created specifically for this project.

### Remove the SELinux policy

If you used the default TCP port `8228` and the mapping belongs to this project:

```sh
sudo semanage port -d -p tcp 8228
sudo semodule -r phone_tun2socks
```

Use your configured TCP port if different. Neither operation changes SELinux enforcement mode.

## Uninstall

```sh
sudo systemctl stop phone-tun2socks.service 2>/dev/null || true
sudo rm -f /etc/NetworkManager/dispatcher.d/90-phone-tun2socks
sudo rm -f /etc/phone-tun2socks/config.yaml
sudo rmdir /etc/phone-tun2socks 2>/dev/null || true
```

To uninstall the SELinux customization as well, follow [Remove the SELinux policy](#remove-the-selinux-policy). The per-profile DNS override, if configured, is also separate and must be reverted using `nmcli connection modify` on that profile.
