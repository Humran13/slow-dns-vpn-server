#!/usr/bin/env bash
#
# uninstall.sh - cleanly remove everything this installer created.
#
# Never touches unrelated VPS services, users, firewall rules, or packages.
#
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

require_root

# Re-exec from a temp copy if we're running from the live install directory,
# so we can safely delete that directory during this same run.
if [[ "$SCRIPT_DIR" == "$SLOWDNS_INSTALL_DIR" && "${SLOWDNS_UNINSTALL_REEXEC:-0}" != "1" ]]; then
    TMP_COPY="$(mktemp -d /tmp/slowdns-uninstall.XXXXXX)"
    cp -a "${SCRIPT_DIR}/." "${TMP_COPY}/"
    export SLOWDNS_UNINSTALL_REEXEC=1
    exec bash "${TMP_COPY}/uninstall.sh" "$@"
fi
if [[ "${SLOWDNS_UNINSTALL_REEXEC:-0}" == "1" ]]; then
    trap 'rm -rf "$SCRIPT_DIR"' EXIT
fi

header "Uninstall Slow DNS VPN Server"

if [[ ! -f "$SLOWDNS_SERVER_CONF" ]]; then
    log_warn "No installation found at ${SLOWDNS_CONFIG_DIR}. Nothing to do."
    exit 0
fi

mapfile -t VPN_USERS < <(list_slowdns_usernames)
mapfile -t UFW_RULES < <(state_list_prefix "UFW_RULE")
mapfile -t SYSTEMD_UNITS < <(state_list_prefix "SYSTEMD_UNIT")
mapfile -t TRACKED_PKGS < <(state_list_prefix "PKG")

cat <<EOF
This will remove:

  - Slow DNS tunnel service and its systemd units:
$(printf '      %s\n' "${SYSTEMD_UNITS[@]}")
  - Slow DNS configuration, tunnel keys, and SSH backend host keys
    (${SLOWDNS_CONFIG_DIR})
  - Firewall rules added by this installer:
$(if [[ "${#UFW_RULES[@]}" -gt 0 ]]; then printf '      %s\n' "${UFW_RULES[@]}"; else echo "      (none)"; fi)
  - The 'slowdns' management command
  - The dedicated service account (${SLOWDNS_SYSTEM_USER}) and group (${SLOWDNS_VPN_GROUP})
  - The installed program files (${SLOWDNS_INSTALL_DIR})

Slow DNS user accounts on this system (${#VPN_USERS[@]}):
$(if [[ "${#VPN_USERS[@]}" -gt 0 ]]; then printf '      %s\n' "${VPN_USERS[@]}"; else echo "      (none)"; fi)
  You will be asked separately whether to remove these.

Packages installed by this installer were left in place (not removed, since
other software on this VPS may depend on them):
$(if [[ "${#TRACKED_PKGS[@]}" -gt 0 ]]; then printf '      %s\n' "${TRACKED_PKGS[@]}"; else echo "      (none tracked)"; fi)

Existing unrelated VPS applications, users, and firewall rules will NOT be
removed.
EOF
echo

if ! confirm "Continue?" n; then
    echo "Aborted."
    exit 0
fi

REMOVE_USERS=0
if [[ "${#VPN_USERS[@]}" -gt 0 ]]; then
    if confirm "Also remove the ${#VPN_USERS[@]} Slow DNS user account(s) listed above?" n; then
        REMOVE_USERS=1
    fi
fi

if confirm "Create a final backup before removing anything?" y; then
    bash "${SCRIPT_DIR}/scripts/backup.sh" || log_warn "Backup failed; continuing with uninstall."
fi

header "Removing Services"

for svc in "$SLOWDNS_TUNNEL_SERVICE" "$SLOWDNS_SSH_SERVICE"; do
    systemctl stop "$svc" 2>/dev/null || true
    systemctl disable "$svc" 2>/dev/null || true
    rm -f "/etc/systemd/system/${svc}"
    state_remove "SYSTEMD_UNIT:${svc}"
done
systemctl daemon-reload
log_ok "Services stopped, disabled, and units removed."

header "Removing Firewall Rules"

if command -v ufw &>/dev/null; then
    for rule in "${UFW_RULES[@]}"; do
        ufw delete allow "$rule" 2>/dev/null || true
        state_remove "UFW_RULE:${rule}"
    done
    log_ok "Firewall rules removed."
else
    log_info "UFW not present; nothing to remove."
fi

if [[ "$REMOVE_USERS" -eq 1 ]]; then
    header "Removing Slow DNS User Accounts"
    for u in "${VPN_USERS[@]}"; do
        if id "$u" &>/dev/null; then
            userdel "$u" 2>/dev/null || log_warn "Could not remove user ${u}."
        fi
    done
    log_ok "Slow DNS user accounts removed."
else
    log_info "Slow DNS user accounts were left in place."
fi

header "Removing Service Account"

if id "$SLOWDNS_SYSTEM_USER" &>/dev/null; then
    userdel "$SLOWDNS_SYSTEM_USER" 2>/dev/null || true
    state_remove "USER:${SLOWDNS_SYSTEM_USER}"
fi
if getent group "$SLOWDNS_VPN_GROUP" &>/dev/null; then
    groupdel "$SLOWDNS_VPN_GROUP" 2>/dev/null || log_warn "Could not remove group ${SLOWDNS_VPN_GROUP} (still in use by a remaining user?)."
    state_remove "GROUP:${SLOWDNS_VPN_GROUP}"
fi
log_ok "Service account cleanup done."

header "Removing Files"

rm -f /usr/local/bin/slowdns
state_remove "FILE:/usr/local/bin/slowdns"
rm -rf "$SLOWDNS_CONFIG_DIR"
log_ok "Removed ${SLOWDNS_CONFIG_DIR} and /usr/local/bin/slowdns"

log_info "Removing installed program files (${SLOWDNS_INSTALL_DIR})..."
rm -rf "$SLOWDNS_INSTALL_DIR"

header "Uninstall Complete"
echo "Slow DNS VPN Server has been removed from this system."
if [[ "${#TRACKED_PKGS[@]}" -gt 0 ]]; then
    echo "The following packages were left installed: ${TRACKED_PKGS[*]}"
fi
