#!/usr/bin/env bash
#
# install.sh - Slow DNS VPN Server installer
#
# Installs a dnstt-based DNS tunnel server, a dedicated loopback-only SSH
# backend for VPN user authentication, systemd services, and the
# `slowdns` management command.
#
# Usage: sudo bash install.sh
#
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

TMP_DIR=""
cleanup() {
    if [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]]; then
        rm -rf "$TMP_DIR"
    fi
    if [[ "${SLOWDNS_INSTALL_REEXEC:-0}" == "1" ]]; then
        rm -rf "$SCRIPT_DIR"
    fi
}
on_error() {
    local line="$1"
    log_err "Installation failed at line ${line}. No partial services were left running that weren't already verified."
    log_err "You can re-run 'sudo bash install.sh' after resolving the issue, or run scripts/repair.sh once a config exists."
}
trap cleanup EXIT
trap 'on_error $LINENO' ERR

# ---------------------------------------------------------------------------
# 1. Root check
# ---------------------------------------------------------------------------
require_root

# If this is being re-run from the already-installed copy (as scripts/repair.sh
# suggests for a rebuild), re-exec from a temp copy first so we can safely
# overwrite ${SLOWDNS_INSTALL_DIR} during this same run without a script
# trying to copy a directory onto itself.
if [[ "$SCRIPT_DIR" == "$SLOWDNS_INSTALL_DIR" && "${SLOWDNS_INSTALL_REEXEC:-0}" != "1" ]]; then
    TMP_SELF_COPY="$(mktemp -d /tmp/slowdns-install.XXXXXX)"
    cp -a "${SCRIPT_DIR}/." "${TMP_SELF_COPY}/"
    export SLOWDNS_INSTALL_REEXEC=1
    exec bash "${TMP_SELF_COPY}/install.sh" "$@"
fi

header "Slow DNS VPN Server Installer"

# ---------------------------------------------------------------------------
# 2. OS detection
# ---------------------------------------------------------------------------
detect_os
if [[ "$OS_SUPPORTED" -ne 1 ]]; then
    print_unsupported_os
    exit 1
fi

echo "Detected OS: ${OS_PRETTY}"
if [[ "$OS_LEGACY" -eq 1 ]]; then
    log_warn "Ubuntu ${OS_VERSION_ID} is an older release and may no longer receive normal public"
    log_warn "security maintenance from Canonical. Installation will continue, but consider"
    log_warn "upgrading to Ubuntu 22.04 LTS or newer when practical."
fi

# ---------------------------------------------------------------------------
# 3. CPU architecture
# ---------------------------------------------------------------------------
detect_arch
echo "Detected CPU architecture: ${ARCH_DEB}"

# ---------------------------------------------------------------------------
# 4. Internet connectivity check
# ---------------------------------------------------------------------------
log_info "Checking internet connectivity..."
if ! curl -fsS --max-time 8 https://www.bamsoftware.com >/dev/null 2>&1 && \
   ! curl -fsS --max-time 8 https://go.dev >/dev/null 2>&1; then
    die "No internet connectivity detected. This installer needs to download the Go toolchain and dnstt source."
fi
log_ok "Internet connectivity OK."

# ---------------------------------------------------------------------------
# 5. Already-installed check
# ---------------------------------------------------------------------------
if [[ -f "$SLOWDNS_SERVER_CONF" ]]; then
    log_warn "Slow DNS VPN already appears to be installed (${SLOWDNS_SERVER_CONF} exists)."
    if ! confirm "Reconfigure / reinstall over the existing installation?" n; then
        echo "Aborted. Use 'slowdns' -> 'Update / Repair Installation' to fix a broken install instead."
        exit 0
    fi
fi

PUBLIC_IPV4="$(get_public_ipv4)"
echo "Public IPv4: ${PUBLIC_IPV4:-unknown}"

DNS_BIND_ADDRESS="$(select_dns_bind_address "$PUBLIC_IPV4")" || \
    die "Could not determine a local IPv4 address for dnstt to bind (no global-scope interface address found)."
