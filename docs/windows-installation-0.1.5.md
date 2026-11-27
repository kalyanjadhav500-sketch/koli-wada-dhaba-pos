# Windows installation — 0.1.5

Install the candidate only on a clean disposable Windows 10/11 VM or test laptop. Do not run Setup.exe on the development host.

1. Copy `Koli Wada Dhaba POS Setup 0.1.5.exe` to the test computer and verify its SHA256 against `release-test-report-0.1.5.md`.
2. Run Setup.exe and approve its machine-wide Windows administrator prompt. The Electron POS starts as the signed-in user with `asInvoker` permissions.
3. Keep the standard destination `C:\Program Files\Koli Wada Dhaba POS`.
4. Wait for setup to verify and install the separate PostgreSQL 17 service, then launch the desktop shortcut.
5. On first launch, create the Owner username and password. Save the one-time offline recovery key separately from the computer.
6. Sign in as Owner, confirm the restaurant menu and 70 tables, and add a Cashier account in Settings.
7. Sign out and verify the Cashier can sign in and perform normal billing. The Cashier must not see Backup & Restore.
8. Follow the [Windows acceptance checklist](windows-acceptance-checklist-0.1.5.md) before using this candidate for restaurant service.

The application runs locally and needs no cloud database, online activation, subscription, or required email service. Windows may warn that Setup.exe is unsigned; verify the SHA256 before choosing to continue.
