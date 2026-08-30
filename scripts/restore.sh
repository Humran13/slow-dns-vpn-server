#!/usr/bin/env bash
# scripts/restore.sh - restore Slow DNS VPN configuration from a backup archive.
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

require_root
require_installed

header "Restore Configuration"

ARCHIVE="${1:-}"
if [[ -z "$ARCHIVE" ]]; then
    mapfile -t backups < <(find "$SLOWDNS_BACKUP_DIR" -maxdepth 1 -name 'slowdns-backup-*.tar.gz' 2>/dev/null | sort -r)
    if [[ "${#backups[@]}" -eq 0 ]]; then
        die "No backups found in ${SLOWDNS_BACKUP_DIR}."
    fi
    echo "Available backups:"
    i=1
    for b in "${backups[@]}"; do
        printf '  %d) %s\n' "$i" "$(basename "$b")"
        ((i++))
    done
    read -r -p "Choose a backup to restore [1-${#backups[@]}]: " sel
    if ! [[ "$sel" =~ ^[0-9]+$ ]] || (( sel < 1 || sel > ${#backups[@]} )); then
        die "Invalid selection."
    fi
    ARCHIVE="${backups[$((sel-1))]}"
fi

[[ -f "$ARCHIVE" ]] || die "Backup file not found: ${ARCHIVE}"

log_info "Validating archive..."
if ! tar -tzf "$ARCHIVE" >/dev/null 2>&1; then
    die "Backup archive failed validation (corrupt or not a tar.gz). Aborting."
fi
if ! tar -tzf "$ARCHIVE" | grep -q '^./server.conf$'; then
    die "Backup archive does not look like a Slow DNS VPN backup (missing server.conf). Aborting."
fi
log_ok "Archive looks valid."

echo
echo "Restoring will overwrite the current Slow DNS configuration, keys, and"
echo "recreate/update Slow DNS user accounts from the backup."
if ! confirm "A safety backup of the CURRENT configuration will be made first. Continue?" n; then
    echo "Cancelled."
    exit 0
fi

log_info "Backing up current configuration before restoring..."
bash "${SCRIPT_DIR}/backup.sh" >/dev/null
log_ok "Safety backup complete."

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
tar -C "$WORK_DIR" -xzf "$ARCHIVE"

log_info "Stopping services for restore..."
systemctl stop "$SLOWDNS_TUNNEL_SERVICE" 2>/dev/null || true
systemctl stop "$SLOWDNS_SSH_SERVICE" 2>/dev/null || true

cp -a "$WORK_DIR/server.conf" "$SLOWDNS_SERVER_CONF"
rm -rf "$SLOWDNS_KEYS_DIR" "$SLOWDNS_SSH_DIR" "$SLOWDNS_USERS_DIR"
cp -a "$WORK_DIR/keys" "$SLOWDNS_KEYS_DIR"
cp -a "$WORK_DIR/ssh" "$SLOWDNS_SSH_DIR"
cp -a "$WORK_DIR/users" "$SLOWDNS_USERS_DIR"
chmod -R go-rwx "$SLOWDNS_KEYS_DIR" "$SLOWDNS_SSH_DIR" "$SLOWDNS_USERS_DIR"
[[ -f "$WORK_DIR/install.state" ]] && cp -a "$WORK_DIR/install.state" "$SLOWDNS_STATE_FILE"

# Re-establish the service-account access model after restore: the tunnel user
# must be able to traverse the config root into its keys, and own the keys
# directory. server.conf and install.state stay root-only.
chown root:"$SLOWDNS_SYSTEM_USER" "$SLOWDNS_CONFIG_DIR"
chmod 0710 "$SLOWDNS_CONFIG_DIR"
chown -R "$SLOWDNS_SYSTEM_USER:$SLOWDNS_SYSTEM_USER" "$SLOWDNS_KEYS_DIR"
chmod 0700 "$SLOWDNS_KEYS_DIR"
chmod 0600 "${SLOWDNS_KEYS_DIR}/server.key"
chmod 0600 "$SLOWDNS_SERVER_CONF"
chmod 0600 "$SLOWDNS_STATE_FILE" 2>/dev/null || true

log_info "Restoring Slow DNS user accounts..."
if ! getent group "$SLOWDNS_VPN_GROUP" &>/dev/null; then
    groupadd --system "$SLOWDNS_VPN_GROUP"
fi
# Only ever touch accounts that are (a) a syntactically valid Slow DNS
# username and (b) actually tracked in this backup's users/ metadata
# directory (the restored SLOWDNS_USERS_DIR, copied into place above). This
# prevents a tampered or malicious archive from creating/overwriting
# unrelated accounts (e.g. "root") via crafted users.passwd/users.shadow
# lines. The archive's shell field is never trusted; nologin is forced.
if [[ -f "$WORK_DIR/users.passwd" ]]; then
    while IFS=: read -r uname _ _uid _gid _ _ _shell; do
        [[ -z "$uname" ]] && continue
        if ! valid_username "$uname" || ! is_slowdns_user "$uname"; then
            log_warn "Skipping untracked/invalid account in backup: '${uname}'"
            continue
        fi
        if ! id "$uname" &>/dev/null; then
            useradd --no-create-home --shell /usr/sbin/nologin -g "$SLOWDNS_VPN_GROUP" "$uname"
        fi
    done < "$WORK_DIR/users.passwd"
fi
if [[ -f "$WORK_DIR/users.shadow" ]]; then
    while IFS=: read -r uname hash _lastchg _min _max _warn _inactive expire _; do
        [[ -z "$uname" ]] && continue
        if ! valid_username "$uname" || ! is_slowdns_user "$uname"; then
            continue
        fi
        id "$uname" &>/dev/null || continue
        usermod -p "$hash" "$uname"
        if [[ -n "$expire" ]]; then
            chage -E "$(date -d "@$(( expire * 86400 ))" +%F)" "$uname"
        else
            chage -E -1 "$uname"
        fi
    done < "$WORK_DIR/users.shadow"
fi

log_info "Validating restored SSH backend configuration..."
if ! /usr/sbin/sshd -t -f "${SLOWDNS_SSH_DIR}/sshd_config"; then
    die "Restored SSH backend configuration failed validation. Not restarting services. Restore your safety backup instead."
fi

systemctl start "$SLOWDNS_SSH_SERVICE"
sleep 1
if ! service_is_active "$SLOWDNS_SSH_SERVICE"; then
    die "${SLOWDNS_SSH_SERVICE} failed to start after restore. Check 'journalctl -u ${SLOWDNS_SSH_SERVICE}'."
fi

systemctl start "$SLOWDNS_TUNNEL_SERVICE"
sleep 1
if ! service_is_active "$SLOWDNS_TUNNEL_SERVICE"; then
    die "${SLOWDNS_TUNNEL_SERVICE} failed to start after restore. Check 'journalctl -u ${SLOWDNS_TUNNEL_SERVICE}'."
fi

log_ok "Restore complete. Both services are running."
