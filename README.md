# Koli Wada Dhaba

Restaurant billing and management workspace for **KOLI WADA DHABA — Family Seafood Restaurant**.

## Current development milestone

The workspace now contains a React/TypeScript restaurant POS, an Express API protected by first-owner setup and role-based authentication, a PostgreSQL/Prisma schema and migrations, 70 seeded tables, the transcribed restaurant menu, bill/order/payments APIs, owner settings and user management, daily reports, and printable receipt/report layouts.

The existing local PostgreSQL database currently contains the restaurant menu/tables, one Owner account, three bills (one paid and two open), and one payment. The records cannot be reliably classified as demo versus real from their current fields, so treat them as business data and preserve them. No cloud migration or deployment has been performed.

## Requirements

- Node.js LTS and npm
- Either PostgreSQL 15+ for Windows, or Docker Desktop for Windows with its Linux-container engine started
- VS Code extensions: ESLint, Prettier, Prisma, and Tailwind CSS IntelliSense

On this Windows setup, restart VS Code after installing Node.js so new terminals see it. In PowerShell, use `npm.cmd` (for example, `npm.cmd install`) because the `npm.ps1` wrapper may be blocked by the local execution policy.

## Local setup

1. From the project root, install dependencies: `npm.cmd install`.
2. Create `.env` and a separate local PostgreSQL administrator-password file with fresh random secrets: `npm.cmd run env:init`. This command will not overwrite an existing `.env`. **Never commit or share `.env` or `.pgadmin-password`.**
3. Generate the Prisma client: `npm.cmd run db:generate`.
4. Choose one local database:
   - Docker: start Docker Desktop's **Linux** engine, then run `npm.cmd run db:up`. Changing engines stops the active Windows containers.
   - Windows service: install PostgreSQL 17, then run `npm.cmd run db:bootstrap` to create the limited POS database account and database. This step requests Administrator approval, uses only loopback connections, and keeps the database-admin secret outside the API's `.env`.
5. Apply the committed PostgreSQL migrations: `npm.cmd run db:deploy`.
6. Add the 70 restaurant tables and all menu cards: `npm.cmd run db:seed`.
7. Start the API and dashboard: `npm.cmd run dev`.
8. Open `http://localhost:5173`. Create the first Owner account on the initial setup screen; then add cashier accounts in **Settings**.

The development API binds to `127.0.0.1` by default, and the PostgreSQL port is loopback-only. Production clients use the HTTPS API URL supplied through `VITE_API_URL` when packaging; web users hosted by the API use a same-origin relative URL. Never expose PostgreSQL itself to the internet.

## Workspace

- `apps/web`: responsive React/Vite dashboard
- `apps/api`: Express API, Prisma schema, and database seed
- `apps/api/prisma/migrations/`: committed database migrations
- `apps/shared/menu.json`: source transcription shared by the menu manager and the database seed
- `compose.yaml`: loopback-only development PostgreSQL container
- `.env.example`: local development and client-build environment template
- `apps/api/.env.example`: cloud API runtime settings template (no secrets)
- `render.yaml`: Render web-service blueprint; it has not been deployed

Owner users can manage item names, categories, prices, and availability. Pricing for the 6 “As Per Size” items and 4 items shown with a dash stays unset until an authorised user enters the actual price. Running the seed again adds missing records and adds original manual-price notes without overwriting price changes or disabled menu items.

Tables use live database status: green indicates an available table and red/orange indicates an occupied table with an open bill. Counts and labels update from the API every 15 seconds.

If the Owner password is forgotten, double-click `Reset-Owner-Password.cmd` from the trusted project folder. Enter and confirm a new 12–128-character password at the hidden prompt; it is not shown on screen or saved to a file. The script resets the single active Owner account without changing its username or restaurant data.

