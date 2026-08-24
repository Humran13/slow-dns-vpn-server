#!/usr/bin/env bash
# scripts/dns-config.sh - show and validate the required DNS records.
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

require_root
load_server_conf

header "DNS Configuration"

echo "Add these records at your domain's DNS provider / registrar:"
echo
echo "  A    ${NS_HOSTNAME}    ->  ${PUBLIC_IPV4:-<this server IPv4>}"
echo "  NS   ${TUNNEL_DOMAIN}  ->  ${NS_HOSTNAME}"
echo
echo "The 'A' record lets recursive resolvers find this server. The 'NS' record"
echo "delegates the tunnel zone to it, so DNS queries for names under"
echo "${TUNNEL_DOMAIN} get forwarded here and carry the tunnel data."
echo

if ! command -v dig &>/dev/null && ! command -v host &>/dev/null; then
    log_warn "Neither 'dig' nor 'host' is installed; cannot validate DNS propagation."
    echo "Install dnsutils (apt install dnsutils) to enable this check."
    exit 0
fi

resolve() {
    local name="$1" type="$2"
    if command -v dig &>/dev/null; then
        dig +short "$type" "$name" 2>/dev/null
    else
        host -t "$type" "$name" 2>/dev/null | awk '{print $NF}'
    fi
}

echo "Checking current DNS state..."
echo

A_RESULT="$(resolve "$NS_HOSTNAME" A)"
if [[ -n "$A_RESULT" ]]; then
    echo "  A record for ${NS_HOSTNAME}: ${A_RESULT}"
    if [[ -n "$PUBLIC_IPV4" && "$A_RESULT" != *"$PUBLIC_IPV4"* ]]; then
        log_warn "  This does not match the server's public IPv4 (${PUBLIC_IPV4}). Update it."
    else
        log_ok "  Matches this server's public IPv4."
    fi
else
    log_warn "  No A record found yet for ${NS_HOSTNAME}. DNS may not have propagated."
fi

NS_RESULT="$(resolve "$TUNNEL_DOMAIN" NS)"
if [[ -n "$NS_RESULT" ]]; then
    echo "  NS record for ${TUNNEL_DOMAIN}: ${NS_RESULT}"
    if echo "$NS_RESULT" | grep -qi "${NS_HOSTNAME%.}"; then
        log_ok "  Delegation looks correct."
    else
        log_warn "  Delegation does not point at ${NS_HOSTNAME}. Check your registrar's NS record."
    fi
else
    log_warn "  No NS record found yet for ${TUNNEL_DOMAIN}. DNS may not have propagated."
fi

echo
echo "DNS propagation can take anywhere from a few minutes up to 24-48 hours"
echo "depending on your registrar and previous TTL values."
