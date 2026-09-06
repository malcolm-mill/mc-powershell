# ---------------------------------------------------------------------------
# The application: key dispatch, modal dialogs, and the main loop.
#
# Key handling is a lookup table from canonical key name to a scriptblock, so
# a keymap file can replace it wholesale later without touching this code.
# ---------------------------------------------------------------------------

function Get-McActivePanel {
    param([hashtable] $State)
    $State[$State.ActiveSide]
}

function Get-McInactivePanel {
    param([hashtable] $State)
    $State[$(if ($State.ActiveSide -eq 'Left') { 'Right' } else { 'Left' })]
}

# --- modal helpers ---------------------------------------------------------

function Show-McList {
    <#
      Generic centred list picker. Returns the chosen item, or $null on escape.
      Used for the drive chooser and the sort menu.
    #>
    param(
        $Screen,
        [hashtable] $State,
        [string] $Title,
        [array] $Items,
        [scriptblock] $Display
    )

    if ($Items.Count -eq 0) { return $null }

    $t = $script:McTheme
    $index = 0
    $maxRows = [Math]::Min($Items.Count, [Math]::Max(3, $Screen.Height - 8))

    $width = $Title.Length + 6
    foreach ($item in $Items) {
        $len = ([string](& $Display $item)).Length + 6
        if ($len -gt $width) { $width = $len }
    }
    $width = [Math]::Min($width, $Screen.Width - 4)
    $height = $maxRows + 4
    $x = [int](($Screen.Width - $width) / 2)
    $y = [int](($Screen.Height - $height) / 2)

    $top = 0
    while ($true) {
        if ($index -lt $top) { $top = $index }
        if ($index -ge $top + $maxRows) { $top = $index - $maxRows + 1 }

        Write-McFrame $Screen $State

        $Screen.Fill($x, $y, $width, $height, ' ', [byte]$t.DialogFg, [byte]$t.DialogBg, $script:AttrNone)
        $Screen.Box($x, $y, $width, $height, [byte]$t.DialogFg, [byte]$t.DialogBg, $true)

        $caption = " $Title "
        [void]$Screen.Write($x + [int](($width - $caption.Length) / 2), $y, $caption,
            [byte]$t.DialogTitleFg, [byte]$t.DialogTitleBg, $script:AttrBold)

        for ($r = 0; $r -lt $maxRows; $r++) {
            $i = $top + $r
            $rowY = $y + 2 + $r
            if ($i -ge $Items.Count) {
                $Screen.Fill($x + 2, $rowY, $width - 4, 1, ' ', [byte]$t.DialogFg, [byte]$t.DialogBg, $script:AttrNone)
                continue
            }
            $text = [string](& $Display $Items[$i])
            if ($i -eq $index) {
                $Screen.WriteFixed($x + 2, $rowY, $text, $width - 4, [byte]$t.CursorFg, [byte]$t.CursorBg, $script:AttrBold)
            } else {
                $Screen.WriteFixed($x + 2, $rowY, $text, $width - 4, [byte]$t.DialogFg, [byte]$t.DialogBg, $script:AttrNone)
            }
        }

        $Screen.Flush()

        $ev = [Mc.Native.Input]::Read(200)
        if ($null -eq $ev) { continue }

        if ($ev.Kind -eq [Mc.Native.InputKind]::Mouse) {
            if (-not $ev.Pressed) { continue }
            if ($ev.Button -eq 'wheelup') { if ($index -gt 0) { $index-- }; continue }
            if ($ev.Button -eq 'wheeldown') { if ($index -lt $Items.Count - 1) { $index++ }; continue }

            $row = $ev.Y - ($y + 2)
            $inside = $ev.X -ge $x -and $ev.X -lt $x + $width -and $row -ge 0 -and $row -lt $maxRows
            if (-not $inside) { return $null }          # click outside dismisses
            $i = $top + $row
            if ($i -ge $Items.Count) { continue }
            if ($i -eq $index -or $ev.Double) { return $Items[$i] }
            $index = $i
            continue
        }

        switch ($ev.Key) {
            'up'    { if ($index -gt 0) { $index-- } }
            'down'  { if ($index -lt $Items.Count - 1) { $index++ } }
            'home'  { $index = 0 }
            'end'   { $index = $Items.Count - 1 }
            'pgup'  { $index = [Math]::Max(0, $index - $maxRows) }
            'pgdn'  { $index = [Math]::Min($Items.Count - 1, $index + $maxRows) }
            'enter' { return $Items[$index] }
            'esc'   { return $null }
            'f10'   { return $null }
        }
    }
}

