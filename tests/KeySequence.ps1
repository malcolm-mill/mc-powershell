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
$state = New-McAppState -LeftPath $repo -RightPath 'Env:'
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

# mc's [panel] section has no Backspace binding, so on an empty command line
# the key must do nothing at all -- not go up, not move the cursor.
$state.CommandLine = ''
$before = (Get-McPanelCurrent $state.Left).Name
Invoke-McKey $state $screen 'backspace'
Assert-That 'Backspace on an empty command line does not navigate' {
    $state.Left.Location -like '*src'
}
Assert-That 'and does not move the cursor' {
    (Get-McPanelCurrent $state.Left).Name -eq $before
}
$state.CommandLine = 'ab'
Invoke-McKey $state $screen 'backspace'
Assert-That 'Backspace with text deletes a character and stays put' {
    $state.CommandLine -eq 'a' -and $state.Left.Location -like '*src'
}
$state.CommandLine = ''

Write-Host "`nParent directory (mc's CdParent)" -ForegroundColor Cyan
# Ctrl+PgUp is the only way up, as in mc.
$deep = Join-Path $repo 'src'
Invoke-McKey $state $screen 'C-pgup'
Assert-That 'Ctrl+PgUp goes up a directory' { $state.Left.Location -eq $repo }
Assert-That 'and leaves the cursor on where we came from' {
    (Get-McPanelCurrent $state.Left).Name -eq 'src'
}

[void](Set-McPanelLocation $state.Left $deep)
$state.CommandLine = 'gci'
Invoke-McKey $state $screen 'C-pgup'
Assert-That 'Ctrl+PgUp navigates even with text on the command line' {
    $state.Left.Location -eq $repo -and $state.CommandLine -eq 'gci'
}
$state.CommandLine = ''

Invoke-McKey $state $screen 'C-h'
Assert-That 'Ctrl+H on an empty line does nothing, like Backspace' {
    $state.Left.Location -eq $repo
}
$state.CommandLine = 'abc'
Invoke-McKey $state $screen 'C-h'
Assert-That 'Ctrl+H deletes a character, as mc binds it in [input]' {
    $state.CommandLine -eq 'ab'
}
$state.CommandLine = ''

