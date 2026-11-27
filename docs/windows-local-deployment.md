# Windows local deployment and acceptance

Koli Wada Dhaba POS is a free, offline, single-machine Windows application. It uses its packaged PostgreSQL 17 runtime and the dedicated `KoliWadaDhabaPostgreSQL` service on `127.0.0.1:5433`. Restaurant operation does not require Render, Neon, another cloud host, Gmail/SMTP, a subscription, or an internet connection.

Production files are kept under `%ProgramData%\Koli Wada Dhaba POS`:

- Database: `Data`
- Protected backup archives: `Backups`
- DPAPI configuration and installation identity: `config`
- Backup and restore status/logs: `Logs`

Never use developer service `postgresql-x64-17`, its `C:\Program Files\PostgreSQL\17\data` directory, or port 5432 for POS installation, migration, backup, restore, or testing.

## Install

1. Verify the Setup.exe SHA256 against the release report before running it.
2. Run Setup.exe and approve the machine-wide Windows administrator prompt. The application itself runs as the signed-in Windows user and is not elevated.
3. Install to the standard `C:\Program Files\Koli Wada Dhaba POS` location. The broker-enabled installer requires this protected Program Files path; it does not accept a user-writable application folder.
4. Start the desktop shortcut. It verifies the POS installation identity, waits for the dedicated database and starts the local API.
5. Create the first Owner account. Keep the one-time offline recovery key away from the laptop. No default credentials or remote email service are shipped.
6. Add Cashier accounts in **Settings**, choose the preferred Windows printer and paper width, and run a physical test print.

If setup reports an error, preserve the full ProgramData folder and installer log. Do not delete the Data folder or initialize a new database to retry.

## Upgrade

1. Close the POS application. The installer makes a verified custom-format pre-migration backup before applying Prisma migrations.
2. Run the reviewed newer Setup.exe. Keep the standard Program Files location.
3. The installer verifies the service command, service account, port, PostgreSQL version, data path, instance marker, roles, and master data. It stops if the existing installation does not match. It does not replace business data with a fresh seed.
4. Reopen POS and confirm tables, recent bills, settings, and reports before resuming service.

Use the installer upgrade path. Do not uninstall as an upgrade step. ProgramData database records, settings, logs, and backups remain outside the application install folder.

## Owner backup and restore

In the broker-enabled 0.1.5 candidate, open **Backup & Restore** from an Owner session. The API independently verifies the Owner bearer token before the SYSTEM broker accepts status, history, manual-backup, or restore preparation requests. Cashiers do not receive this screen or broker authorization.

The Owner screen shows the latest verified archive, backup history, daily schedule, missed-run warning, USB status, and prior restore result. **Create manual backup** runs the fixed backup operation. It validates the archive with `pg_restore --list`, records size and SHA256, and does not overwrite an existing archive. The optional USB copy is used only for a removable volume named `KWD POS BACKUP` that Windows confirms is fully BitLocker-encrypted and protected.

Restore is available only from the protected archive history. Select a backup, review its time and ID, check the data-replacement notice, and type `RESTORE`. The broker rechecks Owner authorization, validates the selected archive and checksum, creates and verifies a separate pre-restore backup, then performs a single-transaction PostgreSQL restore. It reapplies the fixed `kwd_app` grants and verifies the application role can read business data. If restore or validation fails after the target database changes, the broker attempts to restore and validate the pre-restore archive before reporting failure. The Electron main process pauses its local API during the database operation and restarts it afterward. The renderer cannot provide a PowerShell command, SQL text, database URL, or filesystem path. The broker runs as SYSTEM through a protected Task Scheduler task and interactive-user-only named pipe; the Electron application is not an Administrator process.

The archive directory grants write access only to SYSTEM and Administrators. There is no backup-delete control in the POS interface. The 01:30 AM automatic task keeps `StartWhenAvailable` disabled. A missed run appears as a warning and never initiates a daytime catch-up or blocks billing. USB availability is checked when the Owner opens or refreshes this screen; the drive must be connected, removable, labeled `KWD POS BACKUP`, fully encrypted and protected. Each archive separately records whether its optional USB copy passed SHA256 verification.

**Release gate:** the existing 0.1.4 Setup.exe does not contain this Owner screen or broker. The 0.1.5 implementation is a candidate until fresh-install, upgrade, SYSTEM task/ACL, manual backup, missed-run, restore, failure recovery, uninstall, and reinstallation checks pass in a clean Windows VM. Do not use the developer-only `scripts/restore-postgres.ps1` for a customer installation; that script is restricted to disposable test clusters.

## Printer setup

The preferred printer is stored locally in the POS desktop profile. Bill settlement, history reprints, and reports route to it. Receipts follow the configured 58 mm or 80 mm width; reports use an 80 mm layout. If the preferred printer is no longer installed, Windows opens its print selection dialog. Failed jobs are not silently resubmitted, avoiding duplicate receipts. Run the test print on the actual printer and check clipping, paper feed, and cutter behavior; physical hardware acceptance is still pending.

## Uninstall and data preservation

Use Windows **Apps & features**. The uninstaller validates and removes only the POS-owned PostgreSQL service, daily backup task, and SYSTEM maintenance broker task. It preserves ProgramData database files, Owner configuration, status/logs, and backups. Uninstalling the application does not erase restaurant records.

Before retiring a laptop, make a separate verified backup and retain the original machine until that archive has been restored and checked in an approved isolated environment. Do not delete ProgramData unless the Owner separately approves permanent data destruction.

## Regression checks

Run these from the project root:

```powershell
npm.cmd run build
npm.cmd run test:currency --workspace @koliwada/api
npm.cmd run test:desktop-contract
powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File .\scripts\test-isolated-client-database.ps1
```

The PostgreSQL regression suite creates a uniquely named PostgreSQL 17 cluster under Windows TEMP on a dynamically allocated loopback port. It covers Owner/Cashier authentication, 70 tables, 13 categories, 120 menu items, full/half and custom items, bill editing/removal, all payment methods, history/reports, and isolated backup/restore. It must never use the developer or installed POS service.

## Windows acceptance gate

Use the step-by-step [0.1.5 Windows acceptance checklist](windows-acceptance-checklist-0.1.5.md) in a clean disposable Windows VM with no developer database or production restaurant data. Test fresh install, first launch, billing, restart, upgrade and data preservation, 01:30 task settings, manual backup, missed-run warning, restore and failure handling, uninstall, and reinstall while preserving ProgramData. Record the actual OS/build, task principal/trigger/`StartWhenAvailable`, database identities, archive hashes, and result for every case.

The installer, Task Scheduler security descriptors, SYSTEM pipe authorization, Windows lifecycle, and physical printers are not fully accepted by the isolated PostgreSQL test. A customer release is not production-ready until the Windows VM checks and actual printer acceptance pass. Keep the 0.1.4 artifacts unchanged during 0.1.5 development.
