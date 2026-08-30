#!/usr/bin/env bash
# scripts/dns-config.sh - show and validate the required DNS records.
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

require_root
load_server_conf

# Backward compatibility: old installs predate the DNS_ZONE setting. Ask the
# administrator which DNS zone they manage (validated, then stored so this is
# a one-time question).
if [[ -z "${DNS_ZONE:-}" ]]; then
    echo
    log_warn "This installation predates the 'DNS zone' setting."
    while true; do
        read -r -p "Managed DNS zone (must contain ${BASE_DOMAIN}) [${BASE_DOMAIN}]: " input
        DNS_ZONE="${input:-$BASE_DOMAIN}"
        DNS_ZONE="${DNS_ZONE,,}"
        if valid_dns_zone_for_base "$DNS_ZONE" "$BASE_DOMAIN"; then
            break
        fi
        log_warn "'${DNS_ZONE}' does not contain '${BASE_DOMAIN}'. Try again (e.g. mydomain.com)."
    done
    conf_set DNS_ZONE "$DNS_ZONE"
fi

# Relative Host/Name values, derived from the managed zone (never by guessing
# from label counts).
NS_RELATIVE="" TUNNEL_RELATIVE=""
if [[ -n "$DNS_ZONE" && "$NS_HOSTNAME" == *".${DNS_ZONE}" ]]; then
    NS_RELATIVE="${NS_HOSTNAME%.${DNS_ZONE}}"
fi
if [[ -n "$DNS_ZONE" && "$TUNNEL_DOMAIN" == *".${DNS_ZONE}" ]]; then
    TUNNEL_RELATIVE="${TUNNEL_DOMAIN%.${DNS_ZONE}}"
fi

header "DNS Configuration"

echo "The two DNS records you need at your domain's DNS provider:"
echo
echo "  Managed DNS zone : ${DNS_ZONE}"
echo "  Slow DNS base    : ${BASE_DOMAIN}"
echo
echo "Most providers append the managed zone to the Host/Name field, so enter"
echo "the relative Host/Name below (use the full name if yours requires it):"
echo
printf '  A    Type=A  Host/Name: %s  Value: %s   (full name: %s)\n' \
    "${NS_RELATIVE:-<full name>}" "${PUBLIC_IPV4:-<this server IPv4>}" "$NS_HOSTNAME"
printf '  NS   Type=NS  Host/Name: %s  Value: %s   (full name: %s)\n' \
    "${TUNNEL_RELATIVE:-<full name>}" "$NS_HOSTNAME" "$TUNNEL_DOMAIN"
echo
echo "IMPORTANT: if your provider appends '${DNS_ZONE}' automatically, do NOT"
echo "paste the full hostname into Host/Name, or you may create something wrong"
echo "like ${NS_HOSTNAME}.${DNS_ZONE}."
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
    log_warn "  A record not found."
    echo "  Type              : A"
    echo "  Host / Name       : ${NS_RELATIVE:-<full name>}"
    echo "  Value / Target    : ${PUBLIC_IPV4:-<this server IPv4>}"
    echo "  Expected full name: ${NS_HOSTNAME}"
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
    log_warn "  NS record not found."
    echo "  Type              : NS"
    echo "  Host / Name       : ${TUNNEL_RELATIVE:-<full name>}"
    echo "  Value / Target    : ${NS_HOSTNAME}"
    echo "  Expected full name: ${TUNNEL_DOMAIN}"
    echo "  (DNS may simply not have propagated yet.)"
fi

echo
echo "DNS propagation can take anywhere from a few minutes up to 24-48 hours"
echo "depending on your registrar and previous TTL values."