# Hand the state back as this section found it: the cursor on src, which the
# marking checks below rely on.
for ($i = 0; $i -lt $state.Left.Entries.Count; $i++) {
    if ($state.Left.Entries[$i].Name -eq 'src') { Set-McPanelCursor $state.Left $i; break }
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
Assert-That 'Backspace on an empty command line stays put (mc parity)' {
    $state.Left.Location -eq $locationBefore
}

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

Write-Host "`nOutput pane (mc output lines)" -ForegroundColor Cyan
$state.Message = $null
Assert-That 'the pane starts hidden' { [int]$state.OutputLines -eq 0 }

Invoke-McKey $state $screen 'C-up'
Invoke-McKey $state $screen 'C-up'
Assert-That 'Ctrl+Up grows the pane' { [int]$state.OutputLines -eq 2 }
Invoke-McKey $state $screen 'C-down'
Assert-That 'Ctrl+Down shrinks the pane' { [int]$state.OutputLines -eq 1 }
Invoke-McKey $state $screen 'C-down'
Invoke-McKey $state $screen 'C-down'
Assert-That 'the pane does not shrink past zero' { [int]$state.OutputLines -eq 0 }

# Panels must give up the rows, never the command line or the key bar.
Set-McOutputLines $state 0
Write-McFrame $screen $state
$rowsClosed = $state.Left.Rows
Set-McOutputLines $state 6
Write-McFrame $screen $state
Assert-That 'opening the pane shrinks the panels' { $state.Left.Rows -eq $rowsClosed - 6 }

$state.Message = $null
Write-McFrame $screen $state
$framed = ($screen.Snapshot() -split "`n")
Assert-That 'the key bar survives the pane' { $framed[23] -match '10Quit' }

# A read-only command runs in place and lands in the pane.
Invoke-McCommandInPane $screen $state 'Write-Output MC_PANE_MARKER'
Write-McFrame $screen $state
Assert-That 'in-pane output reaches the buffer' {
    (($state.Output) -join ' ') -match 'MC_PANE_MARKER'
}
Assert-That 'in-pane output is drawn'   { $screen.Snapshot() -match 'MC_PANE_MARKER' }
Assert-That 'the command itself is echoed' { (($state.Output) -join ' ') -match 'Write-Output' }

# The guard applies on this path too, not just via Invoke-McShellCommand.
Invoke-McCommandInPane $screen $state 'Remove-Item nosuch-file-xyz'
Assert-That 'a mutating command is refused in the pane' {
    $state.Message -match 'Read-only mode'
}
Assert-That 'the refusal is visible in the pane' {
    (($state.Output) -join ' ') -match 'refused'
}
Set-McOutputLines $state 0
$state.Message = $null

Write-Host "`nSubshell line reader (mc's toggle_subshell)" -ForegroundColor Cyan
# mc's Ctrl+O is a toggle: it takes you to the subshell and brings you back.
# Read-McShellLine reads key by key so Ctrl+O can return at once; $null means
# "go back to the panels", a string means "run this". Keys are fed from a
# queue in place of the console.
function New-Key([char] $Char, [ConsoleKey] $Key, [bool] $Ctrl = $false) {
    [ConsoleKeyInfo]::new($Char, $Key, $false, $false, $Ctrl)
}
$keyQueue = [System.Collections.Queue]::new()
$feed = { if ($keyQueue.Count -gt 0) { $keyQueue.Dequeue() } else { $null } }
function Feed-Keys { param([ConsoleKeyInfo[]] $Keys) foreach ($k in $Keys) { $keyQueue.Enqueue($k) } }
$ENTER = New-Key ([char]13) Enter
$BACK  = New-Key ([char]8)  Backspace
$CTRLO = New-Key ([char]15) O $true
$CTRLC = New-Key ([char]3)  C $true
$CTRLD = New-Key ([char]4)  D $true
$ESC   = New-Key ([char]27) Escape

Feed-Keys @((New-Key 'g' G), (New-Key 'c' C), (New-Key 'i' I), $ENTER)
Assert-That 'typed characters and Enter yield the line' {
    (Read-McShellLine -ReadKey $feed -NoEcho) -eq 'gci'
}
Feed-Keys @((New-Key 'a' A), (New-Key 'b' B), $BACK, $ENTER)
Assert-That 'Backspace edits the line' {
    (Read-McShellLine -ReadKey $feed -NoEcho) -eq 'a'
}
Feed-Keys @((New-Key 'l' L), (New-Key 's' S), (New-Key ' ' Spacebar), (New-Key '-' OemMinus), (New-Key 'l' L), $ENTER)
Assert-That 'space and punctuation reach the line' {
    (Read-McShellLine -ReadKey $feed -NoEcho) -eq 'ls -l'
}
Feed-Keys @($CTRLO)
Assert-That 'Ctrl+O on an empty line returns to the panels ($null)' {
    $null -eq (Read-McShellLine -ReadKey $feed -NoEcho)
}
Feed-Keys @((New-Key 'x' X), (New-Key 'y' Y), $CTRLO)
Assert-That 'Ctrl+O mid-line returns at once, discarding the text' {
    $null -eq (Read-McShellLine -ReadKey $feed -NoEcho) -and $keyQueue.Count -eq 0
}
Feed-Keys @((New-Key 'x' X), $CTRLC, (New-Key 'z' Z), $ENTER)
Assert-That 'Ctrl+C abandons the line and re-prompts' {
    (Read-McShellLine -ReadKey $feed -NoEcho) -eq '' -and
    (Read-McShellLine -ReadKey $feed -NoEcho) -eq 'z'
}
Feed-Keys @((New-Key 'x' X), $ESC, (New-Key 'q' Q), $ENTER)
Assert-That 'Esc clears the line' {
    (Read-McShellLine -ReadKey $feed -NoEcho) -eq 'q'
}
Feed-Keys @($CTRLD)
Assert-That 'Ctrl+D on an empty line returns to the panels' {
    $null -eq (Read-McShellLine -ReadKey $feed -NoEcho)
}
Assert-That 'end of input returns to the panels' {
    $null -eq (Read-McShellLine -ReadKey $feed -NoEcho)
}
Assert-That 'the keymap binds Ctrl+O to the subshell' {
    $null -ne (Get-McKeymap)['C-o']
}

Write-Host "`nQuit" -ForegroundColor Cyan
Invoke-McKey $state $screen 'f10'
Assert-That 'F10 stops the loop' { -not $state.Running }

Write-Host "`nProvider navigation" -ForegroundColor Cyan
# Descending on a provider other than the filesystem. This is the case that
# was missing: Convert-Path stripped the drive from every provider path, so
# Enter on a registry key went nowhere and said nothing.
$state.ActiveSide = 'Right'
Assert-That 'the right panel can open HKLM:\SOFTWARE' { Set-McPanelLocation $state.Right 'HKLM:\SOFTWARE' }
Write-McFrame $screen $state
$subkey = -1
for ($i = 0; $i -lt $state.Right.Entries.Count; $i++) {
    if ($state.Right.Entries[$i].IsContainer -and -not $state.Right.Entries[$i].IsUp) { $subkey = $i; break }
}
Assert-That 'HKLM:\SOFTWARE lists at least one subkey' { $subkey -ge 0 }
$subkeyName = $state.Right.Entries[$subkey].Name
Set-McPanelCursor $state.Right $subkey
$state.Message = $null
Invoke-McKey $state $screen 'enter'
Assert-That 'Enter descends into the subkey' {
    $state.Right.Location -eq "HKLM:\SOFTWARE\$subkeyName"
}
Assert-That 'the location stays drive-qualified, not HKEY_LOCAL_MACHINE\...' {
    $state.Right.Location -like 'HKLM:*'
}
Assert-That 'and no error was reported' { $null -eq $state.Message }
Invoke-McKey $state $screen 'C-pgup'
Assert-That 'Ctrl+PgUp returns to HKLM:\SOFTWARE' { $state.Right.Location -eq 'HKLM:\SOFTWARE' }
Assert-That 'with the cursor back on the subkey we left' {
    (Get-McPanelCurrent $state.Right).Name -eq $subkeyName
}

# A navigation that fails must say why. Point an entry at a key that does
# not exist and press Enter on it.
$ghost = $state.Right.Entries[$subkey]
$ghost.Name = 'mc-powershell-no-such-key'
$ghost.Item = $null
Set-McPanelCursor $state.Right $subkey
$state.Message = $null
Invoke-McKey $state $screen 'enter'
Assert-That 'a failed descend stays where it was' { $state.Right.Location -eq 'HKLM:\SOFTWARE' }
Assert-That 'and says why on the message line' {
    $state.Message -match 'Cannot open' -and $state.Message -match 'mc-powershell-no-such-key'
}

# A key the account cannot read is refused with the provider's reason, not
# shown as an empty key. Only asserted where this account is in fact refused,
# so an elevated CI runner cannot make it flaky.
$denied = @()
$null = Get-ChildItem 'HKLM:\SECURITY' -ErrorAction SilentlyContinue -ErrorVariable denied
if ($denied.Count -gt 0) {
    Assert-That 'an unreadable key is refused' { -not (Set-McPanelLocation $state.Right 'HKLM:\SECURITY') }
    Assert-That 'with the provider''s reason' { $state.Right.NavError -match 'not allowed' }
    Assert-That 'and the panel is still where it was' { $state.Right.Location -eq 'HKLM:\SOFTWARE' }
}

Write-Host "`nJSON documents as panels" -ForegroundColor Cyan
# Enter on a .json file descends into it, as mc enters an archive. The
# location is file::/json/pointer; Ctrl+PgUp from the root exits to the
# directory with the cursor on the file.
$fx = Join-Path $repo 'tests\fixtures'
$state.ActiveSide = 'Left'
Assert-That 'can open the fixtures directory' { Set-McPanelLocation $state.Left $fx }
Write-McFrame $screen $state
$jsonIndex = [array]::FindIndex($state.Left.Entries, [Predicate[object]]{ param($e) $e.Name -eq 'sample.json' })
Assert-That 'sample.json is listed' { $jsonIndex -ge 0 }
Set-McPanelCursor $state.Left $jsonIndex
$state.Message = $null
Invoke-McKey $state $screen 'enter'
Assert-That 'Enter on a .json file enters it' { $state.Left.Location -eq "$fx\sample.json::/" }
Assert-That 'the Json source took over' { $state.Left.Source.Name -eq 'Json' }
Assert-That 'the columns are Name, Type, Value' {
    (($state.Left.Columns | ForEach-Object Header) -join ',') -eq 'Name,Type,Value'
}
Assert-That 'children are in document order, not name order' {
    (($state.Left.Entries | Select-Object -Skip 1 | ForEach-Object Name) -join ',') -eq 'name,enabled,timeout,owner,servers,paths,notes'
}
Assert-That 'each child is typed' {
    (($state.Left.Entries | Select-Object -Skip 1 | ForEach-Object Tag) -join ',') -eq 'string,bool,number,null,array,object,string'
}
Assert-That 'objects and arrays are containers, values are leaves' {
    $c = @($state.Left.Entries | Where-Object { $_.IsContainer -and -not $_.IsUp } | ForEach-Object Name)
    ($c -join ',') -eq 'servers,paths'
}
$servers = $state.Left.Entries | Where-Object Name -eq 'servers'
Assert-That 'the Value column summarises a container' { (& $state.Left.Columns[2].Get $servers) -eq '[11 items]' }
Assert-That 'and quotes a string' {
    (& $state.Left.Columns[2].Get ($state.Left.Entries | Where-Object Name -eq 'name')) -eq '"api-gateway"'
}
Set-McPanelCursor $state.Left ([array]::IndexOf($state.Left.Entries, $servers))
Invoke-McKey $state $screen 'enter'
Assert-That 'Enter on an array descends by pointer' { $state.Left.Location -eq "$fx\sample.json::/servers" }
Assert-That 'array children are [i] in index order, [10] last' {
    $state.Left.Entries[1].Name -eq '[0]' -and $state.Left.Entries[3].Name -eq '[2]' -and $state.Left.Entries[-1].Name -eq '[10]'
}
Set-McPanelCursor $state.Left ($state.Left.Entries.Count - 1)
Invoke-McKey $state $screen 'enter'
Assert-That 'and into [10]' { $state.Left.Location -eq "$fx\sample.json::/servers/10" }
Invoke-McKey $state $screen 'C-pgup'
Assert-That 'Ctrl+PgUp goes up one level with the cursor on [10]' {
    $state.Left.Location -eq "$fx\sample.json::/servers" -and (Get-McPanelCurrent $state.Left).Name -eq '[10]'
}
Invoke-McKey $state $screen 'C-pgup'
Invoke-McKey $state $screen 'C-pgup'
Assert-That 'Ctrl+PgUp from the root exits to the directory, cursor on the file' {
    $state.Left.Location -eq $fx -and (Get-McPanelCurrent $state.Left).Name -eq 'sample.json'
}
Assert-That 'and the filesystem source is back' { $state.Left.Source.Name -eq 'FileSystem' -and -not $state.Left.SortExplicit }

Set-McPanelLocation $state.Left "$fx\sample.json::/" | Out-Null
$notes = $state.Left.Entries | Where-Object Name -eq 'notes'
Assert-That 'a string leaf views as its text, line by line' {
    ((Get-McEntryContent $state.Left $notes).Lines -join '|') -eq 'line one|line two'
}
$paths = $state.Left.Entries | Where-Object Name -eq 'paths'
Assert-That 'an object views as indented JSON' {
    $l = (Get-McEntryContent $state.Left $paths).Lines
    $l[0] -eq '{' -and $l[-1] -eq '}' -and $l.Count -eq 4
}
Set-McPanelCursor $state.Left ([array]::IndexOf($state.Left.Entries, $paths))
Invoke-McKey $state $screen 'enter'
Assert-That 'keys with / and ~ are escaped in the pointer and shown unescaped' {
    $state.Left.Entries[1].Name -eq 'a/b' -and $state.Left.Entries[1].Key -eq "$fx\sample.json::/paths/a~1b" -and
    $state.Left.Entries[2].Name -eq 'c~d' -and $state.Left.Entries[2].Key -eq "$fx\sample.json::/paths/c~0d"
}
Assert-That 'the leaf name of an escaped key is the key' {
    (& $state.Left.Source.LeafName $state.Left.Entries[1].Key) -eq 'a/b'
}

Set-McPanelLocation $state.Left $fx | Out-Null
Set-McPanelCursor $state.Left ([array]::FindIndex($state.Left.Entries, [Predicate[object]]{ param($e) $e.Name -eq 'broken.json' }))
$state.Message = $null
Invoke-McKey $state $screen 'enter'
Assert-That 'a broken document is refused, staying in the directory' { $state.Left.Location -eq $fx }
Assert-That 'with the parser''s reason on the message line' { $state.Message -match 'Cannot open' -and $state.Message -match 'JSON' }

Write-Host "`nXML documents as panels" -ForegroundColor Cyan
# Same mechanism as JSON. Elements are containers; attributes come first as
# @name rows; [n] appears only where siblings share a name. Names are read
# through getter methods because PowerShell's XML adapter lets a child
# element called <name> shadow the element's own .Name.
Set-McPanelLocation $state.Left $fx | Out-Null
Set-McPanelCursor $state.Left ([array]::FindIndex($state.Left.Entries, [Predicate[object]]{ param($e) $e.Name -eq 'sample.xml' }))
$state.Message = $null
Invoke-McKey $state $screen 'enter'
Assert-That 'Enter on a .xml file enters it' { $state.Left.Location -eq "$fx\sample.xml::/" -and $state.Left.Source.Name -eq 'Xml' }
Assert-That 'the document root lists the declaration, the comment and the root element' {
    (($state.Left.Entries | Select-Object -Skip 1 | ForEach-Object { "$($_.Name):$($_.Tag)" }) -join ',') -eq '?xml:xml,#comment:comment,project:element'
}
Assert-That 'the root element is named project, not by its <name> child' {
    ($state.Left.Entries | Where-Object Tag -eq 'element').Name -eq 'project'
}
Set-McPanelCursor $state.Left ($state.Left.Entries.Count - 1)
Invoke-McKey $state $screen 'enter'
Assert-That 'Enter descends into the element' { $state.Left.Location -eq "$fx\sample.xml::/project" }
Assert-That 'attributes come first as @name rows, then children in document order' {
    (($state.Left.Entries | Select-Object -Skip 1 | ForEach-Object Name) -join ',') -eq '@xmlns,@version,name,dependencies,description,mixed'
}
Assert-That 'attributes are leaves with their value' {
    $v = $state.Left.Entries | Where-Object Name -eq '@version'
    -not $v.IsContainer -and (& $state.Left.Columns[2].Get $v) -eq '4'
}
Assert-That 'a simple element shows its text in the Value column' {
    (& $state.Left.Columns[2].Get ($state.Left.Entries | Where-Object Name -eq 'name')) -eq 'demo'
}
Assert-That 'a complex element shows a summary' {
    (& $state.Left.Columns[2].Get ($state.Left.Entries | Where-Object Name -eq 'dependencies')) -eq '3 elements'
}
Set-McPanelCursor $state.Left ([array]::FindIndex($state.Left.Entries, [Predicate[object]]{ param($e) $e.Name -eq 'dependencies' }))
Invoke-McKey $state $screen 'enter'
Assert-That 'repeated siblings get positional names' {
    (($state.Left.Entries | Select-Object -Skip 1 | ForEach-Object Name) -join ',') -eq 'dependency[1],dependency[2],dependency[3]'
}
Set-McPanelCursor $state.Left 2
Invoke-McKey $state $screen 'enter'
Assert-That 'and the location carries the position' { $state.Left.Location -eq "$fx\sample.xml::/project/dependencies/dependency[2]" }
Assert-That 'which resolves to the right element' {
    (& $state.Left.Columns[2].Get ($state.Left.Entries | Where-Object Name -eq 'artifactId')) -eq 'beta'
}
Invoke-McKey $state $screen 'C-pgup'
Assert-That 'Ctrl+PgUp lands on dependency[2]' { (Get-McPanelCurrent $state.Left).Name -eq 'dependency[2]' }
$dep2 = Get-McPanelCurrent $state.Left
Assert-That 'F3 on an element shows it as indented XML' {
    $l = (Get-McEntryContent $state.Left $dep2).Lines
    $l[0] -match '^<dependency scope="test"' -and $l[-1] -eq '</dependency>' -and $l.Count -eq 4
}
Invoke-McKey $state $screen 'C-pgup'
Invoke-McKey $state $screen 'C-pgup'
Invoke-McKey $state $screen 'C-pgup'
Assert-That 'Ctrl+PgUp from the root exits to the directory, cursor on the file' {
    $state.Left.Location -eq $fx -and (Get-McPanelCurrent $state.Left).Name -eq 'sample.xml'
}
Set-McPanelLocation $state.Left "$fx\sample.xml::/project/mixed" | Out-Null
Assert-That 'mixed content lists text and elements in order' {
    (($state.Left.Entries | Select-Object -Skip 1 | ForEach-Object { "$($_.Name):$($_.Tag)" }) -join ',') -eq '#text[1]:text,b:element,#text[2]:text'
}
Set-McPanelLocation $state.Left "$fx\sample.xml::/project/description" | Out-Null
Assert-That 'CDATA is a leaf whose content is the raw text' {
    $c = $state.Left.Entries[1]
    $c.Tag -eq 'cdata' -and ((Get-McEntryContent $state.Left $c).Lines -join '') -eq 'raw <text> here'
}
Assert-That 'a .csproj counts as XML' { (& $state.Left.Source.Open 'C:\nowhere\x.csproj') -eq $null -and (Test-McXmlFile 'x.csproj') }

Write-Host "`nDrive chooser targets" -ForegroundColor Cyan
# Cert: reports its root as "\", which Test-Path accepts as the root of the
# current filesystem drive, so the chooser opened C:\ under the name Cert:.
$byName = @{}
foreach ($d in (Get-PSDrive | Where-Object Provider)) { $byName[$d.Name] = $d }
Assert-That 'a filesystem drive opens at its root' { (Get-McDriveLocation $byName['C']) -eq 'C:\' }
Assert-That 'Cert: opens at Cert:\ and not at \' { (Get-McDriveLocation $byName['Cert']) -eq 'Cert:\' }
Assert-That 'HKLM: opens at HKLM:\' { (Get-McDriveLocation $byName['HKLM']) -eq 'HKLM:\' }
Assert-That 'Env: opens at Env:\' { (Get-McDriveLocation $byName['Env']) -eq 'Env:\' }
Assert-That 'Cert:\ lists the certificate stores' {
    (Set-McPanelLocation $state.Right 'Cert:') -and
    @($state.Right.Entries | Where-Object { $_.Name -in 'CurrentUser', 'LocalMachine' }).Count -eq 2
}
Assert-That 'and the title says so' { (& $state.Right.Source.Title $state.Right.Location) -match 'Certificate' }

Write-Host "`nCertificates by name" -ForegroundColor Cyan
# A certificate's PSChildName is its thumbprint, which identifies it and says
# nothing. The panel names it by what it says and keeps the thumbprint as key.
Assert-That 'can open the trusted root store' { Set-McPanelLocation $state.Right 'Cert:\LocalMachine\Root' }
Assert-That 'the columns are Name, Issued by, Expires' {
    (($state.Right.Columns | ForEach-Object Header) -join ',') -eq 'Name,Issued by,Expires'
}
$cert = $state.Right.Entries | Where-Object { -not $_.IsContainer } | Select-Object -First 1
Assert-That 'a root store lists certificates' { $null -ne $cert }
Assert-That 'a certificate is named by its subject or friendly name, not its thumbprint' {
    $cert.Name -eq (Get-McCertificateName $cert.Item) -and $cert.Name -ne $cert.Item.Thumbprint
}
Assert-That 'a root certificate is self-signed' { (& $state.Right.Columns[1].Get $cert) -eq 'self-signed' }
Assert-That 'the Expires column is a date' { (& $state.Right.Columns[2].Get $cert) -match '^\d{4}-\d{2}-\d{2}$' }
$cc = Get-McEntryContent $state.Right $cert
Assert-That 'Enter/F3 content carries subject, issuer, validity and thumbprint' {
    ($cc.Lines -join "`n") -match 'Subject:' -and ($cc.Lines -join "`n") -match 'Issuer:' -and
    ($cc.Lines -join "`n") -match 'Valid to:' -and ($cc.Lines -join "`n") -match "Thumbprint:\s+$($cert.Item.Thumbprint)"
}
Assert-That 'a store row has no viewer content' {
    Set-McPanelLocation $state.Right 'Cert:\' | Out-Null
    $null -eq (Get-McEntryContent $state.Right ($state.Right.Entries | Where-Object { $_.Name -eq 'CurrentUser' }))
}

Write-Host "`nRegistry values as rows" -ForegroundColor Cyan
# The registry provider's children are keys only. A registry browser must show
# values too, so the source appends one leaf row per value under the subkeys.
$cv = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
Assert-That 'can open Windows NT\CurrentVersion' { Set-McPanelLocation $state.Right $cv }
$keys = @($state.Right.Entries | Where-Object { $_.IsContainer -and -not $_.IsUp })
$values = @($state.Right.Entries | Where-Object { -not $_.IsContainer })
Assert-That 'the listing has both subkeys and values' { $keys.Count -gt 0 -and $values.Count -gt 0 }
Assert-That 'values are leaves tagged with their type' {
    @($values | Where-Object { $_.Tag -notlike 'REG_*' }).Count -eq 0
}
Assert-That 'keys sort before values, as directories before files' {
    $lastKey = -1; $firstValue = [int]::MaxValue
    for ($i = 0; $i -lt $state.Right.Entries.Count; $i++) {
        $e = $state.Right.Entries[$i]
        if ($e.IsContainer -and -not $e.IsUp) { $lastKey = $i }
        elseif (-not $e.IsContainer -and $i -lt $firstValue) { $firstValue = $i }
    }
    $lastKey -lt $firstValue
}
Assert-That 'the columns are Name, Type, Data' {
    (($state.Right.Columns | ForEach-Object Header) -join ',') -eq 'Name,Type,Data'
}
$build = $state.Right.Entries | Where-Object { $_.Name -eq 'CurrentBuild' } | Select-Object -First 1
Assert-That 'CurrentBuild is listed as a REG_SZ value' { $null -ne $build -and $build.Tag -eq 'REG_SZ' }
Assert-That 'the Data column shows its data' {
    (& $state.Right.Columns[2].Get $build) -match '^\d+$'
}
$content = Get-McEntryContent $state.Right $build
Assert-That 'Enter/F3 content names the key, value and type' {
    $content.Lines[0] -like "Key:  $cv" -and $content.Lines[1] -eq 'Name: CurrentBuild' -and $content.Lines[2] -eq 'Type: REG_SZ'
}
Assert-That 'and ends with the data' { $content.Lines[$content.Lines.Count - 1] -match '^\d+$' }
Assert-That 'a key row has no viewer content' {
    $null -eq (Get-McEntryContent $state.Right $state.Right.Entries[1])
}
Assert-That 'DWORD data is shown as hex and decimal' { (Format-McRegistryData 'REG_DWORD' 26200) -eq '0x00006658 (26200)' }
Assert-That 'MULTI_SZ data is joined' { (Format-McRegistryData 'REG_MULTI_SZ' @('a', 'b')) -eq 'a | b' }
Assert-That 'BINARY data is a hex head with a byte count' {
    (Format-McRegistryData 'REG_BINARY' ([byte[]](1, 2, 255))) -eq '01 02 ff (3 bytes)'
}
Assert-That 'an Env: entry has its value as content' {
    Set-McPanelLocation $state.Right 'Env:' | Out-Null
    $path = $state.Right.Entries | Where-Object { $_.Name -eq 'PATH' } | Select-Object -First 1
    $c = Get-McEntryContent $state.Right $path
    $null -ne $c -and ($c.Lines -join '') -eq $env:PATH
}

Write-Host ''
if ($script:fail -eq 0) {
    Write-Host "$script:pass passed, 0 failed" -ForegroundColor Green
    exit 0
} else {
    Write-Host "$script:pass passed, $script:fail FAILED" -ForegroundColor Red
    exit 1
}
