#!/usr/bin/env bash
# Shared library for slow-dns-vpn-server scripts.
# Sourced by install.sh, manager.sh, status.sh, uninstall.sh and scripts/*.sh.
# Not meant to be executed directly.

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
SLOWDNS_INSTALL_DIR="/opt/slow-dns-vpn"
SLOWDNS_CONFIG_DIR="/etc/slow-dns-vpn"
SLOWDNS_SERVER_CONF="${SLOWDNS_CONFIG_DIR}/server.conf"
SLOWDNS_STATE_FILE="${SLOWDNS_CONFIG_DIR}/install.state"
SLOWDNS_USERS_DIR="${SLOWDNS_CONFIG_DIR}/users"
SLOWDNS_KEYS_DIR="${SLOWDNS_CONFIG_DIR}/keys"
SLOWDNS_SSH_DIR="${SLOWDNS_CONFIG_DIR}/ssh"
SLOWDNS_BIN_DIR="${SLOWDNS_INSTALL_DIR}/bin"
SLOWDNS_BUILD_DIR="${SLOWDNS_INSTALL_DIR}/build"
SLOWDNS_BACKUP_DIR="/var/backups/slow-dns-vpn"
SLOWDNS_LOG_TAG="slowdns"

SLOWDNS_TUNNEL_SERVICE="slowdns-tunnel.service"
SLOWDNS_SSH_SERVICE="slowdns-ssh.service"

SLOWDNS_SYSTEM_USER="slowdns"
SLOWDNS_VPN_GROUP="slowdnsusers"

# Pinned upstream versions (see README "Credits" section for rationale).
DNSTT_GIT_URL="https://www.bamsoftware.com/git/dnstt.git"
DNSTT_TAG="v1.20260501.0"
# The checked-out commit that refs/tags/v1.20260501.0 resolves to (the peeled
# ^{} commit, NOT the annotated tag-object hash). Verified against upstream
# with: git ls-remote --tags https://www.bamsoftware.com/git/dnstt.git
DNSTT_COMMIT="0c5c52a57d899c05428c116898941761a2ed83c2"

GO_VERSION="1.27.0"
GO_SHA256_AMD64="675c26c449cbb18fc24b74650de1eabbae6e16f64326fd85a283fb3b58280685"
GO_SHA256_ARM64="51798d2c42d0e1c6ed7fd9f48728b4193abac9e8aad6dbac2fe96a81f5909bda"

# ---------------------------------------------------------------------------
# Colors / output helpers
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
    C_RED=$'\033[0;31m'; C_GREEN=$'\033[0;32m'; C_YELLOW=$'\033[0;33m'
    C_BLUE=$'\033[0;34m'; C_BOLD=$'\033[1m'; C_RESET=$'\033[0m'
else
    C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_BOLD=""; C_RESET=""
fi

log_info() { printf '%s[*]%s %s\n' "${C_BLUE}" "${C_RESET}" "$*"; }
log_ok()   { printf '%s[OK]%s %s\n' "${C_GREEN}" "${C_RESET}" "$*"; }
log_warn() { printf '%s[!]%s %s\n' "${C_YELLOW}" "${C_RESET}" "$*" >&2; }
log_err()  { printf '%s[ERROR]%s %s\n' "${C_RED}" "${C_RESET}" "$*" >&2; }
die()      { log_err "$*"; exit 1; }

header() {
    printf '\n%s========================================%s\n' "${C_BOLD}" "${C_RESET}"
    printf '%s %s%s\n' "${C_BOLD}" "$*" "${C_RESET}"
    printf '%s========================================%s\n\n' "${C_BOLD}" "${C_RESET}"
}

# confirm "Question?" [default(y|n)] -> returns 0 for yes, 1 for no
confirm() {
    local prompt="$1" default="${2:-n}" reply suffix
    if [[ "$default" == "y" ]]; then suffix="[Y/n]"; else suffix="[y/N]"; fi
    read -r -p "$prompt $suffix " reply || reply=""
    reply="${reply,,}"
    if [[ -z "$reply" ]]; then reply="$default"; fi
    [[ "$reply" == "y" || "$reply" == "yes" ]]
}

press_enter() {
    read -r -p "Press Enter to continue..." _ || true
}

