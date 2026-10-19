[CmdletBinding()]
param(
    [string]$ApiBaseUrl = 'https://track.99b.org',
    [string]$PresenterKeyPath = (Join-Path $HOME '.zava\presenter.key')
)

$ErrorActionPreference = 'Stop'
if ([uri]$ApiBaseUrl -and ([uri]$ApiBaseUrl).Scheme -ne 'https') {
    throw 'The private runner requires an HTTPS API origin.'
}
$key = [IO.File]::ReadAllText($PresenterKeyPath).Trim()
if (-not $key) { throw 'The presenter key file is empty.' }
$headers = @{ 'x-zava-presenter-key' = $key }
$base = $ApiBaseUrl.TrimEnd('/')
$runnerId = [guid]::NewGuid().ToString()
$controller = Join-Path $PSScriptRoot 'Close-ZavaFailurePoll.ps1'
$account = az account show --query state -o tsv --only-show-errors
if ($LASTEXITCODE -ne 0 -or $account.Trim() -ne 'Enabled') {
    throw 'An authenticated, enabled Azure CLI subscription is required.'
}
$activeJob = $null
$activePoll = $null
$pendingResult = $null

function Invoke-RunnerApi([string]$Path, [object]$Body) {
    Invoke-RestMethod -Method Post -Uri "$base$Path" -Headers $headers `
        -ContentType 'application/json' -Body ($Body | ConvertTo-Json -Compress) `
        -TimeoutSec 15
}

Write-Output "$(Get-Date -Format o) Private fault runner started; no inbound listener."
while ($true) {
    try {
        if ($activeJob -and $activeJob.State -in @('Completed', 'Failed', 'Stopped')) {
            $output = @(Receive-Job -Job $activeJob -ErrorAction Continue)
            $outcome = @($output | Where-Object { $_.PSObject.Properties['Succeeded'] })
            $pendingResult = @{
                runner_id = $runnerId
                succeeded = ($outcome.Count -eq 1 -and $outcome[0].Succeeded -eq $true)
            }
            Remove-Job -Job $activeJob
            $activeJob = $null
        }
        if ($pendingResult) {
            $result = Invoke-RunnerApi "/api/presenter/polls/$activePoll/injection/result" $pendingResult
            Write-Output "$(Get-Date -Format o) Poll $activePoll injection result: $($result.state)"
            $pendingResult = $null
            $activePoll = $null
        }
        $claim = Invoke-RunnerApi '/api/presenter/runner/claim' @{ runner_id = $runnerId }
        if ($claim.poll_id) {
            if ($activeJob) { throw 'An unexpected second injection was claimed; manual inspection is required.' }
            $activePoll = [long]$claim.poll_id
            Write-Output "$(Get-Date -Format o) Executing requested injection for poll $activePoll."
            $activeJob = Start-Job -ArgumentList $controller, $activePoll, $base, $key -ScriptBlock {
                param($Controller, $PollId, $Base, $Key)
                $ErrorActionPreference = 'Stop'
                try {
                    & $Controller -PollId $PollId -ApiBaseUrl $Base -PresenterKey $Key
                    [pscustomobject]@{ Succeeded = $true }
                }
                catch {
                    Write-Error "Injection failed; a partial fault may remain: $_" -ErrorAction Continue
                    [pscustomobject]@{ Succeeded = $false }
                }
            }
        }
    }
    catch {
        Write-Warning "$(Get-Date -Format o) Private runner operation failed: $_"
    }
    Start-Sleep -Seconds 3
}
