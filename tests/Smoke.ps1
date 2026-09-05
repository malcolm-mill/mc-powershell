#!/usr/bin/env pwsh
<#
    Headless render check. Builds app state, paints one frame into the back
    buffer and prints Screen.Snapshot() as plain text. No terminal required,
    which is exactly what makes golden-frame tests possible.
#>
param(
    [int] $Width = 110,
    [int] $Height = 26,
    [string] $Left = 'C:\projects',
    [string] $Right = 'Env:\'
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '../src/Mc.PowerShell/Mc.psd1') -Force

$screen = [Mc.Native.Screen]::new($Width, $Height)
$state = @{
    Left        = New-McPanel $Left
    Right       = New-McPanel $Right
    ActiveSide  = 'Left'
    CommandLine = 'Get-ChildItem | Measure-Object'
    Message     = $null
    Running     = $true
}

$sw = [System.Diagnostics.Stopwatch]::StartNew()
Write-McFrame $screen $state
$sw.Stop()

Write-Output $screen.Snapshot()
Write-Output ("render: {0:N1} ms   left: {1} rows   right: {2} rows" -f `
    $sw.Elapsed.TotalMilliseconds, $state.Left.Entries.Count, $state.Right.Entries.Count)

# Steady state: the first render pays JIT and module load, which is not the
# number that matters for the redraw loop.
$null = Write-McFrame $screen $state
$sw2 = [System.Diagnostics.Stopwatch]::StartNew()
for ($i = 0; $i -lt 50; $i++) { Write-McFrame $screen $state }
$sw2.Stop()
Write-Output ("steady state: {0:N2} ms/frame over 50 frames" -f ($sw2.Elapsed.TotalMilliseconds / 50))