echo "DNS bind address: ${DNS_BIND_ADDRESS}"

# ---------------------------------------------------------------------------
# 6. Interactive configuration
# ---------------------------------------------------------------------------
header "Domain Configuration"

cat <<'EOF'
Slow DNS tunnels work by delegating a DNS subdomain to this server. Your
domain's DNS provider needs to send tunnel traffic here using two DNS
records. You need a domain name you control (e.g. example.com).
EOF
echo

BASE_DOMAIN=""
while [[ -z "$BASE_DOMAIN" ]]; do
    read -r -p "Enter the domain you want to use for Slow DNS (e.g. example.com): " BASE_DOMAIN
    BASE_DOMAIN="${BASE_DOMAIN,,}"
    if [[ ! "$BASE_DOMAIN" =~ ^([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}$ ]]; then
        log_warn "That doesn't look like a valid domain name. Try again."
        BASE_DOMAIN=""
    fi
done

NS_HOSTNAME="ns.${BASE_DOMAIN}"
TUNNEL_DOMAIN="tunnel.${BASE_DOMAIN}"

echo
echo "By default this installer will use:"
echo "  Nameserver hostname (A/AAAA record) : ${NS_HOSTNAME}"
echo "  Tunnel zone (NS-delegated record)   : ${TUNNEL_DOMAIN}"
echo
if ! confirm "Use these defaults?" y; then
    read -r -p "Nameserver hostname [${NS_HOSTNAME}]: " input
    NS_HOSTNAME="${input:-$NS_HOSTNAME}"
    read -r -p "Tunnel zone domain [${TUNNEL_DOMAIN}]: " input
    TUNNEL_DOMAIN="${input:-$TUNNEL_DOMAIN}"
fi

header "Network Configuration"

DNS_UDP_PORT="53"
read -r -p "UDP port for the DNS tunnel to listen on [53]: " input
DNS_UDP_PORT="${input:-53}"

SSH_TUNNEL_PORT="2222"
read -r -p "Internal loopback-only port for the SSH VPN backend [2222]: " input
SSH_TUNNEL_PORT="${input:-2222}"

MTU="1232"

echo
cat <<'EOF'
Low-Profile Mode makes the server behave more conservatively: a smaller DNS
MTU, longer keepalive/restart intervals, bounded restart attempts, and
sensible resource ceilings. It reduces network and service "noise" and
protects against runaway processes - it is NOT an anti-detection, firewall-
bypass, or traffic-obfuscation feature, and it does not make the tunnel
harder to identify or block on a network that inspects DNS traffic.
EOF
LOW_PROFILE_MODE="false"
if confirm "Enable Low-Profile Mode?" n; then
    LOW_PROFILE_MODE="true"
fi

echo
echo "Configuration summary:"
echo "  Domain base           : ${BASE_DOMAIN}"
echo "  Nameserver hostname    : ${NS_HOSTNAME}"
echo "  Tunnel zone            : ${TUNNEL_DOMAIN}"
echo "  DNS UDP port            : ${DNS_UDP_PORT}"
echo "  SSH backend port (local): ${SSH_TUNNEL_PORT}"
echo "  Low-Profile Mode        : ${LOW_PROFILE_MODE}"
echo
if ! confirm "Proceed with installation?" y; then
    echo "Aborted."
    exit 0
fi

# ---------------------------------------------------------------------------
# Derived values for Low-Profile Mode. Normal-mode values are set to
# systemd/OpenSSH's own real default behavior (explicit, not a behavior
# change); Low-Profile values are more conservative. See README "Low-Profile
# Mode" for what each setting does and why.
# ---------------------------------------------------------------------------
if [[ "$LOW_PROFILE_MODE" == "true" ]]; then
    MTU="512"
    SSHD_CLIENT_ALIVE_INTERVAL="120"
    SSHD_CLIENT_ALIVE_COUNT_MAX="3"
    SSHD_MAX_AUTH_TRIES="3"
    SSHD_LOGIN_GRACE_TIME="15"
    SSHD_MAX_STARTUPS="5:50:20"
    SVC_RESTART_SEC="10"
    SVC_START_LIMIT_INTERVAL="300"
    SVC_START_LIMIT_BURST="5"
    SVC_TIMEOUT_STOP="10"
    TUNNEL_MEMORY_MAX="256M"
    TUNNEL_TASKS_MAX="64"
    SSH_MEMORY_MAX="512M"
    SSH_TASKS_MAX="256"
else
    SSHD_CLIENT_ALIVE_INTERVAL="60"
    SSHD_CLIENT_ALIVE_COUNT_MAX="3"
    SSHD_MAX_AUTH_TRIES="4"
    SSHD_LOGIN_GRACE_TIME="20"
    SSHD_MAX_STARTUPS="10:30:100"
    SVC_RESTART_SEC="3"
    SVC_START_LIMIT_INTERVAL="10"
    SVC_START_LIMIT_BURST="5"
    SVC_TIMEOUT_STOP="90"
    TUNNEL_MEMORY_MAX="infinity"
    TUNNEL_TASKS_MAX="infinity"
    SSH_MEMORY_MAX="infinity"
    SSH_TASKS_MAX="infinity"
fi

# ---------------------------------------------------------------------------
# 7. Package installation
# ---------------------------------------------------------------------------
header "Installing Required Packages"

export DEBIAN_FRONTEND=noninteractive
log_info "Running apt-get update..."
apt-get update -y

BASE_PKGS=(git curl ca-certificates openssh-server iproute2 gzip tar)
for pkg in "${BASE_PKGS[@]}"; do
    if ! dpkg -s "$pkg" &>/dev/null; then
        log_info "Installing package: ${pkg}"
        apt-get install -y "$pkg"
        state_add "PKG:${pkg}"
    else
        log_info "Package already present: ${pkg} (leaving it managed by the system)"
    fi
done

if ! command -v ufw &>/dev/null; then
    if confirm "UFW firewall is not installed. Install it so this installer can manage tunnel ports safely?" y; then
        apt-get install -y ufw
        state_add "PKG:ufw"
    fi
fi

# Preflight: confirm nothing already owns the exact bind address:port before
# building/starting anything. Wildcard (0.0.0.0/*) listeners on the port count
# as conflicts; loopback-only listeners such as systemd-resolved's
# 127.0.0.53:53 do NOT conflict with a specific non-loopback bind.
DNS_BIND_CONFLICT="$(find_udp_conflict "$DNS_BIND_ADDRESS" "$DNS_UDP_PORT" || true)"
if [[ -n "$DNS_BIND_CONFLICT" ]]; then
    log_err "UDP port ${DNS_UDP_PORT} is not free on bind address ${DNS_BIND_ADDRESS}:"
    echo "  ${DNS_BIND_CONFLICT}"
    die "Choose a different DNS UDP port (or stop the process owning that socket first), then re-run."
fi
log_ok "Preflight OK: ${DNS_BIND_ADDRESS}:${DNS_UDP_PORT}/udp is available."

# ---------------------------------------------------------------------------
# 8. Directories
# ---------------------------------------------------------------------------
header "Creating Directories"

install -d -m 0755 -o root -g root "$SLOWDNS_INSTALL_DIR"
install -d -m 0700 -o root -g root "$SLOWDNS_CONFIG_DIR"
install -d -m 0700 -o root -g root "$SLOWDNS_USERS_DIR"
install -d -m 0700 -o root -g root "$SLOWDNS_KEYS_DIR"
install -d -m 0700 -o root -g root "$SLOWDNS_SSH_DIR"
install -d -m 0755 -o root -g root "$SLOWDNS_BIN_DIR"
install -d -m 0700 -o root -g root "$SLOWDNS_BUILD_DIR"
install -d -m 0700 -o root -g root "$SLOWDNS_BACKUP_DIR"
log_ok "Directories created."

# ---------------------------------------------------------------------------
# 9. Dedicated system user/group for the dnstt-server process
# ---------------------------------------------------------------------------
header "Creating Dedicated Service Account"

if ! getent group "$SLOWDNS_VPN_GROUP" &>/dev/null; then
    groupadd --system "$SLOWDNS_VPN_GROUP"
    state_add "GROUP:${SLOWDNS_VPN_GROUP}"
    log_ok "Created group: ${SLOWDNS_VPN_GROUP} (used only to scope SSH tunnel access; carries no privileges)"
fi

if ! id "$SLOWDNS_SYSTEM_USER" &>/dev/null; then
    useradd --system --no-create-home --shell /usr/sbin/nologin "$SLOWDNS_SYSTEM_USER"
    state_add "USER:${SLOWDNS_SYSTEM_USER}"
    log_ok "Created unprivileged service account: ${SLOWDNS_SYSTEM_USER} (runs the dnstt tunnel process only)"
fi

# The dedicated service account must be able to traverse into its keys
# directory, but must NOT be able to read/list the rest of the configuration.
# Give its primary group (slowdns) traverse-only access to the config root and
# keep everything else root-only. Applied unconditionally so re-running the
# installer repairs an existing install that has root:root 0700 here.
chown root:"$SLOWDNS_SYSTEM_USER" "$SLOWDNS_CONFIG_DIR"
chmod 0710 "$SLOWDNS_CONFIG_DIR"

# ---------------------------------------------------------------------------
# 10. Build dnstt from pinned, verified source
# ---------------------------------------------------------------------------
header "Building the Slow DNS Tunnel Server (dnstt)"

cat <<EOF
This installer builds the dnstt tunnel server from its official public-domain
source (David Fifield, ${DNSTT_GIT_URL}), pinned to release ${DNSTT_TAG}.
Ubuntu's packaged Go compiler is too old to build modern dnstt, so a
verified copy of the official Go ${GO_VERSION} toolchain is downloaded and
checked against its published SHA-256 checksum before use.
EOF
echo

TMP_DIR="$(mktemp -d)"

GO_TARBALL="go${GO_VERSION}.linux-${GO_ARCH}.tar.gz"
GO_URL="https://go.dev/dl/${GO_TARBALL}"
log_info "Downloading Go ${GO_VERSION} (${GO_ARCH})..."
curl -fSL --retry 3 --max-time 180 -o "${TMP_DIR}/${GO_TARBALL}" "$GO_URL"

log_info "Verifying Go toolchain checksum..."
echo "${GO_SHA256}  ${TMP_DIR}/${GO_TARBALL}" | sha256sum -c - \
    || die "Go toolchain checksum verification FAILED. Aborting for your safety."
log_ok "Checksum verified."

rm -rf "${SLOWDNS_BUILD_DIR}/go"
tar -C "${SLOWDNS_BUILD_DIR}" -xzf "${TMP_DIR}/${GO_TARBALL}"

BUILD_GO="${SLOWDNS_BUILD_DIR}/go/bin/go"
export GOROOT="${SLOWDNS_BUILD_DIR}/go"
export GOPATH="${SLOWDNS_BUILD_DIR}/gopath"
export GOCACHE="${SLOWDNS_BUILD_DIR}/gocache"
export GO111MODULE=on

log_info "Cloning dnstt source (pinned commit ${DNSTT_COMMIT})..."
rm -rf "${SLOWDNS_BUILD_DIR}/dnstt-src"
git clone --quiet "$DNSTT_GIT_URL" "${SLOWDNS_BUILD_DIR}/dnstt-src"
git -C "${SLOWDNS_BUILD_DIR}/dnstt-src" checkout --quiet "$DNSTT_TAG"

ACTUAL_COMMIT="$(git -C "${SLOWDNS_BUILD_DIR}/dnstt-src" rev-parse HEAD)"
if [[ "$ACTUAL_COMMIT" != "$DNSTT_COMMIT" ]]; then
    die "dnstt source commit mismatch! Expected ${DNSTT_COMMIT}, got ${ACTUAL_COMMIT}. Aborting for your safety."
fi
log_ok "Source integrity verified (commit matches pinned value)."

log_info "Compiling dnstt-server (this can take a minute)..."
(
    cd "${SLOWDNS_BUILD_DIR}/dnstt-src/dnstt-server"
    "$BUILD_GO" build -trimpath -o "${SLOWDNS_BIN_DIR}/dnstt-server" .
)
chmod 0755 "${SLOWDNS_BIN_DIR}/dnstt-server"
log_ok "dnstt-server built: ${SLOWDNS_BIN_DIR}/dnstt-server"

log_info "Cleaning up build toolchain to save disk space..."
rm -rf "${SLOWDNS_BUILD_DIR}/go" "${SLOWDNS_BUILD_DIR}/gopath" "${SLOWDNS_BUILD_DIR}/gocache" "${SLOWDNS_BUILD_DIR}/dnstt-src"

# ---------------------------------------------------------------------------
# 11. Generate dnstt tunnel keypair
# ---------------------------------------------------------------------------
header "Generating Tunnel Encryption Keys"

if [[ ! -f "${SLOWDNS_KEYS_DIR}/server.key" ]]; then
    "${SLOWDNS_BIN_DIR}/dnstt-server" -gen-key \
        -privkey-file "${SLOWDNS_KEYS_DIR}/server.key" \
        -pubkey-file "${SLOWDNS_KEYS_DIR}/server.pub"
    log_ok "Generated tunnel keypair (server.key is private and never leaves this server)."
else
    log_info "Existing tunnel keypair found, keeping it."
fi
# Enforce the key ownership/modes unconditionally so a re-run or partial
# recovery repairs them too. server.key stays 0600 to the service account.
chown -R "${SLOWDNS_SYSTEM_USER}:${SLOWDNS_SYSTEM_USER}" "$SLOWDNS_KEYS_DIR"
chmod 0700 "$SLOWDNS_KEYS_DIR"
chmod 0600 "${SLOWDNS_KEYS_DIR}/server.key"
chmod 0644 "${SLOWDNS_KEYS_DIR}/server.pub"

PUBKEY_HEX="$(cat "${SLOWDNS_KEYS_DIR}/server.pub")"

# ---------------------------------------------------------------------------
# 12. Dedicated SSH backend for VPN users
# ---------------------------------------------------------------------------
header "Configuring the SSH VPN Backend"

echo "This backend is a SEPARATE sshd instance, isolated from your main SSH"
echo "server. It listens only on 127.0.0.1:${SSH_TUNNEL_PORT} and is never reachable"
echo "from the internet directly - only through the DNS tunnel. Your existing"
echo "SSH administrator access is not touched."
echo

for kt in rsa ed25519; do
    keyfile="${SLOWDNS_SSH_DIR}/ssh_host_${kt}_key"
    if [[ ! -f "$keyfile" ]]; then
        ssh-keygen -q -t "$kt" -f "$keyfile" -N "" </dev/null
        chmod 0600 "$keyfile"
        chmod 0644 "${keyfile}.pub"
    fi
done

SSHD_CONFIG_PATH="${SLOWDNS_SSH_DIR}/sshd_config"
sed \
    -e "s#__PORT__#${SSH_TUNNEL_PORT}#" \
    -e "s#__HOSTKEY_RSA__#${SLOWDNS_SSH_DIR}/ssh_host_rsa_key#" \
    -e "s#__HOSTKEY_ED25519__#${SLOWDNS_SSH_DIR}/ssh_host_ed25519_key#" \
    -e "s#__PIDFILE__#/run/slowdns-ssh.pid#" \
    -e "s#__ALLOWGROUP__#${SLOWDNS_VPN_GROUP}#" \
    -e "s#__CLIENTALIVEINTERVAL__#${SSHD_CLIENT_ALIVE_INTERVAL}#" \
    -e "s#__CLIENTALIVECOUNTMAX__#${SSHD_CLIENT_ALIVE_COUNT_MAX}#" \
    -e "s#__MAXAUTHTRIES__#${SSHD_MAX_AUTH_TRIES}#" \
    -e "s#__LOGINGRACETIME__#${SSHD_LOGIN_GRACE_TIME}#" \
    -e "s#__MAXSTARTUPS__#${SSHD_MAX_STARTUPS}#" \
    "${SCRIPT_DIR}/config/sshd_config.tunnel.template" > "$SSHD_CONFIG_PATH"
chmod 0600 "$SSHD_CONFIG_PATH"

if ! /usr/sbin/sshd -t -f "$SSHD_CONFIG_PATH"; then
    die "Generated SSH backend configuration failed validation (sshd -t). Aborting for your safety."
fi
log_ok "SSH backend configuration validated."

# ---------------------------------------------------------------------------
# 13. server.conf
# ---------------------------------------------------------------------------
header "Writing Server Configuration"

conf_set BASE_DOMAIN "$BASE_DOMAIN"
conf_set TUNNEL_DOMAIN "$TUNNEL_DOMAIN"
conf_set NS_HOSTNAME "$NS_HOSTNAME"
conf_set PUBLIC_IPV4 "$PUBLIC_IPV4"
conf_set DNS_BIND_ADDRESS "$DNS_BIND_ADDRESS"
conf_set DNS_UDP_PORT "$DNS_UDP_PORT"
conf_set MTU "$MTU"
conf_set SSH_TUNNEL_PORT "$SSH_TUNNEL_PORT"
conf_set INSTALL_DATE "$(date +%F)"
conf_set DNSTT_VERSION "$DNSTT_TAG"
conf_set LOW_PROFILE_MODE "$LOW_PROFILE_MODE"
chmod 0600 "$SLOWDNS_SERVER_CONF"
chmod 0600 "$SLOWDNS_STATE_FILE" 2>/dev/null || true
log_ok "Saved ${SLOWDNS_SERVER_CONF}"

# ---------------------------------------------------------------------------
# 14. systemd units
# ---------------------------------------------------------------------------
header "Installing systemd Services"

TUNNEL_EXEC="${SLOWDNS_BIN_DIR}/dnstt-server -mtu ${MTU} -udp ${DNS_BIND_ADDRESS}:${DNS_UDP_PORT} -privkey-file ${SLOWDNS_KEYS_DIR}/server.key ${TUNNEL_DOMAIN} 127.0.0.1:${SSH_TUNNEL_PORT}"

sed \
    -e "s#__EXEC__#${TUNNEL_EXEC}#" \
    -e "s#__USER__#${SLOWDNS_SYSTEM_USER}#" \
    -e "s#__GROUP__#${SLOWDNS_SYSTEM_USER}#" \
    -e "s#__STARTLIMITINTERVAL__#${SVC_START_LIMIT_INTERVAL}#" \
    -e "s#__STARTLIMITBURST__#${SVC_START_LIMIT_BURST}#" \
    -e "s#__RESTARTSEC__#${SVC_RESTART_SEC}#" \
    -e "s#__TIMEOUTSTOP__#${SVC_TIMEOUT_STOP}#" \
    -e "s#__TUNNELMEMORYMAX__#${TUNNEL_MEMORY_MAX}#" \
    -e "s#__TUNNELTASKSMAX__#${TUNNEL_TASKS_MAX}#" \
    "${SCRIPT_DIR}/systemd/slowdns-tunnel.service.template" > "/etc/systemd/system/${SLOWDNS_TUNNEL_SERVICE}"

sed \
    -e "s#__SSHD_CONFIG__#${SSHD_CONFIG_PATH}#" \
    -e "s#__STARTLIMITINTERVAL__#${SVC_START_LIMIT_INTERVAL}#" \
    -e "s#__STARTLIMITBURST__#${SVC_START_LIMIT_BURST}#" \
    -e "s#__RESTARTSEC__#${SVC_RESTART_SEC}#" \
    -e "s#__TIMEOUTSTOP__#${SVC_TIMEOUT_STOP}#" \
    -e "s#__SSHMEMORYMAX__#${SSH_MEMORY_MAX}#" \
    -e "s#__SSHTASKSMAX__#${SSH_TASKS_MAX}#" \
    "${SCRIPT_DIR}/systemd/slowdns-ssh.service.template" > "/etc/systemd/system/${SLOWDNS_SSH_SERVICE}"

state_add "SYSTEMD_UNIT:${SLOWDNS_TUNNEL_SERVICE}"
state_add "SYSTEMD_UNIT:${SLOWDNS_SSH_SERVICE}"

systemctl daemon-reload
systemctl enable "$SLOWDNS_SSH_SERVICE" "$SLOWDNS_TUNNEL_SERVICE"

# ---------------------------------------------------------------------------
# 15. Firewall
# ---------------------------------------------------------------------------
header "Configuring Firewall"

if command -v ufw &>/dev/null; then
    ufw allow "${DNS_UDP_PORT}/udp" comment "Slow DNS VPN tunnel" && state_add "UFW_RULE:${DNS_UDP_PORT}/udp"
    if ufw status | grep -q "Status: active"; then
        log_ok "UFW is active; rule(s) added."
    else
        log_warn "UFW is installed but NOT active. Rules were added but are not being enforced."
        log_warn "The SSH VPN backend listens only on 127.0.0.1 and needs no firewall rule."
    fi
else
    log_warn "UFW not found; skipping firewall configuration. Ensure UDP/${DNS_UDP_PORT} is reachable through any firewall you use."
fi

echo
echo "Note: this architecture does not require IP forwarding or NAT. dnstt is"
echo "a userspace, application-layer tunnel, and the SSH backend provides"
echo "internet access via SSH's dynamic (SOCKS) port forwarding, not routed"
echo "packet forwarding - so no sysctl or iptables NAT changes are made."

# ---------------------------------------------------------------------------
# 16. Start services and verify
# ---------------------------------------------------------------------------
header "Starting Services"

systemctl restart "$SLOWDNS_SSH_SERVICE"
sleep 1
if ! service_is_active "$SLOWDNS_SSH_SERVICE"; then
    journalctl -u "$SLOWDNS_SSH_SERVICE" --no-pager -n 30 || true
    die "${SLOWDNS_SSH_SERVICE} failed to start. See the journal output above."
fi
log_ok "${SLOWDNS_SSH_SERVICE} is running."

systemctl restart "$SLOWDNS_TUNNEL_SERVICE"
sleep 1
if ! service_is_active "$SLOWDNS_TUNNEL_SERVICE"; then
    journalctl -u "$SLOWDNS_TUNNEL_SERVICE" --no-pager -n 30 || true
    die "${SLOWDNS_TUNNEL_SERVICE} failed to start. See the journal output above."
fi
log_ok "${SLOWDNS_TUNNEL_SERVICE} is running."

if ss -uln 2>/dev/null | grep -q ":${DNS_UDP_PORT} "; then
    log_ok "Confirmed: something is listening on UDP/${DNS_UDP_PORT}."
else
    log_warn "Could not confirm a listener on UDP/${DNS_UDP_PORT}. Check 'journalctl -u ${SLOWDNS_TUNNEL_SERVICE}'."
fi

# ---------------------------------------------------------------------------
# 17. Deploy management scripts to /opt and install the `slowdns` command
# ---------------------------------------------------------------------------
header "Installing Management Command"

for d in lib scripts systemd config; do
    mkdir -p "${SLOWDNS_INSTALL_DIR}/${d}"
    cp -a "${SCRIPT_DIR}/${d}/." "${SLOWDNS_INSTALL_DIR}/${d}/"
done
for f in manager.sh status.sh uninstall.sh install.sh README.md LICENSE; do
    [[ -f "${SCRIPT_DIR}/${f}" ]] && cp -a "${SCRIPT_DIR}/${f}" "${SLOWDNS_INSTALL_DIR}/${f}"
done
chmod 0755 "${SLOWDNS_INSTALL_DIR}"/*.sh "${SLOWDNS_INSTALL_DIR}"/scripts/*.sh 2>/dev/null || true

cat > /usr/local/bin/slowdns <<EOF
#!/usr/bin/env bash
exec sudo bash "${SLOWDNS_INSTALL_DIR}/manager.sh" "\$@"
EOF
chmod 0755 /usr/local/bin/slowdns
state_add "FILE:/usr/local/bin/slowdns"
log_ok "Installed the 'slowdns' command."

# ---------------------------------------------------------------------------
# 18. Offer to create the first user
# ---------------------------------------------------------------------------
header "Installation Complete"

echo "Slow DNS domain (client-facing) : ${TUNNEL_DOMAIN}"
echo "Nameserver hostname             : ${NS_HOSTNAME}"
echo "Public IPv4                     : ${PUBLIC_IPV4:-unknown}"
echo "Server public key               : ${PUBKEY_HEX}"
echo "Low-Profile Mode                : ${LOW_PROFILE_MODE}"
echo
# Relative Host/Name examples, derived only when they can be computed without
# guessing the DNS provider's zone: strip the exact base domain the user
# entered from the full hostname. If the user overrode the hostnames, fall
# back to showing full names only.
NS_RELATIVE="" TUNNEL_RELATIVE=""
if [[ "$NS_HOSTNAME" == *".${BASE_DOMAIN}" ]]; then
    NS_RELATIVE="${NS_HOSTNAME%.${BASE_DOMAIN}}"
fi
if [[ "$TUNNEL_DOMAIN" == *".${BASE_DOMAIN}" ]]; then
    TUNNEL_RELATIVE="${TUNNEL_DOMAIN%.${BASE_DOMAIN}}"
fi

cat <<EOF

========================================
  DNS Records You Must Create
========================================

You entered this Slow DNS base domain:
    ${BASE_DOMAIN}

The installer generated these hostnames:
    Nameserver (A record) : ${NS_HOSTNAME}
    Tunnel zone (NS record): ${TUNNEL_DOMAIN}

DNS providers differ in how they handle the Host/Name field. Some
automatically append "${BASE_DOMAIN}", others expect the full hostname.

If your provider appends "${BASE_DOMAIN}" automatically, enter ONLY the
relative Host/Name:

----------------------------------------
A RECORD
----------------------------------------
    Type        : A
    Host / Name : ${NS_RELATIVE:-<use Full name below>}
    Value       : ${PUBLIC_IPV4:-<your server IPv4>}
    Full name   : ${NS_HOSTNAME}

----------------------------------------
NS RECORD
----------------------------------------
    Type        : NS
    Host / Name : ${TUNNEL_RELATIVE:-<use Full name below>}
    Value       : ${NS_HOSTNAME}
    Full name   : ${TUNNEL_DOMAIN}

IMPORTANT: if your provider appends "${BASE_DOMAIN}" automatically, do NOT
paste the full hostname into the Host/Name field - you may accidentally
create something wrong like:
    ${NS_HOSTNAME}.${BASE_DOMAIN}

If your provider expects FULL hostnames, use the "Full name" values above:

    A    ${NS_HOSTNAME}    ->  ${PUBLIC_IPV4:-<your server IPv4>}
    NS   ${TUNNEL_DOMAIN}  ->  ${NS_HOSTNAME}

Providers may call these fields "Host", "Name", "Hostname" or "Record name",
and "Value", "Target", "Points to" or "Nameserver".

If your DNS provider has a proxy/CDN switch, keep the nameserver A record
DNS-only / unproxied.

DNS propagation can take from a few minutes up to 24-48 hours.
EOF
echo

if confirm "Create your first Slow DNS VPN user now?" y; then
    bash "${SLOWDNS_INSTALL_DIR}/scripts/add-user.sh"
fi

header "Done"
echo "Run 'slowdns' any time to open the management menu."
echo
echo "NOTE: This installation was scripted and statically reviewed, but has"
echo "not been validated end-to-end on a live VPS with a real DNS delegation."
echo "Verify DNS propagation and test a client connection before relying on it."
