#!/usr/bin/env bash
# scripts/remove-user.sh - delete one Slow DNS VPN user.
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

require_root
require_installed

header "Remove User"

USERNAME="${1:-}"
if [[ -z "$USERNAME" ]]; then
    USERNAME="$(select_user "Select a user to remove:")" || { echo "No user selected."; exit 0; }
fi

if ! is_slowdns_user "$USERNAME"; then
    die "'${USERNAME}' is not a Slow DNS user managed by this installer."
fi

if ! confirm "Delete Slow DNS user \"${USERNAME}\"?" n; then
    echo "Cancelled."
    exit 0
fi

if id "$USERNAME" &>/dev/null; then
    userdel "$USERNAME"
fi
rm -f "${SLOWDNS_USERS_DIR}/${USERNAME}.conf"

log_ok "User '${USERNAME}' removed."
