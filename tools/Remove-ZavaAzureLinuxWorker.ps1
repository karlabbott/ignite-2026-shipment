[CmdletBinding()]
param(
    [string]$SubscriptionId = '1a0e0107-9711-458a-aed9-a21d2797109a',
    [string]$ResourceGroup = 'rg-zava-rehearsal-wus2',
    [string]$AdminVm = 'zava-cutover-admin',
    [string]$VmName = 'azurelinux-worker',
    [string]$WorkerAddress = '192.168.90.15',
    [switch]$ConfirmRemoval
)

$ErrorActionPreference = 'Stop'
if (-not $ConfirmRemoval) {
    throw "Removal affects only '$VmName'. Re-run with -ConfirmRemoval."
}

az account set --subscription $SubscriptionId
if ($LASTEXITCODE -ne 0) {
    throw "Unable to select Azure subscription '$SubscriptionId'."
}

$vm = az vm show `
    --subscription $SubscriptionId `
    --resource-group $ResourceGroup `
    --name $VmName `
    --only-show-errors `
    --output json 2>$null | ConvertFrom-Json
if (-not $vm) {
    Write-Host "Azure Linux worker '$VmName' is already absent."
    return
}

$nicIds = @($vm.networkProfile.networkInterfaces | ForEach-Object id)
$diskIds = @($vm.storageProfile.osDisk.managedDisk.id)

$stopCommand = @"
set -euo pipefail
key=/home/estate/.ssh/zava_cutover_mgmt
ssh_options="-n -i `$key -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10"
sudo -u estate ssh `$ssh_options estate@$WorkerAddress \
  'sudo systemctl stop shipment-worker.service; sudo sync' || true
sudo -u estate ssh-keygen -f /home/estate/.ssh/known_hosts -R '$WorkerAddress' >/dev/null 2>&1 || true
"@
az vm run-command invoke `
    --subscription $SubscriptionId `
    --resource-group $ResourceGroup `
    --name $AdminVm `
    --command-id RunShellScript `
    --scripts $stopCommand `
    --only-show-errors `
    --output none

az vm delete `
    --subscription $SubscriptionId `
    --resource-group $ResourceGroup `
    --name $VmName `
    --yes `
    --force-deletion true `
    --only-show-errors `
    --output none
if ($LASTEXITCODE -ne 0) {
    throw "Failed to delete Azure Linux worker '$VmName'."
}

foreach ($id in $nicIds) {
    az network nic show --ids $id --only-show-errors --output none 2>$null
    if ($LASTEXITCODE -eq 0) {
        az network nic delete --ids $id --only-show-errors
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to delete worker NIC '$id'."
        }
    }
}
foreach ($id in $diskIds) {
    az disk show --ids $id --only-show-errors --output none 2>$null
    if ($LASTEXITCODE -eq 0) {
        az disk delete --ids $id --yes --only-show-errors --output none
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to delete worker OS disk '$id'."
        }
    }
}

Write-Host "Removed only Azure Linux worker '$VmName'; Rocky and the migrated tiers were not changed."
