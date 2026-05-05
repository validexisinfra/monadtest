#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════
# install-monad-fullnode.sh
# Automated Monad mainnet fullnode installation on Ubuntu 24.04
#
# Installs and configures a Monad fullnode with TrieDB on a raw NVMe
# device, generates keystore, starts sync, and sets up Telegram alerts.
#
# Usage:
#   sudo TELEGRAM_BOT_TOKEN="..." TELEGRAM_CHAT_ID="..." \
#     bash install-monad-fullnode.sh \
#     --triedb-device /dev/nvme1n1 \
#     --node-name "MyNode" \
#     --self-ip "1.2.3.4"
#
# Environment variables (REQUIRED):
#   TELEGRAM_BOT_TOKEN  - Get from @BotFather on Telegram
#   TELEGRAM_CHAT_ID    - Get by messaging your bot then visiting:
#                         https://api.telegram.org/bot<TOKEN>/getUpdates
#
# All arguments:
#   --triedb-device   NVMe device for TrieDB (REQUIRED, e.g. /dev/nvme1n1)
#   --node-name       Node name for P2P network (REQUIRED)
#   --self-ip         Public IP address (REQUIRED)
#   --beneficiary     EVM address for rewards (default: 0x0...0 burn)
#   --ssh-port        SSH port to configure in UFW (default: 2225)
#   --skip-triedb     Skip TrieDB partition/init (if already done)
#   --skip-keys       Skip keystore generation (if keys exist)
#   --skip-monitoring Skip Telegram monitoring setup
#   --dry-run         Show what would be done without executing
#   -h, --help        Show this help
#
# ═══════════════════════════════════════════════════════════════════════
set -euo pipefail

# ═══════════════════════════════════════════════════════════════════════
# CONFIGURATION
# ═══════════════════════════════════════════════════════════════════════
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"
MONAD_VERSION="0.14.2"
APT_REPO_URL="https://pkg.category.xyz/"
APT_REPO_SUITE="noble"
GPG_KEY_URL="https://pkg.category.xyz/keys/public-key.asc"
REMOTE_FORKPOINT_URL="https://bucket.monadinfra.com/forkpoint/mainnet/forkpoint.toml"
REMOTE_VALIDATORS_URL="https://bucket.monadinfra.com/validators/mainnet/validators.toml"
CHAIN="monad_mainnet"
RETENTION_LEDGER=600
RETENTION_WAL=300
RETENTION_FORKPOINT=300
RETENTION_VALIDATORS=43200

# ═���═════════════════════════════════════════════════════════════════════
# GLOBALS
# ═══════════════════════════════════════════════════════════════════════
LOGFILE="/var/log/monad-install.log"
MONAD_HOME="/home/monad"
MONAD_BFT="${MONAD_HOME}/monad-bft"
CONFIG_DIR="${MONAD_BFT}/config"
DRY_RUN=false
SKIP_TRIEDB=false
SKIP_KEYS=false
SKIP_MONITORING=false
SKIP_SNAPSHOT=false
ENABLE_ON_BOOT=false
ASSUME_YES=false
TRIEDB_DEVICE=""
NODE_NAME=""
SELF_IP=""
BENEFICIARY="0x0000000000000000000000000000000000000000"
SSH_PORT=2225

# ═══════════════════════════════════════════════════════════════════════
# LOGGING
# ═══════════════════════════════════════════════════════════════════════
mkdir -p "$(dirname "$LOGFILE")"
# Pre-create LOGFILE with strict perms so tee -a doesn't open it world-readable
touch "$LOGFILE"
chmod 600 "$LOGFILE"
chown root:root "$LOGFILE"
exec > >(tee -a "$LOGFILE") 2>&1

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
log_ok() { log "✓ $*"; }
log_warn() { log "⚠ $*"; }
log_err() { log "✗ $*"; }

tg_notify() {
  local msg="$1"
  curl -sS --max-time 10 \
    -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    -d chat_id="${TELEGRAM_CHAT_ID}" \
    -d parse_mode="Markdown" \
    -d text="${msg}" > /dev/null 2>&1 || true
}

fail() {
  log_err "$1"
  tg_notify "❌ *Install failed* on $(hostname) ($SELF_IP)"$'\n'"Phase: $2"$'\n'"Error: $1"
  exit 1
}

# Extract ONLY the public key line from `monad-keystore recover` output.
# `recover --key-type X` prints multiple lines including IKM and private key
# (this is by-design CLI behavior). We whitelist only the pubkey line.
# Return: prints "Secp public key: <hex>" or "BLS public key: <hex>" to stdout.
extract_pubkey() {
  local key_type="$1"     # secp | bls
  local keystore_path="$2"
  local password="$3"
  sudo -u monad -E env KEYSTORE_PASSWORD="$password" \
    /usr/local/bin/monad-keystore recover \
      --keystore-path "$keystore_path" \
      --password "$password" \
      --key-type "$key_type" 2>/dev/null \
    | grep -iE "^(secp|bls)[[:space:]]+public[[:space:]]+key:"
}

# ═══════════════════════════════════════════════════════════════════════
# ARGUMENT PARSING
# ═══════════════════════════════════════════════════════════════════════
show_help() {
  sed -n '/^# Usage:/,/^# ═/p' "$0" | grep "^#" | sed 's/^# //'
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --triedb-device) TRIEDB_DEVICE="$2"; shift 2 ;;
    --node-name) NODE_NAME="$2"; shift 2 ;;
    --self-ip) SELF_IP="$2"; shift 2 ;;
    --beneficiary) BENEFICIARY="$2"; shift 2 ;;
    --ssh-port) SSH_PORT="$2"; shift 2 ;;
    --skip-triedb) SKIP_TRIEDB=true; shift ;;
    --skip-keys) SKIP_KEYS=true; shift ;;
    --skip-monitoring) SKIP_MONITORING=true; shift ;;
    --skip-snapshot) SKIP_SNAPSHOT=true; shift ;;
    --enable-on-boot) ENABLE_ON_BOOT=true; shift ;;
    -y|--yes) ASSUME_YES=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    -h|--help) show_help ;;
    *) log_err "Unknown argument: $1"; show_help ;;
  esac
done

