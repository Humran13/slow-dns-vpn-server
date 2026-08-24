#!/usr/bin/env bash
# scripts/set-expiry.sh - set, extend, or remove a Slow DNS VPN user's expiry.
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

require_root
require_installed

header "Set User Expiry"

USERNAME="${1:-}"
if [[ -z "$USERNAME" ]]; then
    USERNAME="$(select_user "Select a user:")" || { echo "No user selected."; exit 0; }
fi

if ! is_slowdns_user "$USERNAME" || ! id "$USERNAME" &>/dev/null; then
    die "'${USERNAME}' is not a Slow DNS user."
fi

echo "Current expiry: $(user_expiry_human "$USERNAME")"
echo
echo "  1) 1 day from now"
echo "  2) 7 days from now"
echo "  3) 30 days from now"
echo "  4) 90 days from now"
echo "  5) Custom date (YYYY-MM-DD)"
echo "  6) No expiry"
while true; do
    read -r -p "Choose an option [1-6]: " choice
    case "$choice" in
        1) chage -E "$(date -d '+1 day' +%F)" "$USERNAME"; break ;;
        2) chage -E "$(date -d '+7 days' +%F)" "$USERNAME"; break ;;
        3) chage -E "$(date -d '+30 days' +%F)" "$USERNAME"; break ;;
        4) chage -E "$(date -d '+90 days' +%F)" "$USERNAME"; break ;;
        5)
            read -r -p "Enter expiry date (YYYY-MM-DD): " d
            if ! date -d "$d" &>/dev/null; then
                log_warn "Invalid date."
                continue
            fi
            chage -E "$d" "$USERNAME"
            break
            ;;
        6) chage -E -1 "$USERNAME"; break ;;
        *) log_warn "Invalid choice." ;;
    esac
done

log_ok "New expiry: $(user_expiry_human "$USERNAME")"
