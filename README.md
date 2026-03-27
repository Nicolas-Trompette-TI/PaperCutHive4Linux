# PaperCut Hive Ubuntu Research Kit

This kit implements the Ubuntu research plan with reproducible checks and artifacts.

## Scope
- Track baseline facts from the Windows installer binary.
- Probe Hive/Pocket EU network dependencies from this machine.
- Assess local runtime prerequisites for the two candidate paths:
  - Path A: Chrome extension path (closest to Hive baseline flow).
  - Path B: Native Linux CUPS direct IPP/IPPS path.
- Produce a comparison matrix and a Go/No-Go recommendation template.

## Quick start
Run from this directory:

```bash
./scripts/check_runtime_prereqs.sh
./scripts/collect_binary_baseline.sh ../papercut-hive-eu-aujpa4ek7tfh.exe
./scripts/probe_hive_network.sh eu
./scripts/chrome_extension_probe.sh
```

If CUPS and a test printer URI are available:

```bash
PRINTER_URI='ipps://<printer-ip-or-host>/ipp/print' \
  ./scripts/cups_direct_probe.sh --dry-run
```

## Real phase (user-space lab, no sudo install)
Run this to execute both paths in an isolated local lab:

```bash
./scripts/setup_local_chromium_and_extension.sh
./scripts/pathA_chromium_extension_smoke.sh
./scripts/setup_local_cups_lab.sh
./scripts/pathB_cups_smoke.sh
./scripts/cleanup_local_cups_lab.sh
```

## Real phase (Docker Ubuntu 22.04)
Run this to execute the A/B smoke in an Ubuntu 22.04 container:

```bash
./scripts/docker_ubuntu2204_ab.sh
```

If your current shell has not refreshed `docker` group membership yet:

```bash
sg docker -c './scripts/docker_ubuntu2204_ab.sh'
```

## Secret handling (PaperCut auth)
Store credentials in a local protected file (not in code):

```bash
./scripts/papercut_auth_store.sh
```

Load credentials into current shell env when needed:

```bash
source ./scripts/papercut_auth_load.sh
```

Cleanup and remove local secret file:

```bash
./scripts/papercut_auth_cleanup.sh
```

## Ubuntu Lite deployment (policy-based extension setup)
Generate and apply managed browser policy for force-install + org preconfiguration:

```bash
./scripts/install_hive_ubuntu_lite.sh --org-id 112d7ba3 --region-code eu --dry-run
# remove --dry-run to apply
```

## Linux system printing via CUPS (transparent queue)
Install a persistent CUPS backend queue that forwards jobs to PaperCut:

```bash
./scripts/install_hive_cups_backend.sh --org-id 112d7ba3 --cloud-host eu.hive.papercut.com --dry-run
# remove --dry-run to apply
```

Then set token for Linux user (prompted securely):

```bash
./scripts/set_hive_user_token.sh --linux-user "$USER"
```

Or auto-import the JWT already stored by the linked Hive Chromium extension:

```bash
./scripts/import_hive_jwt_from_extension.sh \
  --linux-user "$USER"
```

Create `test.txt` and print through CUPS queue:

```bash
./scripts/print_test_txt.sh PaperCut-Hive-Lite
```

Notes:
- Backend queue name defaults to `PaperCut-Hive-Lite`.
- Backend converts non-PDF inputs to PDF with `cupsfilter` when available.
- JWT auto-import detects profiles in order: `~/.config/google-chrome`, `~/.config/chromium`, `./tools/chromium-user-data-auth` (override with `--profile-dir`).
- File permissions are set for CUPS backend runtime user (`lp`):
  - `/etc/papercut-hive-lite/config.env` -> `root:lp 640`
  - `/etc/papercut-hive-lite/tokens/*.jwt` -> `root:lp 640`
  - `/var/lib/papercut-hive-lite` -> `root:lp 775`
