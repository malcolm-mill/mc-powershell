#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Builds the native layer and stages the module for import.
.DESCRIPTION
    The C# assembly is locked once PowerShell loads it, so a rebuild needs a
    fresh session. This script warns rather than failing silently.
#>
[CmdletBinding()]
param(
    [ValidateSet('Debug', 'Release')]
    [string] $Configuration = 'Release',
    [switch] $SkipCopy
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot

Write-Host 'Building Mc.Native...' -ForegroundColor Cyan
dotnet build (Join-Path $root 'src/Mc.Native/Mc.Native.csproj') -c $Configuration --nologo -v q
if ($LASTEXITCODE -ne 0) { throw 'Native build failed.' }

if (-not $SkipCopy) {
    $dll = Join-Path $root "src/Mc.Native/bin/$Configuration/netstandard2.0/Mc.Native.dll"
    $dest = Join-Path $root 'src/Mc.PowerShell/Mc.Native.dll'
    try {
        Copy-Item -LiteralPath $dll -Destination $dest -Force
        Write-Host "Staged $dest" -ForegroundColor Green
    } catch {
        Write-Warning "Could not copy the assembly (a running session may hold it): $($_.Exception.Message)"
    }
}

Write-Host ''
Write-Host 'Run it with:  ./mc.ps1' -ForegroundColor Yellow
