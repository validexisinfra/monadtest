# monadtest
# install-monad-fullnode.sh

Automated installation script for a Monad mainnet fullnode on Ubuntu 24.04.

## What it does

1. **System preparation** — installs dependencies, creates `monad` user, configures UFW firewall, fail2ban, hidepid, disables swap
2. **Package installation** — adds Category Labs APT repository, installs `monad` package, holds version
3. **TrieDB setup** — partitions NVMe device, creates udev rule for `/dev/triedb` symlink, initializes TrieDB with `monad-mpt`
4. **Keystore generation** — generates random password, creates secp256k1 and BLS keys
5. **Node configuration** — writes `node.toml` for fullnode mode (not validator), signs name record
6. **Systemd overrides** — configures keystore env and ProtectProc for all services
7. **Telegram monitoring** — installs 5 monitoring scripts with cron jobs (disabled by default)
8. **Service startup** — starts monad-execution, monad-bft, monad-rpc, enables them
9. **Verification** — checks RPC responds, sends summary to Telegram

## Requirements

- Ubuntu 24.04 LTS (fresh install or existing server)
- Root access
- Raw NVMe device (unused, will be wiped)
- Public IPv4 address
- Telegram bot token and chat ID

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
| `--beneficiary` | No | `0x0...0` | EVM address for block rewards |
| `--ssh-port` | No | `2225` | SSH port for UFW rule |
| `--skip-triedb` | No | — | Skip TrieDB partition and init |
| `--skip-keys` | No | — | Skip keystore generation |
| `--skip-monitoring` | No | — | Skip Telegram monitoring setup |
| `--dry-run` | No | — | Show plan without executing |

## Usage

```bash
sudo TELEGRAM_BOT_TOKEN="123456:ABC-DEF..." TELEGRAM_CHAT_ID="-100123456789" \
  bash install-monad-fullnode.sh \
  --triedb-device /dev/nvme1n1 \
  --node-name "my-fullnode" \
  --self-ip "203.0.113.50"
```

### With beneficiary address (for future validator)

```bash
sudo TELEGRAM_BOT_TOKEN="..." TELEGRAM_CHAT_ID="..." \
  bash install-monad-fullnode.sh \
  --triedb-device /dev/nvme1n1 \
  --node-name "my-validator" \
  --self-ip "203.0.113.50" \
  --beneficiary "0xYourAddress..."
```

### Re-run on partially configured server

```bash
sudo TELEGRAM_BOT_TOKEN="..." TELEGRAM_CHAT_ID="..." \
  bash install-monad-fullnode.sh \
  --triedb-device /dev/nvme1n1 \
  --node-name "my-fullnode" \
  --self-ip "203.0.113.50" \
  --skip-triedb \
  --skip-keys
```

## Idempotency

Each phase checks existing state before acting:
- APT source exists → skip
- Package already installed at target version → skip
- `/dev/triedb` symlink exists → prompt before re-init
- Keys exist → prompt before overwrite

## Monitoring

The script installs 5 monitoring scripts but leaves them **disabled**:

| Script | Purpose |
|--------|---------|
| `monad-monitor.sh` | Alerts every 3 min (service down, disk, RAM, stuck blocks) |
| `monad-send-status.sh` | Full status dashboard on demand |
| `monad-daily-report.sh` | Daily summary at 09:00 UTC |
| `monad-bot-handler.sh` | Telegram `/status` command handler |
| `monad-upgrade-notify.sh` | Safe upgrade with rollback and notifications |

### Activate monitoring

```bash
sudo mv /etc/cron.d/monad-monitor.disabled /etc/cron.d/monad-monitor
sudo mv /etc/cron.d/monad-daily-report.disabled /etc/cron.d/monad-daily-report
# Optional: enable bot handler
sudo systemctl enable --now monad-bot.service
```

## Post-install

- Pubkeys: `/opt/monad/backup/pubkeys.txt`
- Keystore password backup: `/opt/monad/backup/keystore-password-backup`
- Config: `/home/monad/monad-bft/config/node.toml`
- Logs: `journalctl -u monad-bft -f`
- Install log: `/var/log/monad-install.log`

## License

MIT
