# PaperCut Hive Driver for Ubuntu

Lightweight production deployment for Ubuntu users who need to print to PaperCut Hive from standard Linux applications.

## One-command setup

```bash
./setup.sh --org-id <ORG_ID> --cloud-host eu.hive.papercut.com --linux-user "$USER"
```

What setup installs:
1. CUPS queue (`PaperCut-Hive-Lite`) for normal Linux printing
2. Secure token storage in OS keyring (Secret Service)
3. Automatic token sync after login/reboot (systemd --user timer)
4. Local print verification

If setup is launched from a non-graphical shell, run finalization from your desktop session:

```bash
./release/finalize-session.sh --org-id <ORG_ID> --cloud-host eu.hive.papercut.com --linux-user "$USER"
```

## Print a document

```bash
echo test > ~/test.txt
lp -d 'PaperCut-Hive-Lite' ~/test.txt
```

## Security
- User JWT is stored in OS keyring (not in repository files)
- Runtime token files are restricted to `root:lp` (`640`)
- Privileged token writes are limited to a dedicated helper command

## Useful commands

```bash
./release/install.sh --org-id <ORG_ID> --cloud-host eu.hive.papercut.com --linux-user "$USER"
./release/finalize-session.sh --org-id <ORG_ID> --cloud-host eu.hive.papercut.com --linux-user "$USER"
./release/verify-print.sh --printer-name PaperCut-Hive-Lite
```

## Supported scope
- Ubuntu-focused deployment
- System printing through CUPS
- Secure release behavior governed by your PaperCut Hive tenant policy
