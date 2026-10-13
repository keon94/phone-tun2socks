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



## SELinux Configuration (Fedora)

On Fedora with SELinux enabled, `tun2socks` may generate AVC denials when accessing the SOCKS5 proxy or the TUN device.

When launched through NetworkManager and a transient systemd unit, `tun2socks` may run under the `init_t` SELinux domain.

The following denials were observed:

| Operation | SELinux target | Denied permission |
|---|---|---|
| Connecting to SOCKS5 proxy on TCP port 8228 | `unreserved_port_t` | `tcp_socket name_connect` |
| Reading `/dev/net/tun` | `tun_tap_device_t` | `chr_file read` |
| Writing `/dev/net/tun` | `tun_tap_device_t` | `chr_file write` |

A small custom SELinux policy can authorize these operations without disabling SELinux.

### 1. Install dependencies

```bash
sudo dnf install checkpolicy policycoreutils policycoreutils-python-utils
```

### 2. Create the policy

Create `phone_tun2socks.te`:

```selinux
module phone_tun2socks 1.1;

require {
    type init_t;
    type tun_tap_device_t;

    attribute port_type;

    class tcp_socket name_connect;
    class chr_file { read write };
}

type phone_proxy_port_t;
typeattribute phone_proxy_port_t port_type;

# Allow outgoing TCP connections to the SOCKS5 proxy port.
allow init_t phone_proxy_port_t:tcp_socket name_connect;

# Allow reading and writing the TUN device.
allow init_t tun_tap_device_t:chr_file { read write };
```

**Note:** This policy applies to the `init_t` domain, not exclusively to the `tun2socks` executable. A dedicated SELinux domain would offer stronger isolation.

### 3. Compile and install

From the directory containing `phone_tun2socks.te`:

```bash
checkmodule -M -m \
    -o phone_tun2socks.mod \
    phone_tun2socks.te

semodule_package \
    -o phone_tun2socks.pp \
    -m phone_tun2socks.mod

sudo semodule -i phone_tun2socks.pp
```

The module name and compiled `.mod` filename must match.

### 4. Register the SOCKS5 proxy port

Map TCP port `8228` to the newly defined SELinux port type:

```bash
sudo semanage port -a \
    -t phone_proxy_port_t \
    -p tcp 8228
```

If the port already has a local custom mapping, inspect it before changing it:

```bash
sudo semanage port -l | grep 8228
```

Only TCP is registered because the observed proxy connection denial was for `tcp_socket name_connect`. UDP permissions should be handled separately if actual denials are observed.

### 5. Verify

Confirm the module and port mapping:

```bash
sudo semodule -l | grep phone_tun2socks
sudo semanage port -l | grep phone_proxy_port_t
```

Inspect new SELinux denials:

```bash
sudo ausearch -m AVC,USER_AVC -ts recent -c tun2socks
```

Historical denials remain in the audit logs even after fixing the policy.

Once connectivity has been verified, SELinux can be switched back to enforcing mode if it was temporarily made permissive:

```bash
sudo setenforce 1
getenforce
```

Reconnect to the configured phone Wi-Fi network and verify that the tunnel works under enforcing mode.

### 6. Uninstall the policy

To reverse these changes:

```bash
sudo semanage port -d -p tcp 8228
sudo semodule -r phone_tun2socks
```

Only delete the port mapping if it was created specifically for this configuration.

### Troubleshooting

If additional SELinux denials appear:

```bash
sudo ausearch -m AVC,USER_AVC -ts recent
```

Inspect the source context (`scontext`), target context (`tcontext`), object class (`tclass`), and denied operation before extending the policy.

Avoid disabling SELinux globally or automatically applying every permission suggested by `audit2allow`.

The policy above addresses only the denials observed in this setup. Other installations may require different permissions or SELinux domains.
