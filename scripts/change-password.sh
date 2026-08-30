#!/usr/bin/env bash
# scripts/change-password.sh - change a Slow DNS VPN user's password.
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

require_root
require_installed

header "Change User Password"

USERNAME="${1:-}"
if [[ -z "$USERNAME" ]]; then
    USERNAME="$(select_user "Select a user:")" || { echo "No user selected."; exit 0; }
fi

if ! is_slowdns_user "$USERNAME" || ! id "$USERNAME" &>/dev/null; then
    die "'${USERNAME}' is not a Slow DNS user."
fi

PASSWORD=""
if confirm "Auto-generate a new secure random password?" y; then
    # Finite read from /dev/urandom converted to hex: od reads exactly 12 bytes
    # and exits normally, so no SIGPIPE can kill an upstream producer the way
    # `tr -dc ... </dev/urandom | head -c 16` does under `set -o pipefail`.
    PASSWORD="$(od -An -v -N 12 -tx1 /dev/urandom | tr -cd '[:xdigit:]')"
    echo "${USERNAME}:${PASSWORD}" | chpasswd
    log_ok "Password changed."
    echo "New password: ${PASSWORD}   (shown once - save it now)"
else
    while true; do
        read -r -s -p "New password (min 8 characters): " PASSWORD
        echo
        if ! valid_password "$PASSWORD"; then
            log_warn "Password must be at least 8 characters."
            continue
        fi
        read -r -s -p "Confirm password: " PASSWORD_CONFIRM
        echo
        if [[ "$PASSWORD" != "$PASSWORD_CONFIRM" ]]; then
            log_warn "Passwords do not match. Try again."
            continue
        fi
        break
    done
    echo "${USERNAME}:${PASSWORD}" | chpasswd
    log_ok "Password changed for '${USERNAME}'."
fi
