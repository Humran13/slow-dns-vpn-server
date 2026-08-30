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
MAIN MENU
 1) User Manager
 2) Service Control
 3) Connection Details
 4) Server Information
 5) DNS Configuration
 6) Server Status
 7) Logs
 8) Backup
 9) Restore
10) Update / Repair Installation
11) Uninstall

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

logs_menu() {
    while true; do
        clear
        header "Logs"
        cat <<'EOF'
 [01] Tunnel Logs - Last 50 Lines
 [02] SSH Backend Logs - Last 50 Lines
 [03] Follow Tunnel Logs
 [04] Follow SSH Backend Logs
 [05] Show Both Service Status

 [00] Back
EOF
        echo
        read -r -p "Select an option: " choice
        echo
        case "$choice" in
            1|01) journalctl -u "$SLOWDNS_TUNNEL_SERVICE" -n 50 --no-pager ;;
            2|02) journalctl -u "$SLOWDNS_SSH_SERVICE" -n 50 --no-pager ;;
            3|03) follow_journal "$SLOWDNS_TUNNEL_SERVICE" ;;
            4|04) follow_journal "$SLOWDNS_SSH_SERVICE" ;;
            5|05) show_service_status ;;
            0|00) break ;;
            *) log_warn "Invalid option." ;;
        esac
        echo
        press_enter
    done
}

# Live-follow a project journal. Ctrl+C only stops the follower, not the menu.
follow_journal() {
    local svc="$1" pid rc
    log_info "Following ${svc} - press Ctrl+C to stop."
    (
        trap 'exit 130' INT
        journalctl -fu "$svc"
    ) &
    pid=$!
    # Ignore Ctrl+C in this shell so it only reaches the follower subshell.
    trap '' INT
    if wait "$pid"; then
        rc=0
    else
        rc=$?
    fi
    trap - INT
    echo
    if [[ "$rc" -gt 128 ]]; then
        log_info "Log following stopped."
    fi
}

show_service_status() {
    header "Service Status"
    printf '%-22s : %s\n' \
        "SSH Backend" "$(service_is_active "$SLOWDNS_SSH_SERVICE" && echo ONLINE || echo OFFLINE)"
    printf '%-22s : %s\n' \
        "Slow DNS Tunnel" "$(service_is_active "$SLOWDNS_TUNNEL_SERVICE" && echo ONLINE || echo OFFLINE)"
}

start_slowdns() {
    header "Start Slow DNS"
    log_info "Starting SSH backend (${SLOWDNS_SSH_SERVICE})..."
    systemctl start "$SLOWDNS_SSH_SERVICE" || true
    sleep 1
    if service_is_active "$SLOWDNS_SSH_SERVICE"; then
        log_ok "SSH backend is running."
    else
        log_err "SSH backend failed to start. Recent log:"
        journalctl -u "$SLOWDNS_SSH_SERVICE" --no-pager -n 30 || true
    fi
    log_info "Starting Slow DNS tunnel (${SLOWDNS_TUNNEL_SERVICE})..."
    systemctl start "$SLOWDNS_TUNNEL_SERVICE" || true
    sleep 1
    if service_is_active "$SLOWDNS_TUNNEL_SERVICE"; then
        log_ok "Slow DNS tunnel is running."
    else
        log_err "Slow DNS tunnel failed to start. Recent log:"
        journalctl -u "$SLOWDNS_TUNNEL_SERVICE" --no-pager -n 30 || true
    fi
    show_service_summary
}

stop_slowdns() {
    header "Stop Slow DNS"
    log_info "Stopping Slow DNS tunnel (${SLOWDNS_TUNNEL_SERVICE})..."
    systemctl stop "$SLOWDNS_TUNNEL_SERVICE" || true
    sleep 1
    if service_is_active "$SLOWDNS_TUNNEL_SERVICE"; then
        log_err "Slow DNS tunnel is still running."
    else
        log_ok "Slow DNS tunnel stopped."
    fi
    log_info "Stopping SSH backend (${SLOWDNS_SSH_SERVICE})..."
    systemctl stop "$SLOWDNS_SSH_SERVICE" || true
    sleep 1
    if service_is_active "$SLOWDNS_SSH_SERVICE"; then
        log_err "SSH backend is still running."
    else
        log_ok "SSH backend stopped."
    fi
    show_service_summary
}

