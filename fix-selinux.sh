#!/usr/bin/env bash
# Install the local SELinux permissions needed by phone-tun2socks on Fedora.
# Run as root after installing the NetworkManager dispatcher and YAML config.
set -euo pipefail

CONFIG_FILE=${CONFIG_FILE:-/etc/phone-tun2socks/config.yaml}
POLICY_NAME=phone_tun2socks
PORT_TYPE=phone_proxy_port_t

fail() { printf 'Error: %s\n' "$*" >&2; exit 1; }
log()  { printf '%s\n' "$*"; }

[[ $EUID -eq 0 ]] || fail "Run with sudo: sudo ./fix-selinux.sh"
[[ -r "$CONFIG_FILE" ]] || fail "Cannot read YAML configuration: $CONFIG_FILE"

# Tools are normally already installed for the tunnel; install SELinux policy
# utilities if necessary. Do not change the machine's SELinux mode.
missing=0
for tool in yq checkmodule semodule_package semodule semanage restorecon; do
    command -v "$tool" >/dev/null 2>&1 || missing=1
done
if (( missing )); then
    command -v dnf >/dev/null 2>&1 || fail 'Missing required tools; install yq, checkpolicy, policycoreutils, and policycoreutils-python-utils.'
    log 'Installing required Fedora utilities...'
    dnf install -y yq checkpolicy policycoreutils policycoreutils-python-utils
fi

# Read the proxy endpoint from the same YAML file the dispatcher uses.
proxy_url=$(yq -r '.proxy_url // ""' "$CONFIG_FILE")
if [[ $proxy_url =~ ^[[:alpha:]][[:alnum:]+.-]*://[^/:]+:([0-9]+)$ ]]; then
    port=${BASH_REMATCH[1]}
else
    fail "Expected proxy_url: scheme://host:port in $CONFIG_FILE (got '$proxy_url')"
fi
[[ $port =~ ^[0-9]+$ ]] || fail "Invalid port: $port"
port=$((10#$port))
(( port >= 1 && port <= 65535 )) || fail "Proxy port must be 1-65535"

bin=${TUN2SOCKS_BIN:-$(command -v tun2socks || true)}
[[ -n $bin && -f $bin ]] || fail 'tun2socks executable not found; set TUN2SOCKS_BIN=/absolute/path/to/tun2socks'
[[ $bin == /* ]] || fail "tun2socks binary path must be absolute: $bin"

log "Restoring default SELinux labels for $bin and dispatcher..."
restorecon -v "$bin"
if [[ -f /etc/NetworkManager/dispatcher.d/90-phone-tun2socks ]]; then
    restorecon -v /etc/NetworkManager/dispatcher.d/90-phone-tun2socks
fi
if [[ -e /dev/net/tun ]]; then
    restorecon -v /dev/net/tun
fi

# Generate and build the policy in a private scratch directory. The filenames
# intentionally use underscores to match the SELinux module declaration.
tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

cat > "$tmp_dir/$POLICY_NAME.te" <<'POLICY'
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
POLICY

log "Compiling and installing SELinux module $POLICY_NAME..."
checkmodule -M -m -o "$tmp_dir/$POLICY_NAME.mod" "$tmp_dir/$POLICY_NAME.te"
semodule_package -o "$tmp_dir/$POLICY_NAME.pp" -m "$tmp_dir/$POLICY_NAME.mod"
semodule -i "$tmp_dir/$POLICY_NAME.pp"

# semanage -a is not idempotent, so only add the mapping when necessary.
# Refuse to take over a preexisting mapping that belongs to another policy.
if semanage port -l | awk -v port="$port" '
    $1 == "phone_proxy_port_t" && $2 == "tcp" {
        for (i=3; i<=NF; i++) {
            gsub(/,/, "", $i)
            if ($i == port) found=1
        }
    }
    END { exit !found }
'; then
    log "TCP port $port is already mapped to $PORT_TYPE."
else
    log "Mapping TCP port $port to $PORT_TYPE..."
    semanage port -a -t "$PORT_TYPE" -p tcp "$port" ||
        fail "Could not label TCP port $port. Check existing mappings with: semanage port -l | grep '$port'"
fi

log 'SELinux fix installed. SELinux mode has not been changed.'
log 'Reconnect to the phone Wi-Fi and test with: getenforce; curl -4 https://example.com'
