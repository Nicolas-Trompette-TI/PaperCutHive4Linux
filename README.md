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
- `setup.sh` now runs a mandatory `doctor` preflight before install.
- Desktop notifications are enabled by default for setup issues and print-send failures.
- You can still run non-interactive mode:

```bash
./setup.sh --org-id <ORG_ID> --cloud-host eu.hive.papercut.com --linux-user "$USER"
```

Useful operations:

```bash
./setup.sh --doctor --org-id <ORG_ID>
./setup.sh --repair --org-id <ORG_ID>
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

## Runtime Stability
- Default Python mode is `auto`: system `python3` + `python3-requests` first.
- If system runtime is broken, installer can auto-fallback to a local driver venv.
- Token sync timer auto-refreshes from the PaperCut browser extension if keyring token is missing/expired.
- On `token-invalid`/`missing-token` print errors, the user-side alert service now triggers an immediate token-sync attempt automatically.
- If token is still invalid during print, a desktop popup asks the user to reconnect the extension.
- To force strict system mode: `--python-mode apt-only`.
- To disable desktop notifications: `--no-notify`.

## Health, Repair, and Logs
- `--doctor` returns standardized exit codes:
  - `0` OK
  - `2` warnings
  - `20` missing package install refused
  - `21` missing package install failed
  - `22` critical state not valid
- `--repair` runs the same preflight, then repairs backend, queue, timers, and token sync path.
- Lightweight structured logs are stored in:
  - `~/.local/state/papercut-hive-lite/events.jsonl`

## Debian Package
Build a production `.deb`:

```bash
./packaging/build_deb.sh --version 1.0.0
sudo apt install ./dist/papercut-hive-driver_1.0.0_$(dpkg --print-architecture).deb
```

CLI wrappers installed by package:
- `papercut-hive-setup`
- `papercut-hive-doctor`
- `papercut-hive-repair`

## Security
- User JWT stored in OS keyring (Secret Service)
- Runtime token files restricted to `root:lp` (`640`)
- Privileged token writes restricted to a dedicated helper command
