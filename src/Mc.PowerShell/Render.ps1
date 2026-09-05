# ---------------------------------------------------------------------------
# Rendering. Takes app state and paints it into the Screen back buffer.
# Never reads input, never mutates state -- so a golden-frame test can call
# Write-McFrame against a fixed state and diff Screen.Snapshot() with a fixture.
# ---------------------------------------------------------------------------

function Get-McColumnLayout {
    param(
        [array] $Columns,
        [int] $InteriorWidth
    )

    $n = $Columns.Count
    if ($n -eq 0) { return @() }

    $separators = $n - 1
    $fixedTotal = 0
    $flexIndices = @()

    for ($i = 0; $i -lt $n; $i++) {
        $w = [int]$Columns[$i].Width
        if ($w -lt 0) { $flexIndices += $i } else { $fixedTotal += $w }
    }

    $widths = New-Object 'int[]' $n
    $available = $InteriorWidth - $separators

    if ($flexIndices.Count -eq 0) {
        for ($i = 0; $i -lt $n; $i++) { $widths[$i] = [int]$Columns[$i].Width }
    } else {
        $flexTotal = $available - $fixedTotal
        $minFlex = 4 * $flexIndices.Count

        # Not enough room: shave the fixed columns from the right until it fits.
        if ($flexTotal -lt $minFlex) {
            $deficit = $minFlex - $flexTotal
            for ($i = $n - 1; $i -ge 0 -and $deficit -gt 0; $i--) {
                if ($Columns[$i].Width -lt 0) { continue }
                $take = [Math]::Min($deficit, [int]$Columns[$i].Width)
                $widths[$i] = [int]$Columns[$i].Width - $take
                $deficit -= $take
            }
            $flexTotal = $minFlex - $deficit
        }

        $each = [int][Math]::Max(1, [Math]::Floor($flexTotal / $flexIndices.Count))
        $remainder = [int]($flexTotal - ($each * $flexIndices.Count))

        for ($i = 0; $i -lt $n; $i++) {
            if ($Columns[$i].Width -ge 0 -and $widths[$i] -eq 0) { $widths[$i] = [int]$Columns[$i].Width }
        }
        foreach ($fi in $flexIndices) {
            $widths[$fi] = $each
        }
        if ($remainder -gt 0 -and $flexIndices.Count -gt 0) {
            $widths[$flexIndices[0]] += $remainder
        }
    }

    for ($i = 0; $i -lt $n; $i++) { if ($widths[$i] -lt 0) { $widths[$i] = 0 } }
    return $widths
}

function Write-McCell {
    param($Screen, [int]$X, [int]$Y, [string]$Text, [int]$Width, [string]$Align, [byte]$Fg, [byte]$Bg, [byte]$Attr)
    if ($Align -eq 'Right') { $Screen.WriteRight($X, $Y, $Text, $Width, $Fg, $Bg, $Attr) }
    else { $Screen.WriteFixed($X, $Y, $Text, $Width, $Fg, $Bg, $Attr) }
}

