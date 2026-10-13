#!/bin/sh
set -eu

if [ "$(id -u)" -ne 0 ]; then
    echo "Run with sudo: sudo ./scripts/install.sh" >&2
    exit 1
fi

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
PY=/usr/bin/python3
"$PY" -c 'import yaml' || {
    echo 'Missing PyYAML. On Fedora: sudo dnf install python3-pyyaml' >&2
    exit 1
}
for cmd in nmcli ip systemctl; do
    command -v "$cmd" >/dev/null || { echo "Missing $cmd" >&2; exit 1; }
done

install -d -m 755 /usr/local/libexec/phone-tun2socks /etc/phone-tun2socks /etc/NetworkManager/dispatcher.d
install -m 755 "$ROOT/src/phone_tun2socks.py" /usr/local/libexec/phone-tun2socks/phone_tun2socks.py
install -m 644 "$ROOT/systemd/phone-tun2socks.service" /etc/systemd/system/phone-tun2socks.service
install -m 755 "$ROOT/networkmanager/90-phone-tunnel" /etc/NetworkManager/dispatcher.d/90-phone-tunnel
if [ ! -e /etc/phone-tun2socks/config.yaml ]; then
    install -m 600 "$ROOT/config/config.yaml" /etc/phone-tun2socks/config.yaml
    echo 'Installed initial /etc/phone-tun2socks/config.yaml; edit it before connecting.'
else
    echo 'Preserved existing /etc/phone-tun2socks/config.yaml.'
fi
systemctl daemon-reload
printf '\nInstalled. Edit /etc/phone-tun2socks/config.yaml and connect to the target SSID.\n'
printf 'The service is triggered by NetworkManager; do not enable it at boot.\n'
