#!/usr/bin/env bash
# scripts/show-user.sh - show details for one Slow DNS VPN user.
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

require_root
load_server_conf

header "Show User"

USERNAME="${1:-}"
if [[ -z "$USERNAME" ]]; then
    USERNAME="$(select_user "Select a user to view:")" || { echo "No user selected."; exit 0; }
fi

if ! is_slowdns_user "$USERNAME" || ! id "$USERNAME" &>/dev/null; then
    die "'${USERNAME}' is not a Slow DNS user."
fi

status="$(user_status "$USERNAME")"
case "$status" in
    active)   status_label="Active" ;;
    disabled) status_label="Disabled" ;;
    expired)  status_label="Expired" ;;
    *)        status_label="$status" ;;
esac

echo "Username         : ${USERNAME}"
echo "Status           : ${status_label}"
echo "Created          : $(user_created_human "$USERNAME")"
echo "Expires          : $(user_expiry_human "$USERNAME")"
echo
echo "Server IPv4      : ${PUBLIC_IPV4:-unknown}"
echo "Slow DNS domain  : ${TUNNEL_DOMAIN}"
echo "Nameserver       : ${NS_HOSTNAME}"
echo "Server Public Key: $(cat "${SLOWDNS_KEYS_DIR}/server.pub" 2>/dev/null || echo unknown)"
echo
echo "(Password hashes are never displayed. Use 'Change User Password' to reset it.)"
