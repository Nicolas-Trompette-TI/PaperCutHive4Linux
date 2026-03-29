# PaperCut Hive Driver for Ubuntu

Install once, then print from standard Linux apps to PaperCut Hive/Pocket.

## Quick Start (Autopilot, No Browser Extension Required)

```bash
git clone https://github.com/Nicolas-Trompette-TI/PaperCutHive4Linux.git
cd PaperCutHive4Linux
./setup.sh
```

Default user flow:
1. Launch `./setup.sh`
2. Enter PaperCut email/password (password is not stored)
3. Enter sudo password when required
4. Wait for install/repair/final verification

`setup.sh` is now the main entrypoint for both first install and day-2 repair.

## What `setup.sh` does (pipeline)

1. Auth (password mode by default)
2. Preflight advisory (`doctor`)
3. Install runtime stack
4. Token bootstrap/sync
5. Finalize desktop session
6. Verify print path + one auto-repair retry

The script is idempotent by design: re-running `./setup.sh` revalidates and repairs what can be repaired automatically.

## Prompt Policy

`setup.sh` minimizes prompts:
- no generic `Continue?` prompt
- destructive prompt only when a queue with the same name exists and is **not** a PaperCut queue
- if queue already points to `papercut-hive-lite:/`, no destructive confirmation prompt

## Auth Modes

- `password` (default): no extension required, prompts login/password in terminal
- `auto`: tries password login first, then fallback to extension/config/manual Org ID flow
- `extension`: extension/config/manual Org ID flow only

Examples:

```bash
./setup.sh --auth-mode password --login-email you@company.com
./setup.sh --auth-mode auto
./setup.sh --auth-mode extension --org-id <ORG_ID> --cloud-host eu.hive.papercut.com --linux-user "$USER"
```

## Setup Exit Status

`setup.sh` final statuses:

- `0` -> `OK` (ready)
- `2` -> `WARN-action-required` (partial success, manual session action still needed)
- `20` -> dependency install refused
- `21` -> dependency install failed
- `22` -> critical non-recoverable blocker

Typical `2` scenarios:
- no active desktop DBus session in current shell
- current shell missing active `papercut-hive-users` group (logout/login needed)
- verification still degraded after one auto-repair pass

When status is `2`, setup prints exact next commands to run.

## Useful Options

```bash
./setup.sh --yes --no-color --no-progress
```

- `--yes`: auto-confirm prompts
- `--no-color`: disable ANSI colors (same effect as `NO_COLOR=1`)
- `--no-progress`: disable progress bar rendering
- `--skip-verify`: skip final verify step
- `--python-mode apt-only`: strict system Python runtime

## Doctor / Repair Modes

```bash
./setup.sh --doctor --org-id <ORG_ID>
./setup.sh --repair --org-id <ORG_ID>
```

Doctor exit codes:
- `0`: OK
- `2`: warnings
- `20`: missing package install refused
- `21`: missing package install failed
- `22`: critical invalid state

## Finalize (If setup returns `2`)

Run finalize from the normal graphical session of the target user.

Password mode / no extension:

```bash
./release/finalize-session.sh --org-id <ORG_ID> --cloud-host eu.hive.papercut.com --linux-user "$USER" --no-bootstrap-from-extension
```

Extension mode:

```bash
./release/finalize-session.sh --cloud-host eu.hive.papercut.com --linux-user "$USER"
```

## Manual Verify

```bash
./release/verify-print.sh --printer-name PaperCut-Hive-TIF
```

## Runtime Notes

- Default Python mode is `auto`: system `python3` + `python3-requests` first, local venv fallback if needed.
- Use `--no-notify` to disable desktop notifications.
- Structured logs: `~/.local/state/papercut-hive-lite/events.jsonl`.
- Queue provisioning prefers `drv:///sample.drv/generic.ppd` (raw fallback only if unavailable).
- Password-login helper auto-refreshes Firebase API key when backend key rotation is detected, then caches host->key mapping in `~/.cache/papercut-hive-lite/firebase_api_keys.json`.

## Debian Package

```bash
./packaging/build_deb.sh --version 1.0.0
sudo apt install ./dist/papercut-hive-driver_1.0.0_$(dpkg --print-architecture).deb
```

Installed wrappers:
- `papercut-hive-setup`
- `papercut-hive-doctor`
- `papercut-hive-repair`

## Security

- User JWT stored in OS keyring (Secret Service).
- Runtime token files restricted to `root:lp` (`640`).
- Privileged token writes restricted to a dedicated helper command.
- Privileged helper blocks cross-user token sync (caller must match target user).
- Runtime rejects insecure token/config paths (symlink, wrong owner/group, permissions too broad).
- Tokens are passed over `stdin` (not CLI args) in setup/sync/submit flows.
- Project secure coding policy: `SECURE_CODING.md`.
