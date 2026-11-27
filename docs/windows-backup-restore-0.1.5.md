# Owner backup and restore — 0.1.5

Only an Owner can open **Backup & Restore**. The screen shows the last verified archive, history, current encrypted USB availability, scheduled-run warnings, and the last restore result.

## Create and review backups

- The automatic task runs daily at 01:30 local Windows time. `StartWhenAvailable` is disabled; a missed backup produces a warning and does not start a daytime catch-up or interrupt billing.
- Select **Create manual backup** for a planned maintenance copy. Wait for the success message and confirm the archive appears in history.
- An optional USB copy requires a connected removable drive labeled `KWD POS BACKUP`, fully encrypted and protected by BitLocker. The history records whether each copy passed SHA256 verification.
- Do not edit or delete files under `%ProgramData%\Koli Wada Dhaba POS\Backups` through Explorer or another application.

## Restore a backup

Restore replaces current restaurant records. Use it only on a disposable acceptance copy until Windows acceptance has passed.

1. Select **Restore** beside the chosen protected archive.
2. Review the archive date and replacement notice.
3. Check the acknowledgment and type `RESTORE`.
4. Confirm the Owner restore action. POS API access pauses while the broker validates and restores.
5. Wait for the success or failure status, then verify the expected bills, users, reports, and settings.

Before changing the database, the SYSTEM broker validates the archive and makes a separate verified pre-restore backup. It rechecks the destination identity, restores the archive, reapplies application permissions, and checks that the application role can read business data. A failed post-restore validation triggers an attempted restore and validation of the pre-restore copy. Keep both archives and local logs if the operation reports failure; do not retry against the development PostgreSQL service.
