[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [long]$PollId,
    [string]$ApiBaseUrl = 'https://track.99b.org',
    [string]$PresenterKey = $env:ZAVA_PRESENTER_KEY
)

$ErrorActionPreference = 'Stop'
if (-not $PresenterKey) {
    throw 'Set ZAVA_PRESENTER_KEY or pass -PresenterKey.'
}

$headers = @{ 'x-zava-presenter-key' = $PresenterKey }
$pollUrl = "$($ApiBaseUrl.TrimEnd('/'))/api/presenter/polls/$PollId"
$poll = Invoke-RestMethod -Method Get -Uri $pollUrl -Headers $headers

if ($poll.state -eq 'recovered') {
    Write-Host "Poll $PollId is already recovered: $($poll.winner_code)."
    return
}
if ($poll.state -ne 'injected' -or -not $poll.winner_code) {
    throw "Poll $PollId must be injected before repair, not '$($poll.state)'."
}

$repairs = @{
    freeze_azurelinux = 'Repair-FreezeAzureLinuxWorker.ps1'
    degrade_worker_sql = 'Repair-DegradeWorkerSql.ps1'
    delay_worker_claims = 'Repair-DelayWorkerClaims.ps1'
}
$scriptName = $repairs[$poll.winner_code]
if (-not $scriptName) {
    throw "Poll winner '$($poll.winner_code)' is not allowlisted."
}

$scriptPath = Join-Path $PSScriptRoot $scriptName
Write-Host "Repairing poll $PollId scenario '$($poll.winner_code)' with $scriptName."
& $scriptPath
if ($LASTEXITCODE -ne 0) {
    throw "Fault repair '$scriptName' failed."
}

$body = @{ state = 'recovered' } | ConvertTo-Json -Compress
$poll = Invoke-RestMethod `
    -Method Post `
    -Uri "$pollUrl/state" `
    -Headers $headers `
    -ContentType 'application/json' `
    -Body $body
if ($poll.state -ne 'recovered') {
    throw "Repair completed, but poll $PollId did not enter the recovered state."
}

Write-Host "Poll $PollId is recovered. No automatic rollback was used."
