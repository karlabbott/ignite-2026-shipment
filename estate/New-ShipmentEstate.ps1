<#
.SYNOPSIS
    Provision the four-VM Zava Logistics estate on Hyper-V.

.DESCRIPTION
    Creates an internal switch with NAT (so the VMs reach the internet for
    package installs while keeping fixed 192.168.90.0/24 addresses), then builds
    four Generation 2 VMs and attaches both the installer ISO and the matching
    unattended answer ISO to each.

    The script is idempotent: re-running it skips anything that already exists.
    Use -Force to destroy and rebuild.

    MUST be run from an ELEVATED PowerShell session.

.PARAMETER IsoPath
    Directory containing the four installer ISOs. Filenames are matched by
    pattern, so exact version numbers do not matter:
        RHEL 10        *rhel*10*.iso
        RLC+ 10        *rlc*10*.iso
        SLES 16        *SLE*16*.iso
        Ubuntu 26.04   *ubuntu*26.04*live-server*.iso

.PARAMETER AnswerPath
    Directory containing the answer ISOs built by estate/build-answer-isos.sh.

.EXAMPLE
    .\New-ShipmentEstate.ps1 -WhatIf

.EXAMPLE
    .\New-ShipmentEstate.ps1
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [string] $IsoPath    = 'C:\Lab\ISOs',
    [string] $AnswerPath = 'C:\Lab\AnswerMedia',
    [string] $VmPath     = 'C:\Hyper-V\Virtual Machines',
    [string] $VhdPath    = 'C:\Hyper-V\Virtual Hard Disks',
    [string] $SwitchName = 'ShipmentInternal',
    [string] $NatName    = 'ShipmentNAT',
    [string] $Subnet     = '192.168.90.0/24',
    [string] $Gateway    = '192.168.90.1',
    [switch] $Force
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Write-Step  { param($m) Write-Host "==> $m" -ForegroundColor Cyan }
function Write-Ok    { param($m) Write-Host "  ok  $m" -ForegroundColor Green }
function Write-Warn2 { param($m) Write-Host "  !   $m" -ForegroundColor Yellow }

# --------------------------------------------------------------- preflight ---
$identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'This script must be run from an elevated PowerShell session.'
}

if (-not (Get-Module -ListAvailable -Name Hyper-V)) {
    throw 'The Hyper-V PowerShell module is not available. Enable the Hyper-V feature first.'
}

# The estate definition. Memory is startup memory; all four use dynamic memory
# so 32 GB of host RAM comfortably carries the lab plus the host.
$Estate = @(
    [pscustomobject]@{
        Name       = 'rhel-db'
        Tier       = 'db'
        Ip         = '192.168.90.11'
        Cpu        = 4
        # SQL Server 2025 refuses setup if Hyper-V balloons the guest below
        # 2 GB, so keep a 4 GB floor and allow growth to 12 GB under load.
        MemoryGB   = 4
        MinMemGB   = 4
        MaxMemGB   = 12
        DiskGB     = 90
        Source     = 'iso'
        IsoPatterns = @('*rhel*10*.iso', '*RHEL*10*.iso')
        AnswerIso  = 'rhel10-db-oemdrv.iso'
        BootNote   = 'Zero touch. Anaconda auto-detects the OEMDRV volume.'
    }
    [pscustomobject]@{
        Name       = 'sles-api'
        Tier       = 'api'
        Ip         = '192.168.90.12'
        Cpu        = 2
        MemoryGB   = 2
        MinMemGB   = 2
        MaxMemGB   = 6
        DiskGB     = 60
        Source     = 'iso'
        IsoPatterns = @('*SLE*16*.iso', '*sles*16*.iso', '*SLE-16*.iso')
        AnswerIso  = 'sles16-api-profile.iso'
        BootNote   = 'Add boot arg: inst.auto=http://192.168.90.1:8099/sles16-api.json'
    }
    [pscustomobject]@{
        Name       = 'ubuntu-web'
        Tier       = 'web'
        Ip         = '192.168.90.13'
        Cpu        = 2
        MemoryGB   = 2
        MinMemGB   = 2
        MaxMemGB   = 6
        DiskGB     = 60
        Source     = 'iso'
        IsoPatterns = @('*ubuntu*26.04*live-server*.iso', '*ubuntu*26*live-server*.iso')
        AnswerIso  = 'ubuntu26-web-cidata.iso'
        BootNote   = 'Add boot arg: autoinstall'
    }
    [pscustomobject]@{
        Name       = 'rocky-worker'
        Tier       = 'worker'
        Ip         = '192.168.90.14'
        Cpu        = 2
        MemoryGB   = 2
        MinMemGB   = 2
        MaxMemGB   = 6
        DiskGB     = 60
        Source       = 'iso'
        IsoPatterns  = @('*rlc*10*.iso', '*RLC*10*.iso')
        AnswerIso    = 'rlc10-worker-oemdrv.iso'
        BootNote     = 'At GRUB, edit the normal Install entry and append inst.ks=hd:LABEL=OEMDRV:/ks.cfg.'
    }
)