function Show-McDriveChooser {
    <#
      The demo of the whole thesis: pick any PSDrive -- filesystem, registry,
      environment, certificates, or anything a module mounted -- and the panel
      shows it with columns appropriate to that provider.
    #>
    param($Screen, [hashtable] $State, [string] $Side)

    $drives = @(Get-PSDrive -ErrorAction SilentlyContinue |
        Where-Object { $_.Provider } |
        Sort-Object { $_.Provider.Name }, Name)

    $choice = Show-McList $Screen $State 'Change drive or provider' $drives {
        param($d)
        '{0,-12} {1,-14} {2}' -f "$($d.Name):", $d.Provider.Name, $d.Root
    }
    if ($null -eq $choice) { return }

    $panel = if ($Side) { $State[$Side] } else { Get-McActivePanel $State }
    $target = if ($choice.Root -and (Test-Path -LiteralPath $choice.Root -ErrorAction SilentlyContinue)) {
        $choice.Root
    } else {
        "$($choice.Name):\"
    }

    if (-not (Set-McPanelLocation $panel $target)) {
        $State.Message = "Cannot open $target"
    }
    $Screen.Invalidate()
}

function Show-McSortMenu {
    param($Screen, [hashtable] $State, [string] $Side)

    $fields = @(
        @{ Label = 'Name';        Field = [Mc.Native.SortField]::Name }
        @{ Label = 'Extension';   Field = [Mc.Native.SortField]::Extension }
        @{ Label = 'Size';        Field = [Mc.Native.SortField]::Size }
        @{ Label = 'Modify time'; Field = [Mc.Native.SortField]::Modified }
        @{ Label = 'Unsorted';    Field = [Mc.Native.SortField]::Unsorted }
    )

    $choice = Show-McList $Screen $State 'Sort order' $fields { param($f) $f.Label }
    if ($null -eq $choice) { return }
    $panel = if ($Side) { $State[$Side] } else { Get-McActivePanel $State }
    Set-McPanelSort $panel $choice.Field
    $Screen.Invalidate()
}

function Invoke-McCommandInPane {
    <#
      Run a command without leaving the panels, capturing its output into the
      pane. Errors are captured too (2>&1) so a failure is visible in place
      rather than silently swallowed.
    #>
    param($Screen, [hashtable] $State, [string] $Command)

    # Screened here as well as in Invoke-McShellCommand: this is an exported
    # entry point, and a guard that only one caller applies is not a guard.
    if (-not (Test-McWritable)) {
        $reasons = @(Test-McCommandMutates $Command)
        if ($reasons.Count -gt 0) {
            Add-McOutput $State @("Read-only mode: refused -- $($reasons[0])")
            $State.Message = "Read-only mode: refused -- $($reasons[0])"
            return
        }
    }

    $panel = Get-McActivePanel $State
    Add-McOutput $State @("$($panel.Location)> $Command")

    Push-Location -LiteralPath $panel.Location -ErrorAction SilentlyContinue
    try {
        if (-not (Test-McWritable)) { $WhatIfPreference = $true }

        $width = [Math]::Max(40, $Screen.Width - 1)
        $text = ''
        try {
            $text = Invoke-Expression $Command 2>&1 | Out-String -Width $width
        } catch {
            $text = $_.Exception.Message
        }

        if (-not [string]::IsNullOrEmpty($text)) {
            $lines = $text -split "`r?`n"
            # Out-String pads with a trailing blank; do not let it eat a row.
            while ($lines.Count -gt 0 -and [string]::IsNullOrWhiteSpace($lines[-1])) {
                $lines = $lines[0..($lines.Count - 2)]
            }
            Add-McOutput $State $lines
        }
    } finally {
        Pop-Location -ErrorAction SilentlyContinue
    }

    Update-McPanel $State.Left
    Update-McPanel $State.Right
}

