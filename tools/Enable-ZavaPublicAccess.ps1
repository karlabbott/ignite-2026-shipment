[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$workloadSubscription = 'Visual Studio Enterprise Subscription'
$resourceGroup = 'rg-zava-rehearsal-wus2'
$nsgName = 'nsg-zava-workload'
$ruleName = 'allow-public-zava-web'
$legacyRuleName = 'allow-public-zava-http'
$webPrivateIp = '192.168.90.13'

az account set --subscription $workloadSubscription
if ($LASTEXITCODE -ne 0) {
    throw "Unable to select Azure subscription '$workloadSubscription'."
}

az network nsg rule delete `
    --resource-group $resourceGroup `
    --nsg-name $nsgName `
    --name $legacyRuleName `
    --only-show-errors 2>$null

az network nsg rule create `
    --resource-group $resourceGroup `
    --nsg-name $nsgName `
    --name $ruleName `
    --priority 200 `
    --direction Inbound `
    --access Allow `
    --protocol Tcp `
    --source-address-prefixes Internet `
    --source-port-ranges '*' `
    --destination-address-prefixes $webPrivateIp `
    --destination-port-ranges 80 443 `
    --description 'Temporary public HTTPS access and HTTP redirect for the Zava Ignite demonstration' `
    --only-show-errors `
    --output none
if ($LASTEXITCODE -ne 0) {
    throw "Unable to create NSG rule '$ruleName'."
}

$rule = az network nsg rule show `
    --resource-group $resourceGroup `
    --nsg-name $nsgName `
    --name $ruleName `
    --output json `
    --only-show-errors | ConvertFrom-Json
if ($LASTEXITCODE -ne 0) {
    throw "Unable to inspect NSG rule '$ruleName'."
}

$ports = @($rule.destinationPortRanges)
if ($rule.destinationPortRange) {
    $ports += $rule.destinationPortRange
}
$ports = @($ports | Sort-Object -Unique)
$expectedPorts = @('80', '443')
if (
    $rule.access -ne 'Allow' -or
    $rule.direction -ne 'Inbound' -or
    $rule.protocol -ne 'Tcp' -or
    $rule.sourceAddressPrefix -ne 'Internet' -or
    $rule.destinationAddressPrefix -ne $webPrivateIp -or
    $rule.priority -ne 200 -or
    (Compare-Object $ports $expectedPorts)
) {
    throw "NSG rule '$ruleName' did not validate."
}

Write-Host 'Zava public access is enabled at https://track.99b.org and https://dash.99b.org'
