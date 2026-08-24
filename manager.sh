#!/usr/bin/env bash
#
# manager.sh - interactive Slow DNS VPN management menu.
# Installed as the `slowdns` command.
#
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

require_root
require_installed

show_menu() {
    load_server_conf
    local tunnel_state ssh_state user_count
    if service_is_active "$SLOWDNS_TUNNEL_SERVICE" && service_is_active "$SLOWDNS_SSH_SERVICE"; then
        tunnel_state="${C_GREEN}ONLINE${C_RESET}"
    else
        tunnel_state="${C_RED}OFFLINE${C_RESET}"
    fi
    ssh_state="$(service_is_active "$SLOWDNS_SSH_SERVICE" && echo "${C_GREEN}ONLINE${C_RESET}" || echo "${C_RED}OFFLINE${C_RESET}")"
    user_count="$(list_slowdns_usernames | grep -c . || true)"

    clear
    printf '%s========================================%s\n' "${C_BOLD}" "${C_RESET}"
    printf '%s           Slow DNS VPN Manager%s\n' "${C_BOLD}" "${C_RESET}"
    printf '%s========================================%s\n\n' "${C_BOLD}" "${C_RESET}"
    printf 'Server Status : %b\n' "$tunnel_state"
    printf 'SSH Backend   : %b\n' "$ssh_state"
    printf 'Domain        : %s\n' "${TUNNEL_DOMAIN:-not configured}"
    printf 'Users         : %s\n\n' "${user_count:-0}"

    cat <<'EOF'
USER MANAGEMENT
 1) Add User
 2) Remove User
 3) List Users
 4) Show User
 5) Change User Password
 6) Set User Expiry
 7) Enable User
 8) Disable User

SERVER MANAGEMENT
 9) Show Server Configuration
10) Show Client Connection Details
11) Show DNS Configuration
12) Show Service Status
13) Restart Slow DNS Tunnel
14) Restart SSH Backend
15) View Logs

MAINTENANCE
16) Backup Configuration
17) Restore Configuration
18) Update / Repair Installation
19) Uninstall Slow DNS

 0) Exit
EOF
    echo
}

show_server_configuration() {
    load_server_conf
    header "Server Configuration"
    echo "Base domain          : $(conf_get BASE_DOMAIN)"
    echo "Tunnel domain         : ${TUNNEL_DOMAIN}"
    echo "Nameserver hostname   : ${NS_HOSTNAME}"
    echo "Public IPv4           : ${PUBLIC_IPV4:-unknown}"
    echo "DNS UDP port          : ${DNS_UDP_PORT}"
    echo "MTU                   : ${MTU}"
    echo "SSH backend port (loopback only) : ${SSH_TUNNEL_PORT}"
    echo "Installed on          : ${INSTALL_DATE}"
    echo "dnstt version         : $(conf_get DNSTT_VERSION)"
    echo "Server public key     : $(cat "${SLOWDNS_KEYS_DIR}/server.pub" 2>/dev/null || echo unknown)"
    if [[ "$LOW_PROFILE_MODE" == "true" ]]; then
        echo "Low-Profile Mode      : Enabled"
    else
        echo "Low-Profile Mode      : Disabled"
    fi
}

restart_service() {
    local svc="$1" label="$2"
    log_info "Restarting ${label}..."
    systemctl restart "$svc" || true
    sleep 1
    if service_is_active "$svc"; then
        log_ok "${label} restarted and running."
    else
        log_err "${label} failed to restart. Recent log:"
        journalctl -u "$svc" --no-pager -n 30 || true
    fi
}

view_logs() {
    header "View Logs"
    echo "1) Slow DNS tunnel - last 50 lines"
    echo "2) Slow DNS tunnel - live (Ctrl+C to stop)"
    echo "3) SSH backend - last 50 lines"
    echo "4) SSH backend - live (Ctrl+C to stop)"
    echo "5) SSH authentication log (system auth log, filtered)"
    read -r -p "Choose an option [1-5]: " choice
    case "$choice" in
        1) journalctl -u "$SLOWDNS_TUNNEL_SERVICE" --no-pager -n 50 ;;
        2) journalctl -u "$SLOWDNS_TUNNEL_SERVICE" -f ;;
        3) journalctl -u "$SLOWDNS_SSH_SERVICE" --no-pager -n 50 ;;
        4) journalctl -u "$SLOWDNS_SSH_SERVICE" -f ;;
        5)
            if [[ -f /var/log/auth.log ]]; then
                grep -i "slowdns-ssh\|sshd\[" /var/log/auth.log | tail -n 50
            else
                journalctl -u "$SLOWDNS_SSH_SERVICE" -t sshd --no-pager -n 50
            fi
            ;;
        *) log_warn "Invalid choice." ;;
    esac
}

while true; do
    show_menu
    read -r -p "Select an option: " choice
    echo
    case "$choice" in
        1) bash "${SCRIPT_DIR}/scripts/add-user.sh" || true ;;
        2) bash "${SCRIPT_DIR}/scripts/remove-user.sh" || true ;;
        3) bash "${SCRIPT_DIR}/scripts/list-users.sh" || true ;;
        4) bash "${SCRIPT_DIR}/scripts/show-user.sh" || true ;;
        5) bash "${SCRIPT_DIR}/scripts/change-password.sh" || true ;;
        6) bash "${SCRIPT_DIR}/scripts/set-expiry.sh" || true ;;
        7) bash "${SCRIPT_DIR}/scripts/enable-user.sh" || true ;;
        8) bash "${SCRIPT_DIR}/scripts/disable-user.sh" || true ;;
        9) show_server_configuration || true ;;
        10) bash "${SCRIPT_DIR}/scripts/connection-details.sh" || true ;;
        11) bash "${SCRIPT_DIR}/scripts/dns-config.sh" || true ;;
        12) bash "${SCRIPT_DIR}/status.sh" || true ;;
        13) restart_service "$SLOWDNS_TUNNEL_SERVICE" "Slow DNS Tunnel" || true ;;
        14) restart_service "$SLOWDNS_SSH_SERVICE" "SSH Backend" || true ;;
        15) view_logs || true ;;
        16) bash "${SCRIPT_DIR}/scripts/backup.sh" || true ;;
        17) bash "${SCRIPT_DIR}/scripts/restore.sh" || true ;;
        18) bash "${SCRIPT_DIR}/scripts/repair.sh" || true ;;
        19)
            bash "${SCRIPT_DIR}/uninstall.sh" || true
            exit 0
            ;;
        0) echo "Goodbye."; exit 0 ;;
        *) log_warn "Invalid option." ;;
    esac
    echo
    press_enter
done
