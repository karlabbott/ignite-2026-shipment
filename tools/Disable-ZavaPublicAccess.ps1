[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$workloadSubscription = 'Visual Studio Enterprise Subscription'
$resourceGroup = 'rg-zava-rehearsal-wus2'
$nsgName = 'nsg-zava-workload'
$ruleNames = @('allow-public-zava-web', 'allow-public-zava-http')

az account set --subscription $workloadSubscription
if ($LASTEXITCODE -ne 0) {
    throw "Unable to select Azure subscription '$workloadSubscription'."
}

foreach ($ruleName in $ruleNames) {
    az network nsg rule show `
        --resource-group $resourceGroup `
        --nsg-name $nsgName `
        --name $ruleName `
        --output none `
        --only-show-errors 2>$null

    if ($LASTEXITCODE -eq 0) {
        az network nsg rule delete `
            --resource-group $resourceGroup `
            --nsg-name $nsgName `
            --name $ruleName `
            --only-show-errors
        if ($LASTEXITCODE -ne 0) {
            throw "Unable to delete NSG rule '$ruleName'."
        }
    }
}

foreach ($ruleName in $ruleNames) {
    az network nsg rule show `
        --resource-group $resourceGroup `
        --nsg-name $nsgName `
        --name $ruleName `
        --output none `
        --only-show-errors 2>$null
    if ($LASTEXITCODE -eq 0) {
        throw "NSG rule '$ruleName' still exists."
    }
}

Write-Host 'Zava public access is disabled. The static IP and DNS record remain reserved.'