function Invoke-McShellCommand {
    <# Leave the alternate screen, run the command, come back. #>
    param($Screen, [hashtable] $State, [string] $Command)

    if ([string]::IsNullOrWhiteSpace($Command)) { return }

    # First layer: screen the command before it ever runs.
    if (-not (Test-McWritable)) {
        $reasons = @(Test-McCommandMutates $Command)
        if ($reasons.Count -gt 0) {
            $State.Message = "Read-only mode: refused -- $($reasons[0])"
            return
        }
    }

    $panel = Get-McActivePanel $State

    # With the output pane open, run without leaving the panels and put the
    # result in the pane. mc can only do this on a Linux virtual console
    # (it reads the physical console buffer); we own the renderer, so it
    # works everywhere.
    if ([int]$State.OutputLines -gt 0) {
        Invoke-McCommandInPane $Screen $State $Command
        return
    }

    [Mc.Native.Terminal]::Shutdown()
    try {
        Push-Location -LiteralPath $panel.Location -ErrorAction SilentlyContinue
        Write-Host "$($panel.Location)> $Command"
        # Second layer: anything ShouldProcess-aware that slipped past the
        # screen reports what it would do instead of doing it. Scoped to this
        # function, so it cannot leak into the rest of the session.
        if (-not (Test-McWritable)) { $WhatIfPreference = $true }
        try { Invoke-Expression $Command | Out-Host }
        catch { Write-Host $_.Exception.Message -ForegroundColor Red }
        Pop-Location -ErrorAction SilentlyContinue
        Write-Host ''
        Write-Host 'Press any key to return to mc-powershell...' -ForegroundColor DarkGray
        [void][Console]::ReadKey($true)
    } finally {
        [Mc.Native.Terminal]::Init()
        $Screen.Invalidate()
    }

    Update-McPanel $State.Left
    Update-McPanel $State.Right
}

# --- application state -----------------------------------------------------

function New-McAppState {
    <#
      One place that knows the shape of app state, so Start-Mc and the tests
      cannot drift apart as fields are added.
    #>
    param(
        [string] $LeftPath = (Get-Location).Path,
        [string] $RightPath = (Get-Location).Path
    )
    @{
        Left        = New-McPanel $LeftPath
        Right       = New-McPanel $RightPath
        ActiveSide  = 'Left'
        CommandLine = ''
        Message     = $null
        Running     = $true

        # mc calls this "output lines" (Options > Layout): rows of shell output
        # kept on screen underneath the panels. 0 hides the pane.
        OutputLines = 0
        Output      = [System.Collections.Generic.List[string]]::new()
    }
}

function Add-McOutput {
    <# Append to the output ring buffer, oldest lines falling off the top. #>
    param([hashtable] $State, [string[]] $Lines)

    if ($null -eq $Lines) { return }
    foreach ($line in $Lines) { [void]$State.Output.Add($line) }

    $limit = 500
    while ($State.Output.Count -gt $limit) { $State.Output.RemoveAt(0) }
}

function Set-McOutputLines {
    param([hashtable] $State, [int] $Lines)

    if ($Lines -lt 0) { $Lines = 0 }
    if ($Lines -gt 30) { $Lines = 30 }
    $State.OutputLines = $Lines
    $State.Message = if ($Lines -eq 0) { 'Output pane hidden' } else { "Output pane: $Lines lines" }
}

# Where the subshell gets its keys. A script variable so tests can feed a
# scripted sequence instead of the console.
$script:McShellReadKey = { [Console]::ReadKey($true) }

