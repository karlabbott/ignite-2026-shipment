[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$subscription = 'Visual Studio Enterprise Subscription'
$resourceGroup = 'rg-zava-rehearsal-wus2'
$adminVm = 'zava-cutover-admin'
$allVms = @(
    'rhel-db',
    'sles-api',
    'ubuntu-web',
    'ciq-rocky-worker',
    $adminVm
)

az account set --subscription $subscription
if ($LASTEXITCODE -ne 0) {
    throw "Unable to select Azure subscription '$subscription'."
}

& "$PSScriptRoot\Disable-ZavaPublicAccess.ps1"

function Test-VmExists {
    param([string]$Name)

    az vm show `
        --resource-group $resourceGroup `
        --name $Name `
        --output none `
        --only-show-errors 2>$null
    return $LASTEXITCODE -eq 0
}

function Test-VmRunning {
    param([string]$Name)

    $state = az vm show `
        --resource-group $resourceGroup `
        --name $Name `
        --show-details `
        --query powerState `
        --output tsv `
        --only-show-errors
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to inspect VM '$Name'."
    }
    return $state.Trim() -eq 'VM running'
}

$stopCommands = [Collections.Generic.List[string]]::new()
$requiredMarkers = [Collections.Generic.List[string]]::new()

if (Test-VmExists -Name 'azurelinux-worker') {
    $allVms = @('azurelinux-worker') + $allVms
    if (Test-VmRunning -Name 'azurelinux-worker') {
        $stopCommands.Add(@"
sudo -u estate ssh `$ssh_options estate@192.168.90.15 'pid=`$(systemctl show shipment-worker.service --property MainPID --value); if test "`$pid" -gt 1; then state=`$(ps -o stat= -p "`$pid" | tr -d " "); if [[ "`$state" = T* ]]; then sudo kill -CONT "`$pid"; fi; fi; sudo systemctl stop shipment-worker.service; test "`$(systemctl is-active shipment-worker.service || true)" = inactive; sudo sync; echo AZURELINUX_WORKER_STOPPED'
"@)
        $requiredMarkers.Add('AZURELINUX_WORKER_STOPPED')
    }
}

if (Test-VmRunning -Name 'ciq-rocky-worker') {
    $stopCommands.Add(@"
sudo -u estate ssh `$ssh_options estate@192.168.90.14 'pid=`$(systemctl show shipment-worker.service --property MainPID --value); if test "`$pid" -gt 1; then state=`$(ps -o stat= -p "`$pid" | tr -d " "); if [[ "`$state" = T* ]]; then sudo kill -CONT "`$pid"; fi; fi; sudo systemctl stop shipment-worker.service; test "`$(systemctl is-active shipment-worker.service || true)" = inactive; sudo sync; echo WORKER_STOPPED'
"@)
    $requiredMarkers.Add('WORKER_STOPPED')
}

if (Test-VmRunning -Name 'ubuntu-web') {
    $stopCommands.Add(@"
sudo -u estate ssh `$ssh_options estate@192.168.90.13 'sudo systemctl stop nginx; sudo systemctl stop shipment-web.service; test "`$(systemctl is-active nginx || true)" = inactive; test "`$(systemctl is-active shipment-web.service || true)" = inactive; sudo sync; echo WEB_STOPPED'
"@)
    $requiredMarkers.Add('WEB_STOPPED')
}

if (Test-VmRunning -Name 'sles-api') {
    $stopCommands.Add(@"
sudo -u estate ssh `$ssh_options estate@192.168.90.12 'sudo systemctl stop zava-loadgen-24.service >/dev/null 2>&1 || true; if pgrep -af "[l]oadgen.py"; then echo "A load generator is still running." >&2; exit 1; fi; sudo systemctl stop shipment-api.service; test "`$(systemctl is-active shipment-api.service || true)" = inactive; sudo sync; echo API_AND_LOADGEN_STOPPED'
"@)
    $requiredMarkers.Add('API_AND_LOADGEN_STOPPED')
}

if (Test-VmRunning -Name 'rhel-db') {
    $stopCommands.Add(@"
sudo -u estate ssh `$ssh_options estate@192.168.90.11 'sudo systemctl stop mssql-server.service; test "`$(systemctl is-active mssql-server.service || true)" = inactive; sudo sync; echo DB_STOPPED'
"@)
    $requiredMarkers.Add('DB_STOPPED')
}

if ($stopCommands.Count -gt 0) {
    if (-not (Test-VmRunning -Name $adminVm)) {
        az vm start `
            --resource-group $resourceGroup `
            --name $adminVm `
            --only-show-errors `
            --output none
        if ($LASTEXITCODE -ne 0) {
            throw "Unable to start private management VM '$adminVm'."
        }
    }

    $stopScript = @'
set -euo pipefail
key=/home/estate/.ssh/zava_cutover_mgmt
ssh_options="-n -i $key -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10"
test -f "$key"
'@ + "`n" + ($stopCommands -join "`n")
    $stopScript = $stopScript -replace "`r`n", "`n"

    $encodedStop = [Convert]::ToBase64String(
        [Text.Encoding]::UTF8.GetBytes($stopScript)
    )
    $result = az vm run-command invoke `
        --resource-group $resourceGroup `
        --name $adminVm `
        --command-id RunShellScript `
        --scripts "echo $encodedStop | base64 -d | bash" `
        --output json `
        --only-show-errors | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to execute the private shutdown workflow from '$adminVm'."
    }

    $message = ($result.value | ForEach-Object message) -join "`n"
    $missingMarkers = @(
        $requiredMarkers |
            Where-Object { $message -notmatch [regex]::Escape($_) }
    )
    if ($missingMarkers.Count -gt 0) {
        Write-Host $message
        throw "The Zava shutdown workflow did not produce: $($missingMarkers -join ', ')."
    }
    Write-Host $message
}

$ids = foreach ($name in $allVms) {
    $id = az vm show `
        --resource-group $resourceGroup `
        --name $name `
        --query id `
        --output tsv `
        --only-show-errors
    if ($LASTEXITCODE -ne 0 -or -not $id) {
        throw "Unable to resolve VM '$name' for deallocation."
    }
    $id
}

az vm deallocate --ids $ids --only-show-errors --output none
if ($LASTEXITCODE -ne 0) {
    throw 'One or more Zava VMs failed to deallocate.'
}

$states = foreach ($name in $allVms) {
    [pscustomobject]@{
        VM = $name
        State = (az vm show `
            --resource-group $resourceGroup `
            --name $name `
            --show-details `
            --query powerState `
            --output tsv `
            --only-show-errors).Trim()
    }
}

if ($states | Where-Object State -ne 'VM deallocated') {
    $states | Format-Table -AutoSize
    throw 'Not all Zava VMs reached the deallocated state.'
}

$states | Format-Table -AutoSize
Write-Host 'The Zava Azure estate is deallocated and public access is disabled.'
