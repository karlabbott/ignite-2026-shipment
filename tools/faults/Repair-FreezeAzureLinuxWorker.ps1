[CmdletBinding()]
param(
    [string]$SubscriptionId = '',
    [string]$ResourceGroup = 'rg-zava-rehearsal-wus2',
    [string]$AdminVm = 'zava-cutover-admin',
    [string]$WorkerAddress = '192.168.90.15'
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\ZavaFault.Common.ps1"

$script = @'
set -euo pipefail
key=/home/estate/.ssh/zava_cutover_mgmt
ssh_options="-n -i $key -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10"
sudo -u estate ssh $ssh_options estate@__WORKER_ADDRESS__ '
  set -euo pipefail
  pid=$(systemctl show shipment-worker.service --property MainPID --value)
  test "$pid" -gt 1
  state=$(ps -o stat= -p "$pid" | tr -d " ")
  if [[ "$state" = T* ]]; then
    sudo kill -CONT "$pid"
  fi
  sleep 2
  test "$(systemctl is-active shipment-worker.service)" = active
  state=$(ps -o stat= -p "$pid" | tr -d " ")
  [[ "$state" != T* ]]
  printf "service=active pid=%s process_state=%s\n" "$pid" "$state"
'
echo ZAVA_FREEZE_AZURELINUX_REPAIRED
'@.Replace('__WORKER_ADDRESS__', $WorkerAddress)

Invoke-ZavaAdminScript `
    -Script $script `
    -SuccessMarker 'ZAVA_FREEZE_AZURELINUX_REPAIRED' `
    -SubscriptionId $SubscriptionId `
    -ResourceGroup $ResourceGroup `
    -AdminVm $AdminVm