restart_slowdns() {
    header "Restart Slow DNS"
    log_info "Restarting SSH backend (${SLOWDNS_SSH_SERVICE})..."
    systemctl restart "$SLOWDNS_SSH_SERVICE" || true
    sleep 1
    if service_is_active "$SLOWDNS_SSH_SERVICE"; then
        log_ok "SSH backend restarted and running."
    else
        log_err "SSH backend failed to restart. Recent log:"
        journalctl -u "$SLOWDNS_SSH_SERVICE" --no-pager -n 30 || true
    fi
    log_info "Restarting Slow DNS tunnel (${SLOWDNS_TUNNEL_SERVICE})..."
    systemctl restart "$SLOWDNS_TUNNEL_SERVICE" || true
    sleep 1
    if service_is_active "$SLOWDNS_TUNNEL_SERVICE"; then
        log_ok "Slow DNS tunnel restarted and running."
    else
        log_err "Slow DNS tunnel failed to restart. Recent log:"
        journalctl -u "$SLOWDNS_TUNNEL_SERVICE" --no-pager -n 30 || true
    fi
    show_service_summary
}

show_service_summary() {
    local tunnel ssh
    tunnel="OFFLINE"; ssh="OFFLINE"
    service_is_active "$SLOWDNS_TUNNEL_SERVICE" && tunnel="ONLINE"
    service_is_active "$SLOWDNS_SSH_SERVICE" && ssh="ONLINE"
    printf '\n%sSSH Backend :%s %s    %sTunnel :%s %s\n' \
        "$C_BOLD" "$C_RESET" "$ssh" "$C_BOLD" "$C_RESET" "$tunnel"
}

user_manager_menu() {
    while true; do
        clear
        header "User Manager"
        cat <<'EOF'
 1) Add User
 2) Remove User
 3) List Users
 4) Show User
 5) Change Password
 6) Set Expiry
 7) Enable User
 8) Disable User

 0) Back to Main Menu
EOF
        echo
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
            0) break ;;
            *) log_warn "Invalid option." ;;
        esac
        echo
        press_enter
    done
}

service_control_menu() {
    while true; do
        clear
        header "Service Control"
        cat <<'EOF'
 1) Start Slow DNS
 2) Restart Slow DNS
 3) Stop Slow DNS
 4) Restart Tunnel Only
 5) Restart SSH Backend Only

 0) Back to Main Menu
EOF
        echo
        read -r -p "Select an option: " choice
        echo
        case "$choice" in
            1) start_slowdns ;;
            2) restart_slowdns ;;
            3) stop_slowdns ;;
            4) restart_service "$SLOWDNS_TUNNEL_SERVICE" "Slow DNS Tunnel" ;;
            5) restart_service "$SLOWDNS_SSH_SERVICE" "SSH Backend" ;;
            0) break ;;
            *) log_warn "Invalid option." ;;
        esac
        echo
        press_enter
    done
}

while true; do
    show_menu
    read -r -p "Select an option: " choice
    echo
    case "$choice" in
        1) user_manager_menu ;;
        2) service_control_menu ;;
        3) bash "${SCRIPT_DIR}/scripts/connection-details.sh" || true ;;
        4) show_server_configuration || true ;;
        5) bash "${SCRIPT_DIR}/scripts/dns-config.sh" || true ;;
        6) bash "${SCRIPT_DIR}/status.sh" || true ;;
        7) logs_menu || true ;;
        8) bash "${SCRIPT_DIR}/scripts/backup.sh" || true ;;
        9) bash "${SCRIPT_DIR}/scripts/restore.sh" || true ;;
        10) bash "${SCRIPT_DIR}/scripts/repair.sh" || true ;;
        11)
            bash "${SCRIPT_DIR}/uninstall.sh" || true
            exit 0
            ;;
        0) echo "Goodbye."; exit 0 ;;
        *) log_warn "Invalid option." ;;
    esac
    echo
    press_enter
done
