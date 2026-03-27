# Release Commands

## 1) Install (system side)
```bash
./release/install.sh --org-id 10196b04 --cloud-host eu.hive.papercut.com --linux-user "$USER"
```

## 2) Finalize in user desktop session (keyring + timer)
```bash
./release/finalize-session.sh --org-id 10196b04 --cloud-host eu.hive.papercut.com --linux-user "$USER"
```

## 3) Self-test
```bash
./release/self-test.sh --printer-name PaperCut-Hive-Lite
```

## Notes
- `finalize-session.sh` should be launched from the user graphical session so Secret Service is available.
- `self-test.sh` validates Linux-side CUPS completion only; verify secure release metadata in Hive admin logs.
