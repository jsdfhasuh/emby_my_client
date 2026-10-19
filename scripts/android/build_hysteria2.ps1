param(
    [ValidateSet('test', 'aar', 'all', 'verify')][string]$Mode = 'all',
    [string]$AndroidSdk = $env:ANDROID_HOME,
    [string]$Go = '',
    [string]$Python = 'python'
)
$ErrorActionPreference = 'Stop'
$arguments = @((Join-Path $PSScriptRoot 'build_hysteria2.py'), $Mode)
if ($AndroidSdk) { $arguments += @('--android-sdk', $AndroidSdk) }
if ($Go) { $arguments += @('--go', $Go) }
& $Python @arguments
if ($LASTEXITCODE -ne 0) { throw "Hysteria2 $Mode failed (exit $LASTEXITCODE)" }
