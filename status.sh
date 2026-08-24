#!/usr/bin/env bash
#
# status.sh - report the real, live status of the Slow DNS VPN server.
#
# Every check here inspects an actual process, socket, or systemd unit state.
# Nothing is reported as running merely because a config file exists.
#
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

require_root
require_installed
load_server_conf

header "Slow DNS Server Status"

if service_is_active "$SLOWDNS_TUNNEL_SERVICE"; then
    echo "Slow DNS Tunnel Service : ${C_GREEN}RUNNING${C_RESET}"
else
    echo "Slow DNS Tunnel Service : ${C_RED}STOPPED${C_RESET}"
fi

if service_is_active "$SLOWDNS_SSH_SERVICE"; then
    echo "SSH Backend Service     : ${C_GREEN}RUNNING${C_RESET}"
else
    echo "SSH Backend Service     : ${C_RED}STOPPED${C_RESET}"
fi

if ss -uln 2>/dev/null | grep -q ":${DNS_UDP_PORT} "; then
    echo "DNS Tunnel Listening    : ${C_GREEN}YES (UDP/${DNS_UDP_PORT})${C_RESET}"
else
    echo "DNS Tunnel Listening    : ${C_RED}NO${C_RESET}"
fi

if ss -tln 2>/dev/null | grep -q "127.0.0.1:${SSH_TUNNEL_PORT} "; then
    echo "SSH Backend Listening   : ${C_GREEN}YES (127.0.0.1:${SSH_TUNNEL_PORT})${C_RESET}"
else
    echo "SSH Backend Listening   : ${C_RED}NO${C_RESET}"
fi

echo "IP Forwarding           : Not required (dnstt + SSH SOCKS is application-layer, no routed VPN)"

echo "Public IPv4             : ${PUBLIC_IPV4:-unknown}"
echo "Tunnel Domain            : ${TUNNEL_DOMAIN}"
echo "Nameserver Hostname      : ${NS_HOSTNAME}"

TOTAL=0 ACTIVE=0 DISABLED=0 EXPIRED=0
while IFS= read -r u; do
    [[ -z "$u" ]] && continue
    TOTAL=$((TOTAL+1))
    case "$(user_status "$u")" in
        active)   ACTIVE=$((ACTIVE+1)) ;;
        disabled) DISABLED=$((DISABLED+1)) ;;
        expired)  EXPIRED=$((EXPIRED+1)) ;;
    esac
done < <(list_slowdns_usernames)

echo "Users                    : ${TOTAL}"
echo "Active Users             : ${ACTIVE}"
echo "Disabled Users           : ${DISABLED}"
echo "Expired Users            : ${EXPIRED}"

DISK_USAGE="$(df -h "$SLOWDNS_CONFIG_DIR" 2>/dev/null | awk 'NR==2{print $5" used on "$6}' || true)"
echo "Disk Usage (config vol)  : ${DISK_USAGE:-unknown}"
echo
