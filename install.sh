#!/bin/sh
set -eu
[ "$(id -u)" -eq 0 ] || { echo 'Run with sudo' >&2; exit 1; }
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
install -d -m 755 /etc/phone-tun2socks /usr/local/libexec /etc/NetworkManager/dispatcher.d
if [ ! -e /etc/phone-tun2socks/config.yaml ]; then
    install -m 644 "$ROOT/config/config.yaml" /etc/phone-tun2socks/config.yaml
fi
install -m 755 "$ROOT/bin/phone-tun2socks" /usr/local/libexec/phone-tun2socks
install -m 755 "$ROOT/bin/phone-tun2socks-dispatcher" /etc/NetworkManager/dispatcher.d/90-phone-tun2socks
install -m 644 "$ROOT/systemd/phone-tun2socks.service" /etc/systemd/system/phone-tun2socks.service
systemctl daemon-reload
echo 'Installed. Edit /etc/phone-tun2socks/config.yaml and reconnect to the phone SSID.'
