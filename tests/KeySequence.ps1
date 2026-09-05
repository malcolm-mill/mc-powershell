#!/usr/bin/env pwsh
<#
    Drives the key dispatcher headlessly with a scripted sequence and asserts
    on the resulting state. No terminal, no input -- which is the payoff of
    keeping the panel a pure state machine.

    Modal keys (F2, F9, F3) are excluded: those block on a real key read and
    belong in an interactive test.
#>
param(
    [string] $Root = $PSScriptRoot
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '../src/Mc.PowerShell/Mc.psd1') -Force

$script:pass = 0
$script:fail = 0

function Assert-That {
    param([string] $What, [scriptblock] $Condition)
    $ok = $false
    try { $ok = [bool](& $Condition) } catch { $ok = $false }
    if ($ok) {
        $script:pass++
        Write-Host "  PASS  $What" -ForegroundColor Green
    } else {
        $script:fail++
        Write-Host "  FAIL  $What" -ForegroundColor Red
    }
}

# The repository root makes a stable fixture: it has known subdirectories.
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$screen = [Mc.Native.Screen]::new(100, 24)
$state = @{
    Left        = New-McPanel $repo
    Right       = New-McPanel 'Env:\'
    ActiveSide  = 'Left'
    CommandLine = ''
    Message     = $null
    Running     = $true
}
Write-McFrame $screen $state   # establishes Panel.Rows

Write-Host "`nPanel sources" -ForegroundColor Cyan
Assert-That 'filesystem path picks the FileSystem source' { $state.Left.Source.Name -eq 'FileSystem' }
Assert-That 'Env:\ picks the PSProvider source'           { $state.Right.Source.Name -eq 'PSProvider' }
Assert-That 'Env:\ produced rows'                          { $state.Right.Entries.Count -gt 0 }
Assert-That 'Env:\ columns differ from filesystem columns' {
    $state.Right.Columns[1].Header -ne $state.Left.Columns[1].Header
}

Write-Host "`nCursor movement" -ForegroundColor Cyan
Invoke-McKey $state $screen 'down'
Invoke-McKey $state $screen 'down'
Assert-That 'two downs land on index 2' { $state.Left.Index -eq 2 }
Invoke-McKey $state $screen 'up'
Assert-That 'up returns to index 1'     { $state.Left.Index -eq 1 }
Invoke-McKey $state $screen 'end'
Assert-That 'end lands on the last row' { $state.Left.Index -eq $state.Left.Entries.Count - 1 }
Invoke-McKey $state $screen 'home'
Assert-That 'home lands on row 0'       { $state.Left.Index -eq 0 }
Invoke-McKey $state $screen 'up'
Assert-That 'up at row 0 does not underflow' { $state.Left.Index -eq 0 }

Write-Host "`nNavigation" -ForegroundColor Cyan
# Put the cursor on the src directory and descend.
$srcIndex = -1
for ($i = 0; $i -lt $state.Left.Entries.Count; $i++) {
    if ($state.Left.Entries[$i].Name -eq 'src') { $srcIndex = $i; break }
}
Assert-That 'found the src directory' { $srcIndex -ge 0 }
Set-McPanelCursor $state.Left $srcIndex
Invoke-McKey $state $screen 'enter'
Assert-That 'Enter descended into src' { $state.Left.Location -like '*src' }
Assert-That 'src listing is not empty' { $state.Left.Entries.Count -gt 1 }

Invoke-McKey $state $screen 'backspace'
Assert-That 'Backspace returned to the repo root' { $state.Left.Location -eq $repo }
Assert-That 'cursor restored onto src' {
    (Get-McPanelCurrent $state.Left).Name -eq 'src'
}

Write-Host "`nPanel switching and marking" -ForegroundColor Cyan
Invoke-McKey $state $screen 'tab'
Assert-That 'Tab activates the right panel' { $state.ActiveSide -eq 'Right' }
Invoke-McKey $state $screen 'tab'
Assert-That 'Tab returns to the left panel' { $state.ActiveSide -eq 'Left' }

$before = (Get-McPanelStats $state.Left).MarkedCount
Invoke-McKey $state $screen 'ins'
Assert-That 'Insert marks one row'     { (Get-McPanelStats $state.Left).MarkedCount -eq $before + 1 }
Assert-That 'Insert advanced the cursor' { (Get-McPanelCurrent $state.Left).Name -ne 'src' }

