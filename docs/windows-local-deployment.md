# Koli Wada Dhaba POS — local Windows deployment

## Current implementation

The Windows NSIS package now has elevated install/uninstall hooks. Installation uses the packaged PostgreSQL 17 runtime and provisions only the dedicated `KoliWadaDhabaPostgreSQL` service and the application’s own cluster. It does not use or change the developer service `postgresql-x64-17`.

- PostgreSQL data: `%ProgramData%\Koli Wada Dhaba POS\Data`
- Backups: `%ProgramData%\Koli Wada Dhaba POS\Backups`
- Protected configuration: `%ProgramData%\Koli Wada Dhaba POS\config`
- Local PostgreSQL listener: `127.0.0.1:5433` (separate from the developer/default PostgreSQL port)
- Local API listener: `127.0.0.1:4000`

The installer refuses to initialize an existing data directory unless it has the expected PostgreSQL 17 version and application marker. Existing clusters and credentials are reused only when the marker, service executable, data path, Windows user SID, and DPAPI files agree. Partial or ambiguous installations fail closed and retain their files for inspection.

For a new cluster, setup generates random PostgreSQL and application credentials, initializes only the newly created empty data directory, configures SCRAM authentication and an IPv4 loopback-only listener, and registers a service with automatic startup and restart recovery. PostgreSQL data access is restricted to the service SID, SYSTEM, and Administrators. The DPAPI-protected app configuration is readable only by SYSTEM, Administrators, and the Windows user who installed the app.

Prisma `migrate deploy` runs on every install/upgrade. The existing seed runs only while the installation marker records an unseeded new cluster and the migrated database has no master or business records. It verifies the 70/13/120 master counts and never drops, resets, or copies a developer database.

The first Owner is created by the application's existing first-run setup screen after installation. No default Owner password is shipped. The Electron app waits for the dedicated PostgreSQL service, starts the local API, and waits for a successful database health response before showing the UI.

## Backups and restore

A Windows scheduled task runs a local custom-format PostgreSQL backup daily at 11:00 PM and starts missed work when the laptop next becomes available. It validates each dump, stores it under ProgramData, and removes only matching backup files older than 30 days. It does not delete database records.

An optional USB copy is attempted only for a removable volume named `KWD POS BACKUP` that Windows confirms is fully BitLocker-encrypted and protected. If unavailable, the task records a warning in `%ProgramData%\Koli Wada Dhaba POS\Logs\backup.log`; the local backup remains. USB retention is not automated, so retain or remove USB backup files manually only after validating another copy.

The developer restore script accepts only loopback PostgreSQL URLs, requires the exact confirmation phrase `RESTORE LOCAL POS DATABASE`, creates and validates a separate pre-restore dump, then restores. Keep both the source and pre-restore dump until the restored POS has been checked.

## Build and isolated validation

Build the API/web and installer with:

```powershell
npm.cmd run desktop:installer
```

The staging step expects a verified PostgreSQL 17 runtime at `build-runtime\postgresql17` with the server and third-party license notices. It stages API production dependencies separately and includes pinned Prisma/tsx installer tooling. It rejects missing PostgreSQL tools, a non-17 server, missing notices, or a staged data directory.

Run the isolated end-to-end test with:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts\test-isolated-client-database.ps1
```

The test uses a unique temporary PostgreSQL cluster on loopback, runs migrations and seed, verifies backup/restore including the required pre-restore backup, and tests first-Owner setup/login. It must not be pointed at the developer database.

## Release gate and limitations

The production NSIS installer has not been run on this developer laptop and must not be used here as a substitute for a clean Windows VM. Before release, test the exact generated installer on a clean Windows 10/11 VM or separate test laptop:

1. Fresh install and UAC prompt; service identity, startup type, recovery actions, ACLs, port, and listener.
2. Owner first-run setup/login and application launch.
3. Windows restart, database persistence, and application launch.
4. Daily backup task, 30-day file-only retention, encrypted USB warning/copy, and restore from a verified dump.
5. Upgrade, uninstall/reinstall, and preservation of Owner settings, database records, and backups.
6. Confirm `postgresql-x64-17` remains untouched throughout.

No physical printer compatibility, clean-client installation, Windows restart, actual uninstall/reinstall preservation, or encrypted USB test is claimed until performed on that isolated Windows target. The PostgreSQL binaries include their bundled notices; independently verify the exact runtime source and redistribution terms before distributing the installer.
