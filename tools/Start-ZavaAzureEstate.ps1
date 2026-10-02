[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$subscription = 'Visual Studio Enterprise Subscription'
$resourceGroup = 'rg-zava-rehearsal-wus2'
$adminVm = 'zava-cutover-admin'
$allVms = @(
    $adminVm,
    'rhel-db',
    'sles-api',
    'ubuntu-web',
    'ciq-rocky-worker'
)

az account set --subscription $subscription
if ($LASTEXITCODE -ne 0) {
    throw "Unable to select Azure subscription '$subscription'."
}

az vm show `
    --resource-group $resourceGroup `
    --name 'azurelinux-worker' `
    --output none `
    --only-show-errors 2>$null
$azureLinuxPresent = $LASTEXITCODE -eq 0
if ($azureLinuxPresent) {
    $allVms += 'azurelinux-worker'
}

$ids = foreach ($name in $allVms) {
    az vm show `
        --resource-group $resourceGroup `
        --name $name `
        --query id `
        --output tsv `
        --only-show-errors
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to resolve VM '$name'."
    }
}

az vm start --ids $ids --only-show-errors --output none
if ($LASTEXITCODE -ne 0) {
    throw 'One or more Zava VMs failed to start.'
}

$startupScript = @'
set -euo pipefail
key=/home/estate/.ssh/zava_cutover_mgmt
ssh_options="-n -i $key -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10"

if [ ! -f "$key" ]; then
    echo "Missing admin SSH key: $key" >&2
    exit 1
fi

sudo -u estate ssh $ssh_options estate@192.168.90.11 \
    'sudo systemctl start mssql-server.service; test "$(systemctl is-active mssql-server.service)" = active; sudo ss -ltn | grep -q ":1433 "; echo DB_ACTIVE'

sudo -u estate ssh $ssh_options estate@192.168.90.12 \
    'sudo systemctl start shipment-api.service; test "$(systemctl is-active shipment-api.service)" = active; echo API_ACTIVE'

sudo -u estate ssh $ssh_options estate@192.168.90.13 \
    'sudo systemctl start shipment-web.service; sudo systemctl start nginx; test "$(systemctl is-active shipment-web.service)" = active; test "$(systemctl is-active nginx)" = active; echo WEB_ACTIVE'

sudo -u estate ssh $ssh_options estate@192.168.90.14 \
    'sudo systemctl start shipment-worker.service; test "$(systemctl is-active shipment-worker.service)" = active; echo WORKER_ACTIVE'
'@

$requiredMarkers = @(
    'DB_ACTIVE',
    'API_ACTIVE',
    'WEB_ACTIVE',
    'WORKER_ACTIVE'
)

if ($azureLinuxPresent) {
    $startupScript += @'

sudo -u estate ssh $ssh_options estate@192.168.90.15 \
    'sudo systemctl start shipment-worker.service; test "$(systemctl is-active shipment-worker.service)" = active; echo AZURELINUX_WORKER_ACTIVE'
'@
    $requiredMarkers += 'AZURELINUX_WORKER_ACTIVE'
}

$startupScript += @'

sudo -u estate ssh $ssh_options estate@192.168.90.13 '
    for i in $(seq 1 18); do
        if estate=$(curl -fsS --max-time 10 http://127.0.0.1:8000/api/estate 2>/dev/null) &&
           golden=$(curl -fsS --max-time 10 http://127.0.0.1:8000/api/shipments/ZAV94388224 2>/dev/null) &&
           printf "%s" "$estate" | grep -q "\"degraded\":false" &&
           printf "%s" "$golden" | grep -q "\"tracking_number\":\"ZAV94388224\""; then
            printf "ESTATE=%s\nGOLDEN=%s\n" "$estate" "$golden"
            echo ZAVA_ACCEPTANCE_OK
            exit 0
        fi
        sleep 10
    done
    exit 1
'
'@
$startupScript = $startupScript -replace "`r`n", "`n"

$encodedStartup = [Convert]::ToBase64String(
    [Text.Encoding]::UTF8.GetBytes($startupScript)
)
$result = az vm run-command invoke `
    --resource-group $resourceGroup `
    --name $adminVm `
    --command-id RunShellScript `
    --scripts "echo $encodedStartup | base64 -d | bash" `
    --output json `
    --only-show-errors | ConvertFrom-Json
if ($LASTEXITCODE -ne 0) {
    throw "Unable to execute the private startup workflow from '$adminVm'."
}

$message = ($result.value | ForEach-Object message) -join "`n"
$requiredMarkers += 'ZAVA_ACCEPTANCE_OK'
$missingMarkers = @($requiredMarkers | Where-Object { $message -notmatch [regex]::Escape($_) })
if ($missingMarkers.Count -gt 0) {
    Write-Host $message
    throw "The Zava startup workflow did not produce: $($missingMarkers -join ', ')."
}

Write-Host $message
Write-Host 'The private Zava Azure estate is healthy. Public access remains disabled.'
Write-Host "Run '$PSScriptRoot\Enable-ZavaPublicAccess.ps1' when public access is required."
