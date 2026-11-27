# Koli Wada Dhaba POS

Offline billing and table management for **KOLI WADA DHABA — Family Seafood Restaurant**. The production target is one Windows laptop with a local Electron desktop app, a dedicated PostgreSQL 17 service, and no cloud or internet dependency during restaurant operations.

The old Capacitor/Android scaffold is unsupported and unrelated to the Windows POS product; it is excluded from the 0.1.5 source ZIP.

## Windows installation

1. Run **Koli Wada Dhaba POS Setup.exe** and approve the Windows administrator prompt. The installer creates the separate `KoliWadaDhabaPostgreSQL` service on `127.0.0.1:5433` and stores its data under `%ProgramData%\Koli Wada Dhaba POS\Data`.
2. Launch the desktop shortcut. The application waits for the dedicated database and local API before showing the sign-in screen.
3. On first use, create the Owner account and save or print the one-time offline recovery key. No default password or remote email service is required.
4. Add cashier accounts in **Settings**. Owner controls are hidden from Cashier sessions and checked again by the API.

Use the focused guides for [installation](docs/windows-installation-0.1.5.md), [upgrade](docs/windows-upgrade-0.1.5.md), [Owner backup and restore](docs/windows-backup-restore-0.1.5.md), and [uninstall/data preservation](docs/windows-uninstall-data-preservation-0.1.5.md). The [full Windows deployment guide](docs/windows-local-deployment.md) includes the acceptance requirements. Never point POS provisioning or tests at the developer PostgreSQL service `postgresql-x64-17` or its `C:\Program Files\PostgreSQL\17\data` directory.

## Restaurant workflows

- 70 tables, 13 menu categories, and the 120-item menu are seeded from `apps/shared/menu.json`. Existing complete or partial business data must be preserved; the installer does not replace it with a fresh seed.
- Bills are attached to a table, with one open bill per table. Names and prices are snapshotted onto bill lines. Cash, UPI, and card settlement are recorded locally; UPI and card require cashier confirmation against the merchant app or terminal.
- All displayed and exported amounts use INR (`₹`) with Indian digit grouping and two decimal places. Database amounts remain numeric.
- Reports include payment-method and table-wise totals, paid and cancelled bills, CSV export, and printable reports and receipts.
- A paid bill prints a receipt through the saved preferred Windows printer. Bill reprints and daily reports use the same route. Receipt layouts support 58 mm and 80 mm rolls; if the saved printer is missing, Windows opens its print selection dialog. Configure the printer and run a physical test print before service. Hardware compatibility remains pending.
- Owner password recovery uses the one-time offline recovery key. Keep it separate from the laptop. No Gmail, SMTP, subscription, online license check, analytics, or cloud authentication is part of the runtime.

## Local backup

Windows Task Scheduler runs the local custom-format PostgreSQL backup daily at **01:30 AM**. `StartWhenAvailable` stays disabled, so a missed run will not interrupt restaurant service. The Owner **Backup & Restore** screen in the 0.1.5 candidate shows history, last successful backup, missed-run warnings, and USB status; it supports manual backup and confirmed restore. Restore validates the selected archive, creates and verifies a separate pre-restore archive, then runs through a fixed-operation SYSTEM broker. The Electron renderer cannot send PowerShell, SQL, filesystem paths, or database URLs to that broker. Backup archives remain writable only by SYSTEM and Administrators.

These screen and broker changes are still awaiting clean Windows VM acceptance. They are not in the preserved 0.1.4 Setup.exe, and the 0.1.5 candidate must not be treated as production-ready until the required Windows lifecycle and restore checks pass. The optional USB copy is attempted only for a removable volume labelled `KWD POS BACKUP` with full BitLocker protection. Never use the developer-only `scripts/restore-postgres.ps1` for a customer installation; it is restricted to disposable test clusters.

## Workspace map

- `apps/web`: React 19, TypeScript, and Vite renderer
- `apps/api`: Express API, authentication, business workflows, Prisma schema and migrations
- `apps/desktop`: Electron main/preload processes and Windows NSIS installer hooks
- `apps/shared/menu.json`: approved menu source
- `docs/menu-reference-review.md`: comparison of the canonical menu with supplied legacy POS references
- `scripts/windows`: Windows installation, backup, restore, broker, and uninstall utilities
- `scripts/test-isolated-client-database.ps1`: disposable PostgreSQL regression test
- `apps/desktop/maintenance-contract.test.cjs`: fixed-operation maintenance request tests
- `apps/desktop/print-contract.test.cjs`: preferred-printer routing and receipt-width tests
- `build-runtime`: locally staged PostgreSQL 17 and installer dependencies used by packaging
- `compose.yaml`: optional local development database on port 55432; never used for POS installs or regression tests
- `docs/windows-local-deployment.md`: client installation, upgrade, backup, and data-preservation guide

## Development and validation

Use Node.js LTS and PowerShell. On this Windows setup, use `npm.cmd` because the PowerShell `npm.ps1` wrapper may be blocked by execution policy.

```powershell
npm.cmd run build
npm.cmd run test:currency --workspace @koliwada/api
npm.cmd run test:desktop-contract
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\test-isolated-client-database.ps1
```

The isolated database test provisions a uniquely named temporary PostgreSQL 17 cluster under the Windows TEMP directory and removes it after successful shutdown. It must never be changed to target the developer or installed restaurant service.

Build the Windows installer with:

```powershell
npm.cmd run desktop:installer
```

This stages the current API, renderer, PostgreSQL runtime, and Windows utilities, then writes the NSIS package under `release/windows-0.1.5/`. To create the 0.1.5 installer and complete source ZIP while preserving current generated staging directories, run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\build-release-candidate.ps1
```

The build uses locally cached dependencies. It excludes `.env`, `.pgadmin-password`, database data, backups, temporary test data, release folders, and the unrelated Android scaffold from the source ZIP. It includes the staged PostgreSQL runtime and license notices. Install Setup.exe only in a separate clean Windows VM or disposable test laptop; never install it on the development host.

## Release status

Source builds and isolated database checks are not a substitute for Windows service/ACL, upgrade, uninstall, restore, printer, and restaurant acceptance testing. Report only tests actually run. Do not describe a release as production-ready until those lifecycle and acceptance checks pass.

See the [0.1.4 release test report](docs/release-test-report-0.1.4.md) for its completed checks. The 0.1.5 release folder contains the candidate package, checksums, and actual test report; Windows lifecycle and printer hardware acceptance remain pending until performed on the separate test system.
