# Legacy development provisioning entry point - intentionally disabled.
#
# This script previously used the Windows service `postgresql-x64-17` and
# port 5432. That service and its data directory are reserved for development
# and must never be modified by the Koli Wada Dhaba POS production installer.
#
# Production provisioning is performed only by the packaged Windows installer
# through `scripts/windows/Install-LocalPos.ps1`, which provisions the separate
# `KoliWadaDhabaPostgreSQL` service on 127.0.0.1:5433.
#
# Keep this file as a fail-closed compatibility stub so older commands,
# shortcuts, or documentation cannot accidentally provision against the
# developer PostgreSQL instance.

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$message = @'
The legacy local POS database provisioning script is disabled for safety.

It previously referenced the development PostgreSQL service `postgresql-x64-17`
and port 5432. This script will not inspect, start, stop, restart, reconfigure,
change passwords, modify permissions, or connect to any PostgreSQL service.

For a production installation, use the Koli Wada Dhaba POS Windows NSIS
installer. Its dedicated PostgreSQL service is `KoliWadaDhabaPostgreSQL`,
listening only on 127.0.0.1:5433 with its data under:
%ProgramData%\Koli Wada Dhaba POS\Data

No database or Windows service has been changed by this script.
'@

Write-Error -Message $message -ErrorAction Continue
exit 1
