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

        $key = [Mc.Native.Keys]::Read()
        switch ($key) {
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

function Show-McViewer {
    <# Minimal F3 viewer: enough to prove the modal-screen mechanics. #>
    param($Screen, [hashtable] $State, [string] $Path)

    $lines = @()
    try {
        $lines = [System.IO.File]::ReadAllLines($Path)
    } catch {
        $State.Message = "Cannot view: $($_.Exception.Message)"
        return
    }

    $t = $script:McTheme
    $top = 0
    while ($true) {
        $h = $Screen.Height
        $w = $Screen.Width
        $rows = $h - 2

        $Screen.Clear([byte]$t.FileFg, [byte]$t.CmdBg)
        $header = " View: $Path  ($($lines.Count) lines) "
        $Screen.WriteFixed(0, 0, $header, $w, [byte]$t.TitleFg, [byte]$t.TitleBg, $script:AttrBold)

        for ($r = 0; $r -lt $rows - 1; $r++) {
            $i = $top + $r
            $text = if ($i -lt $lines.Count) { $lines[$i] -replace "`t", '    ' } else { '' }
            $Screen.WriteFixed(0, $r + 1, $text, $w, [byte]$t.FileFg, [byte]$t.CmdBg, $script:AttrNone)
        }

        $footer = ' Up/Down/PgUp/PgDn scroll   F10 or Esc closes '
        $Screen.WriteFixed(0, $h - 1, $footer, $w, [byte]$t.KeyLabelFg, [byte]$t.KeyLabelBg, $script:AttrNone)
        $Screen.Flush()

        $key = [Mc.Native.Keys]::Read()
        $page = [Math]::Max(1, $rows - 2)
        switch ($key) {
            'up'   { $top = [Math]::Max(0, $top - 1) }
            'down' { $top = [Math]::Min([Math]::Max(0, $lines.Count - 1), $top + 1) }
            'pgup' { $top = [Math]::Max(0, $top - $page) }
            'pgdn' { $top = [Math]::Min([Math]::Max(0, $lines.Count - 1), $top + $page) }
            'home' { $top = 0 }
            'end'  { $top = [Math]::Max(0, $lines.Count - $page) }
            'esc'  { $Screen.Invalidate(); return }
            'f3'   { $Screen.Invalidate(); return }
            'f10'  { $Screen.Invalidate(); return }
        }
    }
}

function Show-McDriveChooser {
    <#
      The demo of the whole thesis: pick any PSDrive -- filesystem, registry,
      environment, certificates, or anything a module mounted -- and the panel
      shows it with columns appropriate to that provider.
    #>
    param($Screen, [hashtable] $State)

    $drives = @(Get-PSDrive -ErrorAction SilentlyContinue |
        Where-Object { $_.Provider } |
        Sort-Object { $_.Provider.Name }, Name)

    $choice = Show-McList $Screen $State 'Change drive or provider' $drives {
        param($d)
        '{0,-12} {1,-14} {2}' -f "$($d.Name):", $d.Provider.Name, $d.Root
    }
    if ($null -eq $choice) { return }

    $panel = Get-McActivePanel $State
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
    param($Screen, [hashtable] $State)

    $fields = @(
        @{ Label = 'Name';        Field = [Mc.Native.SortField]::Name }
        @{ Label = 'Extension';   Field = [Mc.Native.SortField]::Extension }
        @{ Label = 'Size';        Field = [Mc.Native.SortField]::Size }
        @{ Label = 'Modify time'; Field = [Mc.Native.SortField]::Modified }
        @{ Label = 'Unsorted';    Field = [Mc.Native.SortField]::Unsorted }
    )

    $choice = Show-McList $Screen $State 'Sort order' $fields { param($f) $f.Label }
    if ($null -eq $choice) { return }
    Set-McPanelSort (Get-McActivePanel $State) $choice.Field
    $Screen.Invalidate()
}

function Invoke-McShellCommand {
    <# Leave the alternate screen, run the command, come back. #>
    param($Screen, [hashtable] $State, [string] $Command)

    if ([string]::IsNullOrWhiteSpace($Command)) { return }
    $panel = Get-McActivePanel $State

    [Mc.Native.Terminal]::Shutdown()
    try {
        Push-Location -LiteralPath $panel.Location -ErrorAction SilentlyContinue
        Write-Host "$($panel.Location)> $Command"
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

# --- keymap ----------------------------------------------------------------

$script:McKeymap = @{
    'up'        = { param($S, $Scr) Move-McPanelCursor (Get-McActivePanel $S) -1 }
    'down'      = { param($S, $Scr) Move-McPanelCursor (Get-McActivePanel $S) 1 }
    'pgup'      = { param($S, $Scr) $p = Get-McActivePanel $S; Move-McPanelCursor $p (-$p.Rows) }
    'pgdn'      = { param($S, $Scr) $p = Get-McActivePanel $S; Move-McPanelCursor $p $p.Rows }
    'home'      = { param($S, $Scr) Set-McPanelCursor (Get-McActivePanel $S) 0 }
    'end'       = { param($S, $Scr) $p = Get-McActivePanel $S; Set-McPanelCursor $p ($p.Entries.Count - 1) }

    'tab'       = { param($S, $Scr) $S.ActiveSide = if ($S.ActiveSide -eq 'Left') { 'Right' } else { 'Left' } }
    # Context-sensitive, like Enter: edit the command line when there is one,
    # otherwise navigate. This MUST be decided inside the handler -- the keymap
    # is consulted before command-line editing, so anything bound here
    # unconditionally shadows the command line completely.
    'backspace' = { param($S, $Scr)
                        if ($S.CommandLine.Length -gt 0) {
                            $S.CommandLine = $S.CommandLine.Substring(0, $S.CommandLine.Length - 1)
                        } else {
                            Invoke-McPanelUp (Get-McActivePanel $S)
                        }
                    }

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
    'f3'        = { param($S, $Scr)
                        $e = Get-McPanelCurrent (Get-McActivePanel $S)
                        if ($e -and -not $e.IsContainer -and $e.Key -and (Test-Path -LiteralPath $e.Key -PathType Leaf -ErrorAction SilentlyContinue)) {
                            Show-McViewer $Scr $S $e.Key
                        } else {
                            $S.Message = 'F3 views files only (for now)'
                        }
                    }
    'f9'        = { param($S, $Scr) Show-McSortMenu $Scr $S }
    'f10'       = { param($S, $Scr) $S.Running = $false }

    'C-o'       = { param($S, $Scr) Invoke-McShellCommand $Scr $S 'Get-Location' }
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

    # Command-line editing. Only reached for keys the keymap does not claim,
    # which is why Backspace handles its own context-sensitivity above.
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

        $state = @{
            Left        = New-McPanel $LeftPath
            Right       = New-McPanel $RightPath
            ActiveSide  = 'Left'
            CommandLine = ''
            Message     = $null
            Running     = $true
        }

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
            $key = [Mc.Native.Keys]::ReadTimeout(200)
            if ($null -eq $key) { continue }

            $state.Message = $null
            Invoke-McKey $state $screen $key
            $dirty = $true
        }
    } finally {
        [Mc.Native.Terminal]::Shutdown()
    }
}
