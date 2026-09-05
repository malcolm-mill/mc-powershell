# ---------------------------------------------------------------------------
# The menu bar, following mc's Left / File / Command / Options / Right.
#
# Menus are data. The bar renders from this list, F9 opens it, and the mouse
# hit-tests against the same list -- so a new entry appears everywhere at once
# and there is nothing to keep in sync.
#
# An item is:
#   @{ Label = 'View'; Key = 'F3'; Action = { param($S, $Scr) ... } }
#   @{ Separator = $true }
# ---------------------------------------------------------------------------

function New-McMenuItem {
    param([string] $Label, [string] $Key = '', [scriptblock] $Action)
    @{ Label = $Label; Key = $Key; Action = $Action; Separator = $false }
}

function New-McMenuSeparator { @{ Separator = $true; Label = ''; Key = ''; Action = $null } }

# Left and Right menus act on their own panel, as mc's do, regardless of which
# panel currently has focus.
function New-McPanelMenu {
    param([string] $Title, [string] $Side)

    @{
        Title = $Title
        Side  = $Side
        Items = @(
            New-McMenuItem 'Sort order...' 'F9' { param($S, $Scr, $Side)
                Show-McSortMenu $Scr $S -Side $Side }
            New-McMenuItem 'Change drive or provider...' 'F2' { param($S, $Scr, $Side)
                Show-McDriveChooser $Scr $S -Side $Side }
            New-McMenuSeparator
            New-McMenuItem 'Toggle hidden files' 'Alt+.' { param($S, $Scr, $Side)
                $p = $S[$Side]
                $p.ShowHidden = -not $p.ShowHidden
                Update-McPanel $p
                $S.Message = "Hidden files: $(if ($p.ShowHidden) { 'shown' } else { 'hidden' })" }
            New-McMenuItem 'Reload' 'Ctrl+R' { param($S, $Scr, $Side)
                Update-McPanel $S[$Side]; $S.Message = 'Reloaded' }
        )
    }
}

$script:McMenus = @(
    (New-McPanelMenu 'Left' 'Left')

    @{
        Title = 'File'
        Items = @(
            New-McMenuItem 'View' 'F3' { param($S, $Scr, $Side) Invoke-McViewCurrent $Scr $S }
            New-McMenuItem 'Edit' 'F4' { param($S, $Scr, $Side)
                $S.Message = 'Edit is not implemented yet (roadmap M5)' }
            New-McMenuSeparator
            New-McMenuItem 'Copy' 'F5' { param($S, $Scr, $Side) Invoke-McGuardedStub $S 'Copy' }
            New-McMenuItem 'Rename or move' 'F6' { param($S, $Scr, $Side) Invoke-McGuardedStub $S 'Rename/move' }
            New-McMenuItem 'Make directory' 'F7' { param($S, $Scr, $Side) Invoke-McGuardedStub $S 'Mkdir' }
            New-McMenuItem 'Delete' 'F8' { param($S, $Scr, $Side) Invoke-McGuardedStub $S 'Delete' }
            New-McMenuSeparator
            New-McMenuItem 'Quit' 'F10' { param($S, $Scr, $Side) $S.Running = $false }
        )
    }

    @{
        Title = 'Command'
        Items = @(
            New-McMenuItem 'Subshell' 'Ctrl+O' { param($S, $Scr, $Side) Invoke-McSubshell $Scr $S }
            New-McMenuSeparator
            New-McMenuItem 'Grow output pane' 'Ctrl+Up' { param($S, $Scr, $Side)
                Set-McOutputLines $S ([int]$S.OutputLines + 3); $Scr.Invalidate() }
            New-McMenuItem 'Hide output pane' 'Ctrl+Down' { param($S, $Scr, $Side)
                Set-McOutputLines $S 0; $Scr.Invalidate() }
            New-McMenuSeparator
            New-McMenuItem 'Swap panels' 'Ctrl+U' { param($S, $Scr, $Side)
                $tmp = $S.Left; $S.Left = $S.Right; $S.Right = $tmp }
        )
    }

    @{
        Title = 'Options'
        Items = @(
            New-McMenuItem 'Read-only mode' 'mc.ps1.ro' { param($S, $Scr, $Side)
                [void](Set-McMode -Mode ReadOnly)
                $S.Message = 'READ-ONLY mode: changes are refused' }
            New-McMenuItem 'Read-write mode...' 'mc.ps1.rw' { param($S, $Scr, $Side)
                & $script:McInternalCommands['mc.ps1.rw'] $S $Scr }
            New-McMenuSeparator
            New-McMenuItem 'Current mode' '' { param($S, $Scr, $Side)
                $S.Message = "Current mode: $(Get-McMode)" }
            New-McMenuItem 'Mouse support' '' { param($S, $Scr, $Side)
                $S.Message = if ([Mc.Native.Input]::MouseEnabled) { 'Mouse: enabled' }
                             else { 'Mouse: unavailable on this host' } }
        )
    }

    (New-McPanelMenu 'Right' 'Right')
)

function Get-McMenus { $script:McMenus }

