<#
.SYNOPSIS
    Serve the SLES 16 Agama profile to the lab subnet over HTTP.

.DESCRIPTION
    Agama fetches its unattended-install profile from a URL given by the
    inst.auto= boot argument. It does not auto-detect a labelled volume the way
    Anaconda finds OEMDRV, so the profile is served from the Hyper-V host on the
    lab gateway address.

    Boot argument to add at the SLES installer menu:
        inst.auto=http://192.168.90.1:8099/sles16-api.json

    Leave this running until sles-api has finished installing, then Ctrl-C.

    Binds only to the internal lab gateway, never to a routable interface.
#>
[CmdletBinding()]
param(
    [string] $Root    = (Join-Path $PSScriptRoot 'out\http'),
    [string] $Address = '192.168.90.1',
    [int]    $Port    = 8099
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'HttpListener needs an elevated session to bind a URL prefix.'
}

if (-not (Test-Path $Root)) {
    throw "Answer directory not found: $Root`nRun: wsl -d Ubuntu -e bash estate/build-answer-isos.sh"
}

$prefix   = "http://${Address}:${Port}/"
$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add($prefix)

try {
    $listener.Start()
} catch {
    throw "Could not bind $prefix. Is the ShipmentLab switch up with $Address assigned?`n$($_.Exception.Message)"
}

Write-Host "Serving $Root at $prefix" -ForegroundColor Cyan
Get-ChildItem $Root -File | ForEach-Object {
    Write-Host "  $prefix$($_.Name)" -ForegroundColor Gray
}
Write-Host 'Ctrl-C to stop.' -ForegroundColor DarkGray

try {
    while ($listener.IsListening) {
        $context  = $listener.GetContext()
        $request  = $context.Request
        $response = $context.Response

        # Resolve inside $Root only; refuse anything that escapes it.
        $relative = $request.Url.AbsolutePath.TrimStart('/')
        $target   = Join-Path $Root $relative
        $full     = [System.IO.Path]::GetFullPath($target)
        $rootFull = [System.IO.Path]::GetFullPath($Root)

        if (-not $full.StartsWith($rootFull, [StringComparison]::OrdinalIgnoreCase) -or
            -not (Test-Path $full -PathType Leaf)) {
            $response.StatusCode = 404
            Write-Host ("404  {0}  {1}" -f $request.RemoteEndPoint.Address, $relative) -ForegroundColor Yellow
        } else {
            $bytes = [System.IO.File]::ReadAllBytes($full)
            $response.StatusCode = 200
            $response.ContentType = if ($full -like '*.json') { 'application/json' } else { 'text/plain' }
            $response.ContentLength64 = $bytes.Length
            $response.OutputStream.Write($bytes, 0, $bytes.Length)
            Write-Host ("200  {0}  {1}  ({2} bytes)" -f `
                $request.RemoteEndPoint.Address, $relative, $bytes.Length) -ForegroundColor Green
        }
        $response.Close()
    }
} finally {
    $listener.Stop()
    $listener.Close()
    Write-Host 'Answer server stopped.' -ForegroundColor Cyan
}