function Write-McPanel {
    param(
        $Screen,
        [hashtable] $Panel,
        [int] $X, [int] $Y, [int] $W, [int] $H,
        [bool] $Active
    )

    $t = $script:McTheme
    $bg = [byte]$t.PanelBg
    $borderFg = if ($Active) { [byte]$t.BorderActive } else { [byte]$t.BorderFg }

    $Screen.Fill($X, $Y, $W, $H, ' ', [byte]$t.FileFg, $bg, $script:AttrNone)
    $Screen.Box($X, $Y, $W, $H, $borderFg, $bg, $Active)

    $interiorX = $X + 1
    $interiorW = $W - 2
    if ($interiorW -lt 4) { return }

    # --- title on the top border ------------------------------------------
    $title = if ($Panel.Source -and $Panel.Source.Title) { & $Panel.Source.Title $Panel.Location } else { $Panel.Location }
    $title = " $title "
    if ($title.Length -gt $interiorW) { $title = ' ' + $title.Substring($title.Length - $interiorW + 3).Trim() + ' ' }
    $titleX = $X + [Math]::Max(1, [int](($W - $title.Length) / 2))
    if ($Active) {
        [void]$Screen.Write($titleX, $Y, $title, [byte]$t.TitleFg, [byte]$t.TitleBg, $script:AttrBold)
    } else {
        [void]$Screen.Write($titleX, $Y, $title, [byte]$t.TitleInactive, $bg, $script:AttrNone)
    }

    # --- rows available for entries ---------------------------------------
    $headerY = $Y + 1
    $firstRowY = $Y + 2
    $statusY = $Y + $H - 2
    $rows = $statusY - $firstRowY
    if ($rows -lt 1) { $rows = 1 }
    $Panel.Rows = $rows
    Set-McPanelCursor $Panel $Panel.Index

    if ($Panel.Error) {
        $Screen.WriteFixed($interiorX, $firstRowY, "! $($Panel.Error)", $interiorW, [byte]$t.MarkedFg, $bg, $script:AttrBold)
        return
    }

    $columns = $Panel.Columns
    if ($columns.Count -eq 0) { return }
    $widths = Get-McColumnLayout -Columns $columns -InteriorWidth $interiorW

    # --- column headers ----------------------------------------------------
    $cx = $interiorX
    for ($c = 0; $c -lt $columns.Count; $c++) {
        $header = [string]$columns[$c].Header
        $sortField = $null
        switch ($header) {
            'Name' { $sortField = [Mc.Native.SortField]::Name }
            'Size' { $sortField = [Mc.Native.SortField]::Size }
            'Modify time' { $sortField = [Mc.Native.SortField]::Modified }
        }
        if ($null -ne $sortField -and $Panel.Sort -eq $sortField) {
            $arrow = if ($Panel.Descending) { [char]0x2193 } else { [char]0x2191 }
            $header = "$arrow$header"
        }
        Write-McCell $Screen $cx $headerY $header $widths[$c] $columns[$c].Align ([byte]$t.HeaderFg) $bg $script:AttrBold
        $cx += $widths[$c]
        if ($c -lt $columns.Count - 1) { $Screen.Set($cx, $headerY, [char]0x2502, $borderFg, $bg, $script:AttrNone); $cx++ }
    }

    # --- entries -----------------------------------------------------------
    for ($r = 0; $r -lt $rows; $r++) {
        $idx = $Panel.Top + $r
        $y = $firstRowY + $r
        if ($idx -ge $Panel.Entries.Count) {
            $Screen.Fill($interiorX, $y, $interiorW, 1, ' ', [byte]$t.FileFg, $bg, $script:AttrNone)
            continue
        }

        $e = $Panel.Entries[$idx]
        $isCursor = ($idx -eq $Panel.Index)

        $fg = [byte]$t.FileFg
        $attr = $script:AttrNone
        if ($e.IsContainer) { $fg = [byte]$t.DirFg; $attr = $script:AttrBold }
        if ($e.Tag -eq 'LNK') { $fg = [byte]$t.LinkFg }
        if ($e.Marked) { $fg = [byte]$t.MarkedFg; $attr = $script:AttrBold }

        $rowBg = $bg
        if ($isCursor) {
            if ($Active) {
                $rowBg = [byte]$t.CursorBg
                if (-not $e.Marked) { $fg = [byte]$t.CursorFg }
            } else {
                $rowBg = [byte]$t.CursorBgIdle
                if (-not $e.Marked) { $fg = [byte]$t.CursorFgIdle }
            }
        }

        $cx = $interiorX
        for ($c = 0; $c -lt $columns.Count; $c++) {
            $value = ''
            try { $value = [string](& $columns[$c].Get $e) } catch { $value = '?' }
            Write-McCell $Screen $cx $y $value $widths[$c] $columns[$c].Align $fg $rowBg $attr
            $cx += $widths[$c]
            if ($c -lt $columns.Count - 1) {
                if ($isCursor) { $Screen.Set($cx, $y, ' ', $fg, $rowBg, $script:AttrNone) }
                else { $Screen.Set($cx, $y, [char]0x2502, $borderFg, $bg, $script:AttrNone) }
                $cx++
            }
        }
    }

    # --- mini status -------------------------------------------------------
    $current = Get-McPanelCurrent $Panel
    $stats = Get-McPanelStats $Panel
    $status = if ($current) { $current.Name } else { '' }
    if ($stats.MarkedCount -gt 0) {
        $status = "$($stats.MarkedCount) marked, $([Mc.Native.Fs]::FormatSize($stats.MarkedBytes))"
    }
    $Screen.WriteFixed($interiorX, $statusY, $status, $interiorW, [byte]$t.StatusFg, $bg, $script:AttrNone)
}

