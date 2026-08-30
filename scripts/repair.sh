#!/usr/bin/env bash
# scripts/repair.sh - detect and fix common problems without touching user accounts.
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

require_root
require_installed
load_server_conf

header "Update / Repair Installation"

ISSUES=0
fix() { log_warn "$1"; ISSUES=$((ISSUES+1)); }

# --- Required packages -----------------------------------------------------
for pkg in git curl ca-certificates openssh-server; do
    if ! dpkg -s "$pkg" &>/dev/null; then
        fix "Missing package: ${pkg} - installing."
        apt-get update -y -qq && apt-get install -y "$pkg"
    fi
done

# --- Config directory permissions ------------------------------------------
if [[ "$(stat -c '%a' "$SLOWDNS_CONFIG_DIR" 2>/dev/null)" != "700" ]]; then
    fix "Fixing permissions on ${SLOWDNS_CONFIG_DIR}."
    chmod 0700 "$SLOWDNS_CONFIG_DIR"
fi
for d in "$SLOWDNS_KEYS_DIR" "$SLOWDNS_SSH_DIR" "$SLOWDNS_USERS_DIR"; do
    if [[ -d "$d" && "$(stat -c '%a' "$d" 2>/dev/null)" != "700" ]]; then
        fix "Fixing permissions on ${d}."
        chmod 0700 "$d"
    fi
done
if [[ -f "${SLOWDNS_KEYS_DIR}/server.key" && "$(stat -c '%a' "${SLOWDNS_KEYS_DIR}/server.key")" != "600" ]]; then
    fix "Fixing permissions on server.key."
    chmod 0600 "${SLOWDNS_KEYS_DIR}/server.key"
fi

# --- Binary present ----------------------------------------------------------
if [[ ! -x "${SLOWDNS_BIN_DIR}/dnstt-server" ]]; then
    fix "dnstt-server binary missing. Re-run install.sh to rebuild it (existing users and keys are preserved)."
fi

# --- systemd units enabled/active ------------------------------------------
for svc in "$SLOWDNS_SSH_SERVICE" "$SLOWDNS_TUNNEL_SERVICE"; do
    if [[ ! -f "/etc/systemd/system/${svc}" ]]; then
        fix "Missing systemd unit: ${svc}. Re-run install.sh to recreate it."
        continue
    fi
    if ! service_is_enabled "$svc"; then
        fix "${svc} was not enabled at boot. Enabling."
        systemctl enable "$svc"
    fi
    if ! service_is_active "$svc"; then
        fix "${svc} is not running. Restarting."
        systemctl restart "$svc" || true
        sleep 1
        if ! service_is_active "$svc"; then
            log_err "${svc} still failed to start. Recent log:"
            journalctl -u "$svc" --no-pager -n 20 || true
        else
            log_ok "${svc} is now running."
        fi
    fi
done

# --- DNS tunnel actually listening ------------------------------------------
if [[ -n "${DNS_BIND_ADDRESS:-}" ]]; then
    DNS_TARGET="${DNS_BIND_ADDRESS}:${DNS_UDP_PORT}"
else
    DNS_TARGET=":${DNS_UDP_PORT}"
fi
if ! ss -uln 2>/dev/null | grep -q "${DNS_TARGET} "; then
    fix "Nothing is listening on ${DNS_TARGET}. Check 'journalctl -u ${SLOWDNS_TUNNEL_SERVICE}'."
fi

# --- SSH backend config still valid -----------------------------------------
if [[ -f "${SLOWDNS_SSH_DIR}/sshd_config" ]]; then
    if ! /usr/sbin/sshd -t -f "${SLOWDNS_SSH_DIR}/sshd_config" 2>/dev/null; then
        fix "SSH backend configuration is currently invalid. Manual review of ${SLOWDNS_SSH_DIR}/sshd_config needed."
    fi
fi

# --- Firewall rule present ---------------------------------------------------
if command -v ufw &>/dev/null && ufw status | grep -q "Status: active"; then
    if ! ufw status | grep -q "${DNS_UDP_PORT}/udp"; then
        fix "UFW rule for ${DNS_UDP_PORT}/udp missing. Adding it back."
        ufw allow "${DNS_UDP_PORT}/udp" comment "Slow DNS VPN tunnel"
        state_add "UFW_RULE:${DNS_UDP_PORT}/udp"
    fi
fi

echo
if [[ "$ISSUES" -eq 0 ]]; then
    log_ok "No problems found."
else
    log_ok "Repair pass complete. ${ISSUES} issue(s) were found and addressed above."
fi
