[CmdletBinding()]
param(
    [string]$SubscriptionId = '',
    [string]$ResourceGroup = 'rg-zava-rehearsal-wus2',
    [string]$AdminVm = 'zava-cutover-admin',
    [string[]]$WorkerAddresses = @('192.168.90.14', '192.168.90.15'),
    [string]$DatabaseAddress = '192.168.90.11'
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\ZavaFault.Common.ps1"

$rules = @"
table inet zava_fault {
  chain output {
    type filter hook output priority -10; policy accept;
    ip daddr $DatabaseAddress tcp dport 1433 numgen random mod 100 < 75 counter drop
  }
}
"@
$encodedRules = [Convert]::ToBase64String(
    [Text.Encoding]::UTF8.GetBytes($rules.Replace("`r`n", "`n"))
)
$workers = $WorkerAddresses -join ' '

$script = @'
set -euo pipefail
key=/home/estate/.ssh/zava_cutover_mgmt
ssh_options="-n -i $key -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10"
workers="__WORKER_ADDRESSES__"
for host in $workers; do
  sudo -u estate ssh $ssh_options estate@$host \
    'command -v nft >/dev/null; test "$(systemctl is-active shipment-worker.service)" = active'
done
for host in $workers; do
  sudo -u estate ssh $ssh_options estate@$host \
    'sudo nft delete table inet zava_fault >/dev/null 2>&1 || true; printf "%s" "__ENCODED_RULES__" | base64 -d | sudo nft -f -; sudo nft list table inet zava_fault'
done
echo ZAVA_WORKER_SQL_DEGRADATION_ACTIVE
'@
$script = $script.Replace('__WORKER_ADDRESSES__', $workers).
    Replace('__ENCODED_RULES__', $encodedRules)

Invoke-ZavaAdminScript `
    -Script $script `
    -SuccessMarker 'ZAVA_WORKER_SQL_DEGRADATION_ACTIVE' `
    -SubscriptionId $SubscriptionId `
    -ResourceGroup $ResourceGroup `
    -AdminVm $AdminVm