# ═══════════════════════════════════════════════════════════════════════
# PRE-FLIGHT CHECKS
# ═══════════════════════════════════════════════════════════════════════
preflight() {
  log "═══ PRE-FLIGHT CHECKS ═══"

  [[ $EUID -eq 0 ]] || { log_err "Must run as root"; exit 1; }

  if [[ "$SKIP_MONITORING" == false ]]; then
    if [[ -z "$TELEGRAM_BOT_TOKEN" || -z "$TELEGRAM_CHAT_ID" ]]; then
      log_err "TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID must be set as env vars"
      echo ""
      echo "Usage:"
      echo "  sudo TELEGRAM_BOT_TOKEN=... TELEGRAM_CHAT_ID=... \\"
      echo "    bash $0 --triedb-device /dev/nvme1n1 --node-name NAME --self-ip IP"
      echo ""
      echo "Get TELEGRAM_BOT_TOKEN from @BotFather on Telegram"
      echo "Get TELEGRAM_CHAT_ID from: https://api.telegram.org/bot<TOKEN>/getUpdates"
      echo ""
      echo "Or use --skip-monitoring to skip Telegram setup"
      exit 1
    fi
  fi

  local os_id os_ver
  os_id=$(. /etc/os-release && echo "$ID")
  os_ver=$(. /etc/os-release && echo "$VERSION_ID")
  [[ "$os_id" == "ubuntu" && "$os_ver" == "24.04" ]] || \
    { log_err "Requires Ubuntu 24.04, got $os_id $os_ver"; exit 1; }

  [[ -n "$TRIEDB_DEVICE" ]] || { log_err "--triedb-device is required"; exit 1; }
  [[ -n "$NODE_NAME" ]] || { log_err "--node-name is required"; exit 1; }
  [[ -n "$SELF_IP" ]] || { log_err "--self-ip is required"; exit 1; }

  if [[ "$SKIP_TRIEDB" == false ]]; then
    [[ -b "$TRIEDB_DEVICE" ]] || { log_err "$TRIEDB_DEVICE is not a block device"; exit 1; }
    if mount | grep -q "$TRIEDB_DEVICE"; then
      log_err "$TRIEDB_DEVICE is currently mounted — unmount first"
      exit 1
    fi
  fi

  # Validate IP format
  if ! [[ "$SELF_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    log_err "Invalid IP format: $SELF_IP"
    exit 1
  fi

  log_ok "Pre-flight passed: device=$TRIEDB_DEVICE name=$NODE_NAME ip=$SELF_IP"

  if [[ "$DRY_RUN" == true ]]; then
    log "DRY RUN — would install monad $MONAD_VERSION fullnode"
    log "  TrieDB: $TRIEDB_DEVICE"
    log "  Node: $NODE_NAME @ $SELF_IP:8000"
    log "  Beneficiary: $BENEFICIARY"
    exit 0
  fi

  echo ""
  echo "══════════════════════════════════════════════════"
  echo " Monad Fullnode Installation"
  echo " Version: $MONAD_VERSION"
  echo " TrieDB:  $TRIEDB_DEVICE"
  echo " Name:    $NODE_NAME"
  echo " IP:      $SELF_IP"
  echo "══════════════════════════════════════════════════"
  echo ""
  if [[ "$ASSUME_YES" != true ]]; then
    read -p "Continue? [y/N] " -r
    [[ "$REPLY" =~ ^[Yy]$ ]] || { log "Aborted by user"; exit 0; }
  else
    log "Auto-confirmed (--yes)"
  fi
}

# ═══════════════════════════════════════════════════════════════════════
# PHASE 1: System Preparation
# ═══════════════════════════════════════════════════════════════════════
phase1_system() {
  log "═══ PHASE 1: System Preparation ═══"

  export DEBIAN_FRONTEND=noninteractive

  apt-get update -qq
  # NOTE: iptables-persistent removed in v2 — conflicts with ufw on Ubuntu 24.04 noble
  # (ufw 0.36.2-6 declares Breaks: iptables-persistent). Anti-amplification rule
  # below is added live via iptables; ufw handles persistence via its own service.
  apt-get install -y --no-install-recommends \
    curl nvme-cli jq ufw fail2ban \
    python3 openssl ca-certificates gnupg >> "$LOGFILE" 2>&1

  # Create monad user if not exists
  if ! id monad &>/dev/null; then
    useradd -m -s /bin/bash monad
    passwd -l monad
    log_ok "Created user monad (locked)"
  else
    log_ok "User monad already exists"
  fi

  # Directory structure
  mkdir -p "${CONFIG_DIR}"/{forkpoint,validators}
  mkdir -p "${MONAD_BFT}/ledger"
  mkdir -p /etc/monad
  mkdir -p /opt/monad/backup

  # Firewall
  if command -v ufw &>/dev/null; then
    ufw --force reset > /dev/null 2>&1 || true
    ufw default deny incoming
    ufw default allow outgoing
    ufw allow "${SSH_PORT}/tcp" comment "SSH"
    ufw allow 8000/tcp comment "Monad P2P"
    ufw allow 8001/udp comment "Monad Auth"
    ufw --force enable
    log_ok "UFW configured (SSH:${SSH_PORT}, P2P:8000, Auth:8001)"
  fi

  # Anti-amplification iptables rule (live; not persisted across reboot
  # because iptables-persistent was removed — see note above. To make
  # persistent without iptables-persistent, use ufw: `ufw deny in proto udp
  # to any port 8000 length 0-1400` or systemd-iptables-restore unit.)
  if ! iptables -C INPUT -p udp --dport 8000 -m length --length 0:1400 -j DROP 2>/dev/null; then
    iptables -I INPUT -p udp --dport 8000 -m length --length 0:1400 -j DROP
    log_ok "iptables anti-spam rule added (live, not persisted across reboot)"
  fi

  # Fail2ban
  systemctl enable fail2ban --now 2>/dev/null || true
  log_ok "fail2ban enabled"

  # hidepid on /proc
  if ! mount | grep -q "hidepid=invisible"; then
    mount -o remount,hidepid=invisible /proc 2>/dev/null || true
    if ! grep -q "hidepid" /etc/fstab; then
      echo "proc /proc proc defaults,hidepid=2 0 0" >> /etc/fstab
    fi
    log_ok "hidepid configured"
  fi

  # Disable swap
  swapoff -a 2>/dev/null || true
  sed -i '/\sswap\s/d' /etc/fstab

  # Rsyslog filter for monad logs
  cat > /etc/rsyslog.d/01-monad-discard.conf << 'RSYSEOF'
if $programname startswith 'monad' then stop
if $msg contains 'monad-node' then stop
if $msg contains 'monad-rpc' then stop
if $msg contains 'monad_' then stop
RSYSEOF
  systemctl restart rsyslog 2>/dev/null || true

  log_ok "Phase 1 complete"
}

# ═══════════════════════════════════════════════════════════════════════
# PHASE 2: Monad Package Installation
# ═══════════════════════════════════════════════════════════════════════
phase2_package() {
  log "═══ PHASE 2: Monad Package Installation ═══"

  # GPG key
  if [[ ! -f /etc/apt/keyrings/category-labs.gpg ]]; then
    mkdir -p /etc/apt/keyrings
    curl -fsSL "${GPG_KEY_URL}" | gpg --dearmor --yes -o /etc/apt/keyrings/category-labs.gpg
    log_ok "GPG key installed"
  else
    log_ok "GPG key already exists"
  fi

  # APT source
  if [[ ! -f /etc/apt/sources.list.d/category-labs.sources ]]; then
    cat > /etc/apt/sources.list.d/category-labs.sources << APTEOF
Types: deb
URIs: ${APT_REPO_URL}
Suites: ${APT_REPO_SUITE}
Components: main
Signed-By: /etc/apt/keyrings/category-labs.gpg
APTEOF
    log_ok "APT source added"
  else
    log_ok "APT source already exists"
  fi

  apt-get update -qq

  # Install monad
  local installed_ver
  installed_ver=$(dpkg-query -W -f='${Version}' monad 2>/dev/null || echo "none")
  if [[ "$installed_ver" != "$MONAD_VERSION" ]]; then
    apt-get install -y "monad=${MONAD_VERSION}"
    apt-mark hold monad
    log_ok "Monad ${MONAD_VERSION} installed and held"
  else
    log_ok "Monad ${MONAD_VERSION} already installed"
  fi
}

# ═══════════════════════════════════════════════════════════════════════
# PHASE 3: TrieDB Setup
# ═══════════════════════════════════════════════════════════════════════
phase3_triedb() {
  log "═══ PHASE 3: TrieDB Setup ═══"

  if [[ "$SKIP_TRIEDB" == true ]]; then
    log_warn "Skipping TrieDB setup (--skip-triedb)"
    return 0
  fi

  # Check if /dev/triedb already points to correct device
  if [[ -L /dev/triedb ]]; then
    local current_target
    current_target=$(readlink -f /dev/triedb)
    if [[ "$current_target" == "${TRIEDB_DEVICE}"* ]]; then
      log_warn "/dev/triedb already exists → $current_target"
      if [[ "$ASSUME_YES" != true ]]; then
        read -p "Re-initialize TrieDB? This DESTROYS all data! [y/N] " -r
        [[ "$REPLY" =~ ^[Yy]$ ]] || { log "Keeping existing TrieDB"; return 0; }
      else
        log_warn "Auto-confirmed re-init via --yes (DESTRUCTIVE)"
      fi
    fi
  fi

  # v2: use raw NVMe device (no partition table). Cleaner, simpler, identical
  # performance — TrieDB does its own block management; partition adds zero value.
  log "Wiping signatures on ${TRIEDB_DEVICE}..."
  wipefs -a "${TRIEDB_DEVICE}" >> "$LOGFILE" 2>&1

  # Get serial for udev rule
  local SERIAL
  SERIAL=$(udevadm info --query=property "$TRIEDB_DEVICE" | grep "^ID_SERIAL_SHORT=" | cut -d= -f2)
  if [[ -z "$SERIAL" ]]; then
    SERIAL=$(nvme id-ctrl "$TRIEDB_DEVICE" 2>/dev/null | grep "^sn" | awk '{print $3}')
  fi
  [[ -n "$SERIAL" ]] || fail "Cannot determine NVMe serial number" "Phase 3"

  # Create udev rule — bind /dev/triedb to whole-disk device by serial.
  # OWNER/GROUP/MODE applied to the device node itself; symlink permissions
  # are inherited from target.
  cat > /etc/udev/rules.d/99-monad-triedb.rules << UDEVEOF
SUBSYSTEM=="block", ENV{DEVTYPE}=="disk", ENV{ID_SERIAL_SHORT}=="${SERIAL}", SYMLINK+="triedb", OWNER="monad", GROUP="monad", MODE="0660"
UDEVEOF

  udevadm control --reload-rules
  udevadm trigger --subsystem-match=block
  sleep 2

  [[ -L /dev/triedb ]] || fail "/dev/triedb symlink not created after udev trigger" "Phase 3"
  log_ok "udev rule created: serial=${SERIAL} → /dev/triedb"

  # Initialize TrieDB storage pool on raw device
  log "Initializing TrieDB storage pool (monad-mpt --truncate)..."
  sudo -u monad /usr/local/bin/monad-mpt --storage /dev/triedb --truncate --yes >> "$LOGFILE" 2>&1
  log_ok "TrieDB initialized on /dev/triedb (raw ${TRIEDB_DEVICE})"
}

# ═══════════════════════════════════════════════════════════════════════
# PHASE 4: Keystore Generation
# ═══════════════════════════════════════════════════════════════════════
phase4_keystore() {
  log "═══ PHASE 4: Keystore Generation ═══"

  if [[ "$SKIP_KEYS" == true ]]; then
    log_warn "Skipping keystore generation (--skip-keys)"
    return 0
  fi

  if [[ -f "${CONFIG_DIR}/id-secp" && -f "${CONFIG_DIR}/id-bls" ]]; then
    log_warn "Keys already exist at ${CONFIG_DIR}/id-secp and id-bls"
    if [[ "$ASSUME_YES" != true ]]; then
      read -p "Overwrite existing keys? [y/N] " -r
      [[ "$REPLY" =~ ^[Yy]$ ]] || { log "Keeping existing keys"; return 0; }
    else
      log_warn "Auto-confirmed key overwrite via --yes"
    fi
  fi

  # Generate keystore password
  local KS_PASSWORD
  KS_PASSWORD=$(openssl rand -base64 32)

  # Write .env
  cat > "${MONAD_HOME}/.env" << ENVEOF
CHAIN=${CHAIN}
KEYSTORE_PASSWORD=${KS_PASSWORD}
REMOTE_VALIDATORS_URL='${REMOTE_VALIDATORS_URL}'
REMOTE_FORKPOINT_URL='${REMOTE_FORKPOINT_URL}'
RETENTION_LEDGER=${RETENTION_LEDGER}
RETENTION_WAL=${RETENTION_WAL}
RETENTION_FORKPOINT=${RETENTION_FORKPOINT}
RETENTION_VALIDATORS=${RETENTION_VALIDATORS}
ENVEOF
  chown root:monad "${MONAD_HOME}/.env"
  chmod 640 "${MONAD_HOME}/.env"

  # Write keystore.env for systemd override
  cat > /etc/monad/keystore.env << KSEOF
KEYSTORE_PASSWORD=${KS_PASSWORD}
KSEOF
  chown root:root /etc/monad/keystore.env
  chmod 600 /etc/monad/keystore.env

  # Backup password (root-only)
  echo "$KS_PASSWORD" > /opt/monad/backup/keystore-password-backup
  chown root:root /opt/monad/backup/keystore-password-backup
  chmod 600 /opt/monad/backup/keystore-password-backup

  # v2: Generate keys silently. monad-keystore create stdout contains IKM and
  # private key (by-design CLI behavior). We suppress stdout entirely and use
  # `recover` afterwards with whitelist-grep to extract ONLY the public-key line.
  log "Generating secp256k1 key..."
  sudo -u monad /usr/local/bin/monad-keystore create \
    --keystore-path "${CONFIG_DIR}/id-secp" \
    --password "$KS_PASSWORD" >/dev/null 2>>"$LOGFILE" \
    || fail "monad-keystore create (secp) failed" "Phase 4"

  log "Generating BLS key..."
  sudo -u monad /usr/local/bin/monad-keystore create \
    --keystore-path "${CONFIG_DIR}/id-bls" \
    --password "$KS_PASSWORD" >/dev/null 2>>"$LOGFILE" \
    || fail "monad-keystore create (bls) failed" "Phase 4"

  # Tight perms on keystore files BEFORE exposing anything else
  chown monad:monad "${CONFIG_DIR}/id-secp" "${CONFIG_DIR}/id-bls"
  chmod 600 "${CONFIG_DIR}/id-secp" "${CONFIG_DIR}/id-bls"

  # Extract pubkeys via whitelist filter (no IKM/private-key leak)
  {
    echo "# Monad Fullnode public keys"
    echo "# Generated: $(date -Iseconds)"
    echo "# Node: ${NODE_NAME} @ ${SELF_IP}"
    extract_pubkey secp "${CONFIG_DIR}/id-secp" "$KS_PASSWORD"
    extract_pubkey bls  "${CONFIG_DIR}/id-bls"  "$KS_PASSWORD"
  } > /opt/monad/backup/pubkeys.txt
  chown root:root /opt/monad/backup/pubkeys.txt
  chmod 600 /opt/monad/backup/pubkeys.txt

  # Sanity: ensure no private/IKM leaked into pubkeys.txt
  if grep -qiE "private|secret|IKM" /opt/monad/backup/pubkeys.txt; then
    fail "pubkeys.txt contains private/IKM material — aborting (security)" "Phase 4"
  fi

  log_ok "Keys generated; pubkeys.txt clean (root:root 600)"
}

# ═══════════════════════════════════════════════════════════════════════
# PHASE 5: node.toml Configuration
# ═══════════════════════════════════════════════════════════════════════
phase5_config() {
  log "═══ PHASE 5: node.toml Configuration ═══"

  # Write node.toml
  cat > "${CONFIG_DIR}/node.toml" << 'NODEEOF'
#########################################################
# Node-specific configuration
#########################################################
beneficiary = "__BENEFICIARY__"
node_name = "__NODE_NAME__"
network_name = "mainnet"
ipc_tx_batch_size = 1000
ipc_max_queued_batches = 10
ipc_queued_batches_watermark = 3

statesync_threshold = 600
statesync_max_concurrent_requests = 5

#########################################################
# Network-wide configuration
#########################################################
chain_id = 143

[peer_discovery]
self_address = "__SELF_IP__:8000"
self_auth_port = 8001
self_record_seq_num = 0
self_name_record_sig = "__NAME_RECORD_SIG__"
refresh_period = 20
request_timeout = 5
unresponsive_prune_threshold = 3
last_participation_prune_threshold = 1000
min_num_peers = 150
max_num_peers = 350
ping_rate_limit_per_second = 100

[fullnode_raptorcast]
enable_publisher = false
enable_client = true
raptor10_fullnode_redundancy_factor = 3.0
max_group_size = 150
round_span = 240
invite_lookahead = 20
max_invite_wait = 10
deadline_round_dist = 10
init_empty_round_span = 23
max_num_group = 3
invite_future_dist_min = 1
invite_future_dist_max = 600
invite_accept_heartbeat_ms = 10000

[network]
bind_address_host = "0.0.0.0"
bind_address_port = 8000
authenticated_bind_address_port = 8001
max_rtt_ms = 300
max_mbps = 1000

#########################################################
# Peers configuration
#########################################################

[fullnode_dedicated]
identities = []

[fullnode_raptorcast.full_nodes_prioritized]
identities = []

[blocksync_override]
peers = []

[statesync]
expand_to_group = true
init_peers = []

# mf-mainnet-bootstrap-fn-lsn-fra-006
[[bootstrap.peers]]
address = "64.31.29.190:8000"
record_seq_num = 1
name_record_sig = "1d1cdf398a82fd294e1baa4d179b6b0d0f0489207ab1601b26a806b9468859b92f1397cb7b577ba39c27a7c7ffd2ccc8630d5b5c2aa4095d0fb0090d9fda78ee00"
secp256k1_pubkey = "037d1cbb43ffc35b540f5175cf366f5f5b5ee1c578ce493e5f689856da148f1cba"
auth_port = 8001

# mf-mainnet-bootstrap-fn-lsn-jfk-013
[[bootstrap.peers]]
address = "64.31.53.173:8000"
record_seq_num = 1
name_record_sig = "00e2cbbfd5b9f28ffc8417ed10f02ba2910b07157daae37b19740c66fe7e87535f00418c97534a69caad9b100e2b562a8f119c11debd3eb787433b82378b6d4100"
secp256k1_pubkey = "02b74a25df4a04bf3fda28a8460946e1cc097adfe0f3851a67546ca328a052020e"
auth_port = 8001

# mf-mainnet-bootstrap-fn-lsn-sgp-005
[[bootstrap.peers]]
address = "208.115.197.25:8000"
record_seq_num = 1
name_record_sig = "4d22a214e9fdab1e8ba0b684597c3db1e0fd5e369e148f83fea88af24b7dfca75c82293758aba386e69fa3d538a54c2147e7619d931806bf1a073742bb0a3a9300"
secp256k1_pubkey = "039bed2d57eb4140967b3a114594f046252fd781dba383d8ebcafac1988b7908f0"
auth_port = 8001

# mf-mainnet-bootstrap-fn-tsw-ams-001
[[bootstrap.peers]]
address = "64.130.52.235:8000"
record_seq_num = 1
name_record_sig = "d4edc830f19f1e087989f65e02b306424847b5cd34b85b51834df5556d6018396941fdf86b6a8fb5ba80f9b15d880a3ac93bbcee09e698727284d58ccebb1c1500"
secp256k1_pubkey = "02a7dd4717c55010da5b49fde4515dd1932e138c3b34360d34a9e112e5269eefca"
auth_port = 8001

# mf-mainnet-bootstrap-fn-tsw-pit-004
[[bootstrap.peers]]
address = "64.130.56.50:8000"
record_seq_num = 1
name_record_sig = "7a14e16076ec7013fab5d2e287793eb8a2b0309d5cb636472bf134a7c333368520cec2eaafc6e0a3c7a5f146dc6ac0e3942fd4a4a77af7dc61fc4c097513d23301"
secp256k1_pubkey = "0267695371b9a65a2f3ad8324e15f09be7322c1678e5ae36aca277d4eb85a2c5ed"
auth_port = 8001

# mf-mainnet-bootstrap-fn-tsw-tyo-004
[[bootstrap.peers]]
address = "64.130.49.148:8000"
record_seq_num = 1
name_record_sig = "4d9bc60e5b82da690946e00fbf42c5414fcd28e0796195f55376ec9b296c9f486c5c54f3ea4be6b10a7a3a9f14d763b75bcb36bd992393b2974b3a16576bb05f00"
secp256k1_pubkey = "024ed4df9c6b174ec5eaf9b1d937cf9ce69581aacfd0581f54793b3c13db69757d"
auth_port = 8001

# cl-sgp-007
[[bootstrap.peers]]
address = "69.162.93.53:8000"
record_seq_num = 1
name_record_sig = "6fa31238fd234196338693890c73f91bc893b009cf4c84f40c05d24c62a4c1e2617ef5b6b90c897b356c7d2207a58dc2b1fb2f1d8b787b2f4b4154fe606ef0bd00"
secp256k1_pubkey = "03f9e716c905b1d18ef97ada135799bd885b8c4bf24b01acc9964564cdee898527"
auth_port = 8001

# cl-swe-015
[[bootstrap.peers]]
address = "185.189.46.19:8000"
record_seq_num = 1
name_record_sig = "28198a163a8f6e89bb0b709bfef91f4e4d4d0de86e0c3bd069ea6cb4098b45bd099d3654a135b982906ed8897ed3778f14febf3ec88deee1f30d777fb8f2cba801"
secp256k1_pubkey = "032760f4b5ce58fd6d4c952a1bfcd44bf315a2a178614700ed9e95cd42bbdb1bf6"
auth_port = 8001
NODEEOF

  # Replace placeholders
  sed -i "s|__BENEFICIARY__|${BENEFICIARY}|g" "${CONFIG_DIR}/node.toml"
  sed -i "s|__NODE_NAME__|${NODE_NAME}|g" "${CONFIG_DIR}/node.toml"
  sed -i "s|__SELF_IP__|${SELF_IP}|g" "${CONFIG_DIR}/node.toml"

  # Sign name record
  log "Signing name record..."
  source "${MONAD_HOME}/.env"
  local SIG
  SIG=$(sudo -u monad /usr/local/bin/monad-sign-name-record \
    --address "${SELF_IP}:8000" \
    --authenticated-udp-port 8001 \
    --self-record-seq-num 0 \
    --keystore-path "${CONFIG_DIR}/id-secp" \
    --password "$KEYSTORE_PASSWORD" 2>&1 | grep -oE '[0-9a-f]{128,}' | head -1)

  if [[ -z "$SIG" ]]; then
    log_warn "Could not auto-extract signature. Check manually."
    log_warn "Run: monad-sign-name-record --address ${SELF_IP}:8000 --authenticated-udp-port 8001 --self-record-seq-num 0 --keystore-path ${CONFIG_DIR}/id-secp --password <password>"
  else
    sed -i "s|__NAME_RECORD_SIG__|${SIG}|g" "${CONFIG_DIR}/node.toml"
    log_ok "Name record signed"
  fi

  # Set ownership and immutable bit
  chown root:monad "${CONFIG_DIR}/node.toml"
  chmod 644 "${CONFIG_DIR}/node.toml"

  # Backup
  cp "${CONFIG_DIR}/node.toml" /opt/monad/backup/node.toml.original

  log_ok "node.toml configured for fullnode mode (enable_publisher=false)"
}

# ═══════��═══════════════════════════════════════════════════════════════
# PHASE 6: Systemd Overrides
# ═══════════════════════════════════════════════════════════════════════
phase6_systemd() {
  log "═══ PHASE 6: Systemd Overrides ═══"

  for svc in monad-bft monad-execution monad-rpc; do
    mkdir -p "/etc/systemd/system/${svc}.service.d"
    cat > "/etc/systemd/system/${svc}.service.d/keystore.conf" << SVCEOF
[Service]
EnvironmentFile=-/etc/monad/keystore.env
ProtectProc=invisible
SVCEOF
    cat > "/etc/systemd/system/${svc}.service.d/override.conf" << SVCEOF
[Service]
EnvironmentFile=/etc/monad/keystore.env
ProtectProc=invisible
SVCEOF
  done

  # Fix ownership of all monad dirs
  chown -R monad:monad "${MONAD_HOME}"
  chown root:monad "${MONAD_HOME}/.env"
  chmod 640 "${MONAD_HOME}/.env"

  # Create empty wal file
  touch "${MONAD_BFT}/ledger/wal"
  chown monad:monad "${MONAD_BFT}/ledger/wal"

  systemctl daemon-reload
  log_ok "Systemd overrides configured"
}

# ═══════════════════════════════════════════════════════════════════════
# PHASE 7: Monad Alerts Monitoring
# ═══════════════════════════════════════════════════════════════════════
phase7_monitoring() {
  log "═══ PHASE 7: Monad Alerts Monitoring ═══"

  if [[ "$SKIP_MONITORING" == true ]]; then
    log_warn "Skipping monitoring setup (--skip-monitoring)"
    return 0
  fi

  # Create telegram env (printf to avoid shell injection via special chars in token)
  printf 'TELEGRAM_BOT_TOKEN=%s\nTELEGRAM_CHAT_ID=%s\n' \
    "$TELEGRAM_BOT_TOKEN" "$TELEGRAM_CHAT_ID" > /etc/monad/telegram.env
  chown root:root /etc/monad/telegram.env
  chmod 600 /etc/monad/telegram.env

  # ─── monad-monitor.sh ───
  cat > /usr/local/bin/monad-monitor.sh << 'MONEOF'
#!/bin/bash
source /etc/monad/telegram.env
BOT_TOKEN="$TELEGRAM_BOT_TOKEN"
CHAT_ID="$TELEGRAM_CHAT_ID"
HOSTNAME=$(hostname)
IP=$(curl -s4 ifconfig.me 2>/dev/null || echo "unknown")
ALERT_FILE="/tmp/monad-alert-state"
touch "$ALERT_FILE"
send_alert() { curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" -d chat_id="$CHAT_ID" -d parse_mode="Markdown" -d text="$1" > /dev/null 2>&1; }
ALERTS=""
for svc in monad-bft monad-execution monad-rpc; do
  if ! systemctl is-active --quiet $svc; then ALERTS="${ALERTS}SERVICE_${svc} "; fi
done
DISK_USAGE=$(df / --output=pcent | tail -1 | tr -d ' %')
if [ "$DISK_USAGE" -gt 85 ]; then ALERTS="${ALERTS}DISK_ROOT_${DISK_USAGE} "; fi
TRIEDB_USAGE=$(df /dev/triedb --output=pcent 2>/dev/null | tail -1 | tr -d ' %')
if [ -n "$TRIEDB_USAGE" ] && [ "$TRIEDB_USAGE" -gt 85 ]; then ALERTS="${ALERTS}DISK_TRIEDB_${TRIEDB_USAGE} "; fi
MEM_TOTAL=$(free | awk '/Mem:/{print $2}')
MEM_USED=$(free | awk '/Mem:/{print $3}')
MEM_PCT=$((MEM_USED * 100 / MEM_TOTAL))
if [ "$MEM_PCT" -gt 90 ]; then ALERTS="${ALERTS}RAM_${MEM_PCT} "; fi
CORES=$(nproc)
LOAD=$(cat /proc/loadavg | awk '{print $1}' | cut -d. -f1)
if [ "$LOAD" -gt "$CORES" ]; then ALERTS="${ALERTS}CPU_LOAD_${LOAD} "; fi
RPC_CHECK=$(curl -s -m 5 -X POST http://127.0.0.1:8080 -H "Content-Type: application/json" -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' 2>/dev/null)
if [ -z "$RPC_CHECK" ]; then
  ALERTS="${ALERTS}RPC_DOWN "
else
  RPC_BLOCK=$(echo "$RPC_CHECK" | python3 -c "import sys,json; print(int(json.load(sys.stdin)['result'],16))" 2>/dev/null)
  BLOCK_FILE="/tmp/monad-last-block"
  if [ -n "$RPC_BLOCK" ]; then
    PREV_BLOCK=$(cat "$BLOCK_FILE" 2>/dev/null)
    echo "$RPC_BLOCK" > "$BLOCK_FILE"
    if [ -n "$PREV_BLOCK" ] && [ "$RPC_BLOCK" -eq "$PREV_BLOCK" ]; then
      STUCK_COUNT_FILE="/tmp/monad-stuck-count"
      STUCK_COUNT=$(cat "$STUCK_COUNT_FILE" 2>/dev/null || echo 0)
      STUCK_COUNT=$((STUCK_COUNT + 1))
      echo "$STUCK_COUNT" > "$STUCK_COUNT_FILE"
      if [ "$STUCK_COUNT" -ge 2 ]; then ALERTS="${ALERTS}BLOCK_STUCK_${RPC_BLOCK} "; fi
    else
      echo 0 > /tmp/monad-stuck-count
    fi
  fi
  SYNC_CHECK=$(curl -s -m 5 -X POST http://127.0.0.1:8080 -H "Content-Type: application/json" -d '{"jsonrpc":"2.0","method":"eth_syncing","params":[],"id":1}' 2>/dev/null)
  if echo "$SYNC_CHECK" | grep -q '"result":true'; then ALERTS="${ALERTS}SYNCING "; fi
fi
LAST_VOTE=$(journalctl -u monad-bft --no-pager -n 500 --since "10 min ago" 2>/dev/null | grep -c "vote successful")
if [ "$LAST_VOTE" -eq 0 ]; then
  NOT_VOTING=$(journalctl -u monad-bft --no-pager -n 100 --since "10 min ago" 2>/dev/null | grep -c "not voting")
  if [ "$NOT_VOTING" -gt 0 ]; then ALERTS="${ALERTS}NOT_VOTING "; fi
fi
PANIC=$(journalctl -u monad-bft --no-pager --since "5 min ago" 2>/dev/null | grep -ci "panic\|state root doesn't match\|high qc too far")
if [ "$PANIC" -gt 0 ]; then ALERTS="${ALERTS}PANIC "; fi
TEMP=$(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null)
if [ -n "$TEMP" ]; then TEMP_C=$((TEMP / 1000)); if [ "$TEMP_C" -gt 85 ]; then ALERTS="${ALERTS}TEMP_${TEMP_C}C "; fi; fi
NVME_HEALTH=$(nvme smart-log /dev/nvme0n1 2>/dev/null | grep "critical_warning" | awk '{print $3}')
if [ -n "$NVME_HEALTH" ] && [ "$NVME_HEALTH" != "0" ] && [ "$NVME_HEALTH" != "0x0" ]; then ALERTS="${ALERTS}NVME_CRITICAL "; fi
UPTIME_SEC=$(cat /proc/uptime | cut -d. -f1)
if [ "$UPTIME_SEC" -lt 300 ]; then ALERTS="${ALERTS}RECENT_REBOOT "; fi
PREV_ALERTS=$(cat "$ALERT_FILE" 2>/dev/null)
if [ -n "$ALERTS" ] && [ "$ALERTS" != "$PREV_ALERTS" ]; then
  MSG=$(echo "$ALERTS" | tr ' ' '\n' | while read a; do
    case "$a" in
      SERVICE_*) echo "🔴 Сервис ${a#SERVICE_} DOWN";;
      DISK_ROOT_*) echo "💾 Диск / заполнен на ${a#DISK_ROOT_}%";;
      DISK_TRIEDB_*) echo "💾 TrieDB заполнен на ${a#DISK_TRIEDB_}%";;
      RAM_*) echo "🧠 RAM ${a#RAM_}%";;
      CPU_LOAD_*) echo "🔥 CPU load ${a#CPU_LOAD_} (cores: $CORES)";;
      RPC_DOWN) echo "📡 RPC не отвечает";;
      BLOCK_STUCK_*) echo "⏸ Блок застрял на ${a#BLOCK_STUCK_} (6+ мин)";;
      SYNCING) echo "🔄 Нода ещё синхронизируется";;
      LOW_PEERS_*) echo "👥 Мало пиров: ${a#LOW_PEERS_}";;
      NOT_VOTING) echo "🗳 Не голосует >10 мин";;
      PANIC) echo "💀 Panic/crash в логах!";;
      TEMP_*) echo "🌡 Температура CPU ${a#TEMP_}";;
      NVME_CRITICAL) echo "⚠️ NVMe critical warning";;
      RECENT_REBOOT) echo "🔄 Сервер перезагружен";;
    esac
  done)
  send_alert "🚨 *ALERT — ${HOSTNAME}* (${IP})"$'\n'"${MSG}"
  echo "$ALERTS" > "$ALERT_FILE"
