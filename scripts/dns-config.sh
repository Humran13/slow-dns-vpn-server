#!/usr/bin/env bash
# scripts/dns-config.sh - show and validate the required DNS records.
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

require_root
load_server_conf

header "DNS Configuration"

# Relative Host/Name examples, derived only when they can be computed without
# guessing the DNS provider's zone (strip the exact base domain the user
# entered). Fall back to full names only otherwise.
NS_RELATIVE="" TUNNEL_RELATIVE=""
if [[ "$NS_HOSTNAME" == *".${BASE_DOMAIN}" ]]; then
    NS_RELATIVE="${NS_HOSTNAME%.${BASE_DOMAIN}}"
fi
if [[ "$TUNNEL_DOMAIN" == *".${BASE_DOMAIN}" ]]; then
    TUNNEL_RELATIVE="${TUNNEL_DOMAIN%.${BASE_DOMAIN}}"
fi

header "DNS Configuration"

echo "The two DNS records you need at your domain's DNS provider:"
echo
echo "  A    ${NS_HOSTNAME}    ->  ${PUBLIC_IPV4:-<this server IPv4>}"
echo "  NS   ${TUNNEL_DOMAIN}  ->  ${NS_HOSTNAME}"
echo
echo "If your provider automatically appends '${BASE_DOMAIN}' to the Host/Name"
echo "field, enter the relative part instead of the full hostname:"
echo
printf '  A    Type=A  Host/Name: %s  Value: %s   (creates %s)\n' \
    "${NS_RELATIVE:-<full name>}" "${PUBLIC_IPV4:-<this server IPv4>}" "$NS_HOSTNAME"
printf '  NS   Type=NS  Host/Name: %s  Value: %s   (creates %s)\n' \
    "${TUNNEL_RELATIVE:-<full name>}" "$NS_HOSTNAME" "$TUNNEL_DOMAIN"
echo
echo "IMPORTANT: if your provider appends the domain, do NOT paste the full"
echo "hostname into Host/Name or you may create something wrong like"
echo "${NS_HOSTNAME}.${BASE_DOMAIN}. If your provider wants full hostnames,"
echo "use the full names shown above."
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
    log_warn "  A record not found for ${NS_HOSTNAME}."
    echo "  Expected value    : ${PUBLIC_IPV4:-<this server IPv4>}"
    echo "  Expected full name: ${NS_HOSTNAME}"
    if [[ -n "$NS_RELATIVE" ]]; then
        echo "  Host/Name (if your provider appends '${BASE_DOMAIN}'): ${NS_RELATIVE}"
    fi
    echo "  (DNS may simply not have propagated yet.)"
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
    log_warn "  NS record not found for ${TUNNEL_DOMAIN}."
    echo "  Expected target   : ${NS_HOSTNAME}"
    echo "  Expected full name: ${TUNNEL_DOMAIN}"
    if [[ -n "$TUNNEL_RELATIVE" ]]; then
        echo "  Host/Name (if your provider appends '${BASE_DOMAIN}'): ${TUNNEL_RELATIVE}"
    fi
    echo "  (DNS may simply not have propagated yet.)"
fi

echo
echo "DNS propagation can take anywhere from a few minutes up to 24-48 hours"
echo "depending on your registrar and previous TTL values."
