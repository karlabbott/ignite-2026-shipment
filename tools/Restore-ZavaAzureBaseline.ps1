[CmdletBinding()]
param(
    [switch]$ConfirmRestore,
    [switch]$PreserveCurrentDisks
)

$ErrorActionPreference = 'Stop'
$subscription = 'Visual Studio Enterprise Subscription'
$resourceGroup = 'rg-zava-rehearsal-wus2'
$baseline = @(
    @{ VM = 'rhel-db'; Snapshot = 'baseline-20260923-rhel-db-os' },
    @{ VM = 'sles-api'; Snapshot = 'baseline-20260923-sles-api-os' },
    @{ VM = 'ubuntu-web'; Snapshot = 'baseline-20260923-ubuntu-web-os' },
    @{ VM = 'ciq-rocky-worker'; Snapshot = 'baseline-20260923-ciq-rocky-worker-os' }
)

if (-not $ConfirmRestore) {
    throw 'Baseline restore replaces the four attached OS disks. Re-run with -ConfirmRestore after reviewing the snapshot mapping.'
}

az account set --subscription $subscription
if ($LASTEXITCODE -ne 0) {
    throw "Unable to select Azure subscription '$subscription'."
}

& "$PSScriptRoot\Disable-ZavaPublicAccess.ps1"

foreach ($item in $baseline) {
    $state = (az vm show `
        --resource-group $resourceGroup `
        --name $item.VM `
        --show-details `
        --query powerState `
        --output tsv `
        --only-show-errors).Trim()
    if ($state -ne 'VM deallocated') {
        throw "VM '$($item.VM)' must be deallocated before baseline restore; current state is '$state'."
    }

    $snapshot = az snapshot show `
        --resource-group $resourceGroup `
        --name $item.Snapshot `
        --output json `
        --only-show-errors | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0 -or $snapshot.provisioningState -ne 'Succeeded') {
        throw "Snapshot '$($item.Snapshot)' is not ready."
    }
}

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$results = foreach ($item in $baseline) {
    $snapshotId = (az snapshot show `
        --resource-group $resourceGroup `
        --name $item.Snapshot `
        --query id `
        --output tsv `
        --only-show-errors).Trim()
    $currentDisk = (az vm show `
        --resource-group $resourceGroup `
        --name $item.VM `
        --query storageProfile.osDisk.managedDisk.id `
        --output tsv `
        --only-show-errors).Trim()
    $currentDiskName = $currentDisk.Split('/')[-1]
    $restoredDiskName = "$($item.VM)-OSdisk-baseline-$stamp"

    az disk create `
        --resource-group $resourceGroup `
        --name $restoredDiskName `
        --source $snapshotId `
        --sku Standard_LRS `
        --tags "RestoredFrom=$($item.Snapshot)" "PreviousDisk=$currentDiskName" `
        --only-show-errors `
        --output none
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to create restored disk for '$($item.VM)'."
    }

    az vm update `
        --resource-group $resourceGroup `
        --name $item.VM `
        --os-disk $restoredDiskName `
        --only-show-errors `
        --output none
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to attach restored disk to '$($item.VM)'."
    }

    [pscustomobject]@{
        VM = $item.VM
        Snapshot = $item.Snapshot
        RestoredDisk = $restoredDiskName
        PreservedPreviousDisk = $currentDiskName
    }
}

$results | Format-Table -AutoSize

if ($PreserveCurrentDisks) {
    Write-Host 'Baseline disks are attached. Previous disks were preserved by request.'
}
else {
    foreach ($result in $results) {
        az disk delete `
            --resource-group $resourceGroup `
            --name $result.PreservedPreviousDisk `
            --yes `
            --only-show-errors
        if ($LASTEXITCODE -ne 0) {
            throw "Baseline restore succeeded, but discarded disk '$($result.PreservedPreviousDisk)' could not be deleted."
        }
    }
    Write-Host 'Baseline disks are attached and the discarded development disks were deleted.'
}

Write-Host 'The estate remains deallocated. Run Start-ZavaAzureEstate.ps1 when the next work session begins.'
