#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Show exactly what the input layer receives. mc has "Learn keys" for the
    same reason: when a key does not do what it should, the first question is
    whether the key even arrived, and what it was called.

.DESCRIPTION
    Prints one line per event with the canonical name mc-powershell would
    dispatch on, plus the raw Windows values behind it. Press Esc twice, or
    Ctrl+Q, to quit.

    Run this in a real terminal window -- not through a pipe, and not from
    inside an editor's output pane.

.EXAMPLE
    ./tools/keytest.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '../src/Mc.PowerShell/Mc.psd1') -Force

Write-Host ''
Write-Host 'mc-powershell input diagnostic' -ForegroundColor Cyan
Write-Host '------------------------------' -ForegroundColor Cyan

# Terminal.Init is what starts the raw input backend, so diagnostics before it
# will always say "fallback". Start it, but stay on the normal screen so the
# output scrolls and can be copied.
[Mc.Native.Input]::Start($true)
try {
    Write-Host ([Mc.Native.Input]::Diagnostics())
    Write-Host ''
    Write-Host 'Press keys. Try: Tab, letters, arrows, F-keys, Ctrl+O, and clicks.' -ForegroundColor Yellow
    Write-Host 'Esc twice or Ctrl+Q quits.' -ForegroundColor Yellow
    Write-Host ''

    $keymap = Get-McKeymap
    $lastWasEsc = $false

    while ($true) {
        $ev = [Mc.Native.Input]::Read(1000)
        if ($null -eq $ev) { continue }

        if ($ev.Kind -eq [Mc.Native.InputKind]::Mouse) {
            $line = '{0,-14} button={1,-10} at {2},{3}  pressed={4} double={5}' -f `
                'MOUSE', $ev.Button, $ev.X, $ev.Y, $ev.Pressed, $ev.Double
            Write-Host $line -ForegroundColor Magenta
            $lastWasEsc = $false
            continue
        }

        if ($ev.Kind -eq [Mc.Native.InputKind]::Resize) {
            Write-Host 'RESIZE' -ForegroundColor DarkGray
            $lastWasEsc = $false
            continue
        }

        # What the app would actually do with it.
        $bound = if ($keymap.ContainsKey($ev.Key)) { 'keymap' }
                 elseif ($ev.Key -eq 'enter') { 'enter (context-sensitive)' }
                 elseif ($ev.Key.Length -eq 1 -or $ev.Key -eq 'space') { 'command line' }
                 else { 'UNBOUND -- would do nothing' }

        $colour = if ($bound -like 'UNBOUND*') { 'Red' } else { 'Green' }
        $line = '{0,-14} vk=0x{1:x2} char=0x{2:x4} ctl=0x{3:x4}   -> {4}' -f `
            $ev.Key, $ev.RawKeyCode, [int]$ev.RawChar, $ev.RawControlState, $bound
        Write-Host $line -ForegroundColor $colour

        if ($ev.Key -eq 'C-q') { break }
        if ($ev.Key -eq 'esc') {
            if ($lastWasEsc) { break }
            $lastWasEsc = $true
        } else {
            $lastWasEsc = $false
        }
    }
} finally {
    [Mc.Native.Input]::Stop()
    Write-Host ''
    Write-Host 'Done. Paste the lines above if something is not arriving as expected.' -ForegroundColor Cyan
}