function Read-McShellLine {
    <#
      One line of input for the subshell, read key by key so that Ctrl+O can
      return to the panels immediately -- mc's toggle_subshell -- instead of
      being swallowed by the host's cooked-mode ReadLine.

      Returns the line, or $null when the caller should go back to the panels:
      Ctrl+O, Ctrl+D on an empty line, or end of input.

      Editing is deliberately basic: characters, Backspace, Esc to clear the
      line, Ctrl+C to abandon it. No cursor movement, history or completion;
      a PSReadLine-backed editor is M4.
    #>
    param(
        [scriptblock] $ReadKey = $script:McShellReadKey,
        [switch] $NoEcho
    )

    # Line ends must be CR+LF: Terminal.Init sets DISABLE_NEWLINE_AUTO_RETURN
    # and a bare LF then only moves down, staircasing the prompt to the right.
    $echo = { param([string] $Text) if (-not $NoEcho) { Write-Host $Text -NoNewline } }

    & $echo "$((Get-Location).Path)> "
    $line = [System.Text.StringBuilder]::new()

    # Ctrl+C must reach us as a key here, not stop the pipeline; put it back
    # afterwards so a long-running command can still be interrupted.
    $savedCtrlC = $false
    try { $savedCtrlC = [Console]::TreatControlCAsInput; [Console]::TreatControlCAsInput = $true } catch { }
    try {
        while ($true) {
            $k = $null
            try { $k = & $ReadKey } catch { $k = $null }
            if ($null -eq $k) { & $echo "`r`n"; return $null }         # EOF

            # An if-chain, not a switch: inside a PowerShell switch, 'continue'
            # continues the switch, not this loop, and the key falls through.
            $name = [Mc.Native.Keys]::Describe($k)
            if ($name -eq 'C-o')   { & $echo "`r`n"; return $null }            # toggle back to the panels
            if ($name -eq 'enter') { & $echo "`r`n"; return $line.ToString() }
            if ($name -eq 'C-c')   { & $echo "^C`r`n"; return '' }             # abandon the line, new prompt
            if ($name -eq 'C-d')   { if ($line.Length -eq 0) { & $echo "`r`n"; return $null }; continue }
            if ($name -eq 'backspace') {
                if ($line.Length -gt 0) { $line.Length--; & $echo "`b `b" }
                continue
            }
            if ($name -eq 'esc') {
                & $echo ("`b `b" * $line.Length)
                [void]$line.Clear()
                continue
            }

            $c = $k.KeyChar
            if ($c -and -not [char]::IsControl($c)) {
                [void]$line.Append($c)
                & $echo ([string]$c)
            }
        }
    } finally {
        try { [Console]::TreatControlCAsInput = $savedCtrlC } catch { }
    }
}

function Invoke-McSubshell {
    <#
      Ctrl+O, mc's CK_Shell / toggle_subshell.

      mc leaves its alternate screen and hands the WHOLE terminal to a
      persistent subshell; pressing Ctrl+O again returns to the panels, and if
      you cd'd, the panel follows (mc's do_possible_cd). We do the same, and
      also accept 'exit' at the prompt as an alias -- an extra mc does not
      have (in mc, exit kills the subshell). We get the persistence for free
      because commands run in this very PowerShell session -- the variables,
      modules and location are literally the same ones.
    #>
    param($Screen, [hashtable] $State)

    $panel = Get-McActivePanel $State
    $startLocation = $panel.Location
    $endLocation = $startLocation

    [Mc.Native.Terminal]::Shutdown()
    try {
        Push-Location -LiteralPath $startLocation -ErrorAction SilentlyContinue

        Write-Host ''
        Write-Host "mc-powershell subshell -- Ctrl+O (or 'exit') returns to the panels" -ForegroundColor Cyan
        if (Test-McWritable) {
            Write-Host 'READ-WRITE mode: commands can change files, registry and environment.' -ForegroundColor Red
        } else {
            Write-Host 'READ-ONLY mode: commands that would change anything are refused.' -ForegroundColor Green
            # Second layer, for the whole session in the shell.
            $WhatIfPreference = $true
        }
        Write-Host ''

        while ($true) {
            $line = Read-McShellLine
            if ($null -eq $line) { break }            # Ctrl+O, Ctrl+D or EOF
            $command = $line.Trim()
            if ($command -eq '') { continue }
            if ($command -eq 'exit' -or $command -eq 'quit') { break }   # alias for Ctrl+O

            if (-not (Test-McWritable)) {
                $reasons = @(Test-McCommandMutates $command)
                if ($reasons.Count -gt 0) {
                    Write-Host "Read-only mode: refused -- $($reasons[0])" -ForegroundColor Yellow
                    continue
                }
            }

            try { Invoke-Expression $command | Out-Host }
            catch { Write-Host $_.Exception.Message -ForegroundColor Red }
        }

        $endLocation = (Get-Location).Path
    } finally {
        Pop-Location -ErrorAction SilentlyContinue
        [Mc.Native.Terminal]::Init()
        $Screen.Invalidate()
    }

    # The panel follows the shell, exactly as mc does on return.
    if ($endLocation -and $endLocation -ne $startLocation) {
        if (Set-McPanelLocation $panel $endLocation) {
            $State.Message = "Followed the shell to $endLocation"
        }
    } else {
        Update-McPanel $panel
    }
    Update-McPanel (Get-McInactivePanel $State)
}

