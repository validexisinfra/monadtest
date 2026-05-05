# install-monad-fullnode.sh

Automated installation script for a Monad mainnet fullnode on Ubuntu 24.04.

**v3** is the recommended version. End-to-end install (snapshot included) takes 15-30 minutes.

## What v3 changes (vs v2)

| Change | Why |
|---|---|
| **`aria2` added to apt install (Phase 1)** | Phase 7.5 snapshot script (`restore-from-snapshot.sh`) requires `aria2c` for multi-connection downloads. v2 missed it → snapshot phase silently failed → install fell back to 8h initial statesync instead of 15-30 min. |
| **Phase 9 wrapped with `set +e` / `set -e` (FIX 11)** | RPC port 8080 doesn't bind until first finalized block. With v2's strict `set -euo pipefail`, the `curl http://127.0.0.1:8080` for `eth_syncing` got connection-refused (exit 7) → script silently exited before printing the summary box. v3 disables strict mode for the verification body so the box always renders (with `<missing>` placeholders for unavailable values). |

## What v2 changed (vs v1)

| Change | Why |
|---|---|
| **Snapshot restore (new Phase 7.5)** | Pulls a recent state snapshot from Monad Foundation bucket → node starts near tip. Without snapshot, initial statesync takes ~8h on mainnet. |
| **`iptables-persistent` removed** | Conflicts with `ufw` on Ubuntu 24.04 noble (`Breaks:` relation). Anti-amplification rule still added live; not persisted across reboots without `iptables-persistent` (acceptable for fullnodes). |
| **TrieDB on raw NVMe device (no partition)** | Cleaner; identical performance; matches official Monad docs. v1 used `parted` to create `/dev/nvme1n1p1` — unnecessary indirection. |
| **Keystore stdout suppressed** | `monad-keystore create` prints IKM and private key to stdout by-design. v1 captured this into `/opt/monad/backup/pubkeys.txt` (mode 644) and `/var/log/monad-install.log` — full secret leak. v2 redirects keygen stdout to `/dev/null`, then runs `recover` with whitelist-grep to extract only the public-key line. |
| **File permissions hardened** | `/opt/monad/backup/pubkeys.txt`: 644→600 root:root. `/var/log/monad-install.log`: 644→600 root:root. |
| **Services NOT enabled by default** | Auto-restart loops can cause double-signing risk after slashing is enabled. Pass `--enable-on-boot` to opt in. |
| **`--yes` flag** | Bypass interactive prompts for unattended installs (`curl ... | bash` use case). |
| **Reduced terminal verbosity** | `apt`, `monad-keystore`, snapshot download output goes only to `/var/log/monad-install.log`. Terminal sees phase markers and summary. |
| **Final summary box** | Phase 9 prints a clean recap with pubkeys, sync state, and next-step commands. |

## What it does

1. **Pre-flight** — validates args, root, OS, device existence.
2. **Phase 1: System preparation** — installs dependencies, creates `monad` user, configures UFW + fail2ban + hidepid.
3. **Phase 2: Monad package** — adds Category Labs APT repo, installs `monad`, holds version.
4. **Phase 3: TrieDB** — wipes signatures on raw NVMe, creates udev rule binding `/dev/triedb → <serial>` (whole-disk), initializes storage pool with `monad-mpt --truncate`.
5. **Phase 4: Keystore** — generates SECP256K1 and BLS keys silently; extracts only public-key lines via whitelist-grep into `/opt/monad/backup/pubkeys.txt` (root:root 600).
6. **Phase 5: node.toml** — writes fullnode-mode config (`enable_publisher=false`, `beneficiary=0x0...0` by default), signs `self_name_record`.
7. **Phase 6: Systemd overrides** — wires `EnvironmentFile=/etc/monad/keystore.env` (root-only) for all services.
8. **Phase 7: Telegram monitoring** — installs 5 scripts + cron units, all **disabled by default**.
9. **Phase 7.5: Snapshot restore** *(new in v2)* — pulls Monad Foundation snapshot so node starts near tip. Skip with `--skip-snapshot`.
10. **Phase 8: Start services** — `systemctl start` for monad-execution → monad-bft → monad-rpc with health checks. `systemctl enable` is opt-in via `--enable-on-boot`.
11. **Phase 9: Verification** — RPC checks, Telegram report, summary box.