Write-Step 'Locating installer ISOs'
$available = @(Get-ChildItem -Path $IsoPath -Filter '*.iso' -ErrorAction SilentlyContinue)

function Find-EstateFile {
    param($Candidates, [string[]] $Patterns)
    foreach ($pattern in $Patterns) {
        $hit = $Candidates |
               Where-Object { $_.Name -like $pattern } |
               Sort-Object Name -Descending |
               Select-Object -First 1
        if ($hit) { return $hit }
    }
    return $null
}

foreach ($vm in $Estate | Where-Object { $_.Source -eq 'iso' }) {
    # Try each candidate pattern in order and take the newest match. This copes
    # with vendor naming drift (point releases, 'latest' aliases, vendor prefixes)
    # without needing the script edited for every download.
    $found = Find-EstateFile -Candidates $available -Patterns $vm.IsoPatterns
    if (-not $found) {
        $tried = ($vm.IsoPatterns -join ', ')
        Write-Host "`nISOs present in ${IsoPath}:" -ForegroundColor Yellow
        $available | ForEach-Object { Write-Host "    $($_.Name)" -ForegroundColor Gray }
        throw "No installer ISO for $($vm.Name). Tried: $tried"
    }
    $vm | Add-Member -NotePropertyName IsoFile -NotePropertyValue $found.FullName -Force
    $sizeGB = [math]::Round($found.Length / 1GB, 2)
    Write-Ok "$($vm.Name.PadRight(13)) $($found.Name)  (${sizeGB} GB)"
}

if (-not $available) { throw "No ISO files found in $IsoPath" }

Write-Step 'Locating answer ISOs'
foreach ($vm in $Estate) {
    $answer = Join-Path $AnswerPath $vm.AnswerIso
    if (-not (Test-Path $answer)) {
        throw "Answer ISO not found: $answer`nRun: wsl -d Ubuntu -e bash estate/build-answer-isos.sh"
    }
    $vm | Add-Member -NotePropertyName AnswerFile -NotePropertyValue $answer -Force
    Write-Ok "$($vm.Name.PadRight(13)) $($vm.AnswerIso)"
}

# Capacity sanity check before anything is created.
$totalMem  = ($Estate | Measure-Object MemoryGB -Sum).Sum
$totalDisk = ($Estate | Measure-Object DiskGB   -Sum).Sum
$hostMem   = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB, 1)
Write-Step "Capacity: estate wants ${totalMem} GB startup RAM of ${hostMem} GB host; up to ${totalDisk} GB disk"
if ($totalMem -gt ($hostMem - 8)) {
    Write-Warn2 'Startup memory leaves under 8 GB for the host. Dynamic memory will absorb this, but do not run all four flat out.'
}

# ----------------------------------------------------------------- network ---
Write-Step "Network: internal switch '$SwitchName' with NAT to $Subnet"

$switch = Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue
if (-not $switch) {
    if ($PSCmdlet.ShouldProcess($SwitchName, 'Create internal VM switch')) {
        $switch = New-VMSwitch -Name $SwitchName -SwitchType Internal
        Write-Ok "created switch $SwitchName"
    }
} else {
    Write-Ok "switch $SwitchName already exists"
}

# The host end of the internal switch becomes the VMs' default gateway.
$adapter = Get-NetAdapter -Name "vEthernet ($SwitchName)" -ErrorAction SilentlyContinue
if ($adapter) {
    $existingIp = Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 `
                                   -ErrorAction SilentlyContinue |
                  Where-Object { $_.IPAddress -eq $Gateway }
    if (-not $existingIp) {
        if ($PSCmdlet.ShouldProcess($Gateway, 'Assign gateway address to host adapter')) {
            New-NetIPAddress -InterfaceIndex $adapter.ifIndex -IPAddress $Gateway `
                             -PrefixLength 24 | Out-Null
            Write-Ok "assigned $Gateway to vEthernet ($SwitchName)"
        }
    } else {
        Write-Ok "$Gateway already assigned"
    }
}

# NAT gives the VMs internet access for package installs while keeping the
# fixed lab addressing the answer files hard-code.
$nat = Get-NetNat -Name $NatName -ErrorAction SilentlyContinue
if (-not $nat) {
    $conflict = Get-NetNat -ErrorAction SilentlyContinue |
                Where-Object { $_.InternalIPInterfaceAddressPrefix -eq $Subnet }
    if ($conflict) {
        Write-Warn2 "An existing NAT ($($conflict.Name)) already owns $Subnet; reusing it."
    } elseif ($PSCmdlet.ShouldProcess($NatName, "Create NAT for $Subnet")) {
        New-NetNat -Name $NatName -InternalIPInterfaceAddressPrefix $Subnet | Out-Null
        Write-Ok "created NAT $NatName for $Subnet"
    }
} else {
    Write-Ok "NAT $NatName already exists"
}

# --------------------------------------------------------------------- VMs ---
foreach ($path in @($VmPath, $VhdPath)) {
    if (-not (Test-Path $path)) {
        New-Item -ItemType Directory -Path $path -Force | Out-Null
    }
}

