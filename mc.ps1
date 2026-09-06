#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Launch mc-powershell.
.EXAMPLE
    ./mc.ps1
    ./mc.ps1 -Left C:\projects -Right Env:\
    ./mc.ps1 -Version
#>
[CmdletBinding()]
param(
    [string] $Left = (Get-Location).Path,
    [string] $Right = (Get-Location).Path,
    [switch] $Version
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'src/Mc.PowerShell/Mc.psd1') -Force
if ($Version) { "mc-powershell $(Get-McVersion)"; return }
Start-Mc -LeftPath $Left -RightPath $Right
