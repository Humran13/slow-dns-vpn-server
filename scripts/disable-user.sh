#!/usr/bin/env bash
# scripts/disable-user.sh - temporarily disable a Slow DNS VPN user without deleting it.
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

require_root
require_installed

header "Disable User"

USERNAME="${1:-}"
if [[ -z "$USERNAME" ]]; then
    USERNAME="$(select_user "Select a user to disable:")" || { echo "No user selected."; exit 0; }
fi

if ! is_slowdns_user "$USERNAME" || ! id "$USERNAME" &>/dev/null; then
    die "'${USERNAME}' is not a Slow DNS user."
fi

usermod -L "$USERNAME"
log_ok "User '${USERNAME}' disabled. Current status: $(user_status "$USERNAME")"
