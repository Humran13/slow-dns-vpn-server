# Slow DNS VPN Server

A clean, professional installer and management system for a self-hosted
**Slow DNS** tunnel server on Ubuntu. It builds and runs
[dnstt](https://www.bamsoftware.com/software/dnstt/) (a mature, public-domain
DNS tunnel), wires it to a dedicated, isolated SSH backend, and gives you a
polished interactive manager (`slowdns`) for creating and administering VPN
users - with real usernames and passwords you control, real account expiry,
real service status, backups, and a clean uninstall.

> Statically reviewed and syntax-checked, but not yet validated end-to-end on
> a live VPS with a real DNS delegation. Verify DNS propagation and test a
> client connection before relying on it in production. See
> [Testing status](#testing-status).

## Table of contents

- [What is Slow DNS](#what-is-slow-dns)
- [What this project does](#what-this-project-does)
- [Architecture overview](#architecture-overview)
- [Supported Ubuntu versions](#supported-ubuntu-versions)
- [VPS requirements](#vps-requirements)
- [Domain and DNS requirements](#domain-and-dns-requirements)
- [Installation](#installation)
- [Creating the first user](#creating-the-first-user)
- [Opening the manager](#opening-the-manager)
- [Managing users](#managing-users)
- [Client configuration](#client-configuration)
- [Required ports](#required-ports)
- [Firewall](#firewall)
- [Low-Profile Mode](#low-profile-mode)
- [Server status](#server-status)
- [Logs](#logs)
- [Backup and restore](#backup-and-restore)
- [Repair](#repair)
- [Uninstall](#uninstall)
- [Troubleshooting](#troubleshooting)
- [Security notes](#security-notes)
- [Project structure](#project-structure)
- [How it works technically](#how-it-works-technically)
- [Testing status](#testing-status)
- [Credits and licenses](#credits-and-licenses)

## What is Slow DNS

A "Slow DNS" tunnel disguises other network traffic as ordinary DNS queries
and responses. Because DNS traffic is almost always allowed through
firewalls and captive portals, this technique lets a client reach a server
even on restrictive networks. It's called "slow" because DNS was never
designed to carry bulk traffic, so throughput is much lower than a normal
connection - but it works where little else does.

This project uses **dnstt**, a well-established, actively maintained,
public-domain DNS tunnel implementation, rather than inventing a new tunnel
protocol.

## What this project does

- Installs and runs a dnstt tunnel server, built from verified upstream
  source.
- Runs a **separate, isolated SSH server** (never your system's admin SSH)
  as the tunnel's local backend, used only to authenticate VPN users.
- Lets you create VPN users with real usernames and passwords, real expiry
  dates, and enable/disable controls - all backed by standard Linux account
  management (`useradd`, `chage`, `passwd`), not a custom credential store.
- Ships an interactive manager (`slowdns`) to add/remove/inspect users,
  check live service status, view logs, back up and restore configuration,
  repair a broken install, and cleanly uninstall.

## Architecture overview

```
tunnel client                  public DNS resolver              this server
(dnstt-client)  <--DNS-->      (recursive resolver)  <--DNS-->  (dnstt-server)
                                                                       |
                                                             127.0.0.1:<port>
                                                                       |
                                                     dedicated, loopback-only
                                                        sshd (Slow DNS users)
                                                                       |
                                                          SSH -D SOCKS proxy
                                                                       |
                                                                   Internet
```

dnstt is a **userspace, application-layer** tunnel - it does not create a
TUN/TAP interface and does not route IP packets. On the client, `dnstt-client`
opens a local TCP port that transports data through DNS to `dnstt-server` on
this VPS, which forwards the decoded TCP stream to a dedicated SSH server
listening only on `127.0.0.1`. The client then makes a normal SSH connection
through that tunnel, authenticates with a username and password created by
the administrator, and uses SSH's built-in dynamic port forwarding (`-D`) to
get a SOCKS proxy for internet access. Because everything is application
layer, **no IP forwarding or NAT is configured or required**.

## Supported Ubuntu versions

| Version | Status |
|---|---|
| Ubuntu 18.04 LTS | Supported (legacy - see warning below) |
| Ubuntu 20.04 LTS | Supported (legacy - see warning below) |
| Ubuntu 22.04 LTS | Supported |
| Ubuntu 24.04 LTS | Supported |
| Ubuntu 26.04 LTS | Supported |

`install.sh` auto-detects your Ubuntu version and architecture (amd64 or
arm64). Anything else exits with a clear, non-destructive error message.

**Legacy warning:** Ubuntu 18.04 and 20.04 may no longer receive normal
public security maintenance from Canonical. The installer will still work on
them, but consider upgrading when practical.

Ubuntu's packaged Go compiler is too old to build modern dnstt (which
requires Go 1.21+), so the installer downloads the official Go toolchain
directly from `go.dev`, verifies its SHA-256 checksum against a pinned value
before use, and removes the toolchain again after building - it is never
left on your system.

## VPS requirements

- A fresh or existing Ubuntu server (see supported versions above).
- Root or sudo access.
- Outbound internet access (to download the Go toolchain and dnstt source
  during installation).
- A domain name you control, with access to add DNS records at your
  registrar/DNS provider.

## Domain and DNS requirements

Slow DNS works by making this server the **authoritative name server** for a
subdomain. You need to add two DNS records at your domain's DNS provider:

```
A    ns.example.com       ->  <this server's public IPv4>
NS   tunnel.example.com   ->  ns.example.com
```

The installer asks for your base domain (e.g. `example.com`) and derives
these two subdomains automatically (you can override the labels if you
prefer). DNS propagation can take anywhere from a few minutes to 24-48
hours. The installer and the manager's **Show DNS Configuration** screen
both check whether these records have propagated correctly.

This installer cannot add these records for you automatically - registrar
APIs vary too widely to support safely and generically. You add them
yourself at your DNS provider.

## Installation

```bash
sudo apt update && sudo apt install -y git && \
  git clone https://github.com/Humran13/slow-dns-vpn-server.git && \
  cd slow-dns-vpn-server && \
  sudo bash install.sh
```

The installer will:

1. Confirm it's running as root, detect your Ubuntu version and CPU
   architecture, and check internet connectivity.
2. Ask for your domain and confirm the derived DNS records.
3. Ask for network options (DNS port, internal SSH backend port).
4. Install required packages, build dnstt from verified source, generate
   tunnel and SSH host keys, write systemd services, configure the firewall
   (if UFW is present), and start everything.
5. Verify the services actually started and the tunnel is actually listening
   - not just that config files exist.
6. Print the DNS records you need to add and offer to create your first
   user.

## Creating the first user

The installer offers to create your first user at the end of installation.
You can also do this any time from the manager (**User Manager -> Add User**), or
directly:

```bash
sudo bash scripts/add-user.sh
```

You'll be asked for a username, a password (or let it generate a secure
random one - shown once), and an expiry (1/7/30/90 days, a custom date, or
never).

## Opening the manager

After installation, run:

```bash
slowdns
```

This opens the interactive management menu, showing live server status
(tunnel + SSH backend), domain, and user count, with numbered options for
every management task:

```
[01] User Manager
[02] Service Control
[03] Connection Details
[04] Server Information
[05] DNS Configuration
[06] Server Status
[07] Logs
[08] Backup
[09] Restore
[10] Update / Repair Installation
[11] Uninstall
[00] Exit
```

Three options open their own submenu:

- **User Manager** - add, remove, list, and inspect users; change passwords,
  set expiry, and enable/disable accounts:

  ```
  [01] Add User
  [02] Remove User
  [03] List Users
  [04] Show User
  [05] Change Password
  [06] Set Expiry
  [07] Enable User
  [08] Disable User
  [00] Back
  ```

- **Service Control** - start, restart, and stop the Slow DNS services, or
  restart just the tunnel or just the SSH backend:

  ```
  [01] Start Slow DNS
  [02] Restart Slow DNS
  [03] Stop Slow DNS
  [04] Restart Tunnel Only
  [05] Restart SSH Backend Only
  [00] Back
  ```

- **Logs** - view or follow the tunnel and SSH backend logs, and show the
  real systemd state of both services:

  ```
  [01] Tunnel Logs - Last 50 Lines
  [02] SSH Backend Logs - Last 50 Lines
  [03] Follow Tunnel Logs
  [04] Follow SSH Backend Logs
  [05] Show Both Service Status
  [00] Back
  ```

**Service Control only ever manages the two project services,
`slowdns-tunnel.service` and `slowdns-ssh.service`.** It never stops,
starts, or restarts your VPS's administrative SSH server.

## Managing users

All from the `slowdns` menu (or directly via `scripts/*.sh`):

- **Add User** - create a new VPN user with a username, password, and
  expiry.
- **Remove User** - delete a Slow DNS user (asks for confirmation, default
  No; never touches unrelated Linux accounts).
- **List Users** - a table of username / status / expiry (never shows
  password hashes).
- **Show User** - full detail view for one user.
- **Change User Password** - reset a user's password (generate or enter
  manually).
- **Set User Expiry** - set, extend, or remove an account's expiry date,
  backed by standard `chage`.
- **Enable / Disable User** - lock/unlock an account without deleting it.

Status is always: **Active**, **Disabled**, or **Expired**, computed live
from the real Linux account state (`passwd -S` / `chage`), never guessed.

## Client configuration

Use **slowdns -> 3) Connection Details** for the exact values
for your server. In general, the client needs:

- The tunnel domain (e.g. `tunnel.example.com`)
- The nameserver hostname (e.g. `ns.example.com`)
- The server's tunnel public key (safe to share - it's not a secret)
- A Slow DNS username and password created via the manager

A typical client-side flow (using the official `dnstt-client`, or a
compatible mobile Slow DNS app):

```bash
dnstt-client -udp ns.example.com -pubkey <server-public-key> \
  tunnel.example.com 127.0.0.1:7000

ssh -p 7000 -o HostKeyAlias=slowdns -D 1080 <username>@127.0.0.1
```

Point your applications at the resulting SOCKS proxy on `127.0.0.1:1080`.

## Required ports

| Port | Protocol | Exposure | Purpose |
|---|---|---|---|
| 53 (configurable) | UDP | Public | DNS tunnel traffic |
| SSH backend port (default 2222) | TCP | `127.0.0.1` only | Tunnel's SSH backend - never exposed externally |

Your existing administrative SSH port is never modified.

## Firewall

If UFW is installed, the installer adds an `allow` rule for the DNS tunnel
port(s) with a comment identifying it, and leaves every other rule untouched
- it never runs `ufw reset` or removes existing rules. If UFW isn't active,
you're warned that the rule was added but isn't being enforced. The SSH
backend needs no firewall rule since it only listens on loopback.

## Low-Profile Mode

Low-Profile Mode is an optional installation choice that makes the server
behave more conservatively: smaller DNS responses, longer keepalive and
restart intervals, a bounded number of restart attempts, tighter connection
rate limits on the SSH backend, and sensible resource ceilings so a stuck
process can't run away with memory or process slots.

**What it does not do:** Low-Profile Mode is not an anti-detection,
firewall-bypass, censorship-evasion, or IDS/IPS-evasion feature. It does not
make Slow DNS traffic invisible, undetectable, impossible to block, or
DPI-proof. DNS tunneling has a distinctive traffic pattern; a network
administrator who is actively looking for it (via query volume, query
patterns, or DNS analytics) can still identify and block it regardless of
this setting. Only use this project on networks and services where you are
authorized to do so, and comply with the applicable terms of service and
local laws.

**How to enable it:** answer "y" to the "Enable Low-Profile Mode?" prompt
during `sudo bash install.sh`. To change it on an existing installation,
re-run `sudo bash install.sh` and answer the prompt differently - your
domain, users, and tunnel/SSH keys are preserved; only the SSH backend
config and systemd services are regenerated.

**How to disable it:** answer "n" to the same prompt (this is also the
default). `slowdns -> 4) Server Information` and `slowdns -> 6) Server Status` both
show whether it's currently `Enabled` or `Disabled`.

**Settings it changes** (normal-mode values shown are the project's regular
defaults - Low-Profile Mode does not change them for an install that leaves
it disabled):

| Setting | Normal | Low-Profile | Why |
|---|---|---|---|
| dnstt `-mtu` (DNS response size) | 1232 | 512 | Smaller UDP responses, less fragmentation |
| SSH `ClientAliveInterval` / `CountMax` | 60s / 3 | 120s / 3 | Fewer keepalive probes |
| SSH `MaxAuthTries` | 4 | 3 | Fewer auth attempts per connection |
| SSH `LoginGraceTime` | 20s | 15s | Less time held open by an unauthenticated connection |
| SSH `MaxStartups` (unauthenticated connection limit) | `10:30:100` | `5:50:20` | Tighter cap on concurrent unauthenticated connections |
| systemd `RestartSec` (both services) | 3s | 10s | Fewer, more spaced-out restart attempts |
| systemd `StartLimitIntervalSec` / `StartLimitBurst` | 10s / 5 | 300s / 5 | Bounded restart attempts, never an infinite tight loop |
| systemd `TimeoutStopSec` | 90s | 10s | Faster, cleaner shutdown/restart |
| systemd `MemoryMax` / `TasksMax` | unlimited | 256M/64 (tunnel), 512M/256 (SSH backend) | Ceiling against a runaway process |

The "Normal" values for `MaxStartups`, `StartLimitIntervalSec`/`Burst`,
`TimeoutStopSec`, `MemoryMax`, and `TasksMax` are OpenSSH's and systemd's own
real default behavior, made explicit in the generated config - a normal-mode
install behaves exactly as it always has.

Two things intentionally are **not** changed by Low-Profile Mode, and it's
worth being explicit about why: dnstt-server has no verbose/debug logging
flag to begin with (this installer never enables one, in either mode), and
DNS query frequency is controlled by the client's `dnstt-client`, not this
server-side installer - so there's no honest server-side setting for either
one to toggle.

**Tradeoffs:** enabling Low-Profile Mode reduces downstream tunnel bandwidth
(smaller MTU means less data per DNS response) and means a crashing service
waits longer between restart attempts and gives up sooner if it keeps
failing, which can mean slightly longer downtime during a real outage in
exchange for less restart noise during a transient one.

## Server status

```bash
sudo bash status.sh
```

or **slowdns -> 6) Server Status**. Every line reflects a real check
(systemd unit state, an actual listening socket) - never "the config file
exists, so it must be running."

## Logs

**slowdns -> 7) Logs** opens the Logs submenu: the tunnel and SSH backend
logs (last 50 lines each), live follow mode for each, and a combined view of
real service status. It only reads `slowdns-tunnel.service` and
`slowdns-ssh.service` - the VPS administrative SSH logs are never shown or
followed.

## Backup and restore

**Backup** (`scripts/backup.sh` or **slowdns -> 8) Backup**) archives
`server.conf`, tunnel/SSH keys, per-user metadata, and the account
lines (from `/etc/passwd` / `/etc/shadow`, restricted to Slow DNS users
only - never the whole system files) into
`/var/backups/slow-dns-vpn/slowdns-backup-<timestamp>.tar.gz`, mode `600`.

**Restore** (`scripts/restore.sh` or **slowdns -> 9) Restore**) validates the
archive, takes a safety backup of the *current* state first, restores
configuration/keys/accounts, validates the resulting SSH configuration
before restarting anything, and verifies both services come back up.

## Repair

**slowdns -> 10) Update / Repair Installation** (`scripts/repair.sh`)
detects and fixes: missing packages, incorrect permissions, a missing
binary, disabled or stopped services, a tunnel that isn't actually
listening, an invalid SSH backend config, and a missing firewall rule. It
never touches user accounts.

## Uninstall

```bash
sudo bash uninstall.sh
```

or **slowdns -> 11) Uninstall**. It explains exactly what will be
removed (services, config, keys, firewall rules added by this installer, the
`slowdns` command, the dedicated service account) before asking for
confirmation (default **No**). You are asked separately whether to also
delete the Slow DNS user accounts it created. Packages are left installed
since other software may depend on them. Nothing unrelated - other users,
Docker, Nginx, WireGuard, CloudPanel, your admin SSH access, unrelated
firewall rules - is ever touched.

## Troubleshooting

- **DNS record check fails / tunnel not reachable**: DNS propagation can
  take up to 24-48 hours. Use **slowdns -> 5) DNS Configuration** to
  re-check.
- **Tunnel service won't start**: `journalctl -u slowdns-tunnel.service -n
  50`. Common cause: another process already bound to the configured UDP
  port.
- **SSH backend won't start**: `journalctl -u slowdns-ssh.service -n 50`.
  The installer validates the config with `sshd -t` before ever starting or
  restarting it, so a running install should always have valid config.
- **User can't connect**: check status with **slowdns -> User Manager -> Show User** -
  make sure the account isn't Disabled or Expired.
- **Something seems broken after an update**: run **slowdns -> 10) Update /
  Repair Installation**.

## Security notes

- No default/hidden accounts, credentials, or backdoors of any kind.
- Passwords are only ever handled via standard Linux `chpasswd`/`passwd`
  mechanisms; they are never stored in plaintext by this project, and
  auto-generated passwords are shown exactly once at creation time.
- Password hashes are never printed by any script or menu.
- VPN users get no shell (`/usr/sbin/nologin`), no PTY, no sudo, and are not
  members of any administrative group - they exist solely to authenticate
  to the isolated SSH tunnel backend.
- The tunnel backend SSH server is entirely separate from, and never
  modifies, your system's administrative `sshd`. Any change this project
  makes to SSH is validated with `sshd -t` before the affected service is
  (re)started; on validation failure, the service is left as-is.
- `/etc/sudoers` is never modified.
- The firewall is never reset or flushed; only specific rules this
  installer needs are added, and they are tracked so uninstall removes only
  what it added.
- No telemetry, analytics, tracking, or external accounts of any kind.
- Downloaded artifacts (the Go toolchain, the dnstt source) are verified -
  by SHA-256 checksum and by pinned git commit hash, respectively - before
  use.

## Project structure

```
slow-dns-vpn-server/
├── install.sh              Primary installer
├── manager.sh               Interactive management menu (the `slowdns` command)
├── uninstall.sh              Clean removal
├── status.sh                 Live server status report
├── lib/
│   └── common.sh              Shared functions used by every script
├── scripts/
│   ├── add-user.sh, remove-user.sh, list-users.sh, show-user.sh
│   ├── change-password.sh, set-expiry.sh, enable-user.sh, disable-user.sh
│   ├── connection-details.sh, dns-config.sh
│   └── backup.sh, restore.sh, repair.sh
├── systemd/
│   ├── slowdns-tunnel.service.template
│   └── slowdns-ssh.service.template
├── config/
│   └── sshd_config.tunnel.template
├── README.md, LICENSE, .gitignore
```

## How it works technically

**Authentication flow:** every Slow DNS user is a real (restricted) Linux
account. Passwords are set with `chpasswd`, expiry with `chage -E`, and
enable/disable with `usermod -L` / `usermod -U`. The dedicated tunnel `sshd`
authenticates connections against these accounts via PAM/`pam_unix`, exactly
like normal SSH password authentication - just against an isolated,
loopback-only sshd instance whose config forces no shell, no PTY, and only
TCP forwarding.

**DNS flow:** the client's `dnstt-client` encodes tunnel traffic as DNS
queries under the delegated tunnel zone (e.g. `tunnel.example.com`) and
sends them to a public recursive resolver (or directly to this server in
plaintext UDP test mode). Because of the `NS` delegation, the resolver
forwards those queries to this server's `dnstt-server`, which decodes them,
authenticates/encrypts the session with a Noise protocol handshake
(`Noise_NK_25519_ChaChaPoly_BLAKE2s`), and forwards the resulting TCP stream
to the local SSH backend on `127.0.0.1`.

**Why a second sshd instead of touching the main one:** running an entirely
separate sshd on a loopback-only port, with its own host keys and config,
means this project never needs to edit, restart, or risk your existing
administrative SSH server. If anything about the Slow DNS SSH config were
ever wrong, the worst case is the tunnel backend fails to start - your
ability to SSH into the server as an administrator is completely unaffected.

**Why no IP forwarding/NAT:** dnstt is application-layer (it forwards a TCP
stream, not IP packets), and the VPN's internet access comes from SSH's
built-in dynamic port forwarding (SOCKS proxy), which is also
application-layer. There is no TUN/TAP interface and nothing for the kernel
to route, so `net.ipv4.ip_forward` and NAT rules are irrelevant to this
architecture and are intentionally left untouched.

## Testing status

This project has been statically reviewed (`bash -n` syntax checks on every
script, manual review for unquoted variables, destructive commands, and
unsafe defaults) but **has not yet been validated end-to-end on a real VPS**
across Ubuntu 18.04/20.04/22.04/24.04/26.04 with a real DNS delegation. Real
VPS validation is a separate, follow-up step - do not treat this README as a
claim of "production tested."

## Credits and licenses

- **dnstt** - the DNS tunnel implementation this project builds and runs,
  by David Fifield. Public domain (dual-licensed CC0-1.0 / GPL-3.0). Source:
  `https://www.bamsoftware.com/software/dnstt/`. This installer builds it
  from a pinned, integrity-checked commit rather than bundling a binary.
- **Go** - the official Go toolchain from `go.dev`, downloaded and
  SHA-256-verified at install time solely to compile dnstt, then removed.
- **OpenSSH** - the standard Ubuntu `openssh-server` package provides the
  isolated tunnel backend `sshd`.
- This project's own installer and management scripts are MIT licensed; see
  [LICENSE](LICENSE).