# --- internal commands and guarded operations ------------------------------

function Invoke-McGuardedStub {
    <#
      Placeholder for the M3 file operations. It exists now so the guard is
      wired in and demonstrable from day one rather than retrofitted: every
      mutating operation must pass Assert-McWritable before it does anything.
    #>
    param([hashtable] $State, [string] $Operation)

    try { Assert-McWritable -Operation $Operation }
    catch { $State.Message = $_.Exception.Message; return }

    $State.Message = "$Operation is not implemented yet (roadmap M3)"
}

# Commands mc handles itself instead of passing to the shell.
$script:McInternalCommands = @{

    'mc.ps1.ro' = { param($S, $Scr)
        [void](Set-McMode -Mode ReadOnly)
        $S.Message = 'READ-ONLY mode: changes are refused'
    }

    'mc.ps1.rw' = { param($S, $Scr)
        if (Test-McWritable) { $S.Message = 'Already in read-write mode'; return }

        # Safe by default: the cursor starts on "No".
        $answer = Show-McList $Scr $S 'Leave read-only mode?' @(
            'No   -- stay read-only',
            'Yes  -- allow changes to files, registry and environment'
        ) { param($i) $i }

        if ($answer -like 'Yes*') {
            [void](Set-McMode -Mode ReadWrite)
            $S.Message = 'READ-WRITE mode: changes are allowed'
        } else {
            $S.Message = 'Stayed in read-only mode'
        }
        $Scr.Invalidate()
    }

    'mc.ps1.mode' = { param($S, $Scr)
        $S.Message = "Current mode: $(Get-McMode)"
    }
}

function Invoke-McInternalCommand {
    <#
      Returns $true when the command line was an internal command and has been
      handled, so the caller must not pass it to the shell.
    #>
    param([hashtable] $State, $Screen, [string] $Command)

    $handler = $script:McInternalCommands[$Command.Trim()]
    if ($null -eq $handler) { return $false }
    & $handler $State $Screen
    return $true
}

# --- mouse -----------------------------------------------------------------

function Invoke-McMouse {
    <#
      Route a click to whatever was painted at that cell. Hit-testing uses the
      same Get-McLayout the renderer drew from, so the two cannot disagree.

      The function key bar is clickable on purpose: F1-F10 are widely hijacked
      by the OS or terminal, and mc's key bar has always looked like buttons.
    #>
    param([hashtable] $State, $Screen, $Event)

    $L = Get-McLayout $Screen $State
    $x = [int]$Event.X
    $y = [int]$Event.Y

    # --- wheel scrolls whichever panel is under the pointer -----------------
    if ($Event.Button -eq 'wheelup' -or $Event.Button -eq 'wheeldown') {
        if ($y -ge $L.PanelY -and $y -lt $L.PanelY + $L.PanelH) {
            $side = if ($x -lt $L.RightX) { 'Left' } else { 'Right' }
            $delta = if ($Event.Button -eq 'wheelup') { -3 } else { 3 }
            Move-McPanelCursor $State[$side] $delta
        }
        return
    }

    if (-not $Event.Pressed) { return }

    # --- function key bar ---------------------------------------------------
    if ($y -eq $L.KeyY) {
        $slot = [int]([Math]::Floor($x / $L.KeySlot))
        if ($slot -lt 0) { $slot = 0 }
        if ($slot -gt 9) { $slot = 9 }
        Invoke-McKey $State $Screen ('f' + ($slot + 1))
        return
    }

    # --- menu bar -----------------------------------------------------------
    if ($y -eq $L.MenuY) {
        for ($i = 0; $i -lt $L.MenuHits.Count; $i++) {
            $hit = $L.MenuHits[$i]
            if ($x -ge $hit.X -and $x -lt $hit.X + $hit.W) {
                Show-McMenu $Screen $State $i
                return
            }
        }
        return
    }

    # --- command line -------------------------------------------------------
    if ($y -eq $L.CmdY) { return }

    # --- panels -------------------------------------------------------------
    if ($y -ge $L.PanelY -and $y -lt $L.PanelY + $L.PanelH) {
        $side = if ($x -lt $L.RightX) { 'Left' } else { 'Right' }
        if ($State.ActiveSide -ne $side) { $State.ActiveSide = $side }

        $panel = $State[$side]
        $row = $y - $L.PanelRowY
        if ($row -lt 0 -or $row -ge $L.PanelRows) { return }

        $index = $panel.Top + $row
        if ($index -ge $panel.Entries.Count) { return }

        # Click to select; click again (or double-click) to descend, which is
        # what mc does and what a file manager should feel like.
        $alreadyThere = ($panel.Index -eq $index)
        Set-McPanelCursor $panel $index
        if ($alreadyThere -or $Event.Double) {
            Invoke-McKey $State $Screen 'enter'
        }
        return
    }
}