## Requirements

- Ubuntu 24.04 LTS (fresh install recommended)
- Root access
- Raw NVMe device, **unused** — will be wiped
- Public IPv4 address
- Telegram bot token and chat ID
- ≥ 1 TB free space on TrieDB device, ≥ 32 GB RAM

## ⚠️ macOS users editing this script

**Don't open `.sh` files in TextEdit by double-click** — TextEdit defaults to RTF and will silently convert plain text to Rich Text Format, corrupting the script (`{\rtf1\ansi\ansicpg...` instead of `#!/usr/bin/env bash`).

Use a code editor: **VS Code, Sublime Text, BBEdit, vim, nano, emacs**. If you must use TextEdit: `Format → Make Plain Text` (Cmd+Shift+T) before saving.

## Environment Variables

| Variable | Required | Description |
|----------|----------|-------------|
| `TELEGRAM_BOT_TOKEN` | Yes* | Bot token from [@BotFather](https://t.me/BotFather) |
| `TELEGRAM_CHAT_ID` | Yes* | Chat/group ID for alerts |

\* Not required if using `--skip-monitoring`

### Getting Telegram credentials

1. Message [@BotFather](https://t.me/BotFather) → `/newbot` → copy the token
2. Add your bot to a group or message it directly
3. Visit `https://api.telegram.org/bot<TOKEN>/getUpdates` → find `chat.id`

## CLI Arguments

| Argument | Required | Default | Description |
|----------|----------|---------|-------------|
| `--triedb-device` | Yes | — | NVMe block device (e.g. `/dev/nvme1n1`) |
| `--node-name` | Yes | — | P2P node name |
| `--self-ip` | Yes | — | Public IPv4 address |
| `--beneficiary` | No | `0x0...0` | EVM address for block rewards (burn for fullnode) |
| `--ssh-port` | No | `2225` | SSH port for UFW rule |
| `--skip-triedb` | No | — | Skip TrieDB wipe and init (existing setup) |
| `--skip-keys` | No | — | Skip keystore generation (existing keys) |
| `--skip-monitoring` | No | — | Skip Telegram monitoring scripts |
| `--skip-snapshot` | No | — | Skip Phase 7.5 snapshot restore (uses initial statesync, ~8h) |
| `--enable-on-boot` | No | — | `systemctl enable` services after start (opt-in) |
| `-y`, `--yes` | No | — | Auto-confirm interactive prompts (for `curl \| bash`) |
| `--dry-run` | No | — | Show plan without executing |

## Usage

### Standard install (recommended)

```bash
curl -fsSL https://raw.githubusercontent.com/validexisinfra/monadtest/main/install-monad-fullnode.sh \
  | sudo TELEGRAM_BOT_TOKEN="123456:ABC..." \
         TELEGRAM_CHAT_ID="-100123456789" \
         bash -s -- --yes \
           --triedb-device /dev/nvme1n1 \
           --node-name "my-fullnode" \
           --self-ip "203.0.113.50"
```

### Local install (download first, then run)

```bash
curl -fsSL https://raw.githubusercontent.com/validexisinfra/monadtest/main/install-monad-fullnode.sh \
  -o install-monad-fullnode.sh

sudo TELEGRAM_BOT_TOKEN="..." TELEGRAM_CHAT_ID="..." \
  bash install-monad-fullnode.sh \
  --triedb-device /dev/nvme1n1 \
  --node-name "my-fullnode" \
  --self-ip "203.0.113.50"
```

### With auto-start on boot (validator-style)

```bash
sudo TELEGRAM_BOT_TOKEN="..." TELEGRAM_CHAT_ID="..." \
  bash install-monad-fullnode.sh \
  --triedb-device /dev/nvme1n1 \
  --node-name "my-validator" \
  --self-ip "203.0.113.50" \
  --beneficiary "0xYourAddress..." \
  --enable-on-boot
```

### Skip snapshot (testing or air-gapped)

```bash
sudo TELEGRAM_BOT_TOKEN="..." TELEGRAM_CHAT_ID="..." \
  bash install-monad-fullnode.sh \
  --triedb-device /dev/nvme1n1 \
  --node-name "my-fullnode" \
  --self-ip "203.0.113.50" \
  --skip-snapshot
```

### Re-run on partially configured server

```bash
sudo TELEGRAM_BOT_TOKEN="..." TELEGRAM_CHAT_ID="..." \
  bash install-monad-fullnode.sh \
  --triedb-device /dev/nvme1n1 \
  --node-name "my-fullnode" \
  --self-ip "203.0.113.50" \
  --skip-triedb --skip-keys
```

## Idempotency

Each phase checks existing state before acting:
- APT source exists → skip
- Package already installed at target version → skip
- `/dev/triedb` symlink exists pointing at target device → prompt (or auto-skip with `--yes`)
- Keys exist → prompt (or auto-skip with `--yes`)
- Snapshot bucket unreachable → continue without snapshot, log warning

## Monitoring

The script installs 5 monitoring scripts but leaves them **disabled by default**:

| Script | Purpose |
|--------|---------|
| `monad-monitor.sh` | Alerts every 3 min (service down, disk, RAM, stuck blocks, peers) |
| `monad-send-status.sh` | Full status dashboard on demand |
| `monad-daily-report.sh` | Daily summary at 09:00 UTC |
| `monad-bot-handler.sh` | Telegram `/status` command handler |
| `monad-upgrade-notify.sh` | Safe upgrade with rollback and notifications |

### Activate monitoring

```bash
sudo mv /etc/cron.d/monad-monitor.disabled /etc/cron.d/monad-monitor
sudo mv /etc/cron.d/monad-daily-report.disabled /etc/cron.d/monad-daily-report
# Optional: enable interactive bot handler
sudo systemctl enable --now monad-bot.service
```

## Post-install paths

| Path | Purpose | Mode |
|---|---|---|
| `/opt/monad/backup/pubkeys.txt` | Public keys (SECP + BLS) | `600 root:root` |
| `/opt/monad/backup/keystore-password-backup` | Keystore password (recovery) | `600 root:root` |
| `/etc/monad/keystore.env` | Systemd EnvironmentFile (KEYSTORE_PASSWORD) | `600 root:root` |
| `/etc/monad/telegram.env` | Telegram bot config | `600 root:root` |
| `/home/monad/.env` | CHAIN, REMOTE_*_URL | `640 root:monad` |
| `/home/monad/monad-bft/config/node.toml` | Node config | `644 root:monad` |
| `/var/log/monad-install.log` | Install log (verbose) | `600 root:root` |

## Sync time expectations

| Mode | Time to "near tip" | Notes |
|------|--------------------|-------|
| With snapshot (default v2) | **15-30 min** | Downloads ~few GB compressed state from MF bucket |
| Without snapshot (`--skip-snapshot`) | ~8 hours on mainnet | Full initial statesync from peers |

## Promote fullnode to validator

After fullnode reaches tip, follow the official node migration flow to swap temp keys for validator keys:

→ https://docs.monad.xyz/node-ops/node-recovery/node-migration

Key steps (high-level):
1. Backup current keystore to `/opt/monad/backup/`
2. Copy validator `id-secp` and `id-bls` from source
3. Re-sign `self_name_record` with `seq_num + 1`
4. Set `enable_publisher = true` in `node.toml`
5. Restart services

## Troubleshooting

### Script fails on `apt install` with `iptables-persistent` conflict
You're using v1 — upgrade to v2 (which removes that package).

### Sync seems stuck — no peer connections
- Check firewall: `sudo ufw status` — ports 8000/tcp and 8001/udp must be allowed
- Check journal: `sudo journalctl -u monad-bft --since "5 min ago" | grep -i peer`
- Check `/home/monad/.env` has `REMOTE_FORKPOINT_URL` and `REMOTE_VALIDATORS_URL`

### RPC port 8080 not listening
- This is normal during early statesync — RPC binds after first finalized block (typically a few minutes)
- Verify: `sudo ss -tlnp | grep monad-rpc`

### Log file rotation
The install log accumulates each run. Rotate with:
```bash
sudo logrotate -f /etc/logrotate.d/monad-install 2>/dev/null || \
  sudo mv /var/log/monad-install.log /var/log/monad-install.log.$(date +%s)
```

## License

MIT
