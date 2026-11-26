# Deprecated development bootstrapper.
#
# This script previously modified the machine-wide PostgreSQL 17 service,
# including its service state, administrator password, and pg_hba.conf.
# That behaviour is not permitted for the Koli Wada Dhaba POS project.
#
# Production POS provisioning is performed only by:
#   scripts/windows/Install-LocalPos.ps1
#
# Development database provisioning should use the isolated Docker workflow
# documented in README.md. Disposable PostgreSQL integration tests should use
# scripts/test-isolated-client-database.ps1.
#
# This guard intentionally performs no service, filesystem, process, network,
# or database operations. It is safe if an old npm script invokes it.

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

throw @"
The legacy PostgreSQL bootstrap script is disabled for safety.

It must not configure, start, stop, restart, unregister, or modify any
machine-wide PostgreSQL service or database.

For production POS installation, use the packaged Windows installer, which
provisions the dedicated KoliWadaDhabaPostgreSQL service on port 5433.

For local development, use the Docker Compose database workflow.
For integration testing, use the disposable-cluster test script.

No PostgreSQL service or database was accessed or changed by this script.
"@