- Token resolution order:
  1) `/etc/papercut-hive-lite/tokens/<linux-user>.jwt`
  2) `/etc/papercut-hive-lite/tokens/default.jwt`
  3) `PAPERCUT_USER_JWT` or `PAPERCUT_ID_TOKEN` in `/etc/papercut-hive-lite/config.env`

## Secure OS keyring + auto-sync (recommended for production)
Deploy end-to-end with keyring-backed secret handling and auto-resync after reboot/login:

```bash
./scripts/install_hive_secure_autodeploy.sh \
  --org-id 112d7ba3 \
  --cloud-host eu.hive.papercut.com \
  --linux-user "$USER" \
  --bootstrap-from-extension
```

What this adds:
- OS keyring storage via `secret-tool` (Secret Service/libsecret).
- Restricted root helper `/usr/local/sbin/papercut-hive-token-sync`.
- Scoped sudoers rule in `/etc/sudoers.d/91-papercut-hive-token-sync`.
- `systemd --user` timer `papercut-hive-token-sync.timer` for periodic sync.

Manual keyring flows:

```bash
./scripts/papercut_secret_store.sh --org-id 112d7ba3 --from-extension --sync-now
./scripts/papercut_secret_sync.sh --org-id 112d7ba3 --verbose
./scripts/papercut_keyring_init.sh --label login
```

Note:
- `secret-tool` requires an active user Secret Service session (typically desktop login session).
- If deployment is launched from a headless/non-graphical shell, run the two manual keyring commands later from your normal user session.

Security model:
- Long-lived token is stored in OS keyring, not in repo files.
- Runtime CUPS token file remains restricted to `root:lp` with mode `640`.
- Privileged token write path is constrained to a single helper command.

GitHub mode:
- CI validation workflow is included at `.github/workflows/validate.yml`.

Release mode:
- Use `./release/install.sh` then `./release/finalize-session.sh`.
- Post-install verification: `./release/self-test.sh`.

Unit tests:
```bash
python3 -m unittest discover -s tests -p "test_*.py" -v
```

## Reverse protocol + job submit POC
Extract protocol hints from the extension service worker:

```bash
python3 ./scripts/reverse_hive_extension_protocol.py \
  --output ./outputs/reverse-protocol-$(date -u +%Y%m%dT%H%M%SZ).json
```

Submit a PDF using extension-like API flow (claim token, discover node, send multipart `/print`):

```bash
python3 ./scripts/papercut_submit_job_poc.py \
  --cloud-host eu.hive.papercut.com \
  --org-id 112d7ba3 \
  --id-token '<pc-idtoken>' \
  --file ./sample.pdf \
  --dry-run
```

Network-free planning mode:

```bash
python3 ./scripts/papercut_submit_job_poc.py \
  --file ./sample.pdf \
  --cloud-host eu.hive.papercut.com \
  --offline-dry-run
```

Interactive wrapper (prompts token securely if env vars are unset):

```bash
./scripts/papercut_submit_job_poc.sh --file ./sample.pdf --org-id 112d7ba3 --dry-run
```

## What is generated
- `outputs/runtime-prereqs-<timestamp>.txt`
- `outputs/binary-baseline-<timestamp>.txt`
- `outputs/network-probe-<region>-<timestamp>.csv`
- `outputs/network-probe-<region>-<timestamp>.txt`
- `outputs/chrome-extension-probe-<timestamp>.txt`
- `outputs/pathA-smoke-<timestamp>.txt`
- `outputs/pathB-smoke-<timestamp>.txt`

## Notes
- This machine may not be Ubuntu 24.04. The runtime report captures exact OS details.
- Some checks require tenant access and real printers; use `templates/test-log.md` and `templates/compatibility-matrix.md` to record those outcomes.
- In Ubuntu 22.04 Docker, `chromium-browser` requires Snap by default, so browser-extension validation may be constrained in headless containers.
- Local secrets are ignored by `.gitignore` via `.secrets/`.
