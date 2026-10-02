[CmdletBinding()]
param(
    [switch]$ConfirmReset,
    [switch]$PreserveCurrentDisks
)

$ErrorActionPreference = 'Stop'

if (-not $ConfirmReset) {
    throw 'Reset discards changes made since the September 23 baseline. Re-run with -ConfirmReset after deciding whether current disks should be preserved.'
}

& "$PSScriptRoot\Stop-ZavaAzureEstate.ps1"
& "$PSScriptRoot\Remove-ZavaAzureLinuxWorker.ps1" -ConfirmRemoval

$restoreParameters = @{
    ConfirmRestore = $true
}
if ($PreserveCurrentDisks) {
    $restoreParameters.PreserveCurrentDisks = $true
}

& "$PSScriptRoot\Restore-ZavaAzureBaseline.ps1" @restoreParameters

Write-Host 'The Zava estate is reset to the four-workload-VM baseline, deallocated, and ready for the staged rebuild.'
