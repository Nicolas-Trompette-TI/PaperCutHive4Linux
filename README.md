# PaperCut Hive Driver for Ubuntu

Install once, then print from normal Linux apps to PaperCut Hive.

## For End Users

### 1) Clone and run setup

```bash
git clone https://github.com/Nicolas-Trompette-TI/PaperCutHive4Linux.git
cd PaperCutHive4Linux
./setup.sh
```

- `setup.sh` asks for your `Org ID` if missing.
- You can still run non-interactive mode:

```bash
./setup.sh --org-id <ORG_ID> --cloud-host eu.hive.papercut.com --linux-user "$USER"
```

### 2) Print from GUI apps
After setup, in any graphical app:
1. `Ctrl+P`
2. Select printer `PaperCut-Hive-TIF`
3. Print

### 3) Done
Your Linux workstation keeps the configuration and token sync across reboot/login.

## Direct Answer To Your Question
Yes: for a Linux user, the expected flow is exactly:
1. Clone repo
2. Run install (`./setup.sh`)
3. Use `PaperCut-Hive-TIF` in GUI print dialog

The only requirement is having a valid PaperCut user session/token during setup (handled by the setup/finalize flow).

## If Finalization Is Required
If setup was launched outside a graphical desktop session, run:

```bash
./release/finalize-session.sh --org-id <ORG_ID> --cloud-host eu.hive.papercut.com --linux-user "$USER"
```

## Verify Quickly

```bash
./release/verify-print.sh --printer-name PaperCut-Hive-TIF
```

## Security
- User JWT stored in OS keyring (Secret Service)
- Runtime token files restricted to `root:lp` (`640`)
- Privileged token writes restricted to a dedicated helper command