# ---------------------------------------------------------------------------
# Privilege / environment checks
# ---------------------------------------------------------------------------
require_root() {
    if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
        die "This must be run as root. Try: sudo bash $0"
    fi
}

require_installed() {
    if [[ ! -f "$SLOWDNS_SERVER_CONF" ]]; then
        die "Slow DNS VPN does not appear to be installed (missing $SLOWDNS_SERVER_CONF). Run install.sh first."
    fi
}

# ---------------------------------------------------------------------------
# OS detection
# ---------------------------------------------------------------------------
# Sets: OS_ID, OS_VERSION_ID, OS_PRETTY, OS_SUPPORTED (0/1), OS_LEGACY (0/1)
detect_os() {
    OS_ID=""; OS_VERSION_ID=""; OS_PRETTY=""; OS_SUPPORTED=0; OS_LEGACY=0

    if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        source /etc/os-release
        OS_ID="${ID:-}"
        OS_VERSION_ID="${VERSION_ID:-}"
        OS_PRETTY="${PRETTY_NAME:-$OS_ID $OS_VERSION_ID}"
    fi

    if [[ "$OS_ID" != "ubuntu" ]]; then
        OS_SUPPORTED=0
        return
    fi

    case "$OS_VERSION_ID" in
        18.04|20.04)
            OS_SUPPORTED=1
            OS_LEGACY=1
            ;;
        22.04|24.04|26.04)
            OS_SUPPORTED=1
            OS_LEGACY=0
            ;;
        *)
            OS_SUPPORTED=0
            ;;
    esac
}

print_unsupported_os() {
    cat <<EOF

Unsupported operating system: ${OS_PRETTY:-unknown}

Supported:
  Ubuntu 18.04 LTS (legacy)
  Ubuntu 20.04 LTS (legacy)
  Ubuntu 22.04 LTS
  Ubuntu 24.04 LTS
  Ubuntu 26.04 LTS

EOF
}

# Sets: ARCH_DEB (amd64/arm64), GO_ARCH (amd64/arm64), GO_SHA256
detect_arch() {
    local machine
    machine="$(uname -m)"
    case "$machine" in
        x86_64|amd64)
            ARCH_DEB="amd64"; GO_ARCH="amd64"; GO_SHA256="$GO_SHA256_AMD64" ;;
        aarch64|arm64)
            ARCH_DEB="arm64"; GO_ARCH="arm64"; GO_SHA256="$GO_SHA256_ARM64" ;;
        *)
            die "Unsupported CPU architecture: $machine (only x86_64/amd64 and aarch64/arm64 are supported)" ;;
    esac
}

# ---------------------------------------------------------------------------
# Install-state tracking (used by uninstall.sh / repair.sh)
# Format: one "TYPE:VALUE" line per created resource. Deduplicated on write.
# ---------------------------------------------------------------------------
state_add() {
    local entry="$1"
    mkdir -p "$(dirname "$SLOWDNS_STATE_FILE")"
    touch "$SLOWDNS_STATE_FILE"
    if ! grep -qxF "$entry" "$SLOWDNS_STATE_FILE" 2>/dev/null; then
        echo "$entry" >> "$SLOWDNS_STATE_FILE"
    fi
}

state_has() {
    local entry="$1"
    [[ -f "$SLOWDNS_STATE_FILE" ]] && grep -qxF "$entry" "$SLOWDNS_STATE_FILE" 2>/dev/null
}

state_remove() {
    local entry="$1"
    [[ -f "$SLOWDNS_STATE_FILE" ]] || return 0
    grep -vxF "$entry" "$SLOWDNS_STATE_FILE" > "${SLOWDNS_STATE_FILE}.tmp" 2>/dev/null || true
    mv "${SLOWDNS_STATE_FILE}.tmp" "$SLOWDNS_STATE_FILE"
}

state_list_prefix() {
    local prefix="$1"
    [[ -f "$SLOWDNS_STATE_FILE" ]] || return 0
    grep "^${prefix}:" "$SLOWDNS_STATE_FILE" 2>/dev/null | sed "s/^${prefix}://"
}

# ---------------------------------------------------------------------------
# server.conf helpers (simple KEY=VALUE file)
# ---------------------------------------------------------------------------
conf_get() {
    local key="$1" default="${2:-}"
    [[ -f "$SLOWDNS_SERVER_CONF" ]] || { echo "$default"; return; }
    local line
    line="$(grep -E "^${key}=" "$SLOWDNS_SERVER_CONF" 2>/dev/null | tail -n1 || true)"
    if [[ -z "$line" ]]; then
        echo "$default"
    else
        echo "${line#*=}"
    fi
}

