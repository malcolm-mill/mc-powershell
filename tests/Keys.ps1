#!/usr/bin/env pwsh
<#
    The keyboard path, end to end, without a terminal.

    This covers the seam that had no tests and where tab and typing broke: raw
    Windows key event -> canonical name -> what the app actually does with it.
    Keys.DescribeConsoleKey is a pure function precisely so this is possible.

    What is NOT covered here is ReadConsoleInput itself -- whether the console
    hands us the record at all. tools/keytest.ps1 answers that on a real
    terminal.
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

# Windows virtual key codes.
$VK = @{
    Back = 0x08; Tab = 0x09; Enter = 0x0D; Esc = 0x1B; Space = 0x20
    PgUp = 0x21; PgDn = 0x22; End = 0x23; Home = 0x24
    Left = 0x25; Up = 0x26; Right = 0x27; Down = 0x28
    Ins = 0x2D; Del = 0x2E
    A = 0x41; G = 0x47; I = 0x49; O = 0x4F; R = 0x52; U = 0x55; Z = 0x5A
    D0 = 0x30; D9 = 0x39
    F1 = 0x70; F3 = 0x72; F5 = 0x74; F9 = 0x78; F10 = 0x79; F12 = 0x7B
    Shift = 0x10; Ctrl = 0x11; Alt = 0x12; CapsLock = 0x14
    Period = 0xBE
}
$CTRL = 0x0008; $ALT = 0x0002; $SHIFT = 0x0010
$NUMLOCK = 0x0020; $CAPSLOCK = 0x0080; $ENHANCED = 0x0100

function Name {
    param([int] $Vk, [int] $Char = 0, [uint32] $Ctl = 0, [bool] $Down = $true)
    [Mc.Native.Keys]::DescribeConsoleKey($Vk, [char]$Char, [uint32]$Ctl, $Down)
}

function Assert-Name {
    param([string] $Expected, [int] $Vk, [int] $Char = 0, [uint32] $Ctl = 0)
    Assert-That "vk 0x$('{0:x2}' -f $Vk) -> '$Expected'" { (Name $Vk $Char $Ctl) -eq $Expected }
}

Write-Host "`nTranslation: the keys tab and typing depend on" -ForegroundColor Cyan
Assert-Name 'tab'   $VK.Tab 9
Assert-Name 'a'     $VK.A 0x61
Assert-Name 'A'     $VK.A 0x41 $SHIFT
Assert-Name 'z'     $VK.Z 0x7a
Assert-Name '0'     $VK.D0 0x30
Assert-Name '9'     $VK.D9 0x39
Assert-Name 'space' $VK.Space 0x20
Assert-Name 'enter' $VK.Enter 13
Assert-Name 'backspace' $VK.Back 8
Assert-Name 'esc'   $VK.Esc 27

Write-Host "`nTranslation: navigation and function keys" -ForegroundColor Cyan
Assert-Name 'up'    $VK.Up 0 $ENHANCED
Assert-Name 'down'  $VK.Down 0 $ENHANCED
Assert-Name 'left'  $VK.Left 0 $ENHANCED
Assert-Name 'right' $VK.Right 0 $ENHANCED
Assert-Name 'home'  $VK.Home
Assert-Name 'end'   $VK.End
Assert-Name 'pgup'  $VK.PgUp
Assert-Name 'pgdn'  $VK.PgDn
Assert-Name 'ins'   $VK.Ins
Assert-Name 'del'   $VK.Del
Assert-Name 'f1'    $VK.F1
Assert-Name 'f3'    $VK.F3
Assert-Name 'f5'    $VK.F5
Assert-Name 'f9'    $VK.F9
Assert-Name 'f10'   $VK.F10
Assert-Name 'f12'   $VK.F12

Write-Host "`nTranslation: modifiers" -ForegroundColor Cyan
Assert-Name 'C-o'   $VK.O 15 $CTRL
Assert-Name 'C-r'   $VK.R 18 $CTRL
Assert-Name 'C-u'   $VK.U 21 $CTRL
Assert-Name 'C-up'  $VK.Up 0 ($CTRL -bor $ENHANCED)
Assert-Name 'C-down' $VK.Down 0 ($CTRL -bor $ENHANCED)
Assert-Name 'S-f3'  $VK.F3 0 $SHIFT
# Windows sends UnicodeChar 0 for Alt combinations, so this needs the OEM table.
Assert-Name 'M-.'   $VK.Period 0 $ALT

Write-Host "`nTranslation: what must NOT become an event" -ForegroundColor Cyan
Assert-That 'a key release is ignored'  { $null -eq (Name $VK.A 0x61 0 $false) }
Assert-That 'bare Shift is ignored'     { $null -eq (Name $VK.Shift 0 $SHIFT) }
Assert-That 'bare Ctrl is ignored'      { $null -eq (Name $VK.Ctrl 0 $CTRL) }
Assert-That 'bare Alt is ignored'       { $null -eq (Name $VK.Alt 0 $ALT) }
Assert-That 'CapsLock itself is ignored' { $null -eq (Name $VK.CapsLock) }