Write-Host "`nHidden files" -ForegroundColor Cyan
$visible = $state.Left.Entries.Count
Invoke-McKey $state $screen 'M-.'
Assert-That 'Alt+. sets ShowHidden'          { $state.Left.ShowHidden }
Assert-That 'Alt+. reveals more rows'        { $state.Left.Entries.Count -ge $visible }
Assert-That 'the .git directory is now shown' {
    @($state.Left.Entries | Where-Object { $_.Name -eq '.git' }).Count -eq 1
}
Invoke-McKey $state $screen 'M-.'
Assert-That 'Alt+. toggles back'             { -not $state.Left.ShowHidden }

Write-Host "`nSorting" -ForegroundColor Cyan
Set-McPanelSort $state.Left ([Mc.Native.SortField]::Size)
Assert-That 'sort field changed to Size'  { $state.Left.Sort -eq [Mc.Native.SortField]::Size }
Assert-That 'first sort is ascending'     { -not $state.Left.Descending }
Set-McPanelSort $state.Left ([Mc.Native.SortField]::Size)
Assert-That 're-picking the field reverses it' { $state.Left.Descending }
Assert-That '".." stays pinned to the top' { $state.Left.Entries[0].IsUp }

Write-Host "`nCommand line" -ForegroundColor Cyan
foreach ($ch in 'g', 'c', 'i') { Invoke-McKey $state $screen $ch }
Assert-That 'typed characters reach the command line' { $state.CommandLine -eq 'gci' }
Invoke-McKey $state $screen 'space'
Assert-That 'space appends'   { $state.CommandLine -eq 'gci ' }
Invoke-McKey $state $screen 'esc'
Assert-That 'Esc clears the command line' { $state.CommandLine -eq '' }

Write-Host "`nCommand line vs. keymap (regression)" -ForegroundColor Cyan
# Backspace was bound unconditionally in the keymap, and the keymap is consulted
# before command-line editing -- so the delete-a-character branch was dead code.
# Typing then backspacing walked the panel up to the drive root instead.
$state.CommandLine = ''
$locationBefore = $state.Left.Location
foreach ($ch in 'l', 'l', 'l') { Invoke-McKey $state $screen $ch }
Assert-That 'lll reaches the command line' { $state.CommandLine -eq 'lll' }

foreach ($n in 1, 2, 3) { Invoke-McKey $state $screen 'backspace' }
Assert-That 'Backspace deletes command-line characters' { $state.CommandLine -eq '' }
Assert-That 'Backspace did not navigate while typing'   { $state.Left.Location -eq $locationBefore }

Invoke-McKey $state $screen 'backspace'
Assert-That 'Backspace on an empty command line navigates up' {
    $state.Left.Location -ne $locationBefore
}
[void](Set-McPanelLocation $state.Left $locationBefore)

# The class of bug, not just the instance: any key the keymap claims becomes
# unreachable for the command line, so printable keys must never be bound.
Assert-That 'no single printable key is bound in the keymap' {
    @((Get-McKeymap).Keys | Where-Object { $_.Length -eq 1 }).Count -eq 0
}


Write-Host "`nRendering" -ForegroundColor Cyan
# The main loop clears Message before each dispatch; do the same here, because
# a pending message deliberately overlays the function key bar.
$state.Message = $null
Write-McFrame $screen $state
$frame = $screen.Snapshot()
Assert-That 'frame has one line per screen row' { ($frame -split "`n").Count -eq 25 }
Assert-That 'every row is exactly the screen width' {
    @(($frame -split "`n") | Select-Object -SkipLast 1 | Where-Object { $_.Length -ne 100 }).Count -eq 0
}
Assert-That 'the function key bar is drawn' { $frame -match '10Quit' }
# The checkout directory is not named the same everywhere, so derive it.
$repoLeaf = [regex]::Escape((Get-McLeafName $repo))
Assert-That 'the active panel path is in the frame' { $frame -match $repoLeaf }

$state.Message = 'Hidden files: shown'
Write-McFrame $screen $state
$overlaid = $screen.Snapshot()
Assert-That 'a message overlays the key bar' { $overlaid -match 'Hidden files: shown' }
Assert-That 'the overlaid key bar is hidden'  { $overlaid -notmatch '10Quit' }

Write-Host "`nQuit" -ForegroundColor Cyan
Invoke-McKey $state $screen 'f10'
Assert-That 'F10 stops the loop' { -not $state.Running }

Write-Host ''
if ($script:fail -eq 0) {
    Write-Host "$script:pass passed, 0 failed" -ForegroundColor Green
    exit 0
} else {
    Write-Host "$script:pass passed, $script:fail FAILED" -ForegroundColor Red
    exit 1
}
