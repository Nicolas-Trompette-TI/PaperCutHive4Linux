# Release Commands

## Recommended (interactive)

```bash
./setup.sh
```

## Recommended (non-interactive)

```bash
./setup.sh --org-id <ORG_ID> --cloud-host eu.hive.papercut.com --linux-user "$USER"
```

## Manual Step-by-Step (advanced)

```bash
./release/install.sh --org-id <ORG_ID> --cloud-host eu.hive.papercut.com --linux-user "$USER"
./release/finalize-session.sh --org-id <ORG_ID> --cloud-host eu.hive.papercut.com --linux-user "$USER"
./release/verify-print.sh --printer-name PaperCut-Hive-Lite
```

## Notes
- Run `finalize-session.sh` in a normal desktop user session.
- In GUI applications, choose printer `PaperCut-Hive-Lite`.
