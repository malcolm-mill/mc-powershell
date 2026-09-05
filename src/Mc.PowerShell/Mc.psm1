# mc-powershell : Midnight Commander's UI over PowerShell's object model.
# Copyright (C) 2026  Malcolm Mill
# Licensed under the GNU General Public License v3 or later. See COPYING.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- load the native layer -------------------------------------------------
# Rendering, key decoding and filesystem enumeration live in C#. Everything
# else is script, so features and plugins stay editable without a rebuild.

$candidates = @(
    (Join-Path $PSScriptRoot 'Mc.Native.dll')
    (Join-Path $PSScriptRoot '../Mc.Native/bin/Release/netstandard2.0/Mc.Native.dll')
    (Join-Path $PSScriptRoot '../Mc.Native/bin/Debug/netstandard2.0/Mc.Native.dll')
)

$nativePath = $null
foreach ($c in $candidates) {
    if (Test-Path -LiteralPath $c) { $nativePath = (Resolve-Path -LiteralPath $c).Path; break }
}
if (-not $nativePath) {
    throw "Mc.Native.dll not found. Run ./build.ps1 first. Looked in:`n  $($candidates -join "`n  ")"
}

if (-not ('Mc.Native.Screen' -as [type])) {
    Add-Type -Path $nativePath
}

# --- script parts ----------------------------------------------------------

. (Join-Path $PSScriptRoot 'Theme.ps1')
. (Join-Path $PSScriptRoot 'Sources.ps1')
. (Join-Path $PSScriptRoot 'Panel.ps1')
. (Join-Path $PSScriptRoot 'Render.ps1')
. (Join-Path $PSScriptRoot 'App.ps1')

Export-ModuleMember -Function @(
    'Start-Mc'
    'Register-McPanelSource'
    'Get-McPanelSource'
    'New-McEntry'
    'New-McPanel'
    'Update-McPanel'
    'Write-McFrame'
    'Get-McColumnLayout'
    'Invoke-McKey'
    'Get-McPanelCurrent'
    'Move-McPanelCursor'
    'Set-McPanelCursor'
    'Set-McPanelLocation'
    'Invoke-McPanelEnter'
    'Invoke-McPanelUp'
    'Switch-McPanelMark'
    'Set-McPanelSort'
    'Get-McPanelStats'
    'Write-McPanel'
    'Get-McProp'
)
