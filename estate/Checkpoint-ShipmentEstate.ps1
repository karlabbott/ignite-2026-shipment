<#
.SYNOPSIS
    Checkpoint, restore, or list snapshots for the whole Zava Logistics estate.

.DESCRIPTION
    Rehearsing the break/fix act means resetting four VMs to a known state over
    and over. This does all four at once.

    Take the clean baseline immediately after the unattended installs finish and
    again after the application is deployed and verified.

.EXAMPLE
    .\Checkpoint-ShipmentEstate.ps1 -Name baseline
    .\Checkpoint-ShipmentEstate.ps1 -Name app-deployed
    .\Checkpoint-ShipmentEstate.ps1 -Restore -Name app-deployed
    .\Checkpoint-ShipmentEstate.ps1 -List
#>
[CmdletBinding(SupportsShouldProcess = $true, DefaultParameterSetName = 'Take')]
param(
    [Parameter(ParameterSetName = 'Take', Mandatory = $true)]
    [Parameter(ParameterSetName = 'Restore', Mandatory = $true)]
    [string] $Name,

    [Parameter(ParameterSetName = 'Restore', Mandatory = $true)]
    [switch] $Restore,

    [Parameter(ParameterSetName = 'List', Mandatory = $true)]
    [switch] $List,

    [string[]] $VMs = @('rhel-db', 'sles-api', 'ubuntu-web', 'ciq-rocky-worker'),

    [switch] $StartAfterRestore
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Write-Step { param($m) Write-Host "==> $m" -ForegroundColor Cyan }
function Write-Ok   { param($m) Write-Host "  ok  $m" -ForegroundColor Green }

$present = foreach ($name in $VMs) {
    $vm = Get-VM -Name $name -ErrorAction SilentlyContinue
    if ($vm) { $vm } else { Write-Warning "VM not found: $name" }
}
if (-not $present) { throw 'None of the estate VMs exist.' }

switch ($PSCmdlet.ParameterSetName) {

    'List' {
        foreach ($vm in $present) {
            Write-Step $vm.Name
            $snaps = Get-VMSnapshot -VMName $vm.Name -ErrorAction SilentlyContinue
            if (-not $snaps) { Write-Host '      (none)' -ForegroundColor DarkGray; continue }
            $snaps | Sort-Object CreationTime |
                Format-Table @{n='Snapshot';e={$_.Name}},
                             @{n='Created';e={$_.CreationTime}},
                             @{n='Type';e={$_.SnapshotType}} -AutoSize | Out-Host
        }
    }

    'Take' {
        # Shut the estate down first so the checkpoints are crash-consistent in
        # the same way across all four -- a half-running SQL Server restores to
        # a state that needs recovery, which wastes rehearsal time.
        Write-Step "Stopping the estate before checkpointing '$Name'"
        foreach ($vm in $present) {
            if ($vm.State -ne 'Off' -and $PSCmdlet.ShouldProcess($vm.Name, 'Shut down')) {
                Stop-VM -Name $vm.Name -Force
                Write-Ok "stopped $($vm.Name)"
            }
        }

        Write-Step "Taking checkpoint '$Name'"
        foreach ($vm in $present) {
            $existing = Get-VMSnapshot -VMName $vm.Name -Name $Name -ErrorAction SilentlyContinue
            if ($existing -and $PSCmdlet.ShouldProcess("$($vm.Name)\$Name", 'Replace existing checkpoint')) {
                Remove-VMSnapshot -VMName $vm.Name -Name $Name -Confirm:$false
            }
            if ($PSCmdlet.ShouldProcess($vm.Name, "Checkpoint as '$Name'")) {
                Checkpoint-VM -Name $vm.Name -SnapshotName $Name
                Write-Ok "$($vm.Name) -> $Name"
            }
        }
        Write-Host "`nCheckpoint '$Name' taken for $($present.Count) VM(s)." -ForegroundColor Green
    }

    'Restore' {
        Write-Step "Restoring the estate to '$Name'"
        foreach ($vm in $present) {
            $snap = Get-VMSnapshot -VMName $vm.Name -Name $Name -ErrorAction SilentlyContinue
            if (-not $snap) { Write-Warning "No checkpoint '$Name' on $($vm.Name); skipping."; continue }
            if ($vm.State -ne 'Off' -and $PSCmdlet.ShouldProcess($vm.Name, 'Turn off')) {
                Stop-VM -Name $vm.Name -TurnOff -Force
            }
            if ($PSCmdlet.ShouldProcess($vm.Name, "Restore '$Name'")) {
                Restore-VMSnapshot -VMName $vm.Name -Name $Name -Confirm:$false
                Write-Ok "$($vm.Name) restored"
            }
        }

        if ($StartAfterRestore) {
            # Database first: the API and worker tiers come up healthier if
            # SQL Server is already accepting connections.
            Write-Step 'Starting the estate (database first)'
            foreach ($name in @('rhel-db', 'sles-api', 'ciq-rocky-worker', 'ubuntu-web')) {
                $vm = $present | Where-Object Name -eq $name
                if (-not $vm) { continue }
                if ($PSCmdlet.ShouldProcess($name, 'Start')) {
                    Start-VM -Name $name
                    Write-Ok "started $name"
                    if ($name -eq 'rhel-db') { Start-Sleep -Seconds 20 }
                }
            }
        }
        Write-Host "`nEstate restored to '$Name'." -ForegroundColor Green
    }
}