Owner email recovery uses free Gmail SMTP (no paid AI/email service). Add an Owner recovery email during first setup. For an existing Owner, assign the recovery email through the trusted local database before enabling recovery. Turn on Google 2-Step Verification, create a Gmail App Password at [Google App Passwords](https://myaccount.google.com/apppasswords), then double-click `Configure-Gmail-Recovery.cmd`; the app password is entered privately, SMTP connectivity is verified, and the secret is saved only in the ignored local `.env`. Then double-click `Restart-POS-API.cmd`. The sign-in screen can request an 8-digit code sent to the registered Owner email; codes expire after 15 minutes and are single-use.

The sign-in screen's **Change server address** option allows an installed client to change its HTTPS API address without rebuilding. Production installers reject temporary `trycloudflare.com` URLs.

## Current operations and deployment limits

- Bills are per table; the database enforces at most one open bill per table. Item prices and names are snapshotted onto each bill.
- Only a cashier's explicit confirmation after checking the merchant app/terminal records UPI/card payment. A generated UPI QR code does **not** verify payment.
- Reports can be printed or saved to PDF through the installed system print dialog; CSV export is also available.
- Receipt formatting targets 58 mm or 80 mm rolls and can print through the desktop OS printer dialog. Test paper width, cutter, and the actual printer before service; Bluetooth/USB Android printer-driver support has not been hardware-certified.
- The Electron shell uses a custom secure protocol and the Android app uses HTTPS with cleartext traffic disabled. Windows NSIS and Android debug outputs exist, but no production backend connection, signed Android release, physical-device acceptance test, or printer hardware certification has been completed.
- API authentication hashes passwords with bcrypt; JWTs expire after eight hours. The client keeps its token in `sessionStorage`, which is not Android hardware-backed secure storage. Assess a Capacitor secure-storage solution before a public production rollout.
- Use `npm.cmd run backup:postgres` before any database migration or upgrade. It creates a non-overwriting custom-format dump and validates the archive with `pg_restore --list`. Store it on an encrypted, access-restricted drive; archive validation is not a substitute for a restore rehearsal.

## Prepared Render + Neon deployment (not deployed)

The intended production path is a paid, always-on Render Node web service plus a Neon PostgreSQL database. The Render service serves both the web dashboard and API from one stable provider HTTPS subdomain. The API connects to Neon using `DATABASE_URL`; Prisma migration commands use `DIRECT_URL`. Both database URLs must use TLS (`sslmode=require`). Render's blueprint sets a single trusted proxy hop, a database-backed health check, and a small connection pool. No account has been created, no source has been uploaded, and no service or database has been deployed.

### Before deployment

1. Review the local database inventory and make a validated backup: `npm.cmd run backup:postgres`. The current data includes two open bills; do not seed, reset, or restore over a non-empty destination.
2. Create a Neon project/database only after approving its current paid plan and usage billing. Keep Neon secrets private. Use the pooled connection string for the API `DATABASE_URL`, and the direct connection string for migration/restore `DIRECT_URL`; include `sslmode=require` in both. Put the direct URL in the ignored local `.env`, not in source control or chat.
3. Before creating the Render service, finish the Neon restore steps below and verify the restored data. Render's health check will remain unhealthy until the database contains the restored schema.
4. Use the Render dashboard to deploy the reviewed source from a private Git provider repository only after explicitly approving that source upload and the paid service. `render.yaml` selects the `starter` plan, Singapore region, and `/api/health`. Add `DATABASE_URL` and `DIRECT_URL` as secret environment values; the blueprint generates a separate `JWT_SECRET`. Do not add a `VITE_API_URL` to the server build; its browser dashboard uses the same origin.
5. Wait for the Render service's stable `https://<service>.onrender.com` address, then confirm `https://<service>.onrender.com/api/health` reports `"database":"connected"`.

### Preserve local data when initializing Neon

Restore the validated custom-format backup into a **new, empty** Neon database using the direct URL. Do not run `prisma migrate deploy` first: the dump already contains the existing schema, migration history, menu, users, bills, payments, and audit records. Set `DIRECT_URL` privately in the ignored local `.env`, then run `powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts\restore-postgres.ps1 -BackupPath 'backups\postgres\<backup-file>.dump'`. The script validates the archive, refuses a non-empty destination, and requires the exact confirmation `RESTORE INTO EMPTY NEON DATABASE`. It never uses `--clean`. Compare table/bill/payment counts with the pre-migration inventory, then test the API health check and application workflows. Keep the original local database and backup unchanged until the restore and acceptance tests pass. For later schema changes, back up again, then run `npm.cmd run db:deploy` with `DIRECT_URL` pointing to Neon.

### Package Windows and Android clients after the stable URL exists

1. Set `VITE_API_URL=https://<service>.onrender.com` in the local ignored `.env`. Never use a Quick Tunnel, localhost, or a secret in this setting.
2. Build the Windows installer with `npm.cmd run desktop:installer`. The desktop version is now 0.1.2 so it will not overwrite the existing 0.1.0 or 0.1.1 installers.
3. Android version is 1.2 / versionCode 3. Generate an unsigned release build with `npm.cmd run android:sync` followed by `apps\web\android\gradlew.bat -p apps\web\android assembleRelease`. A production Android release still needs a private signing key and a physical-device installation/test.

Render and Neon prices are variable and can change. Review the current plan, compute/storage usage, backup/restore features, taxes, and billing limits in each provider dashboard before authorizing any purchase. A paid always-on API and a managed database are separate costs.

## Windows and Android packages

The project includes the Windows Electron shell and Android Capacitor configuration. Installing a client alone does not provide a restaurant server; both clients must point to the same HTTPS API and central database.

- `npm.cmd run desktop:installer` builds a Windows NSIS installer under `release/windows/`.
- `npm.cmd run android:sync` builds the web app and synchronizes the Android project.
- `npm.cmd run android:debug` builds a debug APK under `apps/web/android/app/build/outputs/apk/debug/`. Android Studio, a JDK, and the Android SDK must be installed and configured. Play Store publishing/signing is a separate release task.

Installer commands reject missing, local, temporary-tunnel, or non-HTTPS production API URLs, because `localhost` on a phone/second computer is not the restaurant server and plain HTTP can expose staff credentials.