Write-Host "`nTranslation: lock keys must not look like modifiers" -ForegroundColor Cyan
Assert-That 'NumLock does not turn a into something else'  { (Name $VK.A 0x61 $NUMLOCK) -eq 'a' }
Assert-That 'CapsLock does not add a Shift prefix'         { (Name $VK.A 0x41 $CAPSLOCK) -eq 'A' }
Assert-That 'Enhanced flag does not disturb Tab'           { (Name $VK.Tab 9 $ENHANCED) -eq 'tab' }
Assert-That 'NumLock does not disturb Tab'                 { (Name $VK.Tab 9 $NUMLOCK) -eq 'tab' }
Assert-That 'ScrollLock does not disturb Tab'              { (Name $VK.Tab 9 0x0040) -eq 'tab' }

# --- the part that actually broke: does the app respond? -------------------

$repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$screen = [Mc.Native.Screen]::new(100, 24)
$state = New-McAppState -LeftPath $repo -RightPath 'Env:'
Write-McFrame $screen $state

function Send {
    <# The real chain, minus ReadConsoleInput: raw event -> name -> dispatch. #>
    param([int] $Vk, [int] $Char = 0, [uint32] $Ctl = 0)
    $name = Name $Vk $Char $Ctl
    if ($null -eq $name) { return $null }
    Invoke-McKey $state $screen $name
    $name
}

Write-Host "`nTab cycles between panels" -ForegroundColor Cyan
$state.ActiveSide = 'Left'
[void](Send $VK.Tab 9)
Assert-That 'Tab moves focus to the right panel' { $state.ActiveSide -eq 'Right' }
[void](Send $VK.Tab 9)
Assert-That 'Tab moves focus back to the left'   { $state.ActiveSide -eq 'Left' }
[void](Send $VK.Tab 9)
[void](Send $VK.Tab 9)
[void](Send $VK.Tab 9)
Assert-That 'an odd number of Tabs ends on the right' { $state.ActiveSide -eq 'Right' }
[void](Send $VK.Tab 9)

Assert-That 'Tab still cycles with NumLock on' {
    $before = $state.ActiveSide
    [void](Send $VK.Tab 9 $NUMLOCK)
    $state.ActiveSide -ne $before
}
[void](Send $VK.Tab 9)

Write-Host "`nThe command line accepts text" -ForegroundColor Cyan
$state.CommandLine = ''
foreach ($pair in @(@($VK.G, 0x67), @($VK.I, 0x69))) { [void](Send $pair[0] $pair[1]) }
Assert-That 'letters reach the command line' { $state.CommandLine -eq 'gi' }

[void](Send $VK.Space 0x20)
Assert-That 'space reaches the command line' { $state.CommandLine -eq 'gi ' }

foreach ($pair in @(@($VK.A, 0x61), @($VK.Z, 0x7a))) { [void](Send $pair[0] $pair[1]) }
Assert-That 'more letters append'  { $state.CommandLine -eq 'gi az' }

[void](Send $VK.A 0x41 $SHIFT)
Assert-That 'shifted letters arrive as capitals' { $state.CommandLine -eq 'gi azA' }

[void](Send $VK.D9 0x39)
Assert-That 'digits reach the command line' { $state.CommandLine -eq 'gi azA9' }

[void](Send $VK.Back 8)
Assert-That 'Backspace deletes a character' { $state.CommandLine -eq 'gi azA' }

[void](Send $VK.Esc 27)
Assert-That 'Esc clears the command line' { $state.CommandLine -eq '' }

Assert-That 'typing does not move the panel cursor' {
    $before = $state[$state.ActiveSide].Index
    foreach ($pair in @(@($VK.A, 0x61), @($VK.Z, 0x7a))) { [void](Send $pair[0] $pair[1]) }
    $state[$state.ActiveSide].Index -eq $before -and $state.CommandLine -eq 'az'
}
$state.CommandLine = ''

Write-Host "`nNavigation keys still act on the panel" -ForegroundColor Cyan
$panel = $state[$state.ActiveSide]
Set-McPanelCursor $panel 0
[void](Send $VK.Down 0 $ENHANCED)
[void](Send $VK.Down 0 $ENHANCED)
Assert-That 'Down moves the cursor'  { $panel.Index -eq 2 }
[void](Send $VK.Up 0 $ENHANCED)
Assert-That 'Up moves the cursor'    { $panel.Index -eq 1 }

Write-Host "`nEvery key the app binds is reachable from a real key press" -ForegroundColor Cyan
# The guard that would have caught a name mismatch between C# and the keymap:
# each binding must be producible by some Windows key event.
$reachable = @{}
foreach ($vk in 0x08..0xFF) {
    foreach ($ctl in @(0, $CTRL, $ALT, $SHIFT, ($CTRL -bor $ALT))) {
        $n = Name $vk 0 $ctl
        if ($n) { $reachable[$n] = $true }
    }
}
# Printable keys carry their glyph rather than a virtual key code.
foreach ($c in [char[]]'abcdefghijklmnopqrstuvwxyz0123456789') { $reachable[[string]$c] = $true }

$unreachable = @((Get-McKeymap).Keys | Where-Object { -not $reachable.ContainsKey($_) })
Assert-That 'no keymap binding is unreachable' { $unreachable.Count -eq 0 }
if ($unreachable.Count -gt 0) {
    Write-Host "        unreachable: $($unreachable -join ', ')" -ForegroundColor Red
}

Write-Host ''
if ($script:fail -eq 0) {
    Write-Host "$script:pass passed, 0 failed" -ForegroundColor Green
    exit 0
} else {
    Write-Host "$script:pass passed, $script:fail FAILED" -ForegroundColor Red
    exit 1
}
