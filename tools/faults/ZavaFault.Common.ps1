function Invoke-ZavaAdminScript {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Script,
        [Parameter(Mandatory)]
        [string]$SuccessMarker,
        [string]$SubscriptionId = '1a0e0107-9711-458a-aed9-a21d2797109a',
        [string]$ResourceGroup = 'rg-zava-rehearsal-wus2',
        [string]$AdminVm = 'zava-cutover-admin'
    )

    az account set --subscription $SubscriptionId
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to select Azure subscription '$SubscriptionId'."
    }

    $encoded = [Convert]::ToBase64String(
        [Text.Encoding]::UTF8.GetBytes($Script.Replace("`r`n", "`n"))
    )
    $result = az vm run-command invoke `
        --subscription $SubscriptionId `
        --resource-group $ResourceGroup `
        --name $AdminVm `
        --command-id RunShellScript `
        --scripts "printf '%s' '$encoded' | base64 -d | bash" `
        --only-show-errors `
        --output json | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0) {
        throw "Private fault operation failed on '$AdminVm'."
    }

    $message = ($result.value | ForEach-Object message) -join "`n"
    Write-Host $message
    if ($message -notmatch [regex]::Escape($SuccessMarker)) {
        throw "Private fault operation did not produce '$SuccessMarker'."
    }
}
