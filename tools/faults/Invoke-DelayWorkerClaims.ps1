[CmdletBinding()]
param(
    [string]$SubscriptionId = '',
    [string]$ResourceGroup = 'rg-zava-rehearsal-wus2',
    [string]$AdminVm = 'zava-cutover-admin',
    [string]$DatabaseAddress = '192.168.90.11'
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\ZavaFault.Common.ps1"

$sqlPath = Join-Path $PSScriptRoot 'sql\delay-worker-claims.sql'
$sql = [Convert]::ToBase64String([IO.File]::ReadAllBytes($sqlPath))
$runnerScript = @'
#!/usr/bin/env bash
set -euo pipefail
set -a
source /etc/shipment/db-heartbeat.env
set +a
/opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P "$SA_PASSWORD" -C -b \
  -i /var/tmp/zava-worker-claims.sql
state=$(/opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P "$SA_PASSWORD" -C -b -h -1 -W \
  -d shipping -Q "SET NOCOUNT ON; SELECT CONCAT(
      'quoted_identifier=', uses_quoted_identifier,
      ' ansi_nulls=', uses_ansi_nulls,
      ' delay_active=', CASE WHEN OBJECT_DEFINITION(object_id) LIKE '%WAITFOR DELAY ''00:00:07''%' THEN 1 ELSE 0 END
    ) FROM sys.sql_modules WHERE object_id = OBJECT_ID('dbo.usp_claim_scan');" |
  tr -d '\r' | sed '/^[[:space:]]*$/d' | tail -n 1)
printf '%s\n' "$state"
test "$state" = 'quoted_identifier=1 ansi_nulls=1 delay_active=1'
'@
$runner = [Convert]::ToBase64String(
    [Text.Encoding]::UTF8.GetBytes($runnerScript.Replace("`r`n", "`n"))
)

$script = @'
set -euo pipefail
key=/home/estate/.ssh/zava_cutover_mgmt
scp_options="-i $key -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10"
ssh_options="-n -i $key -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10"
stage=$(mktemp -d /var/tmp/zava-claim-delay.XXXXXX)
trap 'rm -rf "$stage"' EXIT
chown estate:estate "$stage"
printf '%s' '__SQL_PAYLOAD__' | base64 -d > "$stage/zava-worker-claims.sql"
printf '%s' '__RUNNER_PAYLOAD__' | base64 -d > "$stage/run-zava-worker-claims.sh"
chmod 0700 "$stage/run-zava-worker-claims.sh"
chown estate:estate "$stage/zava-worker-claims.sql" "$stage/run-zava-worker-claims.sh"
sudo -u estate scp $scp_options "$stage/zava-worker-claims.sql" estate@__DATABASE_ADDRESS__:/var/tmp/zava-worker-claims.sql
sudo -u estate scp $scp_options "$stage/run-zava-worker-claims.sh" estate@__DATABASE_ADDRESS__:/var/tmp/run-zava-worker-claims.sh
sudo -u estate ssh $ssh_options estate@__DATABASE_ADDRESS__ \
  'sudo bash /var/tmp/run-zava-worker-claims.sh && rm -f /var/tmp/zava-worker-claims.sql /var/tmp/run-zava-worker-claims.sh'
echo ZAVA_WORKER_CLAIM_DELAY_ACTIVE
'@
$script = $script.Replace('__SQL_PAYLOAD__', $sql).
    Replace('__RUNNER_PAYLOAD__', $runner).
    Replace('__DATABASE_ADDRESS__', $DatabaseAddress)

Invoke-ZavaAdminScript `
    -Script $script `
    -SuccessMarker 'ZAVA_WORKER_CLAIM_DELAY_ACTIVE' `
    -SubscriptionId $SubscriptionId `
    -ResourceGroup $ResourceGroup `
    -AdminVm $AdminVm