foreach ($vm in $Estate) {
    Write-Step "VM $($vm.Name)  [$($vm.Tier) tier]  $($vm.Ip)"

    $existing = Get-VM -Name $vm.Name -ErrorAction SilentlyContinue
    if ($existing) {
        if (-not $Force) {
            Write-Warn2 "$($vm.Name) already exists. Use -Force to rebuild. Skipping."
            continue
        }
        if ($PSCmdlet.ShouldProcess($vm.Name, 'Remove existing VM and its disk')) {
            if ($existing.State -ne 'Off') { Stop-VM -Name $vm.Name -TurnOff -Force }
            $oldDisks = (Get-VMHardDiskDrive -VMName $vm.Name).Path
            Remove-VM -Name $vm.Name -Force
            foreach ($disk in $oldDisks) {
                if ($disk -and (Test-Path $disk)) { Remove-Item $disk -Force }
            }
            Write-Ok "removed previous $($vm.Name)"
        }
    }

    $vhd = Join-Path $VhdPath "$($vm.Name).vhdx"
    if (-not $PSCmdlet.ShouldProcess($vm.Name, 'Create VM')) { continue }

    if (Test-Path $vhd) { Remove-Item $vhd -Force }

    # Generation 2 so the VMs are UEFI, which matches how they will land in
    # Azure. Dynamic VHDX keeps 4 x 60-90 GB honest on a laptop SSD.
    New-VM -Name $vm.Name -Generation 2 -MemoryStartupBytes ($vm.MemoryGB * 1GB) `
           -NewVHDPath $vhd -NewVHDSizeBytes ($vm.DiskGB * 1GB) `
           -SwitchName $SwitchName -Path $VmPath | Out-Null

    Set-VM -Name $vm.Name -ProcessorCount $vm.Cpu -CheckpointType Production `
           -AutomaticCheckpointsEnabled $false `
           -AutomaticStartAction Nothing -AutomaticStopAction ShutDown

    Set-VMMemory -VMName $vm.Name -DynamicMemoryEnabled $true `
                 -MinimumBytes ($vm.MinMemGB * 1GB) `
                 -StartupBytes ($vm.MemoryGB * 1GB) `
                 -MaximumBytes ($vm.MaxMemGB * 1GB)

    # Linux needs the UEFI CA certificate, not the default Windows template.
    Set-VMFirmware -VMName $vm.Name -EnableSecureBoot On `
                   -SecureBootTemplate 'MicrosoftUEFICertificateAuthority'

    Add-VMDvdDrive -VMName $vm.Name -Path $vm.IsoFile
    Add-VMDvdDrive -VMName $vm.Name -Path $vm.AnswerFile

    # Boot from the installer DVD.
    $dvd = Get-VMDvdDrive -VMName $vm.Name |
           Where-Object Path -eq $vm.IsoFile |
           Select-Object -First 1
    Set-VMFirmware -VMName $vm.Name -FirstBootDevice $dvd

    # A COM port so serial console output is capturable from the host. The
    # guests that have serial console disabled will simply say nothing here,
    # which is the point.
    Set-VMComPort -VMName $vm.Name -Number 1 -Path "\\.\pipe\$($vm.Name)-console"

    # Integration services: keep guest services on so files can be pushed to a
    # VM whose networking is broken -- a genuinely useful rescue path.
    Enable-VMIntegrationService -VMName $vm.Name -Name 'Guest Service Interface'

    Write-Ok "created $($vm.Name): $($vm.Cpu) vCPU, $($vm.MemoryGB) GB, $($vm.DiskGB) GB"
    Write-Host "      $($vm.BootNote)" -ForegroundColor DarkGray
}

# ------------------------------------------------------------------ summary --
Write-Host ''
Write-Step 'Estate created. Next steps:'
Write-Host @"

  1. If installing SLES, start the answer server on this host first:
         .\estate\Start-AnswerServer.ps1

  2. Start each VM and connect to its console:
         Start-VM -Name rhel-db ; vmconnect.exe localhost rhel-db

     rhel-db      zero touch - Anaconda finds the OEMDRV answer ISO
     rocky-worker at the normal CIQ Install entry press 'e', append
                  'inst.ks=hd:LABEL=OEMDRV:/ks.cfg' to the linuxefi line
                  after the vendor's inst.ks arguments, then press Ctrl-X
     ubuntu-web   at the GRUB menu press 'e', append 'autoinstall' to the
                  linux line, then Ctrl-X
     sles-api     at the boot menu press 'e' and append
                  inst.auto=http://192.168.90.1:8099/sles16-api.json

  3. When all four have installed and rebooted, take the clean baseline:
         .\estate\Checkpoint-ShipmentEstate.ps1 -Name os-clean

  4. Deploy the application:
         wsl -d Ubuntu-24.04 -e bash estate/deploy.sh

  5. Verify:
         ./tools/smoke-test.sh

"@ -ForegroundColor Gray
