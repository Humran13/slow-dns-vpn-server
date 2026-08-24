#!/usr/bin/env bash
# scripts/add-user.sh - create a new Slow DNS VPN user.
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

require_root
load_server_conf

header "Add Slow DNS User"

USERNAME=""
while true; do
    read -r -p "Username: " USERNAME
    if ! valid_username "$USERNAME"; then
        log_warn "Invalid username. Use lowercase letters, numbers, '-' or '_', 3-32 chars, starting with a letter. Reserved names are not allowed."
        continue
    fi
    if id "$USERNAME" &>/dev/null; then
        log_warn "A Linux account named '${USERNAME}' already exists. Choose a different username."
        continue
    fi
    break
done

PASSWORD=""
AUTO_GENERATED=0
if confirm "Auto-generate a secure random password?" y; then
    PASSWORD="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 16)"
    AUTO_GENERATED=1
else
    while true; do
        read -r -s -p "Password (min 8 characters): " PASSWORD
        echo
        if ! valid_password "$PASSWORD"; then
            log_warn "Password must be at least 8 characters."
            continue
        fi
        read -r -s -p "Confirm Password: " PASSWORD_CONFIRM
        echo
        if [[ "$PASSWORD" != "$PASSWORD_CONFIRM" ]]; then
            log_warn "Passwords do not match. Try again."
            continue
        fi
        break
    done
fi

echo
echo "Expiry options:"
echo "  1) 1 day"
echo "  2) 7 days"
echo "  3) 30 days"
echo "  4) 90 days"
echo "  5) Custom date (YYYY-MM-DD)"
echo "  6) No expiry"
EXPIRY_DATE=""
while true; do
    read -r -p "Choose an option [1-6]: " choice
    case "$choice" in
        1) EXPIRY_DATE="$(date -d '+1 day' +%F)"; break ;;
        2) EXPIRY_DATE="$(date -d '+7 days' +%F)"; break ;;
        3) EXPIRY_DATE="$(date -d '+30 days' +%F)"; break ;;
        4) EXPIRY_DATE="$(date -d '+90 days' +%F)"; break ;;
        5)
            read -r -p "Enter expiry date (YYYY-MM-DD): " EXPIRY_DATE
            if ! date -d "$EXPIRY_DATE" &>/dev/null; then
                log_warn "Invalid date."
                EXPIRY_DATE=""
                continue
            fi
            break
            ;;
        6) EXPIRY_DATE=""; break ;;
        *) log_warn "Invalid choice." ;;
    esac
done

# ---------------------------------------------------------------------------
# Create the account
# ---------------------------------------------------------------------------
useradd --no-create-home --shell /usr/sbin/nologin -g "$SLOWDNS_VPN_GROUP" "$USERNAME"
echo "${USERNAME}:${PASSWORD}" | chpasswd

if [[ -n "$EXPIRY_DATE" ]]; then
    chage -E "$EXPIRY_DATE" "$USERNAME"
else
    chage -E -1 "$USERNAME"
fi

install -d -m 0700 "$SLOWDNS_USERS_DIR"
cat > "${SLOWDNS_USERS_DIR}/${USERNAME}.conf" <<EOF
CREATED=$(date +%F)
CREATED_BY=slowdns-manager
EOF
chmod 0600 "${SLOWDNS_USERS_DIR}/${USERNAME}.conf"

header "Slow DNS User Created"
echo "Username:  ${USERNAME}"
if [[ "$AUTO_GENERATED" -eq 1 ]]; then
    echo "Password:  ${PASSWORD}   (shown once - save it now)"
else
    echo "Password:  (set by administrator)"
fi
echo "Expires:   ${EXPIRY_DATE:-Never}"
echo
echo "Tunnel Domain      : ${TUNNEL_DOMAIN}"
echo "Nameserver         : ${NS_HOSTNAME}"
echo "Server Public Key  : $(cat "${SLOWDNS_KEYS_DIR}/server.pub" 2>/dev/null || echo unknown)"
echo "========================================"
echo
echo "For full client setup instructions, use 'slowdns' -> 'Connection Details'."
