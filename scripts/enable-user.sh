#!/usr/bin/env bash
# scripts/enable-user.sh - re-enable a disabled Slow DNS VPN user.
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

require_root
require_installed

header "Enable User"

USERNAME="${1:-}"
if [[ -z "$USERNAME" ]]; then
    USERNAME="$(select_user "Select a user to enable:")" || { echo "No user selected."; exit 0; }
fi

if ! is_slowdns_user "$USERNAME" || ! id "$USERNAME" &>/dev/null; then
    die "'${USERNAME}' is not a Slow DNS user."
fi

usermod -U "$USERNAME"
log_ok "User '${USERNAME}' enabled. Current status: $(user_status "$USERNAME")"
