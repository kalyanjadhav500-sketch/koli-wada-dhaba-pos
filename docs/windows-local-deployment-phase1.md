# ARCHIVED — historical Phase 1 PostgreSQL provisioning notes

> **Do not follow these instructions for the current POS release.** They describe an older 5432/EDB provisioning design and are retained only for development history. The approved production target is the packaged local PostgreSQL 17 service `KoliWadaDhabaPostgreSQL` on `127.0.0.1:5433`, provisioned by the current installer. Follow [Windows local deployment](windows-local-deployment.md) instead. Never run the legacy steps against `postgresql-x64-17` or the developer PostgreSQL data directory.

This phase prepares a dedicated PostgreSQL 17 cluster and its application database. It does not install or package PostgreSQL, install the Express API as a Windows service, or create the Electron installer. Do not run these steps against the developer database.

## PostgreSQL distribution decision

The PostgreSQL download page links to EDB's Windows installer. PostgreSQL's community page documents a graphical installation wizard, selection of an installation and data directory, PostgreSQL service creation, and command-line tools. The PostgreSQL project license permits redistribution of PostgreSQL software when its notices and license terms are retained. The EDB installer also contains separately named components such as pgAdmin and StackBuilder; this project does **not** redistribute the EDB installer or assume those components can be repackaged.

For the first client install, obtain the PostgreSQL 17 x64 installer only from the EDB link reached through the official PostgreSQL Windows download page. Verify its Authenticode signature and publisher before running it. Use its interactive wizard; the current EDB documentation does not establish a safe, secret-free unattended command line for this product configuration.

On a clean client laptop, select PostgreSQL Server and Command Line Tools only. Configure:

- Installation binaries: the EDB PostgreSQL 17 installation location.
- Data directory: `%ProgramData%\Koli Wada Dhaba POS\PostgreSQL17\data`.
- Service: the EDB-created PostgreSQL 17 Windows service, set to Automatic.
- Service identity: the dedicated `postgres` identity created by the EDB installer.
- Port: `5432`.
- Listener: localhost only.
- Administrator credential: unique, entered privately in the installer; do not put it in a command line, script, source file, or chat.

EDB's Windows instructions state that the installer password is used for both its PostgreSQL superuser and service account. If an account/service named `postgres` or a PostgreSQL 17 service already exists, stop and review the machine before proceeding. **Do not reuse, upgrade, reset, stop, or reconfigure an existing database cluster.** The provisioning script verifies the exact ProgramData data path before it changes the service startup type or starts it.

## Provision a new POS database

Run from an elevated PowerShell window in the project workspace after the clean EDB installation:

```powershell
.\scripts\provision-local-pos-database.ps1
```

The script fails closed unless all of these conditions hold:

- It is running on 64-bit Windows with elevation.
- The PostgreSQL 17 cluster is exactly at the Koli Wada Dhaba ProgramData data path.
- The detected service executable is PostgreSQL 17 and the service runs as `postgres`.
- The server reports the verified data directory, port 5432, and loopback-only listener addresses.
- The application role, database, and protected application secret file do not already exist.
- The checked-in menu still contains exactly 13 categories and 120 items.

It ensures the verified POS service is Automatic and running, prompts for the PostgreSQL administrator password without echoing it, creates a least-privilege `kwd_app` role and a new `koli_wada_dhaba` database, applies only the committed Prisma migrations, and runs the existing idempotent seed. It generates fresh application and JWT secrets, encrypts them with Windows DPAPI (LocalMachine), and places the encrypted file in `%ProgramData%\Koli Wada Dhaba POS\config\database-secrets.dpapi`; the directory and file ACLs grant access only to SYSTEM and Administrators until the API service identity is chosen in Phase 2.

The script refuses to continue when the target role or database already exists. It never drops a role, database, table, or record. If a failure happens after creation, leave the cluster and encrypted configuration in place for investigation; do not delete the cluster to retry.

The existing first-Owner endpoint requires a name, username, recovery email, and a password of at least 12 characters. It does not ship a default password. The installer will present this first-run setup only after the local API and desktop shell are integrated in later phases. The existing email reset path requires SMTP and is not an offline recovery solution; that limitation remains open for later design.

## Isolated test

Before any service integration or installer work, run:

```powershell
.\scripts\test-isolated-client-database.ps1
```

This creates a temporary PostgreSQL 17 cluster under the current user's temp directory, binds it to a random loopback port, applies migrations and seed, starts the existing API against that temporary database, creates and signs in a randomly generated test Owner, verifies the API health endpoint, and confirms that no bills or payments were created. It does not register a Windows service and does not connect to the developer database. The test shuts down and removes only the unique temporary directory it created; if PostgreSQL cannot be stopped, it retains that directory and reports its path.

## Explicitly out of scope until later approval

- Phase 2: production API configuration loading from the protected ProgramData secret, loopback request authentication, Windows service identity/registration, dependency ordering, recovery actions, and Electron health/readiness integration.
- Phase 3: customer installer, shortcuts, upgrades, uninstaller, backup scheduling, USB copy, retention, and recovery workflow.
- Any modification to existing developer PostgreSQL service/data or existing business records.
- Reuse of developer test bills, payments, users, or local backups on the client installation.

## Official references

- [PostgreSQL — Windows installers](https://www.postgresql.org/download/windows/)
- [EDB — Installing PostgreSQL on Windows](https://www.enterprisedb.com/docs/supported-open-source/postgresql/installing/windows/)
- [EDB — PostgreSQL 17 Windows downloads](https://www.enterprisedb.com/downloads/postgres-postgresql-downloads)
- [PostgreSQL License](https://www.postgresql.org/about/licence/)
