#!/usr/bin/env bash
# scripts/connection-details.sh - print everything a client needs to connect.
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

require_root
load_server_conf

header "Client Connection Details"

PUBKEY="$(cat "${SLOWDNS_KEYS_DIR}/server.pub" 2>/dev/null || echo unknown)"

echo "Server Public IPv4   : ${PUBLIC_IPV4:-unknown}"
echo "Slow DNS Tunnel Host : ${TUNNEL_DOMAIN}"
echo "Nameserver Hostname  : ${NS_HOSTNAME}"
echo "Server Public Key    : ${PUBKEY}"
echo "DNS UDP Port         : ${DNS_UDP_PORT}"
if [[ "$DNS_TCP_ENABLED" == "true" ]]; then
    echo "DNS TCP Port         : ${DNS_UDP_PORT} (fallback enabled)"
fi
echo
echo "On the client, dnstt-client (or a compatible SlowDNS client app) is used"
echo "to open a local TCP port that tunnels to this server's SSH backend, e.g.:"
echo
echo "  dnstt-client -udp ${NS_HOSTNAME} -pubkey ${PUBKEY} ${TUNNEL_DOMAIN} 127.0.0.1:7000"
echo
echo "Then the client makes an SSH connection through that local port to"
echo "authenticate as a Slow DNS user, e.g.:"
echo
echo "  ssh -p 7000 -o HostKeyAlias=slowdns -D 1080 <username>@127.0.0.1"
echo
echo "The resulting SOCKS proxy on 127.0.0.1:1080 (client side) is what apps"
echo "should be pointed at for internet access through the tunnel."
echo

if confirm "Show details for a specific user (username to authenticate with)?" n; then
    USERNAME="$(select_user "Select a user:")" || true
    if [[ -n "${USERNAME:-}" ]]; then
        echo
        echo "Username : ${USERNAME}"
        echo "Status   : $(user_status "$USERNAME")"
        echo "Expires  : $(user_expiry_human "$USERNAME")"
        echo "(Password is known only to the administrator/user who set it.)"
    fi
fi
