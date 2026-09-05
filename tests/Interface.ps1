#!/usr/bin/env pwsh
<#
    Menu bar, mouse routing and the file viewer.

    All headless: the layout is computed data, mouse events are just objects,
    and the viewer's file loading is separable from its screen loop. The modal
    loops themselves (Show-McMenu, Show-McViewer) need a terminal and are not
    covered here.
#>
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '../src/Mc.PowerShell/Mc.psd1') -Force

$script:pass = 0
$script:fail = 0

function Assert-That {
    param([string] $What, [scriptblock] $Condition)
    $ok = $false
    try { $ok = [bool](& $Condition) } catch { $ok = $false }
    if ($ok) { $script:pass++; Write-Host "  PASS  $What" -ForegroundColor Green }
    else { $script:fail++; Write-Host "  FAIL  $What" -ForegroundColor Red }
}

function New-Click {
    param([int] $X, [int] $Y, [string] $Button = 'left', [switch] $Double)
    $ev = [Mc.Native.InputEvent]::new()
    $ev.Kind = [Mc.Native.InputKind]::Mouse
    $ev.X = $X
    $ev.Y = $Y
    $ev.Button = $Button
    $ev.Pressed = $true
    $ev.Double = [bool]$Double
    $ev
}

$repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$screen = [Mc.Native.Screen]::new(100, 24)
$state = New-McAppState -LeftPath $repo -RightPath 'Env:'
Write-McFrame $screen $state

# --- layout ----------------------------------------------------------------

Write-Host "`nLayout" -ForegroundColor Cyan
$L = Get-McLayout $screen $state
Assert-That 'the menu bar owns row 0'          { $L.MenuY -eq 0 }
Assert-That 'panels start below the menu bar'  { $L.PanelY -eq 1 }
Assert-That 'the key bar is the last row'      { $L.KeyY -eq 23 }
Assert-That 'the command line is above it'     { $L.CmdY -eq 22 }
Assert-That 'panel rows match what the panel reports' {
    $L.PanelRows -eq $state.Left.Rows
}
Assert-That 'the two panels tile the width' {
    $L.LeftW + $L.RightW -eq $L.Width -and $L.RightX -eq $L.LeftW
}

Write-Host "`nMenu bar" -ForegroundColor Cyan
Assert-That 'five menus, as mc has' { (Get-McMenus).Count -eq 5 }
Assert-That 'they are titled like mc' {
    ((Get-McMenus | ForEach-Object Title) -join ',') -eq 'Left,File,Command,Options,Right'
}
Assert-That 'every menu has items' {
    @(Get-McMenus | Where-Object { $_.Items.Count -eq 0 }).Count -eq 0
}
Assert-That 'every non-separator item has an action' {
    $bad = 0
    foreach ($m in Get-McMenus) {
        foreach ($i in $m.Items) { if (-not $i.Separator -and $null -eq $i.Action) { $bad++ } }
    }
    $bad -eq 0
}

# The hit boxes must line up with what was actually painted, or clicks land
# somewhere other than the label the user aimed at.
$frame = ($screen.Snapshot() -split "`n")
Assert-That 'each hit box sits on its own painted title' {
    $bad = 0
    foreach ($hit in $L.MenuHits) {
        $painted = $frame[$L.MenuY].Substring($hit.X, $hit.W).Trim()
        if ($painted -ne $hit.Title) { $bad++ }
    }
    $bad -eq 0
}
Assert-That 'the menu titles are on screen' { $frame[0] -match 'Left' -and $frame[0] -match 'Options' }

# --- mouse -----------------------------------------------------------------

Write-Host "`nMouse: function key bar" -ForegroundColor Cyan
$state.Message = $null
Invoke-McMouse $state $screen (New-Click ($L.KeySlot * 7 + 1) $L.KeyY)
Assert-That 'clicking 8Delete refuses in read-only mode' { $state.Message -match 'Read-only mode' }

$state.Message = $null
Invoke-McMouse $state $screen (New-Click ($L.KeySlot * 4 + 1) $L.KeyY)
Assert-That 'clicking 5Copy refuses too' { $state.Message -match 'Read-only mode' }

Assert-That 'clicking 10Quit stops the loop' {
    Invoke-McMouse $state $screen (New-Click ($L.KeySlot * 9 + 1) $L.KeyY)
    -not $state.Running
}
$state.Running = $true

Write-Host "`nMouse: panels" -ForegroundColor Cyan
$state.ActiveSide = 'Left'
Write-McFrame $screen $state
Invoke-McMouse $state $screen (New-Click ($L.RightX + 5) ($L.PanelRowY + 1))
Assert-That 'clicking the right panel focuses it' { $state.ActiveSide -eq 'Right' }
Assert-That 'and lands on the clicked row'        { $state.Right.Index -eq $state.Right.Top + 1 }

Invoke-McMouse $state $screen (New-Click 5 ($L.PanelRowY + 3))
Assert-That 'clicking the left panel focuses it'  { $state.ActiveSide -eq 'Left' }
Assert-That 'and lands on the clicked row'        { $state.Left.Index -eq $state.Left.Top + 3 }

Assert-That 'a click below the last row is ignored' {
    $before = $state.Left.Index
    Invoke-McMouse $state $screen (New-Click 5 ($L.PanelRowY + $L.PanelRows + 1))
    $state.Left.Index -eq $before
}