function Show-McMenu {
    <#
      Open the menu bar at the given index and run whatever the user picks.
      Left/Right move between menus, Up/Down within one, Enter runs, Esc closes.
      A click on another title switches to it; a click on an item runs it.
    #>
    param(
        $Screen,
        [hashtable] $State,
        [int] $MenuIndex = 0
    )

    $t = $script:McTheme
    $menus = $script:McMenus
    if ($menus.Count -eq 0) { return }

    $mi = [Math]::Max(0, [Math]::Min($MenuIndex, $menus.Count - 1))
    $ii = 0

    # Never rest on a separator.
    function Script:Step-McMenuItem {
        param($Items, [int] $Index, [int] $Delta)
        $n = $Items.Count
        for ($k = 0; $k -lt $n; $k++) {
            $Index = (($Index + $Delta) % $n + $n) % $n
            if (-not $Items[$Index].Separator) { break }
        }
        $Index
    }

    while ($true) {
        $menu = $menus[$mi]
        $items = $menu.Items
        if ($items[$ii].Separator) { $ii = Step-McMenuItem $items $ii 1 }

        $layout = Get-McLayout $Screen $State
        Write-McFrame $Screen $State -OpenMenuIndex $mi

        # --- drop-down box --------------------------------------------------
        $hit = $layout.MenuHits[$mi]
        $width = 4
        foreach ($item in $items) {
            $len = $item.Label.Length + $item.Key.Length + 6
            if ($len -gt $width) { $width = $len }
        }
        $width = [Math]::Min($width, [Math]::Max(10, $Screen.Width - 2))
        $height = $items.Count + 2
        $x = [Math]::Min($hit.X, [Math]::Max(0, $Screen.Width - $width))
        $y = $layout.MenuY + 1

        $Screen.Fill($x, $y, $width, $height, ' ', [byte]$t.DialogFg, [byte]$t.DialogBg, $script:AttrNone)
        $Screen.Box($x, $y, $width, $height, [byte]$t.DialogFg, [byte]$t.DialogBg, $false)

        for ($r = 0; $r -lt $items.Count; $r++) {
            $item = $items[$r]
            $rowY = $y + 1 + $r
            if ($item.Separator) {
                $Screen.HLine($x, $rowY, $width, [byte]$t.DialogFg, [byte]$t.DialogBg)
                continue
            }
            $selected = ($r -eq $ii)
            $fg = if ($selected) { [byte]$t.CursorFg } else { [byte]$t.DialogFg }
            $bg = if ($selected) { [byte]$t.CursorBg } else { [byte]$t.DialogBg }
            $attr = if ($selected) { $script:AttrBold } else { $script:AttrNone }

            $Screen.WriteFixed($x + 1, $rowY, " $($item.Label)", $width - 2, $fg, $bg, $attr)
            if ($item.Key) {
                $Screen.WriteRight($x + 1, $rowY, "$($item.Key) ", $width - 2, $fg, $bg, $attr)
            }
        }

        $Screen.Flush()

        # --- input ----------------------------------------------------------
        $ev = [Mc.Native.Input]::Read(200)
        if ($null -eq $ev) { continue }

        if ($ev.Kind -eq [Mc.Native.InputKind]::Mouse) {
            if (-not $ev.Pressed) { continue }
            if ($ev.Button -eq 'wheelup') { $ii = Step-McMenuItem $items $ii -1; continue }
            if ($ev.Button -eq 'wheeldown') { $ii = Step-McMenuItem $items $ii 1; continue }

            # A click on another menu title switches to it.
            if ($ev.Y -eq $layout.MenuY) {
                for ($k = 0; $k -lt $layout.MenuHits.Count; $k++) {
                    $h = $layout.MenuHits[$k]
                    if ($ev.X -ge $h.X -and $ev.X -lt $h.X + $h.W) {
                        if ($k -eq $mi) { return }        # clicking the open one closes it
                        $mi = $k; $ii = 0
                        break
                    }
                }
                continue
            }

            # A click inside the drop-down runs that item.
            $row = $ev.Y - ($y + 1)
            if ($ev.X -ge $x -and $ev.X -lt $x + $width -and $row -ge 0 -and $row -lt $items.Count) {
                if ($items[$row].Separator) { continue }
                Invoke-McMenuItem $State $Screen $menu $items[$row]
                return
            }

            return   # a click anywhere else dismisses the menu
        }

        switch ($ev.Key) {
            'left'  { $mi = (($mi - 1) % $menus.Count + $menus.Count) % $menus.Count; $ii = 0 }
            'right' { $mi = ($mi + 1) % $menus.Count; $ii = 0 }
            'up'    { $ii = Step-McMenuItem $items $ii -1 }
            'down'  { $ii = Step-McMenuItem $items $ii 1 }
            'home'  { $ii = Step-McMenuItem $items ($items.Count - 1) 1 }
            'end'   { $ii = Step-McMenuItem $items 0 -1 }
            'enter' { Invoke-McMenuItem $State $Screen $menu $items[$ii]; return }
            'esc'   { return }
            'f9'    { return }
            'f10'   { $State.Running = $false; return }
        }
    }
}

function Invoke-McMenuItem {
    param([hashtable] $State, $Screen, [hashtable] $Menu, [hashtable] $Item)

    if ($null -eq $Item -or $Item.Separator -or $null -eq $Item.Action) { return }
    $side = if ($Menu.ContainsKey('Side')) { $Menu.Side } else { $State.ActiveSide }
    & $Item.Action $State $Screen $side
    $Screen.Invalidate()
}
