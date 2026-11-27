# Release candidate test report — 0.1.4

**Status:** Release candidate only. The application has not passed the required Windows installation, upgrade, production restore, printer, or restaurant acceptance tests and must not be described as production-ready.

## Artifact

- Installer: `release/windows-0.1.4/Koli Wada Dhaba POS Setup 0.1.4.exe`
- SHA256: `969029A15D40B3998C7BFD5EBB2D6541D0755D96F6D755C191109502C37B03B8`
- Size: 287,323,818 bytes
- Packaging: Electron 45.3.3 / NSIS x64; unsigned because no code-signing certificate was configured.
- The pre-existing 0.1.3 installer remains in `release/windows/`.

## Checks that passed

- `npm.cmd run build`: Prisma client generation, API TypeScript builds, web TypeScript check, and Vite production build.
- `npm.cmd run test:currency --workspace @koliwada/api`: both INR formatting tests passed, including two decimal places and Indian grouping.
- `scripts/test-isolated-client-database.ps1`: passed against a unique temporary PostgreSQL 17 cluster on a dynamically allocated loopback port. It verified migrations, the 70/13/120 seed, custom-format backup, SHA256 verification, pre-restore backup and restore, Owner/Cashier authentication and access, menu/settings management, bill creation/reuse, Full/Half/manual pricing, quantity edits/removal, snapshots, Cash/UPI/Card settlement, confirmations, change, idempotency, history, cancellation, reports, offline Owner recovery, and API restart/database reconnection.
- `npm.cmd ls --package-lock-only --all --depth=0`: lockfile dependency validation passed.
- `node --check` for Electron main/preload and runtime staging scripts; PowerShell parser check for the isolated database test; `git diff --check`.
- The packaged `win-unpacked` tree contains the Electron app, API, PostgreSQL 17 tools, and all three production Windows install/backup/uninstall scripts.
- The isolated test did not query, start, stop, or modify either `postgresql-x64-17` or `KoliWadaDhabaPostgreSQL`.

## Not run

- Lint: no lint script is configured in the current package manifests.
- Windows VM synthetic installer/ACL/service tests, fresh installation, upgrade, scheduled-task validation, uninstall/data-preservation, and recovery acceptance.
- Production Windows restore: the Owner UI and privileged restore broker are not implemented. The developer restore script remains restricted to isolated test clusters.
- Owner-facing backup/status/history UI and missed-backup warning. The scheduled 01:30 backup task and protected backup script exist, but Owners currently have no in-app manual backup or restore controls.
- Printing on a physical 58 mm or 80 mm printer, cutter behavior, and receipt acceptance.
- Install or execution of Setup.exe on this development laptop. The installer was built and its packaged files were inspected only.
- Client reference videos were present but could not be decoded in this environment. The two available JPEGs show the legacy table and cash-payment screens, not menu cards or prices; no menu prices were changed.

## Release blockers and limits

- Implement and test the Owner-only backup/restore UI and narrowly scoped privileged broker, including archive history, manual backup, missed-run warning, explicit restore confirmation, and verified pre-restore backup.
- Run service/ACL/task install, upgrade, backup, restore, uninstall, and data-preservation tests in a disposable Windows VM. Do not use the developer PostgreSQL service for these tests.
- Complete physical-printer and restaurant acceptance tests.
- Obtain and apply a Windows code-signing certificate before customer distribution if a signed Setup.exe is required.
