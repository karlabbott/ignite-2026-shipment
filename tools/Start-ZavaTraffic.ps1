[CmdletBinding()]
param(
    [string] $Web = 'http://localhost:8090',
    [string] $ReturnWeb = 'https://track.99b.org',
    [double] $Rate = 32,
    [double] $Duration = 0,
    [string] $KeyFile = "$HOME\.zava\loadgen.key"
)

$ErrorActionPreference = 'Stop'
$generator = Join-Path $PSScriptRoot 'loadgen.py'

if (Test-Path -LiteralPath $KeyFile) {
    $env:SHIPMENT_LOADGEN_KEY = (Get-Content -LiteralPath $KeyFile -Raw).Trim()
} elseif (-not $env:SHIPMENT_LOADGEN_KEY) {
    throw "Load-generator key not found at $KeyFile."
}

$arguments = @(
    $generator,
    '--web', $Web,
    '--failover-web', $ReturnWeb,
    '--rate', $Rate,
    '--advance', 0
)
if ($Duration -gt 0) {
    $arguments += @('--duration', $Duration)
}

python @arguments
exit $LASTEXITCODE
