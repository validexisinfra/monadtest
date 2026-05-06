# install-monad-fullnode.sh v6 → v7

Status: bash -n syntax OK. 1517 lines (+57 vs v6's 1460).

sha256: `cfd7e53c8612529f24b67e29dea72fa5f9cd92486db3251d1d310fcab5b738b9`

## Why v7

v6 was tested on 2026-05-06 against host `lax-sm3015mr-h8tnr-2-1` (216.152.152.72). Install hit a Phase 4 keystore-generation `PermissionDenied` failure that required hand-fixing `chown monad:monad /home/monad/monad-bft/config` before re-running. v7 makes a fresh-server install go end-to-end without manual intervention, plus four smaller production-quality fixes captured during the same session.

## Fixes

### FIX 13 — Phase 4 keystore PermissionDenied (CRITICAL, blocking)

**Symptom:**

```
[2026-05-06 13:12:42] ═══ PHASE 4: Keystore Generation ═══
[2026-05-06 13:12:42] Generating secp256k1 key...
error: keystore file generation failed: FileIOError(Os { code: 13, kind: PermissionDenied, message: "Permission denied" })
[2026-05-06 13:12:42] ✗ monad-keystore create (secp) failed
```

**Root cause:** the `monad` apt package's postinst creates `/home/monad/monad-bft/config/` as `root:root 0755`. v6's `phase4_keystore` runs `sudo -u monad /usr/local/bin/monad-keystore create --keystore-path ${CONFIG_DIR}/id-secp`, which the `monad` user cannot do because it lacks write on the directory. v6's `phase1_system` does `mkdir -p "${CONFIG_DIR}"/{forkpoint,validators}` but never chowns — and even if it did, Phase 2's apt postinst runs after Phase 1 and resets ownership.

**Fix:** at the start of `phase4_keystore`, after the phase header, take ownership before any `sudo -u monad` write:

```bash
chown -R monad:monad "${CONFIG_DIR}"
chmod 0755 "${CONFIG_DIR}"
```

This runs after Phase 2's apt postinst, so it cannot be clobbered. Idempotent on re-runs.

### FIX 15 — `--enable-on-boot` becomes default

**Old:** `ENABLE_ON_BOOT=false`. Operator had to remember `--enable-on-boot` or the node would not survive a reboot.

**New:** `ENABLE_ON_BOOT=true` by default. Added `--no-enable-on-boot` for opt-out (validator promotion windows where slashing risk requires manual control).

**Rationale:** v6's existing comment said "opt-in default for validator double-signing safety". For a fullnode (`enable_publisher=false`, no consensus participation), there is no double-signing risk, so the default has been wrong since v2. Validators continue to use `--no-enable-on-boot`.

### FIX 16 — `/etc/monad` ownership root:monad 0775

**Old:** `mkdir -p /etc/monad` left it as `root:root 0755`.

**New:** Phase 1 chowns to `root:monad 0775` after mkdir. `keystore.env` inside is still `root:root 0600`, unchanged.

**Rationale:** opens the door for companion scripts (key rotation, version updates) that run as a service user without full root.

### FIX 17 — Telegram bootstrap delivery verification

**Old:** `tg_notify` is best-effort and swallows curl errors silently. A misconfigured `TELEGRAM_BOT_TOKEN` was invisible until the operator checked their phone and found nothing.

**New:** Phase 9, after `tg_notify`, runs a `getMe` check against `https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/getMe` with 10 s timeout. Logs `✓ Telegram bot reachable` on success, `⚠ Telegram bot getMe check failed` on failure. Result lands in `/var/log/monad-install.log` so the operator can grep for it.

Skipped when `--skip-monitoring` is set.

### FIX 18 — `phase7_monitoring` moved after `phase8_start` / `phase9_verify`

**Old order:** `... phase6_systemd → phase7_monitoring → phase7_5_snapshot → phase8_start → phase9_verify`

**Problem:** v6's `phase7` writes `/etc/cron.d/monad-monitor` directly (no `.disabled` state — that change came in v6's other fix). Cron picks up the file within seconds and runs `monad-monitor.sh` every 3 minutes. During Phase 7.5 snapshot download (10–30 min) the services aren't running yet → cron sees "service down + RPC down" → fires Telegram "service down" alerts during a clean install. False positive, every time.

**New order:** `... phase6_systemd → phase7_5_snapshot → phase8_start → phase7_monitoring → phase9_verify`

Monitoring activates only after RPC is responding and `eth_blockNumber` works. No false alerts during install.

Final order: snapshot → start → monitoring → verify. Ensures TG bootstrap notification claim "monitoring active" is accurate at send time.

## What did not change

- TrieDB raw-NVMe handling (Phase 3) — works.
- Snapshot restore (Phase 7.5) — works (took ~3 min on this host vs. estimated 15–30; depends on bandwidth).
- node.toml + sign name record (Phase 5) — works.
- All v5/v6 changelog items (BFT watchdog, otelcol, monad-bot UID rename) — preserved.
- v6 audit trail (changelog comments in header) — preserved.

## FIX 14 (no-op)

User feedback flagged "sudo session priming". This is an invocation-side concern (whether the operator has fresh sudo creds when launching), not a script bug. Documented in README only — no script change.

## Validation

```
$ bash -n /tmp/install-monad-fullnode-v7.sh && echo OK
OK
$ sha256sum /tmp/install-monad-fullnode-v7.sh
cfd7e53c8612529f24b67e29dea72fa5f9cd92486db3251d1d310fcab5b738b9  /tmp/install-monad-fullnode-v7.sh
$ wc -l /tmp/install-monad-fullnode-v7.sh
1517 /tmp/install-monad-fullnode-v7.sh
```

Not pushed to GitHub. File at `/tmp/install-monad-fullnode-v7.sh`.