function Write-McFrame {
    param(
        $Screen,
        [hashtable] $State
    )

    $t = $script:McTheme
    $w = $Screen.Width
    $h = $Screen.Height

    $Screen.Clear([byte]$t.FileFg, [byte]$t.CmdBg)

    # mc's "output lines": the pane takes rows from the panels, never from the
    # command line or key bar, and the panels keep a workable minimum.
    $outputLines = [int]$State.OutputLines
    $panelH = $h - 2 - $outputLines
    if ($panelH -lt 5) {
        $panelH = [Math]::Min(5, [Math]::Max(1, $h - 2))
        $outputLines = [Math]::Max(0, $h - 2 - $panelH)
    }
    $leftW = [int]($w / 2)
    $rightW = $w - $leftW

    Write-McPanel $Screen $State.Left 0 0 $leftW $panelH ($State.ActiveSide -eq 'Left')
    Write-McPanel $Screen $State.Right $leftW 0 $rightW $panelH ($State.ActiveSide -eq 'Right')

    # --- output pane -------------------------------------------------------
    if ($outputLines -gt 0) {
        $paneY = $panelH
        $Screen.Fill(0, $paneY, $w, $outputLines, ' ', [byte]$t.CmdFg, [byte]$t.CmdBg, $script:AttrNone)

        $buffer = $State.Output
        $count = $buffer.Count
        $first = [Math]::Max(0, $count - $outputLines)
        for ($r = 0; $r -lt $outputLines; $r++) {
            $i = $first + $r
            $line = if ($i -lt $count) { [string]$buffer[$i] } else { '' }
            $line = $line -replace "`t", '    '
            $Screen.WriteFixed(0, $paneY + $r, $line, $w, [byte]$t.CmdFg, [byte]$t.CmdBg, $script:AttrNone)
        }
    }

    # --- command line ------------------------------------------------------
    $cmdY = $h - 2
    $active = $State.($State.ActiveSide)
    $Screen.Fill(0, $cmdY, $w, 1, ' ', [byte]$t.CmdFg, [byte]$t.CmdBg, $script:AttrNone)

    # Mode badge. The user must never have to guess whether mc can write, so
    # this is always on screen and read-write is deliberately alarming.
    $writable = Test-McWritable
    $badge = if ($writable) { ' RW ' } else { ' RO ' }
    $badgeFg = if ($writable) { [byte]$t.ModeRwFg } else { [byte]$t.ModeRoFg }
    $badgeBg = if ($writable) { [byte]$t.ModeRwBg } else { [byte]$t.ModeRoBg }
    $Screen.WriteFixed(0, $cmdY, $badge, [Math]::Min($badge.Length, $w), $badgeFg, $badgeBg, $script:AttrBold)

    $promptX = [Math]::Min($badge.Length + 1, [Math]::Max(0, $w - 1))
    $prompt = "$($active.Location)> "
    $Screen.WriteFixed($promptX, $cmdY, $prompt, [Math]::Min($prompt.Length, [Math]::Max(0, $w - $promptX)), [byte]$t.DirFg, [byte]$t.CmdBg, $script:AttrBold)
    $cmdX = [Math]::Min($promptX + $prompt.Length, $w - 1)
    [void]$Screen.Write($cmdX, $cmdY, $State.CommandLine, [byte]$t.CmdFg, [byte]$t.CmdBg, $script:AttrNone)
    $Screen.Set($cmdX + $State.CommandLine.Length, $cmdY, ' ', [byte]$t.CmdBg, [byte]$t.CmdFg, $script:AttrNone)

    # --- function key bar --------------------------------------------------
    $keyY = $h - 1
    $labels = @(
        '1', 'Help', '2', 'Drive', '3', 'View', '4', 'Edit', '5', 'Copy',
        '6', 'RenMov', '7', 'Mkdir', '8', 'Delete', '9', 'Sort', '10', 'Quit'
    )
    $Screen.Fill(0, $keyY, $w, 1, ' ', [byte]$t.KeyLabelFg, [byte]$t.KeyLabelBg, $script:AttrNone)
    $slot = [int]($w / 10)
    for ($i = 0; $i -lt 10; $i++) {
        $x = $i * $slot
        $num = $labels[$i * 2]
        $lbl = $labels[$i * 2 + 1]
        [void]$Screen.Write($x, $keyY, $num, [byte]$t.KeyNumFg, [byte]$t.KeyNumBg, $script:AttrNone)
        $Screen.WriteFixed($x + $num.Length, $keyY, $lbl, $slot - $num.Length, [byte]$t.KeyLabelFg, [byte]$t.KeyLabelBg, $script:AttrNone)
    }
    if ($State.Message) {
        $Screen.WriteFixed(0, $keyY, " $($State.Message) ", $w, [byte]$t.MarkedFg, [byte]$t.KeyNumBg, $script:AttrBold)
    }
}
