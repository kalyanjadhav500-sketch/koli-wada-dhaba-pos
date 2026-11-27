# Windows upgrade — 0.1.5

Perform this procedure in a disposable VM containing a copy of the existing POS installation. Keep the original installation available until the upgraded copy has been checked.

1. Close the POS application.
2. Verify the 0.1.5 Setup.exe SHA256 using `release-test-report-0.1.5.md`.
3. Run Setup.exe and approve the Windows administrator prompt. Keep the existing standard Program Files location.
4. Allow setup to validate the dedicated POS service and create a verified pre-migration backup before migrations run.
5. If setup stops on an identity, service, path, archive, or master-data check, preserve the complete `%ProgramData%\Koli Wada Dhaba POS` directory and installer logs. Do not initialize a replacement database or uninstall as an upgrade step.
6. After setup completes, sign in and verify Owner/Cashier accounts, settings, recent bills, payments, menu, tables, and daily reports.
7. Check the 01:30 AM backup task and create a manual Owner backup before accepting the upgrade.

The installer recognizes the dedicated 0.1.4 POS instance and preserves ProgramData business records. Do not point any step at `postgresql-x64-17`, port 5432, or its data directory.
