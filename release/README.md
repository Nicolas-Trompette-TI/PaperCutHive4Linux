# Release Commands

## Recommended (interactive)

```bash
./setup.sh
```

`setup.sh` always runs `doctor` preflight before installation.

## Recommended (non-interactive)

```bash
./setup.sh --org-id <ORG_ID> --cloud-host eu.hive.papercut.com --linux-user "$USER"
```

Useful flags:
- `--python-mode auto|apt-only` (default: `auto`)
- `--no-notify` to disable desktop popups

Health and repair:

```bash
./setup.sh --doctor --org-id <ORG_ID>
./setup.sh --repair --org-id <ORG_ID>
```

## Manual Step-by-Step (advanced)

```bash
./release/install.sh --org-id <ORG_ID> --cloud-host eu.hive.papercut.com --linux-user "$USER"
./release/finalize-session.sh --org-id <ORG_ID> --cloud-host eu.hive.papercut.com --linux-user "$USER"
./release/verify-print.sh --printer-name PaperCut-Hive-TIF
```

## Notes
- Run `finalize-session.sh` in a normal desktop user session.
- In GUI applications, choose printer `PaperCut-Hive-TIF`.
- Token sync runs by user timer and now auto-refreshes from extension storage if token is invalid.
- On token-related print failures, the alert service triggers an immediate token-sync attempt before asking manual re-login.
- If refresh is impossible, the user gets a desktop popup asking to reconnect the extension.
- Structured support logs are stored in `~/.local/state/papercut-hive-lite/events.jsonl`.
