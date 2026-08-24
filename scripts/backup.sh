#!/usr/bin/env bash
# scripts/backup.sh - back up Slow DNS VPN configuration, keys, and user accounts.
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

require_root
require_installed

header "Backup Configuration"

install -d -m 0700 "$SLOWDNS_BACKUP_DIR"

TS="$(date +%Y%m%d-%H%M%S)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

cp -a "$SLOWDNS_SERVER_CONF" "$WORK_DIR/server.conf"
cp -a "$SLOWDNS_KEYS_DIR" "$WORK_DIR/keys"
cp -a "$SLOWDNS_SSH_DIR" "$WORK_DIR/ssh"
cp -a "$SLOWDNS_USERS_DIR" "$WORK_DIR/users"
[[ -f "$SLOWDNS_STATE_FILE" ]] && cp -a "$SLOWDNS_STATE_FILE" "$WORK_DIR/install.state"

# Export only the account lines for users this installer manages - never the
# whole system passwd/shadow/group files.
: > "$WORK_DIR/users.passwd"
: > "$WORK_DIR/users.shadow"
: > "$WORK_DIR/users.group"
while IFS= read -r u; do
    getent passwd "$u" >> "$WORK_DIR/users.passwd" 2>/dev/null || true
    getent shadow "$u" >> "$WORK_DIR/users.shadow" 2>/dev/null || true
done < <(list_slowdns_usernames)
chmod 0600 "$WORK_DIR/users.shadow" "$WORK_DIR/users.passwd"

ARCHIVE="${SLOWDNS_BACKUP_DIR}/slowdns-backup-${TS}.tar.gz"
tar -C "$WORK_DIR" -czf "$ARCHIVE" .
chmod 0600 "$ARCHIVE"

log_ok "Backup created: ${ARCHIVE}"
echo "This archive contains private tunnel/SSH keys and account password hashes."
echo "Store it somewhere safe and do not share it."
