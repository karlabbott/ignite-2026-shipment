[CmdletBinding()]
param(
    [string]$SubscriptionId = '',
    [string]$ResourceGroup = 'rg-zava-rehearsal-wus2',
    [string]$AdminVm = 'zava-cutover-admin',
    [string[]]$WorkerAddresses = @('192.168.90.14', '192.168.90.15')
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\ZavaFault.Common.ps1"
$workers = $WorkerAddresses -join ' '

$script = @'
set -euo pipefail
key=/home/estate/.ssh/zava_cutover_mgmt
ssh_options="-n -i $key -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10"
workers="__WORKER_ADDRESSES__"
for host in $workers; do
  sudo -u estate ssh $ssh_options estate@$host '
    sudo nft delete table inet zava_fault >/dev/null 2>&1 || true
    if sudo nft list table inet zava_fault >/dev/null 2>&1; then
      exit 1
    fi
    test "$(systemctl is-active shipment-worker.service)" = active
    echo "host=$(hostname) zava_fault=absent service=active"
  '
done
echo ZAVA_WORKER_SQL_DEGRADATION_REPAIRED
'@.Replace('__WORKER_ADDRESSES__', $workers)

Invoke-ZavaAdminScript `
    -Script $script `
    -SuccessMarker 'ZAVA_WORKER_SQL_DEGRADATION_REPAIRED' `
    -SubscriptionId $SubscriptionId `
    -ResourceGroup $ResourceGroup `
    -AdminVm $AdminVm