function Invoke-McBackspace {
    <#
      Delete a character from the command line, and nothing else. This is mc's
      [input] behaviour: its [panel] section binds no Backspace, so an empty
      command line means the key does nothing. Going up is Ctrl+PgUp
      (CdParent), for every provider.
    #>
    param([hashtable] $State)

    if ($State.CommandLine.Length -gt 0) {
        $State.CommandLine = $State.CommandLine.Substring(0, $State.CommandLine.Length - 1)
    }
}

function Get-McVersion {
    <#
      The version, from the module manifest -- the single source of truth
      (docs/VERSIONING.md). Returned as a string such as '0.5.0'.
    #>
    $module = $ExecutionContext.SessionState.Module
    if ($module -and $module.Version) { return $module.Version.ToString() }
    (Import-PowerShellDataFile (Join-Path $PSScriptRoot 'Mc.psd1')).ModuleVersion
}

# --- keymap ----------------------------------------------------------------

$script:McKeymap = @{
    'up'        = { param($S, $Scr) Move-McPanelCursor (Get-McActivePanel $S) -1 }
    'down'      = { param($S, $Scr) Move-McPanelCursor (Get-McActivePanel $S) 1 }
    'pgup'      = { param($S, $Scr) $p = Get-McActivePanel $S; Move-McPanelCursor $p (-$p.Rows) }
    'pgdn'      = { param($S, $Scr) $p = Get-McActivePanel $S; Move-McPanelCursor $p $p.Rows }
    'home'      = { param($S, $Scr) Set-McPanelCursor (Get-McActivePanel $S) 0 }
    'end'       = { param($S, $Scr) $p = Get-McActivePanel $S; Set-McPanelCursor $p ($p.Entries.Count - 1) }

    'tab'       = { param($S, $Scr) $S.ActiveSide = if ($S.ActiveSide -eq 'Left') { 'Right' } else { 'Left' } }
    # mc binds Backspace only in [input], where it deletes a character; its
    # [panel] section has no Backspace at all and uses CdParent = ctrl-pgup to
    # go up. We match that exactly: Backspace never navigates, on any provider.
    # (An earlier version went up when the line was empty; dropped for parity.)
    #
    # Bound here rather than left to the command-line editing below so that the
    # binding is visible in the keymap alongside its Ctrl+H alias.
    'backspace' = { param($S, $Scr) Invoke-McBackspace $S }
    'C-h'       = { param($S, $Scr) Invoke-McBackspace $S }   # mc: [input] Backspace = backspace; ctrl-h

    'C-pgup'    = { param($S, $Scr) Invoke-McPanelUp (Get-McActivePanel $S) }   # mc: [panel] CdParent

    'ins'       = { param($S, $Scr) Switch-McPanelMark (Get-McActivePanel $S) -Advance }

    'C-r'       = { param($S, $Scr) Update-McPanel (Get-McActivePanel $S); $S.Message = 'Reloaded' }
    'C-u'       = { param($S, $Scr)
                        $tmp = $S.Left; $S.Left = $S.Right; $S.Right = $tmp
                    }
    'M-.'       = { param($S, $Scr)
                        $p = Get-McActivePanel $S
                        $p.ShowHidden = -not $p.ShowHidden
                        Update-McPanel $p
                        $S.Message = "Hidden files: $(if ($p.ShowHidden) { 'shown' } else { 'hidden' })"
                    }

    'f2'        = { param($S, $Scr) Show-McDriveChooser $Scr $S }
    'f3'        = { param($S, $Scr) Invoke-McViewCurrent $Scr $S }
    'f5'        = { param($S, $Scr) Invoke-McGuardedStub $S 'Copy' }
    'f6'        = { param($S, $Scr) Invoke-McGuardedStub $S 'Rename/move' }
    'f7'        = { param($S, $Scr) Invoke-McGuardedStub $S 'Mkdir' }
    'f8'        = { param($S, $Scr) Invoke-McGuardedStub $S 'Delete' }
    'f9'        = { param($S, $Scr) Show-McMenu $Scr $S 0 }
    'f10'       = { param($S, $Scr) $S.Running = $false }

    'C-o'       = { param($S, $Scr) Invoke-McSubshell $Scr $S }

    # mc puts "Output lines" in the Layout dialog; a shortcut is friendlier.
    'C-up'      = { param($S, $Scr) Set-McOutputLines $S ([int]$S.OutputLines + 1); $Scr.Invalidate() }
    'C-down'    = { param($S, $Scr) Set-McOutputLines $S ([int]$S.OutputLines - 1); $Scr.Invalidate() }
}

