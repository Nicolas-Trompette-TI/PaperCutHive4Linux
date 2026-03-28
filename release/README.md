# Release Commands

## Recommended (interactive)

```bash
./setup.sh
```

## Recommended (non-interactive)

```bash
./setup.sh --org-id <ORG_ID> --cloud-host eu.hive.papercut.com --linux-user "$USER"
```

Useful flags:
- `--python-mode auto|apt-only` (default: `auto`)
- `--no-notify` to disable desktop popups

## Manual Step-by-Step (advanced)

```bash
./release/install.sh --org-id <ORG_ID> --cloud-host eu.hive.papercut.com --linux-user "$USER"
./release/finalize-session.sh --org-id <ORG_ID> --cloud-host eu.hive.papercut.com --linux-user "$USER"
./release/verify-print.sh --printer-name PaperCut-Hive-TIF
```

## Notes
- Run `finalize-session.sh` in a normal desktop user session.
- In GUI applications, choose printer `PaperCut-Hive-TIF`.
