# Release Commands

## Recommended (Interactive)

```bash
./setup.sh
```

Default behavior (`--auth-mode password`):
- asks for PaperCut email/password in terminal
- does not store the password
- fetches token + Org ID automatically
- does not require browser extension

## Auth Modes

```bash
./setup.sh --auth-mode password --login-email you@company.com
./setup.sh --auth-mode auto
./setup.sh --auth-mode extension --org-id <ORG_ID>
```

- `password`: no extension required
- `auto`: tries password login first, fallback to extension/config/manual org flow
- `extension`: extension/config/manual org flow only

## Non-Interactive Example

```bash
./setup.sh --auth-mode extension --org-id <ORG_ID> --cloud-host eu.hive.papercut.com --linux-user "$USER"
```

## Health / Repair

```bash
./setup.sh --doctor --org-id <ORG_ID>
./setup.sh --repair --org-id <ORG_ID>
```

## Manual Step-By-Step (Advanced)

```bash
./release/install.sh --org-id <ORG_ID> --cloud-host eu.hive.papercut.com --linux-user "$USER"
./release/finalize-session.sh --org-id <ORG_ID> --cloud-host eu.hive.papercut.com --linux-user "$USER" --no-bootstrap-from-extension
./release/verify-print.sh --printer-name PaperCut-Hive-TIF
```

## Finalize Variants

No extension / password mode:

```bash
./release/finalize-session.sh --org-id <ORG_ID> --cloud-host eu.hive.papercut.com --linux-user "$USER" --no-bootstrap-from-extension
```

Extension mode:

```bash
./release/finalize-session.sh --cloud-host eu.hive.papercut.com --linux-user "$USER"
```

## Notes

- Run `finalize-session.sh` in a normal desktop user session.
- In GUI applications, choose printer `PaperCut-Hive-TIF`.
- Structured support logs are stored in `~/.local/state/papercut-hive-lite/events.jsonl`.
