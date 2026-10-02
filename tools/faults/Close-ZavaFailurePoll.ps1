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

if ($poll.state -eq 'open') {
    $poll = Invoke-RestMethod -Method Post -Uri "$pollUrl/lock" -Headers $headers
}
if ($poll.state -eq 'injected') {
    Write-Host "Poll $PollId is already injected: $($poll.winner_code)."
    return
}
if ($poll.state -ne 'locked' -or -not $poll.winner_code) {
    throw "Poll $PollId must be open or locked, not '$($poll.state)'."
}

$scenarios = @{
    freeze_azurelinux = @{
        Script = 'Invoke-FreezeAzureLinuxWorker.ps1'
        Scope = 'Azure Linux shipment-worker process only (192.168.90.15)'
        Evidence = 'systemd active; process state T; heartbeat and contribution fall'
    }
    degrade_worker_sql = @{
        Script = 'Invoke-DegradeWorkerSql.ps1'
        Scope = '75% outbound TCP/1433 loss from both workers to 192.168.90.11'
        Evidence = 'nft counters and TCP retransmissions rise; API remains available'
    }
    delay_worker_claims = @{
        Script = 'Invoke-DelayWorkerClaims.ps1'
        Scope = 'dbo.usp_claim_scan only; seven seconds before row locking'
        Evidence = 'worker completions fall while API reads and disk latency remain healthy'
    }
}
$scenario = $scenarios[$poll.winner_code]
if (-not $scenario) {
    throw "Poll winner '$($poll.winner_code)' is not allowlisted."
}

$scriptName = $scenario.Script
$scriptPath = Join-Path $PSScriptRoot $scriptName
Write-Host "Poll $PollId closed. Injecting allowlisted scenario '$($poll.winner_code)'."
Write-Host "Scope: $($scenario.Scope)"
Write-Host 'Duration: until Copilot diagnoses the incident and runs the reviewed repair.'
Write-Host "Expected evidence: $($scenario.Evidence)"
Write-Host "Injector: $scriptName"
& $scriptPath
if ($LASTEXITCODE -ne 0) {
    throw "Fault injector '$scriptName' failed."
}

$body = @{ state = 'injected' } | ConvertTo-Json -Compress
$poll = Invoke-RestMethod `
    -Method Post `
    -Uri "$pollUrl/state" `
    -Headers $headers `
    -ContentType 'application/json' `
    -Body $body
if ($poll.state -ne 'injected') {
    throw "Fault is active, but poll $PollId did not enter the injected state."
}

Write-Host "Poll $PollId is injected. The fault remains active until Copilot runs Repair-ZavaFailurePoll.ps1."
