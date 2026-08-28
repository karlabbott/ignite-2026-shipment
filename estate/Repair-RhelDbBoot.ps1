<#
.SYNOPSIS
Restores the RHEL installer and OEMDRV answer media on rhel-db.

.DESCRIPTION
Use this after rebuilding estate/out/rhel10-db-oemdrv.iso. It self-elevates,
so launch it with "Run with PowerShell" from File Explorer; no elevated
terminal copy/paste is needed.
#>
[CmdletBinding()]
param(
    [string] $InstallerIso = "$env:USERPROFILE\isos\rhel-10.2-x86_64-boot.iso",
    [string] $AnswerIso = (Join-Path $PSScriptRoot 'out\rhel10-db-oemdrv.iso')
)

$ErrorActionPreference = 'Stop'

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process PowerShell -Verb RunAs -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`""
    )
    exit
}

foreach ($path in $InstallerIso, $AnswerIso) {
    if (-not (Test-Path $path -PathType Leaf)) {
        throw "Required media not found: $path"
    }
}

if ((Get-VM -Name rhel-db -ErrorAction SilentlyContinue).State -ne 'Off') {
    Stop-VM -Name rhel-db -TurnOff -Force
}

$drives = @(Get-VMDvdDrive -VMName rhel-db)
$installerDrive = $drives | Where-Object {
    $_.ControllerNumber -eq 0 -and $_.ControllerLocation -eq 1
}
if (-not $installerDrive) {
    $installerDrive = Add-VMDvdDrive -VMName rhel-db -Path $InstallerIso
} else {
    Set-VMDvdDrive -VMName rhel-db -ControllerNumber 0 -ControllerLocation 1 -Path $InstallerIso
}

$answerDrive = @(Get-VMDvdDrive -VMName rhel-db | Where-Object {
    $_.Path -like '*rhel10-db-oemdrv.iso'
}) | Select-Object -First 1
if (-not $answerDrive) {
    Add-VMDvdDrive -VMName rhel-db -Path $AnswerIso | Out-Null
} else {
    Set-VMDvdDrive -VMName rhel-db -ControllerNumber $answerDrive.ControllerNumber `
        -ControllerLocation $answerDrive.ControllerLocation -Path $AnswerIso
}

$installerDrive = Get-VMDvdDrive -VMName rhel-db | Where-Object {
    $_.ControllerNumber -eq 0 -and $_.ControllerLocation -eq 1
}
Set-VMFirmware -VMName rhel-db -FirstBootDevice $installerDrive
Start-VM -Name rhel-db

Write-Host 'rhel-db is booting from the RHEL installer ISO with OEMDRV attached.' -ForegroundColor Green
