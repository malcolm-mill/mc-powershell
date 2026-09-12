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

# Whichever build is newest wins, so a staging copy that could not be replaced
# (because another session had it loaded) never shadows a fresh build.
$nativePath = $null
$newest = [datetime]::MinValue
foreach ($c in $candidates) {
    if (-not (Test-Path -LiteralPath $c)) { continue }
    $item = Get-Item -LiteralPath $c
    if ($item.LastWriteTimeUtc -gt $newest) {
        $newest = $item.LastWriteTimeUtc
        $nativePath = $item.FullName
    }
}
if (-not $nativePath) {
    throw "Mc.Native.dll not found. Run ./build.ps1 first. Looked in:`n  $($candidates -join "`n  ")"
}

# Every type the module needs. Checking the whole set matters: guarding on one
# type meant a session holding an OLDER Mc.Native skipped the load and then
# failed later on a type that build did not have.
$requiredTypes = @(
    'Mc.Native.Screen'
    'Mc.Native.Terminal'
    'Mc.Native.Keys'
    'Mc.Native.Input'
    'Mc.Native.InputEvent'
    'Mc.Native.PanelEntry'
    'Mc.Native.Fs'
)

$missing = @($requiredTypes | Where-Object { -not ($_ -as [type]) })

if ($missing.Count -eq $requiredTypes.Count) {
    # Nothing loaded yet in this session, so load the build.
    #
    # .NET locks an assembly for the life of the process, so loading the build
    # output directly would make the next `dotnet build` fail while any session
    # still holds it. Load a shadow copy instead, keyed on the build timestamp
    # so repeated loads of one build share a directory rather than littering
    # one per session.
    $shadowRoot = Join-Path ([System.IO.Path]::GetTempPath()) 'mc-powershell-native'
    $shadowDir = Join-Path $shadowRoot ($newest.Ticks.ToString())
    $shadow = Join-Path $shadowDir 'Mc.Native.dll'

    if (-not (Test-Path -LiteralPath $shadow)) {
        [void](New-Item -ItemType Directory -Path $shadowDir -Force)
        Copy-Item -LiteralPath $nativePath -Destination $shadow -Force
    }

    try {
        Get-ChildItem -LiteralPath $shadowRoot -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -ne $newest.Ticks.ToString() } |
            ForEach-Object { Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue }
    } catch { }

    Add-Type -Path $shadow
    $missing = @($requiredTypes | Where-Object { -not ($_ -as [type]) })
}

if ($missing.Count -gt 0) {
    throw @"
This PowerShell session already has an older Mc.Native.dll loaded, and .NET
cannot unload an assembly once it is in a process. Missing from the loaded
build: $($missing -join ', ')

Open a new PowerShell window and run ./mc.ps1 again. The build itself is fine --
only this session is stuck on the old one.
"@
}

# --- script parts ----------------------------------------------------------

. (Join-Path $PSScriptRoot 'Theme.ps1')
. (Join-Path $PSScriptRoot 'Guard.ps1')
. (Join-Path $PSScriptRoot 'Sources.ps1')
. (Join-Path $PSScriptRoot 'Documents.ps1')
. (Join-Path $PSScriptRoot 'Panel.ps1')
. (Join-Path $PSScriptRoot 'Menu.ps1')
. (Join-Path $PSScriptRoot 'Markdown.ps1')
. (Join-Path $PSScriptRoot 'Viewer.ps1')
. (Join-Path $PSScriptRoot 'Render.ps1')
. (Join-Path $PSScriptRoot 'App.ps1')

Export-ModuleMember -Function @(
    'Start-Mc'
    'Get-McVersion'
    'Register-McPanelSource'
    'Get-McPanelSource'
    'New-McEntry'
    'New-McPanel'
    'Update-McPanel'
    'Write-McFrame'
    'Get-McColumnLayout'
    'Invoke-McKey'
    'Get-McKeymap'
    'Get-McMode'
    'Set-McMode'
    'Test-McWritable'
    'Assert-McWritable'
    'Test-McCommandMutates'
    'Invoke-McInternalCommand'
    'New-McAppState'
    'Add-McOutput'
    'Set-McOutputLines'
    'Invoke-McSubshell'
    'Read-McShellLine'
    'Invoke-McCommandInPane'
    'Get-McLayout'
    'Get-McMenus'
    'Show-McMenu'
    'Invoke-McMenuItem'
    'Invoke-McMouse'
    'Show-McViewer'
    'Invoke-McViewCurrent'
    'Invoke-McOpenCurrent'
    'Get-McViewablePath'
    'Get-McEntryContent'
    'Read-McViewerFile'
    'Find-McViewerMatch'
    'Get-McFileEncoding'
    'Convert-McMarkdown'
    'Get-McSegmentSlice'
    'Show-McDriveChooser'
    'Get-McDriveLocation'
    'Show-McSortMenu'
    'Get-McPanelCurrent'
    'Get-McPanelLeafName'
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
    'Get-McParentPath'
    'Get-McChildPath'
    'Get-McRegistryValueRows'
    'Format-McRegistryData'
    'Get-McCertificateName'
    'Get-McCertificateContent'
    'Get-McLeafName'
)
