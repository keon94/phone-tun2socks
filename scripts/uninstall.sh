#!/bin/sh
set -eu
[ "$(id -u)" -eq 0 ] || { echo 'Run with sudo' >&2; exit 1; }
systemctl stop phone-tun2socks.service 2>/dev/null || true
rm -f /etc/NetworkManager/dispatcher.d/90-phone-tunnel
rm -f /etc/systemd/system/phone-tun2socks.service
rm -f /usr/local/libexec/phone-tun2socks/phone_tun2socks.py
rmdir /usr/local/libexec/phone-tun2socks 2>/dev/null || true
systemctl daemon-reload
echo 'Uninstalled. Preserved /etc/phone-tun2socks/config.yaml.'