function Get-McKeymap {
    <#
      The key dispatch table: canonical key name -> scriptblock.
      Exposed so it can be inspected, rebound, or checked by tests -- notably
      that it never claims a key the command line needs.
    #>
    $script:McKeymap
}

function Invoke-McKey {
    param(
        [hashtable] $State,
        $Screen,
        [string] $Key
    )

    # Enter is context-sensitive: run the command line if there is one,
    # otherwise descend into the highlighted row.
    if ($Key -eq 'enter') {
        if (-not [string]::IsNullOrWhiteSpace($State.CommandLine)) {
            $cmd = $State.CommandLine
            $State.CommandLine = ''
            if (Invoke-McInternalCommand $State $Screen $cmd) { return }
            Invoke-McShellCommand $Screen $State $cmd
            return
        }
        $panel = Get-McActivePanel $State
        $leaf = Invoke-McPanelEnter $panel
        if ($null -ne $leaf) {
            $State.Message = "$($leaf.Name) -- no action bound yet (F3 to view)"
        }
        return
    }

    $handler = $script:McKeymap[$Key]
    if ($handler) { & $handler $State $Screen; return }

    # Command-line editing. Only reached for keys the keymap does not claim.
    if ($Key -eq 'esc') { $State.CommandLine = ''; return }
    if ($Key -eq 'C-c') { $State.CommandLine = ''; return }
    if ($Key -eq 'space') { $State.CommandLine += ' '; return }
    if ($Key.Length -eq 1) { $State.CommandLine += $Key; return }
}

# --- main loop -------------------------------------------------------------

function Start-Mc {
    [CmdletBinding()]
    param(
        [string] $LeftPath = (Get-Location).Path,
        [string] $RightPath = (Get-Location).Path
    )

    if ([Console]::IsInputRedirected) {
        throw 'mc-powershell needs an interactive terminal; stdin is redirected. Run it directly, not through a pipe.'
    }

    [Mc.Native.Terminal]::Init()
    try {
        $screen = [Mc.Native.Screen]::new([Console]::WindowWidth, [Console]::WindowHeight)

        $state = New-McAppState -LeftPath $LeftPath -RightPath $RightPath

        $dirty = $true
        while ($state.Running) {
            $w = [Console]::WindowWidth
            $h = [Console]::WindowHeight
            if ($w -ne $screen.Width -or $h -ne $screen.Height) {
                $screen.Resize($w, $h)
                $screen.Invalidate()
                $dirty = $true
            }

            if ($dirty) {
                Write-McFrame $screen $state
                $screen.Flush()
                $dirty = $false
            }

            # Timeout so the loop still notices a window resize while idle.
            $ev = [Mc.Native.Input]::Read(200)
            if ($null -eq $ev) { continue }

            if ($ev.Kind -eq [Mc.Native.InputKind]::Resize) {
                $screen.Invalidate()
            } elseif ($ev.Kind -eq [Mc.Native.InputKind]::Mouse) {
                $state.Message = $null
                Invoke-McMouse $state $screen $ev
            } else {
                $state.Message = $null
                Invoke-McKey $state $screen $ev.Key
            }
            $dirty = $true
        }
    } finally {
        [Mc.Native.Terminal]::Shutdown()
    }
}