conf_set() {
    local key="$1" value="$2"
    mkdir -p "$(dirname "$SLOWDNS_SERVER_CONF")"
    touch "$SLOWDNS_SERVER_CONF"
    if grep -qE "^${key}=" "$SLOWDNS_SERVER_CONF" 2>/dev/null; then
        local tmp
        tmp="$(mktemp)"
        awk -F= -v k="$key" -v v="$value" 'BEGIN{OFS="="} $1==k{$0=k"="v} {print}' "$SLOWDNS_SERVER_CONF" > "$tmp"
        mv "$tmp" "$SLOWDNS_SERVER_CONF"
    else
        echo "${key}=${value}" >> "$SLOWDNS_SERVER_CONF"
    fi
}

load_server_conf() {
    require_installed
    BASE_DOMAIN="$(conf_get BASE_DOMAIN)"
    TUNNEL_DOMAIN="$(conf_get TUNNEL_DOMAIN)"
    NS_HOSTNAME="$(conf_get NS_HOSTNAME)"
    PUBLIC_IPV4="$(conf_get PUBLIC_IPV4)"
    DNS_BIND_ADDRESS="$(conf_get DNS_BIND_ADDRESS)"
    DNS_UDP_PORT="$(conf_get DNS_UDP_PORT 53)"
    MTU="$(conf_get MTU 1232)"
    SSH_TUNNEL_PORT="$(conf_get SSH_TUNNEL_PORT 2222)"
    INSTALL_DATE="$(conf_get INSTALL_DATE)"
    LOW_PROFILE_MODE="$(conf_get LOW_PROFILE_MODE false)"
}

# ---------------------------------------------------------------------------
# Networking helpers
# ---------------------------------------------------------------------------
get_public_ipv4() {
    local ip
    ip="$(curl -4 -fsS --max-time 5 https://ifconfig.me 2>/dev/null)" || \
    ip="$(curl -4 -fsS --max-time 5 https://api.ipify.org 2>/dev/null)" || \
    ip="$(ip -4 addr show scope global 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -n1)" || true
    echo "$ip"
}

# ---------------------------------------------------------------------------
# DNS bind address helpers
# ---------------------------------------------------------------------------
# dnstt must bind UDP/<port> only on the address that receives external DNS
# tunnel traffic. Binding to the wildcard address (:port) collides with
# systemd-resolved's loopback listeners on 127.0.0.53:53 / 127.0.0.54:53.
local_ipv4_addresses() {
    ip -4 addr show scope global 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1
}

ip_is_local() {
    local addr="$1" ip
    for ip in $(local_ipv4_addresses); do
        [[ "$ip" == "$addr" ]] && return 0
    done
    return 1
}

get_outbound_ipv4() {
    ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -n1
}

# Echo the local IPv4 address dnstt should bind for external tunnel traffic.
# Prefers the configured public IPv4 when it is actually assigned to a local
# interface; otherwise falls back to the interface address used for outbound
# traffic (covers NAT/cloud VPS where the public IP is not local). Never
# returns a loopback or wildcard address. Exits 1 if nothing is found.
select_dns_bind_address() {
    local public_ip="${1:-}" outbound first
    if [[ -n "$public_ip" ]] && ip_is_local "$public_ip"; then
        echo "$public_ip"
        return 0
    fi
    outbound="$(get_outbound_ipv4)"
    if [[ -n "$outbound" && "$outbound" != 127.* ]]; then
        echo "$outbound"
        return 0
    fi
    first="$(local_ipv4_addresses | head -n1)"
    if [[ -n "$first" && "$first" != 127.* ]]; then
        echo "$first"
        return 0
    fi
    return 1
}

# Print the ss line for any UDP socket that would block binding <addr>:<port>:
# the exact address or a wildcard (0.0.0.0 / * / [::]) on that port.
# Loopback-only listeners (e.g. systemd-resolved's 127.0.0.53:53) are not
# conflicts for a specific non-loopback bind and are intentionally ignored.
find_udp_conflict() {
    local addr="$1" port="$2"
    ss -ulnp 2>/dev/null | awk -v a="$addr" -v p="$port" '
        $4 ~ /^(0\.0\.0\.0|\*|\[::\]):[0-9]+$/ { split($4, x, ":"); if (x[length(x)] == p) { print; exit } }
        $4 == (a ":" p) { print; exit }
    '
}

