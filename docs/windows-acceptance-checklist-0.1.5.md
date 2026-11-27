# Windows acceptance checklist — 0.1.5

Use this checklist only in a disposable Windows VM. Do not install the candidate on a development machine or a laptop containing restaurant data. The VM must have no access to the developer PostgreSQL service (`postgresql-x64-17`, port 5432) and must not use another machine's POS service (port 5433).

## Test record

- VM image and Windows edition/build: **Pending**
- VM snapshot name and date: **Pending**
- Candidate Setup.exe version and SHA256: **Pending**
- Test operator and date: **Pending**
- Receipt printer model, driver, paper width: **Pending**

Do not mark a case passed until its expected result is observed and recorded. Attach screenshots or logs from the VM for failures. Keep a pre-test VM snapshot so each installation sequence can be repeated.

## Fresh install and first launch

- [ ] Install the candidate to `C:\Program Files\Koli Wada Dhaba POS`.
- [ ] Confirm setup creates only `KoliWadaDhabaPostgreSQL`, using the packaged PostgreSQL 17 binaries, `%ProgramData%\Koli Wada Dhaba POS\Data`, and loopback port 5433.
- [ ] Confirm setup stops if any service identity, database path, port, or PostgreSQL version does not match the POS instance.
- [ ] Confirm the backup folder DACL grants write access only to SYSTEM and Administrators; verify cashier/standard-user write and delete attempts fail.
- [ ] Confirm the broker and daily backup tasks run as SYSTEM, use only their packaged scripts, and have the protected task DACL.
- [ ] Confirm the broker pipe DACL grants SYSTEM full control and interactive users only the required client access.
- [ ] Confirm the Electron process runs as the signed-in standard user, not Administrator.
- [ ] Launch POS, create the first Owner account, save the one-time recovery key, and sign in.
- [ ] Confirm 70 tables, 13 categories, and 120 menu items are present.
- [ ] Add a Cashier and confirm the Owner-only Backup & Restore navigation is absent for that account.

## Billing, printer, and restart

- [ ] Create a new bill and an existing-table bill; verify Full/Half prices, Other Item, quantity edits, and item removal.
- [ ] Settle sample bills with Cash, UPI, and Card, including the UPI/Card confirmation controls and cash change.
- [ ] Confirm paid bill history, reprint, daily report, and payment-method totals.
- [ ] Save a preferred printer and verify receipt routing at 58 mm and 80 mm, test print, history reprint, and report print where applicable.
- [ ] Remove or disconnect the saved printer and confirm Windows opens its selection dialog without silently retrying a job.
- [ ] Test paper clipping, feed, and cutter on the actual receipt printer; record device model, driver, and results.
- [ ] Restart Windows; confirm the database, bills, settings, preferred printer, and bill history remain available.

## Upgrade and data preservation

- [ ] From a VM snapshot, install the preserved 0.1.4 Setup.exe and create Owner/Cashier accounts, settings, and identifiable paid bills.
- [ ] Record the database and backup identities, then upgrade using the candidate 0.1.5 Setup.exe.
- [ ] Confirm the installer creates a verified pre-migration archive and does not initialize a new database or reseed over existing data.
- [ ] Confirm accounts, settings, table data, bills, payments, and reports survive the upgrade.
- [ ] Confirm the daily backup task is set to 01:30 local time, daily, with `StartWhenAvailable` disabled.

## Backup and restore

- [ ] From the Owner screen, create a manual backup and confirm the archive appears in history with time, size, and SHA256.
- [ ] Confirm a connected, correctly labeled, fully encrypted USB drive is detected and the copied archive passes SHA256; disconnect it and confirm status refreshes to unavailable.
- [ ] Leave the VM stopped across the 01:30 trigger, then start it after 01:30. Confirm `StartWhenAvailable` did not cause a catch-up backup, a missed-run warning appears, and billing remains usable.
- [ ] Create a fresh backup, make a separately identifiable bill, then restore the earlier backup as Owner.
- [ ] Confirm the restore dialog requires the data-replacement acknowledgment and typed `RESTORE`; cancel once and verify no data changed.
- [ ] Confirm restore creates and verifies a separate pre-restore archive, pauses the local API, restores the selected records, reapplies `kwd_app` permissions, verifies business data, and restarts the API.
- [ ] Confirm restore status reports success and both the selected and pre-restore archives remain available.
- [ ] With a disposable copy of an archive only, test a checksum/validation failure. Confirm restore is rejected before data changes.
- [ ] If a post-restore validation failure can be safely induced in the VM, confirm the verified pre-restore archive is restored and status reports rollback; capture the result.

## Uninstall and reinstallation

- [ ] Uninstall from Windows Apps & features. Confirm only POS-owned tasks and service are removed.
- [ ] Confirm `%ProgramData%\Koli Wada Dhaba POS` and its business data, configuration, logs, and archives remain.
- [ ] Reinstall the candidate and confirm the existing database is recognized and preserved without reseeding over business data.
- [ ] Sign in and verify sample bills, users, settings, and reports remain.

## Result summary

| Case | Result | Evidence / notes |
| --- | --- | --- |
| Fresh install and first launch | Pending | |
| Billing and business-data regression | Pending | |
| Printer hardware acceptance | Pending | |
| Windows restart | Pending | |
| 0.1.4 to 0.1.5 upgrade and preservation | Pending | |
| 01:30 schedule and missed-run warning | Pending | |
| Manual backup and USB verification | Pending | |
| Owner-authorized restore and rollback | Pending | |
| Uninstall and reinstall with ProgramData preserved | Pending | |

The 0.1.5 customer release remains blocked until every applicable row passes in the disposable VM and the actual receipt printer is tested.