fi
if [ -z "$ALERTS" ] && [ -n "$PREV_ALERTS" ]; then
  send_alert "✅ *RECOVERED — ${HOSTNAME}* (${IP})"$'\n'"Все проблемы устранены."
  echo "" > "$ALERT_FILE"
fi
MONEOF

  # ─── monad-send-status.sh ───
  cat > /usr/local/bin/monad-send-status.sh << 'STATUSEOF'
#!/bin/bash
source /etc/monad/telegram.env
BOT_TOKEN="$TELEGRAM_BOT_TOKEN"
CHAT_ID="${1:-$TELEGRAM_CHAT_ID}"
HOSTNAME=$(hostname)
IP=$(curl -s4 ifconfig.me 2>/dev/null || echo "unknown")
BFT=$(systemctl is-active monad-bft 2>/dev/null)
EXEC=$(systemctl is-active monad-execution 2>/dev/null)
RPC_SVC=$(systemctl is-active monad-rpc 2>/dev/null)
UPTIME=$(uptime -p 2>/dev/null)
LOAD=$(cat /proc/loadavg | awk '{print $1}')
MEM_USED=$(free -h | awk '/Mem:/{print $3}')
MEM_TOTAL=$(free -h | awk '/Mem:/{print $2}')
DISK=$(df / --output=pcent | tail -1 | tr -d ' ')
CORES=$(nproc)
RPC_BLOCK=$(curl -s -m 3 -X POST http://127.0.0.1:8080 -H "Content-Type: application/json" -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' 2>/dev/null | python3 -c "import sys,json; print(int(json.load(sys.stdin)['result'],16))" 2>/dev/null || echo "N/A")
SYNC=$(curl -s -m 3 -X POST http://127.0.0.1:8080 -H "Content-Type: application/json" -d '{"jsonrpc":"2.0","method":"eth_syncing","params":[],"id":1}' 2>/dev/null)
if echo "$SYNC" | grep -q '"result":false'; then SYNC_STATUS="in-sync"; else SYNC_STATUS="syncing"; fi
VOTING=$(journalctl -u monad-bft --no-pager -n 200 --since "5 min ago" 2>/dev/null | grep -c "vote successful")
if [ "$VOTING" -gt 0 ]; then VOTE_STATUS="yes ($VOTING/5min)"; else VOTE_STATUS="no"; fi
MONAD_VER=$(dpkg -l 2>/dev/null | grep "monad " | awk '{print $3}')
TEMP=$(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null)
if [ -n "$TEMP" ]; then TEMP_C="$((TEMP / 1000))°C"; else TEMP_C="N/A"; fi
NODE_NAME=$(grep node_name /home/monad/monad-bft/config/node.toml 2>/dev/null | head -1 | cut -d'"' -f2)
BENEFICIARY=$(grep beneficiary /home/monad/monad-bft/config/node.toml 2>/dev/null | head -1 | cut -d'"' -f2)
TRIEDB_DISK=$(df /dev/triedb --output=pcent 2>/dev/null | tail -1 | tr -d ' ' || echo "N/A")
NVME_TEMP=$(nvme smart-log /dev/nvme0n1 2>/dev/null | grep "temperature" | head -1 | awk '{print $3}')
ALERT_STATE=$(cat /tmp/monad-alert-state 2>/dev/null)
if [ -z "$ALERT_STATE" ]; then ALERTS="none"; else ALERTS="$ALERT_STATE"; fi
if [ "$BFT" = "active" ]; then I_BFT="✅"; else I_BFT="🔴"; fi
if [ "$EXEC" = "active" ]; then I_EXEC="✅"; else I_EXEC="🔴"; fi
if [ "$RPC_SVC" = "active" ]; then I_RPC="✅"; else I_RPC="🔴"; fi
if [ "$SYNC_STATUS" = "in-sync" ]; then I_SYNC="✅"; else I_SYNC="🔄"; fi
if [ "$VOTING" -gt 0 ]; then I_VOTE="✅"; else I_VOTE="⚠️"; fi
if [ "$RPC_BLOCK" != "N/A" ]; then I_RPCB="✅"; else I_RPCB="🔴"; fi
if [ -z "$ALERT_STATE" ]; then I_ALERT="✅"; else I_ALERT="🚨"; fi
MSG="*${NODE_NAME:-$HOSTNAME}* | \`${IP}\`
━━━━━━━━━━━━━━━━━━━━━
${I_SYNC} Sync: *${SYNC_STATUS}*  ${I_VOTE} Voting: *${VOTE_STATUS}*
${I_RPCB} RPC: *${RPC_BLOCK}*
${I_BFT} BFT  ${I_EXEC} Execution  ${I_RPC} RPC
${I_ALERT} Alerts: *${ALERTS}*
━━━━━━━━━━━━━━━━━━━━━
⚙️ Monad \`${MONAD_VER}\` | ${UPTIME}
💻 CPU: ${CORES} cores | Load: ${LOAD}
🧠 RAM: ${MEM_USED} / ${MEM_TOTAL}
💾 OS: ${DISK} | TrieDB: ${TRIEDB_DISK}
🌡 Temp: ${TEMP_C} | NVMe: ${NVME_TEMP:-N/A}°C
━━━━━━━━━━━━━━━━━━━━━
💰 Beneficiary: \`${BENEFICIARY:-N/A}\`"
curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
  -d chat_id="$CHAT_ID" -d parse_mode="Markdown" -d text="$MSG" > /dev/null 2>&1
STATUSEOF

  # ─── monad-daily-report.sh ───
  cat > /usr/local/bin/monad-daily-report.sh << 'DAILYEOF'
#!/bin/bash
source /etc/monad/telegram.env
BOT_TOKEN="$TELEGRAM_BOT_TOKEN"
CHAT_ID="$TELEGRAM_CHAT_ID"
HOSTNAME=$(hostname)
IP=$(curl -s4 ifconfig.me 2>/dev/null || echo "unknown")
UPTIME=$(uptime -p)
DISK=$(df / --output=pcent | tail -1 | tr -d ' ')
MEM_TOTAL=$(free -h | awk '/Mem:/{print $2}')
MEM_USED=$(free -h | awk '/Mem:/{print $3}')
LOAD=$(cat /proc/loadavg | awk '{print $1}')
BFT=$(systemctl is-active monad-bft)
EXEC=$(systemctl is-active monad-execution)
RPC_SVC=$(systemctl is-active monad-rpc)
RPC_BLOCK=$(curl -s -m 5 -X POST http://127.0.0.1:8080 -H "Content-Type: application/json" -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' 2>/dev/null | python3 -c "import sys,json; print(int(json.load(sys.stdin)['result'],16))" 2>/dev/null || echo "N/A")
MONAD_VER=$(dpkg -l | grep monad | awk '{print $3}' | head -1)
curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" -d chat_id="$CHAT_ID" -d parse_mode="Markdown" -d text="📊 *Daily — ${HOSTNAME}* (${IP})"$'\n'"Uptime: ${UPTIME}"$'\n'"Monad: ${MONAD_VER}"$'\n'"Load: ${LOAD} | RAM: ${MEM_USED}/${MEM_TOTAL} | Disk: ${DISK}"$'\n'"Services: bft=${BFT} exec=${EXEC} rpc=${RPC_SVC}"$'\n'"RPC block: ${RPC_BLOCK}" > /dev/null 2>&1
DAILYEOF

  # ─── monad-bot-handler.sh ───
  cat > /usr/local/bin/monad-bot-handler.sh << 'BOTEOF'
#!/bin/bash
source /etc/monad/telegram.env
BOT_TOKEN="$TELEGRAM_BOT_TOKEN"
CHAT_ID="$TELEGRAM_CHAT_ID"
HOSTNAME=$(hostname)
OFFSET_FILE="/tmp/monad-bot-offset"
touch "$OFFSET_FILE"

while true; do
  OFFSET=$(cat "$OFFSET_FILE" 2>/dev/null || echo "0")
  UPDATES=$(curl -s -m 35 "https://api.telegram.org/bot${BOT_TOKEN}/getUpdates?offset=${OFFSET}&timeout=30" 2>/dev/null)
  if [ -z "$UPDATES" ]; then sleep 5; continue; fi
  echo "$UPDATES" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    if not data.get('ok'): sys.exit(0)
    for u in data.get('result', []):
        uid = u['update_id']
        msg = u.get('message', {})
        text = msg.get('text', '')
        chat_id = msg.get('chat', {}).get('id', 0)
        print(f'{uid}|{chat_id}|{text}')
except: pass
" | while IFS='|' read -r UID RCHAT TEXT; do
    echo $((UID + 1)) > "$OFFSET_FILE"
    if [ "$TEXT" = "/status" ] || [ "$TEXT" = "/status@monadalertzbot" ]; then
      /usr/local/bin/monad-send-status.sh "$RCHAT"
    fi
  done
  sleep 2
done
BOTEOF

  # ─── monad-upgrade-notify.sh ───
  cat > /usr/local/bin/monad-upgrade-notify.sh << 'UPGEOF'
#!/bin/bash
source /etc/monad/telegram.env
BOT_TOKEN="$TELEGRAM_BOT_TOKEN"
CHAT_ID="$TELEGRAM_CHAT_ID"
HOSTNAME=$(hostname)
send_tg() { curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" -d chat_id="$CHAT_ID" -d parse_mode="Markdown" -d text="$1" > /dev/null 2>&1; }

restore_override() {
  for svc in monad-bft monad-execution monad-rpc; do
    mkdir -p /etc/systemd/system/${svc}.service.d/
    cat << OVR > /etc/systemd/system/${svc}.service.d/keystore.conf
[Service]
EnvironmentFile=-/etc/monad/keystore.env
ProtectProc=invisible
OVR
  done
  systemctl daemon-reload
}

VERSION="$1"
if [ -z "$VERSION" ]; then
  echo "Usage: sudo $0 <version>"
  exit 1
fi

OLD_VERSION=$(dpkg -l | grep "^ii  monad " | awk '{print $3}')
echo "=== Upgrading Monad from $OLD_VERSION to $VERSION on $HOSTNAME ==="
send_tg "🔄 *${HOSTNAME}* — Начало обновления ${OLD_VERSION} → ${VERSION}"

echo "[1/5] Backup..."
mkdir -p /root/monad-backup
cp -r /etc/systemd/system/monad-*.service.d /root/monad-backup/ 2>/dev/null || true
dpkg -l | grep monad > /root/monad-backup/packages-before.txt

echo "[2/5] Unhold and install..."
apt-mark unhold monad
apt update
if ! apt install --reinstall monad=${VERSION} -y --allow-downgrades --allow-change-held-packages; then
  apt install --reinstall monad=${OLD_VERSION} -y --allow-downgrades --allow-change-held-packages
  apt-mark hold monad
  restore_override
  systemctl restart monad-bft monad-execution monad-rpc
  send_tg "❌ *${HOSTNAME}* — APT install failed. Откат на ${OLD_VERSION}"
  exit 1
fi
apt-mark hold monad

echo "[3/5] Restoring override..."
restore_override

echo "[4/5] Restart services..."
systemctl restart monad-bft monad-execution monad-rpc

echo "[5/5] Wait 60 sec and check..."
sleep 60

BFT_STATUS=$(systemctl is-active monad-bft)
EXEC_STATUS=$(systemctl is-active monad-execution)
RPC_STATUS=$(systemctl is-active monad-rpc)

if [ "$BFT_STATUS" != "active" ] || [ "$EXEC_STATUS" != "active" ] || [ "$RPC_STATUS" != "active" ]; then
  echo "[ROLLBACK]"
  apt-mark unhold monad
  apt install --reinstall monad=${OLD_VERSION} -y --allow-downgrades --allow-change-held-packages
  apt-mark hold monad
  restore_override
  systemctl restart monad-bft monad-execution monad-rpc
  send_tg "❌ *${HOSTNAME}* — Сервисы не запустились на ${VERSION}. Откат на ${OLD_VERSION}"
  exit 1
fi

sleep 30
VOTES=$(journalctl -u monad-bft --no-pager -n 500 --since "2 min ago" 2>/dev/null | grep -c "vote successful")
NEW_VERSION=$(dpkg -l | grep "^ii  monad " | awk '{print $3}')

send_tg "✅ *${HOSTNAME}* — Обновление успешно
Old: ${OLD_VERSION}
New: ${NEW_VERSION}
Services: active
Votes за 2 мин: ${VOTES}"

echo "=== Upgrade complete: $OLD_VERSION → $NEW_VERSION ==="
UPGEOF

  # Set permissions
  chmod 750 /usr/local/bin/monad-monitor.sh \
            /usr/local/bin/monad-send-status.sh \
            /usr/local/bin/monad-daily-report.sh \
            /usr/local/bin/monad-bot-handler.sh \
            /usr/local/bin/monad-upgrade-notify.sh
  chown root:root /usr/local/bin/monad-*.sh

  # Create cron jobs (DISABLED — with .disabled extension)
  echo "*/3 * * * * root /usr/local/bin/monad-monitor.sh" > /etc/cron.d/monad-monitor.disabled
  echo "0 9 * * * root /usr/local/bin/monad-daily-report.sh" > /etc/cron.d/monad-daily-report.disabled
  chmod 644 /etc/cron.d/monad-monitor.disabled /etc/cron.d/monad-daily-report.disabled

  # Create bot-handler systemd unit (NOT enabled)
  cat > /etc/systemd/system/monad-bot.service << 'BOTUNIT'
[Unit]
Description=Monad Telegram Bot Handler
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/monad-bot-handler.sh
Restart=always
RestartSec=10
User=root

[Install]
WantedBy=multi-user.target
BOTUNIT
  systemctl daemon-reload

  log_ok "Monitoring scripts installed (cron DISABLED, bot-handler NOT enabled)"
  log_warn "To activate: mv /etc/cron.d/monad-monitor.disabled /etc/cron.d/monad-monitor"
  log_warn "To activate: mv /etc/cron.d/monad-daily-report.disabled /etc/cron.d/monad-daily-report"
  log_warn "Bot handler: systemctl enable --now monad-bot.service"
}

# ═══════════════════════════════════════════════════════════════════════
# PHASE 7.5: Snapshot restore (NEW in v2)
# ═══════════════════════════════════════════════════════════════════════
# Pulls a recent state snapshot from Monad Foundation bucket so the node
# starts close to chain tip. Without this, a fresh node would do a full
# initial statesync (≈8 hours on mainnet). With snapshot: 15-30 min.
#
# Skip with --skip-snapshot for testing or if MF bucket is unreachable.
# ═══════════════════════════════════════════════════════════════════════
phase7_5_snapshot() {
  log "═══ PHASE 7.5: Snapshot Restore ═══"

  if [[ "$SKIP_SNAPSHOT" == true ]]; then
    log_warn "Skipping snapshot restore (--skip-snapshot). Initial sync will take hours."
    return 0
  fi

  local MF_SCRIPT_URL="https://bucket.monadinfra.com/scripts/mainnet/restore-from-snapshot.sh"

  # Probe bucket reachability
  if ! curl -fsSI --max-time 10 "$MF_SCRIPT_URL" >> "$LOGFILE" 2>&1; then
    log_warn "MF bucket unreachable at ${MF_SCRIPT_URL}"
    log_warn "Continuing without snapshot — node will sync from network (slow, hours)."
    return 0
  fi

  # Reset workspace cleanly so snapshot can write fresh state.
  if [[ -x /opt/monad/scripts/reset-workspace.sh ]]; then
    log "Resetting workspace before snapshot..."
    bash /opt/monad/scripts/reset-workspace.sh >> "$LOGFILE" 2>&1 \
      || log_warn "reset-workspace.sh exited non-zero — continuing"
  fi

  log "Downloading and applying snapshot (10-30 min, progress in $LOGFILE)..."
  if ! curl -fsSL "$MF_SCRIPT_URL" | bash >> "$LOGFILE" 2>&1; then
    log_err "Snapshot restore failed — check $LOGFILE"
    log_warn "Node will fall back to full statesync (slow, hours)."
    return 0
  fi

  # Restore monad ownership over anything snapshot may have touched
  chown -R monad:monad "${MONAD_HOME}"
  log_ok "Snapshot restored — node will start near chain tip"
}

# ═══════════════════════════════════════════════════════════════════════
# PHASE 8: Start Services
# ═══════════════════════════════════════════════════════════════════════
phase8_start() {
  log "═══ PHASE 8: Start Services ═══"

  log "Starting monad-execution..."
  systemctl start monad-execution
  sleep 30
  if ! systemctl is-active --quiet monad-execution; then
    fail "monad-execution failed to start" "Phase 8"
  fi
  log_ok "monad-execution active"

  log "Starting monad-bft..."
  systemctl start monad-bft
  sleep 30
  if ! systemctl is-active --quiet monad-bft; then
    fail "monad-bft failed to start" "Phase 8"
  fi
  log_ok "monad-bft active"

  log "Starting monad-rpc..."
  systemctl start monad-rpc
  sleep 15
  if ! systemctl is-active --quiet monad-rpc; then
    fail "monad-rpc failed to start" "Phase 8"
  fi
  log_ok "monad-rpc active"

  # v2: opt-in enable. Default = manual control (safer for validator promotion;
  # auto-restart loops can cause double-signing risk once slashing is enabled).
  if [[ "$ENABLE_ON_BOOT" == true ]]; then
    systemctl enable monad-bft monad-execution monad-rpc >> "$LOGFILE" 2>&1
    log_ok "All services started and enabled (auto-start on boot)"
  else
    log_ok "All services started (NOT enabled on boot — pass --enable-on-boot to auto-start)"
  fi
}

# ═══════════════════════════════════════════════════════════════════════
# PHASE 9: Verification & Report
# ═══════════════════════════════════════════════════════════════════════
phase9_verify() {
  log "═══ PHASE 9: Verification ═══"

  sleep 10

  local BLOCK_HEX BLOCK_DEC SYNCING SYNC_LABEL TRIEDB_TARGET
  local SECP_PUB BLS_PUB

  BLOCK_HEX=$(curl -s -m 5 -X POST http://127.0.0.1:8080 \
    -H "Content-Type: application/json" \
    -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['result'])" 2>/dev/null || echo "0x0")
  BLOCK_DEC=$(python3 -c "print(int('${BLOCK_HEX}', 16))" 2>/dev/null || echo "0")

  SYNCING=$(curl -s -m 5 -X POST http://127.0.0.1:8080 \
    -H "Content-Type: application/json" \
    -d '{"jsonrpc":"2.0","method":"eth_syncing","params":[],"id":1}' 2>/dev/null)
  SYNC_LABEL=$(echo "$SYNCING" | python3 -c "import sys,json; d=json.load(sys.stdin); print('syncing' if d['result'] != False else 'synced')" 2>/dev/null || echo "unknown")

  TRIEDB_TARGET=$(readlink -f /dev/triedb 2>/dev/null || echo "?")

  # Read whitelist-filtered pubkeys (already cleaned in Phase 4)
  SECP_PUB=$(grep -i "^Secp public key:" /opt/monad/backup/pubkeys.txt 2>/dev/null | awk '{print $NF}')
  BLS_PUB=$(grep -i "^BLS public key:"  /opt/monad/backup/pubkeys.txt 2>/dev/null | awk '{print $NF}')

  log_ok "Block: $BLOCK_DEC | Syncing: $SYNC_LABEL"

  # Send Telegram report
  tg_notify "🆕 *Fullnode installed: ${NODE_NAME}*
━━━━━━━━━━━━━━━━━━━━━
Host: $(hostname) (${SELF_IP})
Monad: ${MONAD_VERSION}
TrieDB: /dev/triedb → ${TRIEDB_TARGET}
Block: ${BLOCK_DEC}
Status: ${SYNC_LABEL}
━━━━━━━━━━━━━━━━━━━━━
Monitoring: DISABLED (activate manually)
Pubkeys: /opt/monad/backup/pubkeys.txt"

  echo ""
  echo "╔══════════════════════════════════════════════════════════════════════╗"
  echo "║              Monad Fullnode Bootstrap Complete                       ║"
  echo "╠══════════════════════════════════════════════════════════════════════╣"
  printf "║ Hostname:        %-52s ║\n" "$(hostname)"
  printf "║ IP:              %-52s ║\n" "${SELF_IP}"
  printf "║ Node name:       %-52s ║\n" "${NODE_NAME}"
  printf "║ Monad version:   %-52s ║\n" "${MONAD_VERSION}"
  printf "║ TrieDB device:   /dev/triedb → %-38s ║\n" "${TRIEDB_TARGET}"
  printf "║ Block height:    %-52s ║\n" "${BLOCK_DEC}"
  printf "║ Sync state:      %-52s ║\n" "${SYNC_LABEL}"
  echo  "║                                                                      ║"
  printf "║ SECP pubkey:     %-52s ║\n" "${SECP_PUB:-<missing>}"
  printf "║ BLS pubkey:      %-52s ║\n" "${BLS_PUB:0:48}"
  [ ${#BLS_PUB} -gt 48 ] && printf "║                  %-52s ║\n" "${BLS_PUB:48}"
  echo  "║                                                                      ║"
  echo  "║ Logs:            journalctl -u monad-bft -f                          ║"
  echo  "║ Status:          sudo /usr/local/bin/monad-send-status.sh            ║"
  echo  "║ Install log:     ${LOGFILE}                       ║"
  echo  "║                                                                      ║"
  echo  "║ TG monitoring:   DISABLED by default                                 ║"
  echo  "║   Enable cron:   sudo mv /etc/cron.d/monad-monitor{.disabled,}       ║"
  echo  "║   Enable daily:  sudo mv /etc/cron.d/monad-daily-report{.disabled,}  ║"
  echo  "║   Enable bot:    sudo systemctl enable --now monad-bot.service       ║"
  echo  "║                                                                      ║"
  echo  "║ Auto-start:      $(if [[ "$ENABLE_ON_BOOT" == true ]]; then echo "ENABLED (services will boot at startup)              "; else echo "DISABLED — enable with --enable-on-boot at install   "; fi)║"
  echo  "║                                                                      ║"
  echo  "║ Promote to validator:                                                ║"
  echo  "║   https://docs.monad.xyz/node-ops/node-recovery/node-migration       ║"
  echo  "╚══════════════════════════════════════════════════════════════════════╝"
}

# ═══════════════════════════════════════════════════════════════════════
# MAIN
# ═══════════════════════════════════════════════════════════════════════
main() {
  preflight
  phase1_system
  phase2_package
  phase3_triedb
  phase4_keystore
  phase5_config
  phase6_systemd
  phase7_monitoring
  phase7_5_snapshot     # v2: snapshot restore — saves ~8h sync vs starting empty
  phase8_start
  phase9_verify
}

main "$@"
