# Uninstall and preserve restaurant data — 0.1.5

Use this procedure only on a disposable acceptance copy until Windows acceptance has passed.

1. Close the POS application and make a verified Owner backup.
2. Open Windows **Settings → Apps → Installed apps** (or **Apps & features**) and uninstall **Koli Wada Dhaba POS**.
3. Confirm the POS-owned PostgreSQL service and scheduled tasks are removed.
4. Confirm `%ProgramData%\Koli Wada Dhaba POS` remains, including `Data`, `Backups`, `config`, and `Logs`.
5. To reinstall, run the matching Setup.exe and let it validate the existing POS installation. Confirm bills, accounts, settings, and reports remain.

Uninstall preserves restaurant data. Do not delete ProgramData or initialize a new database to recover from an installer error. Permanent deletion of the ProgramData folder requires a separate Owner decision and a verified retained backup.
