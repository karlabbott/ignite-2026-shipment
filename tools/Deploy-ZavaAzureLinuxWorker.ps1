[CmdletBinding()]
param(
    [string]$SubscriptionId = '1a0e0107-9711-458a-aed9-a21d2797109a',
    [string]$ResourceGroup = 'rg-zava-rehearsal-wus2',
    [string]$AdminVm = 'zava-cutover-admin',
    [string]$ApiAddress = '192.168.90.12',
    [string]$WorkerAddress = '192.168.90.15',
    [string]$VmName = 'azurelinux-worker',
    [string]$RepositoryUrl = 'https://github.com/karlabbott/ignite-2026-shipment.git',
    [string]$Commit = '',
    [string]$ObservabilityRepository = '..\ignite-2026-zava-observability',
    [switch]$SkipObservability
)

$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$template = Join-Path $repositoryRoot 'infra\azurelinux-worker.bicep'

if (-not $Commit) {
    $Commit = (git -C $repositoryRoot rev-parse HEAD).Trim()
}
if (-not $Commit) {
    throw 'Unable to resolve the shipment repository commit.'
}

az account set --subscription $SubscriptionId
if ($LASTEXITCODE -ne 0) {
    throw "Unable to select Azure subscription '$SubscriptionId'."
}

$keyCommand = @'
set -euo pipefail
key=/home/estate/.ssh/zava_cutover_mgmt
test -f "$key"
sudo -u estate ssh-keygen -y -f "$key"
'@
$keyResult = az vm run-command invoke `
    --subscription $SubscriptionId `
    --resource-group $ResourceGroup `
    --name $AdminVm `
    --command-id RunShellScript `
    --scripts $keyCommand `
    --only-show-errors `
    --output json | ConvertFrom-Json
if ($LASTEXITCODE -ne 0) {
    throw "Unable to derive the management SSH public key from '$AdminVm'."
}
$sshPublicKey = (($keyResult.value | ForEach-Object message) -join "`n" -split "`r?`n" |
    Where-Object { $_ -match '^ssh-' } |
    Select-Object -First 1).Trim()
if (-not $sshPublicKey) {
    throw 'The management SSH public key was not returned.'
}

$deploymentName = "zava-azurelinux-worker-$((Get-Date).ToUniversalTime().ToString('yyyyMMddHHmmss'))"
az deployment group create `
    --subscription $SubscriptionId `
    --resource-group $ResourceGroup `
    --name $deploymentName `
    --template-file $template `
    --parameters vmName=$VmName privateIpAddress=$WorkerAddress sshPublicKey="$sshPublicKey" `
    --only-show-errors `
    --output none
if ($LASTEXITCODE -ne 0) {
    throw 'Azure Linux worker infrastructure deployment failed.'
}

$configure = @"
set -euo pipefail
key=/home/estate/.ssh/zava_cutover_mgmt
ssh_options="-n -i `$key -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10"
scp_options="-i `$key -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10"
worker='$WorkerAddress'
api='$ApiAddress'
stage=`$(mktemp -d /var/tmp/zava-azurelinux-worker.XXXXXX)
trap 'rm -rf "`$stage"' EXIT
chown estate:estate "`$stage"

for attempt in `$(seq 1 30); do
  if sudo -u estate ssh `$ssh_options estate@`$worker 'echo AZURE_LINUX_SSH_READY' >/dev/null 2>&1; then
    break
  fi
  if [ "`$attempt" -eq 30 ]; then
    echo 'Azure Linux worker did not become reachable over private SSH.' >&2
    exit 1
  fi
  sleep 10
done

sudo -u estate ssh `$ssh_options estate@`$api 'sudo cat /etc/shipment/shipment.env' > "`$stage/shipment.env"
sed -i '/^SHIPMENT_DRIFT_ENABLED=/d' "`$stage/shipment.env"
printf 'SHIPMENT_DRIFT_ENABLED=false\n' >> "`$stage/shipment.env"
chmod 0600 "`$stage/shipment.env"
chown estate:estate "`$stage/shipment.env"

sudo -u estate scp `$scp_options "`$stage/shipment.env" estate@`$worker:/var/tmp/zava-shipment.env
sudo -u estate ssh `$ssh_options estate@`$worker "
  set -euo pipefail
  rm -rf /var/tmp/zava-shipment-source
  git clone --quiet '$RepositoryUrl' /var/tmp/zava-shipment-source
  git -C /var/tmp/zava-shipment-source checkout --quiet --detach '$Commit'
  sudo groupadd --system shipment >/dev/null 2>&1 || true
  sudo useradd --system --gid shipment --home-dir /opt/shipment --shell /usr/sbin/nologin shipment >/dev/null 2>&1 || true
  sudo install -d -m 0750 -o root -g shipment /etc/shipment
  sudo install -m 0640 -o root -g shipment /var/tmp/zava-shipment.env /etc/shipment/shipment.env
  sudo bash /var/tmp/zava-shipment-source/worker/install-azurelinux.sh
  rm -f /var/tmp/zava-shipment.env
  test \"`$(systemctl is-active shipment-worker.service)\" = active
  /opt/shipment/venv/bin/python -c 'import pymssql'
  echo ZAVA_AZURE_LINUX_WORKER_READY
"
"@
$encodedConfigure = [Convert]::ToBase64String(
    [Text.Encoding]::UTF8.GetBytes($configure.Replace("`r`n", "`n"))
)
$configurationResult = az vm run-command invoke `
    --subscription $SubscriptionId `
    --resource-group $ResourceGroup `
    --name $AdminVm `
    --command-id RunShellScript `
    --scripts "printf '%s' '$encodedConfigure' | base64 -d | bash" `
    --only-show-errors `
    --output json | ConvertFrom-Json
if ($LASTEXITCODE -ne 0) {
    throw 'Azure Linux worker application configuration failed.'
}
$configurationMessage = ($configurationResult.value | ForEach-Object message) -join "`n"
Write-Host $configurationMessage
if ($configurationMessage -notmatch 'ZAVA_AZURE_LINUX_WORKER_READY') {
    throw 'Azure Linux worker configuration did not reach acceptance.'
}

if (-not $SkipObservability) {
    $observabilityRoot = [IO.Path]::GetFullPath(
        (Join-Path $repositoryRoot $ObservabilityRepository)
    )
    $observabilityDeployment = Join-Path $observabilityRoot 'tools\Invoke-PrivateEstateDeployment.ps1'
    if (-not (Test-Path -LiteralPath $observabilityDeployment)) {
        throw "Observability deployment wrapper not found: $observabilityDeployment"
    }
    & $observabilityDeployment `
        -SubscriptionId $SubscriptionId `
        -ResourceGroup $ResourceGroup `
        -AdminVm $AdminVm
}

Write-Host "Azure Linux worker '$VmName' is deployed at $WorkerAddress."
