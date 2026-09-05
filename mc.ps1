#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Launch mc-powershell.
.EXAMPLE
    ./mc.ps1
    ./mc.ps1 -Left C:\projects -Right Env:\
#>
[CmdletBinding()]
param(
    [string] $Left = (Get-Location).Path,
    [string] $Right = (Get-Location).Path
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'src/Mc.PowerShell/Mc.psd1') -Force
Start-Mc -LeftPath $Left -RightPath $Right