# ---------------------------------------------------------------------------
# systemd helpers
# ---------------------------------------------------------------------------
service_is_active() {
    systemctl is-active --quiet "$1" 2>/dev/null
}

service_is_enabled() {
    systemctl is-enabled --quiet "$1" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Validation helpers
# ---------------------------------------------------------------------------
# Linux username rules, plus block a short list of dangerous/reserved names.
valid_username() {
    local u="$1"
    [[ "$u" =~ ^[a-z][a-z0-9_-]{2,31}$ ]] || return 1
    case "$u" in
        root|admin|administrator|toor|test|guest|slowdns|daemon|bin|sys|sync|games|man|lp|mail|news|uucp|proxy|www-data|backup|list|irc|gnats|nobody|systemd*|sshd|_apt|messagebus)
            return 1 ;;
    esac
    return 0
}

valid_password() {
    local p="$1"
    [[ ${#p} -ge 8 ]]
}

is_slowdns_user() {
    local u="$1"
    [[ -f "${SLOWDNS_USERS_DIR}/${u}.conf" ]]
}

# echoes: active | disabled | expired
user_status() {
    local u="$1" today epoch_today expiry_days
    if ! id "$u" &>/dev/null; then echo "missing"; return; fi

    local shadow_line lock_flag
    shadow_line="$(getent shadow "$u" 2>/dev/null || true)"
    # Second field of the shadow line is the password hash; its first character
    # is '!' when the account is locked. Pure-bash extraction avoids the old
    # `echo ... | cut ... | head -c1` pipeline, which can trip SIGPIPE and fail
    # the whole command substitution under `set -o pipefail`.
    lock_flag="${shadow_line#*:}"
    lock_flag="${lock_flag%%:*}"
    lock_flag="${lock_flag:0:1}"

    expiry_days="$(echo "$shadow_line" | cut -d: -f8)"
    if [[ -n "$expiry_days" ]]; then
        epoch_today=$(( $(date +%s) / 86400 ))
        if [[ "$expiry_days" -lt "$epoch_today" ]]; then
            echo "expired"
            return
        fi
    fi

    if [[ "$lock_flag" == "!" ]]; then
        echo "disabled"
        return
    fi

    echo "active"
}

user_expiry_human() {
    local u="$1" line
    line="$(chage -l "$u" 2>/dev/null | grep "Account expires" || true)"
    local val="${line#*: }"
    if [[ -z "$val" || "$val" == "never" ]]; then
        echo "Never"
    else
        echo "$val"
    fi
}

list_slowdns_usernames() {
    install -d -m 0700 "$SLOWDNS_USERS_DIR"
    find "$SLOWDNS_USERS_DIR" -maxdepth 1 -name '*.conf' -printf '%f\n' 2>/dev/null | sed 's/\.conf$//' | sort
}

# select_user "Prompt text" -> echoes chosen username, or empty if none chosen.
select_user() {
    local prompt="$1"
    mapfile -t _users < <(list_slowdns_usernames)
    if [[ "${#_users[@]}" -eq 0 ]]; then
        log_warn "No Slow DNS users exist yet."
        return 1
    fi
    echo "$prompt" >&2
    local i=1
    for u in "${_users[@]}"; do
        printf '  %d) %s\n' "$i" "$u" >&2
        ((i++))
    done
    local sel
    read -r -p "Enter number or username: " sel
    if [[ "$sel" =~ ^[0-9]+$ ]] && (( sel >= 1 && sel <= ${#_users[@]} )); then
        echo "${_users[$((sel-1))]}"
        return 0
    fi
    for u in "${_users[@]}"; do
        if [[ "$u" == "$sel" ]]; then
            echo "$u"
            return 0
        fi
    done
    return 1
}

user_created_human() {
    local u="$1" f="${SLOWDNS_USERS_DIR}/${u}.conf"
    [[ -f "$f" ]] || { echo "Unknown"; return; }
    grep -E '^CREATED=' "$f" | tail -n1 | cut -d= -f2-
}
