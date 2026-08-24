#!/usr/bin/env bash
# scripts/list-users.sh - print a table of all Slow DNS VPN users.
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

require_root
require_installed

header "Slow DNS Users"

install -d -m 0700 "$SLOWDNS_USERS_DIR"
mapfile -t users < <(find "$SLOWDNS_USERS_DIR" -maxdepth 1 -name '*.conf' -printf '%f\n' 2>/dev/null | sed 's/\.conf$//' | sort)

if [[ "${#users[@]}" -eq 0 ]]; then
    echo "No Slow DNS users have been created yet."
    exit 0
fi

printf '%-16s %-10s %-12s\n' "USERNAME" "STATUS" "EXPIRES"
printf '%s\n' "----------------------------------------------"
for u in "${users[@]}"; do
    if ! id "$u" &>/dev/null; then
        printf '%-16s %-10s %-12s\n' "$u" "MISSING" "-"
        continue
    fi
    status="$(user_status "$u")"
    case "$status" in
        active)   status_label="Active" ;;
        disabled) status_label="Disabled" ;;
        expired)  status_label="Expired" ;;
        *)        status_label="$status" ;;
    esac
    expiry="$(user_expiry_human "$u")"
    printf '%-16s %-10s %-12s\n' "$u" "$status_label" "$expiry"
done
