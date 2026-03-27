# Release Commands

For most users, run the root command:

```bash
./setup.sh --org-id <ORG_ID> --cloud-host eu.hive.papercut.com --linux-user "$USER"
```

If you need step-by-step control:

## 1) Install runtime stack

```bash
./release/install.sh --org-id <ORG_ID> --cloud-host eu.hive.papercut.com --linux-user "$USER"
```

## 2) Finalize desktop keyring/session

```bash
./release/finalize-session.sh --org-id <ORG_ID> --cloud-host eu.hive.papercut.com --linux-user "$USER"
```

## 3) Verify printing path

```bash
./release/verify-print.sh --printer-name PaperCut-Hive-Lite
```

## Notes
- Run `finalize-session.sh` inside a normal graphical desktop session.
- `verify-print.sh` checks Linux-side queue completion; confirm release behavior in Hive admin logs if required by policy.