Write-Host "`nMouse: wheel" -ForegroundColor Cyan
Set-McPanelCursor $state.Left 0
Invoke-McMouse $state $screen (New-Click 5 ($L.PanelRowY + 1) 'wheeldown')
Assert-That 'the wheel scrolls down' { $state.Left.Index -eq 3 }
Invoke-McMouse $state $screen (New-Click 5 ($L.PanelRowY + 1) 'wheelup')
Assert-That 'the wheel scrolls back up' { $state.Left.Index -eq 0 }

Assert-That 'the wheel scrolls the panel under the pointer, not the focused one' {
    $state.ActiveSide = 'Left'
    Set-McPanelCursor $state.Right 0
    Invoke-McMouse $state $screen (New-Click ($L.RightX + 5) ($L.PanelRowY + 1) 'wheeldown')
    $state.ActiveSide -eq 'Left' -and $state.Right.Index -eq 3
}

# --- viewer ----------------------------------------------------------------

Write-Host "`nViewer: reading files" -ForegroundColor Cyan
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("mc-viewer-" + [guid]::NewGuid().ToString('n'))
[void](New-Item -ItemType Directory -Path $tmp -Force)
try {
    $utf8 = Join-Path $tmp 'utf8.txt'
    [System.IO.File]::WriteAllText($utf8, "first`nsecond `u{00e9}`nthird", [System.Text.UTF8Encoding]::new($false))
    $r = Read-McViewerFile $utf8
    Assert-That 'plain UTF-8 reads back'       { $r.Lines.Count -eq 3 -and $r.Lines[0] -eq 'first' }
    Assert-That 'accented characters survive'  { $r.Lines[1] -match ([char]0x00e9) }
    Assert-That 'it is not flagged binary'     { -not $r.Binary }

    $bom = Join-Path $tmp 'bom.txt'
    [System.IO.File]::WriteAllText($bom, "with bom", [System.Text.UTF8Encoding]::new($true))
    $r = Read-McViewerFile $bom
    Assert-That 'a BOM is consumed, not shown' { $r.Lines[0] -eq 'with bom' }

    # Latin-1 bytes are not valid UTF-8; the viewer must not mangle them.
    $latin = Join-Path $tmp 'latin1.txt'
    [System.IO.File]::WriteAllBytes($latin, [byte[]](0x63, 0x61, 0x66, 0xE9, 0x0A, 0x6F, 0x6B))
    $r = Read-McViewerFile $latin
    Assert-That 'invalid UTF-8 falls back to Latin-1' { $r.Lines[0] -eq ('caf' + [char]0x00e9) }
    Assert-That 'no replacement characters appear'    { $r.Lines[0] -notmatch [char]0xFFFD }

    $crlf = Join-Path $tmp 'crlf.txt'
    [System.IO.File]::WriteAllText($crlf, "a`r`nb`r`nc")
    $r = Read-McViewerFile $crlf
    Assert-That 'CRLF splits into lines without stray CR' {
        $r.Lines.Count -eq 3 -and $r.Lines[1] -eq 'b'
    }

    $bin = Join-Path $tmp 'binary.bin'
    [System.IO.File]::WriteAllBytes($bin, [byte[]](0x00, 0x01, 0x02, 0x00, 0xFF))
    $r = Read-McViewerFile $bin
    Assert-That 'binary content is detected'   { $r.Binary }
    Assert-That 'and says so rather than spewing bytes' { $r.Lines[0] -match 'binary file' }

    $empty = Join-Path $tmp 'empty.txt'
    [System.IO.File]::WriteAllText($empty, '')
    $r = Read-McViewerFile $empty
    Assert-That 'an empty file is not an error' { -not $r.ContainsKey('Error') -and $r.Lines.Count -eq 0 }

    $r = Read-McViewerFile (Join-Path $tmp 'nosuch.txt')
    Assert-That 'a missing file reports an error' { $r.ContainsKey('Error') }

    Write-Host "`nViewer: search" -ForegroundColor Cyan
    $hay = @('alpha', 'beta', 'GAMMA', 'delta', 'beta again')
    Assert-That 'finds the first match'        { (Find-McViewerMatch $hay 'beta' 0) -eq 1 }
    Assert-That 'search is case-insensitive'   { (Find-McViewerMatch $hay 'gamma' 0) -eq 2 }
    Assert-That 'finds the next match'         { (Find-McViewerMatch $hay 'beta' 2) -eq 4 }
    Assert-That 'searches backwards'           { (Find-McViewerMatch $hay 'beta' 3 -Backwards) -eq 1 }
    Assert-That 'reports no match as -1'       { (Find-McViewerMatch $hay 'zeta' 0) -eq -1 }

    Write-Host "`nViewer: dispatch" -ForegroundColor Cyan
    $state.ActiveSide = 'Left'
    Set-McPanelCursor $state.Left 0
    $state.Message = $null
    Invoke-McViewCurrent $screen $state
    Assert-That 'F3 on ".." declines rather than opening a directory' {
        $state.Message -match 'F3 views files' -or $state.Message -match 'directory'
    }
} finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($script:fail -eq 0) {
    Write-Host "$script:pass passed, 0 failed" -ForegroundColor Green
    exit 0
} else {
    Write-Host "$script:pass passed, $script:fail FAILED" -ForegroundColor Red
    exit 1
}
