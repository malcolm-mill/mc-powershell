# ---------------------------------------------------------------------------
# The built-in file viewer (F3), following mc's viewer.
#
# Scope for now: show the contents of a text file correctly, whatever encoding
# it happens to be in. Markdown rendering, syntax colouring and a hex mode come
# later; this is the plumbing they will sit on.
# ---------------------------------------------------------------------------

function Get-McFileEncoding {
    <#
      Pick an encoding by looking at the bytes, in mc's spirit of showing you
      what is actually there rather than guessing and mangling it.

      BOM wins. Otherwise, if the bytes are valid UTF-8, use UTF-8 -- that is
      almost always right today. If they are not, fall back to Latin-1, which
      never throws and never loses a byte, so at worst you see the wrong glyph
      rather than a replacement character.
    #>
    param([byte[]] $Head)

    if ($Head.Length -ge 3 -and $Head[0] -eq 0xEF -and $Head[1] -eq 0xBB -and $Head[2] -eq 0xBF) {
        return [System.Text.Encoding]::UTF8
    }
    if ($Head.Length -ge 2 -and $Head[0] -eq 0xFF -and $Head[1] -eq 0xFE) {
        return [System.Text.Encoding]::Unicode
    }
    if ($Head.Length -ge 2 -and $Head[0] -eq 0xFE -and $Head[1] -eq 0xFF) {
        return [System.Text.Encoding]::BigEndianUnicode
    }

    $strict = [System.Text.UTF8Encoding]::new($false, $true)
    try {
        [void]$strict.GetString($Head)
        return [System.Text.Encoding]::UTF8
    } catch {
        return [System.Text.Encoding]::GetEncoding(28591)   # ISO-8859-1
    }
}

function Test-McBinaryContent {
    <# A NUL byte in the first block is the usual give-away. #>
    param([byte[]] $Head)
    foreach ($b in $Head) { if ($b -eq 0) { return $true } }
    $false
}

function Read-McFileHead {
    <# The first block of a file, for encoding and binary sniffing. #>
    param([string] $Path, [int] $Size = 8192)

    $length = [System.IO.FileInfo]::new($Path).Length
    $headSize = [int][Math]::Min($length, $Size)
    $head = [byte[]]::new($headSize)
    if ($headSize -gt 0) {
        $fs = [System.IO.File]::OpenRead($Path)
        try { [void]$fs.Read($head, 0, $headSize) } finally { $fs.Dispose() }
    }
    # The comma stops PowerShell unrolling an empty array into nothing.
    ,$head
}

function Test-McBinaryFile {
    <# True if the file on disk looks binary; false if it is text or unreadable. #>
    param([string] $Path)
    try { Test-McBinaryContent (Read-McFileHead $Path) } catch { $false }
}

function Get-McViewablePath {
    <#
      The on-disk path behind a panel entry, or $null if there is none.
      Provider items (Env:, HKLM:, Cert:) are not necessarily files; only
      what exists on disk as a leaf is viewable.
    #>
    param($Entry)

    if ($null -eq $Entry -or $Entry.IsContainer) { return $null }
    $path = $Entry.Key
    if (-not $path) { return $null }

    # Test-Path -PathType Leaf is true for an Env: variable too, so ask which
    # provider owns the path rather than trusting "leaf" alone.
    try {
        $info = Resolve-Path -LiteralPath $path -ErrorAction Stop
        if ($info.Provider.Name -ne 'FileSystem') { return $null }
        if ([System.IO.File]::Exists($info.ProviderPath)) { return $info.ProviderPath }
    } catch { }
    $null
}

function Read-McViewerFile {
    <#
      Load a file for viewing. Returns a hashtable with Lines, Encoding, Binary
      and Truncated, or Error if it could not be read.
    #>
    param([string] $Path, [int] $MaxLines = 500000)

    try {
        $length = [System.IO.FileInfo]::new($Path).Length
        $head = Read-McFileHead $Path

        if (Test-McBinaryContent $head) {
            return @{
                Lines = @("[binary file: $([Mc.Native.Fs]::FormatSize($length))]",
                          '',
                          'A hex view is on the roadmap (M5). Nothing has been changed.')
                Encoding = 'binary'; Binary = $true; Truncated = $false; Length = $length
            }
        }

        $encoding = Get-McFileEncoding $head
        $lines = [System.Collections.Generic.List[string]]::new()
        $truncated = $false

        $reader = [System.IO.StreamReader]::new($Path, $encoding, $true)
        try {
            while (-not $reader.EndOfStream) {
                if ($lines.Count -ge $MaxLines) { $truncated = $true; break }
                [void]$lines.Add($reader.ReadLine())
            }
            $encodingName = $reader.CurrentEncoding.WebName
        } finally { $reader.Dispose() }

        @{
            Lines = $lines
            Encoding = $encodingName
            Binary = $false
            Truncated = $truncated
            Length = $length
        }
    } catch {
        @{ Error = $_.Exception.Message }
    }
}

function Get-McEntryContent {
    <#
      Viewer content a source supplies for a leaf that is not a file on disk
      (a registry value, an environment variable), or $null.
    #>
    param([hashtable] $Panel, $Entry)
    if ($null -eq $Entry -or $null -eq $Panel.Source -or -not $Panel.Source.ContainsKey('Content')) { return $null }
    try { & $Panel.Source.Content $Panel.Location $Entry } catch { $null }
}

function Invoke-McViewCurrent {
    <# F3 on whatever the active panel is pointing at. #>
    param($Screen, [hashtable] $State)

    $panel = Get-McActivePanel $State
    $entry = Get-McPanelCurrent $panel
    if ($null -eq $entry) { return }

    # A container may still have something to show (a JSON object's subtree).
    $content = if ($entry.IsUp) { $null } else { Get-McEntryContent $panel $entry }
    if ($content) { Show-McViewerSafe $Screen $State "$($panel.Location)  $($entry.Name)" -Content $content; return }
    if ($entry.IsContainer) { $State.Message = 'Enter opens a directory; F3 views files'; return }

    $resolved = Get-McViewablePath $entry
    if (-not $resolved) {
        $State.Message = "$($entry.Name) is not a file on disk"
        return
    }

    Show-McViewerSafe $Screen $State $resolved
}

function Show-McViewerSafe {
    <#
      A bug in the viewer must cost the user the viewer, not the session.
      Start-Mc's finally restores the terminal either way, but landing at a
      bare prompt with a stack trace is not what a file manager does.
    #>
    param($Screen, [hashtable] $State, [string] $Path, [hashtable] $Content)
    try {
        Show-McViewer $Screen $State $Path -Content $Content
    } catch {
        $Screen.Invalidate()
        $State.Message = "Viewer failed: $($_.Exception.Message)"
    }
}

function Invoke-McOpenCurrent {
    <#
      Enter, or a click on the highlighted row, when that row is a leaf.

      mc executes the file here. We never execute anything -- it would be
      unguardable in read-only mode -- so the gesture opens the viewer for a
      text file and says so for anything else. Recorded in docs/COMPAT.md as
      a deliberate difference.
    #>
    param($Screen, [hashtable] $State)

    $panel = Get-McActivePanel $State
    $entry = Get-McPanelCurrent $panel
    if ($null -eq $entry -or $entry.IsContainer) { return }

    $content = Get-McEntryContent $panel $entry
    if ($content) { Show-McViewerSafe $Screen $State "$($panel.Location)  $($entry.Name)" -Content $content; return }

    $resolved = Get-McViewablePath $entry
    if (-not $resolved) {
        $State.Message = "$($entry.Name) is not a file on disk"
        return
    }

    # A click on notepad.exe should not fill the screen with a placeholder.
    if (Test-McBinaryFile $resolved) {
        $State.Message = "$($entry.Name) is a binary file -- not executed (F3 for details)"
        return
    }

    Show-McViewerSafe $Screen $State $resolved
}

function Show-McViewer {
    <#
      mc's viewer keys, as far as we implement them:
        arrows / PgUp / PgDn / Home / End   move
        left / right                        scroll sideways when unwrapped
        F2                                  wrap on/off
        F4                                  line numbers on/off
        F5                                  go to line
        F7                                  search;  n / N  next / previous
        F9                                  formatted / raw (mc's Format key)
        F3 / F10 / Esc                      close
      Markdown files open formatted (see Markdown.ps1); F9 shows the source.
      The mouse works too: wheel scrolls, and a click on the key bar acts as
      that F-key.
      With -Content, $Path is only the title and nothing is read from disk:
      that is how a registry value or a variable is shown.
    #>
    param($Screen, [hashtable] $State, [string] $Path, [hashtable] $Content)

    $file = if ($Content) { $Content } else { Read-McViewerFile $Path }
    if ($file.ContainsKey('Error')) {
        $State.Message = "Cannot view: $($file.Error)"
        return
    }

    $t = $script:McTheme
    $lines = $file.Lines
    $count = $lines.Count

    $top = 0
    $left = 0
    $wrap = $false
    $numbers = $false
    $search = ''
    $matchLine = -1

    # Formatting keeps one display line per source line, so $count, line
    # numbers and "go to line" mean the same thing in both modes.
    $formatted = $Path -match '\.(md|markdown|mdown|mkd)$'
    $rendered = $null
    $renderedText = $null

    $keyLabels = @(
        '1', 'Help', '2', 'Wrap', '3', 'Quit', '4', 'LineNo', '5', 'Goto',
        '6', '', '7', 'Search', '8', '', '9', 'Format', '10', 'Quit'
    )

    while ($true) {
        $w = $Screen.Width
        $h = $Screen.Height
        $bodyY = 1
        $rows = [Math]::Max(1, $h - 2)
        $keyY = $h - 1

        # --- wrapping produces display rows from source lines ---------------
        $gutter = if ($numbers) { ([string]$count).Length + 1 } else { 0 }
        $textW = [Math]::Max(1, $w - $gutter)

        if ($formatted -and $null -eq $rendered) {
            $rendered = Convert-McMarkdown $lines
            $renderedText = [string[]]@($rendered | ForEach-Object { $_.Text })
        }
        $searchLines = if ($formatted) { $renderedText } else { $lines }

        $display = [System.Collections.Generic.List[object]]::new()
        $i = $top
        while ($display.Count -lt $rows -and $i -lt $count) {
            if ($formatted) {
                $fl = $rendered[$i]
                if ($fl.Rule) {
                    $line = ''
                    $segs = @(New-McSeg ([string]::new([char]0x2500, $textW)) $t.ViewLineNoFg)
                } else {
                    $line = $fl.Text
                    $segs = $fl.Segs
                }
            } else {
                $line = ([string]$lines[$i]) -replace "`t", '    '
                $segs = @(New-McSeg $line)
            }

            if ($wrap -and $line.Length -gt $textW) {
                $offset = 0
                while ($offset -lt $line.Length -and $display.Count -lt $rows) {
                    [void]$display.Add(@{ Number = $i; Segs = (Get-McSegmentSlice $segs $offset $textW); First = ($offset -eq 0) })
                    $offset += $textW
                }
            } else {
                [void]$display.Add(@{ Number = $i; Segs = (Get-McSegmentSlice $segs $left $textW); First = $true })
            }
            $i++
        }

        # --- paint -----------------------------------------------------------
        $Screen.Clear([byte]$t.ViewFg, [byte]$t.ViewBg)

        $title = " $Path "
        $Screen.WriteFixed(0, 0, $title, $w, [byte]$t.TitleFg, [byte]$t.TitleBg, $script:AttrBold)

        for ($r = 0; $r -lt $rows; $r++) {
            $y = $bodyY + $r
            if ($r -ge $display.Count) {
                $Screen.WriteFixed(0, $y, '~', $w, [byte]$t.ViewLineNoFg, [byte]$t.ViewBg, $script:AttrNone)
                continue
            }
            $row = $display[$r]

            if ($numbers) {
                $label = if ($row.First) { [string]($row.Number + 1) } else { '' }
                $Screen.WriteRight(0, $y, "$label ", $gutter, [byte]$t.ViewLineNoFg, [byte]$t.ViewBg, $script:AttrNone)
            }

            $isMatch = ($search -and $row.Number -eq $matchLine)
            $bg = if ($isMatch) { [byte]$t.ViewMatchBg } else { [byte]$t.ViewBg }
            $x = $gutter
            foreach ($s in $row.Segs) {
                $fg = if ($isMatch) { [byte]$t.ViewMatchFg }
                      elseif ($null -ne $s.Fg) { [byte]$s.Fg }
                      else { [byte]$t.ViewFg }
                $x += $Screen.Write($x, $y, $s.Text, $fg, $bg, [byte]$s.Attr)
            }
            if ($x -lt $gutter + $textW) {
                $Screen.Fill($x, $y, $gutter + $textW - $x, 1, ' ', [byte]$t.ViewFg, $bg, $script:AttrNone)
            }
        }

        # --- status and key bar ---------------------------------------------
        $percent = if ($count -le 0) { 100 } else { [int](100 * [Math]::Min(1.0, ($top + $rows) / [double]$count)) }
        $flags = @()
        if ($formatted) { $flags += 'formatted' }
        if ($wrap) { $flags += 'wrap' }
        if ($numbers) { $flags += 'numbers' }
        if ($file.Truncated) { $flags += 'TRUNCATED' }
        if ($left -gt 0) { $flags += "col $($left + 1)" }
        $status = " $($file.Encoding)  line $($top + 1)/$count  $percent%"
        if ($flags.Count -gt 0) { $status += '  [' + ($flags -join ' ') + ']' }
        if ($search) { $status += "  search: $search" }

        $Screen.Fill(0, $keyY, $w, 1, ' ', [byte]$t.KeyLabelFg, [byte]$t.KeyLabelBg, $script:AttrNone)
        $slot = [Math]::Max(1, [int]($w / 10))
        for ($k = 0; $k -lt 10; $k++) {
            $x = $k * $slot
            $num = $keyLabels[$k * 2]
            $lbl = $keyLabels[$k * 2 + 1]
            [void]$Screen.Write($x, $keyY, $num, [byte]$t.KeyNumFg, [byte]$t.KeyNumBg, $script:AttrNone)
            $Screen.WriteFixed($x + $num.Length, $keyY, $lbl, $slot - $num.Length, [byte]$t.KeyLabelFg, [byte]$t.KeyLabelBg, $script:AttrNone)
        }
        $Screen.WriteFixed(0, $h - 2, $status, $w, [byte]$t.StatusFg, [byte]$t.PanelBg, $script:AttrNone)
        $Screen.Flush()

        # --- input ------------------------------------------------------------
        $ev = [Mc.Native.Input]::Read(200)
        if ($null -eq $ev) { continue }

        $key = $null
        if ($ev.Kind -eq [Mc.Native.InputKind]::Mouse) {
            if (-not $ev.Pressed) { continue }
            if ($ev.Button -eq 'wheelup') { $top = [Math]::Max(0, $top - 3); continue }
            if ($ev.Button -eq 'wheeldown') { $top = [Math]::Min([Math]::Max(0, $count - 1), $top + 3); continue }
            if ($ev.Y -eq $keyY) {
                $k = [int]([Math]::Floor($ev.X / $slot))
                $key = 'f' + ([Math]::Max(0, [Math]::Min(9, $k)) + 1)
            } else { continue }
        } else {
            $key = $ev.Key
        }

        $page = [Math]::Max(1, $rows - 1)
        $lastTop = [Math]::Max(0, $count - 1)

        switch ($key) {
            'up'    { $top = [Math]::Max(0, $top - 1) }
            'down'  { $top = [Math]::Min($lastTop, $top + 1) }
            'pgup'  { $top = [Math]::Max(0, $top - $page) }
            'pgdn'  { $top = [Math]::Min($lastTop, $top + $page) }
            'home'  { $top = 0; $left = 0 }
            'end'   { $top = [Math]::Max(0, $count - $page) }
            'left'  { if (-not $wrap) { $left = [Math]::Max(0, $left - 8) } }
            'right' { if (-not $wrap) { $left += 8 } }

            'f2'    { $wrap = -not $wrap; $left = 0 }
            'f4'    { $numbers = -not $numbers }
            'f9'    { $formatted = -not $formatted; $left = 0 }

            'f5' {
                $answer = Read-McViewerPrompt $Screen $State 'Go to line' ''
                if ($answer) {
                    $n = 0
                    if ([int]::TryParse($answer.Trim(), [ref]$n)) {
                        $top = [Math]::Max(0, [Math]::Min($lastTop, $n - 1))
                    }
                }
            }

            'f7' {
                $answer = Read-McViewerPrompt $Screen $State 'Search for' $search
                if ($answer) {
                    $search = $answer
                    $found = Find-McViewerMatch $searchLines $search ($top)
                    if ($found -ge 0) { $top = $found; $matchLine = $found }
                    else { $matchLine = -1 }
                }
            }
            'n' {
                if ($search) {
                    $found = Find-McViewerMatch $searchLines $search ($top + 1)
                    if ($found -ge 0) { $top = $found; $matchLine = $found }
                }
            }
            'S-n' {
                if ($search) {
                    $found = Find-McViewerMatch $searchLines $search ($top - 1) -Backwards
                    if ($found -ge 0) { $top = $found; $matchLine = $found }
                }
            }
            'N' {
                if ($search) {
                    $found = Find-McViewerMatch $searchLines $search ($top - 1) -Backwards
                    if ($found -ge 0) { $top = $found; $matchLine = $found }
                }
            }

            'f3'  { $Screen.Invalidate(); return }
            'f10' { $Screen.Invalidate(); return }
            'esc' { $Screen.Invalidate(); return }
            'q'   { $Screen.Invalidate(); return }
        }
    }
}

function Find-McViewerMatch {
    <# Case-insensitive plain-text search. Returns a line index, or -1. #>
    param($Lines, [string] $Needle, [int] $From, [switch] $Backwards)

    $count = $Lines.Count
    if ($count -eq 0 -or [string]::IsNullOrEmpty($Needle)) { return -1 }

    if ($Backwards) {
        for ($i = [Math]::Min($From, $count - 1); $i -ge 0; $i--) {
            if (([string]$Lines[$i]).IndexOf($Needle, [StringComparison]::OrdinalIgnoreCase) -ge 0) { return $i }
        }
        return -1
    }

    for ($i = [Math]::Max(0, $From); $i -lt $count; $i++) {
        if (([string]$Lines[$i]).IndexOf($Needle, [StringComparison]::OrdinalIgnoreCase) -ge 0) { return $i }
    }
    -1
}

function Read-McViewerPrompt {
    <# A one-line modal input box, for "go to line" and "search for". #>
    param($Screen, [hashtable] $State, [string] $Title, [string] $Initial = '')

    $t = $script:McTheme
    $text = [string]$Initial

    $width = [Math]::Min([Math]::Max(40, $Title.Length + 10), $Screen.Width - 4)
    $height = 5
    $x = [int](($Screen.Width - $width) / 2)
    $y = [int](($Screen.Height - $height) / 2)

    while ($true) {
        $Screen.Fill($x, $y, $width, $height, ' ', [byte]$t.DialogFg, [byte]$t.DialogBg, $script:AttrNone)
        $Screen.Box($x, $y, $width, $height, [byte]$t.DialogFg, [byte]$t.DialogBg, $true)

        $caption = " $Title "
        [void]$Screen.Write($x + [int](($width - $caption.Length) / 2), $y, $caption,
            [byte]$t.DialogTitleFg, [byte]$t.DialogTitleBg, $script:AttrBold)

        $Screen.WriteFixed($x + 2, $y + 2, $text, $width - 4, [byte]$t.CmdFg, [byte]$t.CmdBg, $script:AttrNone)
        $Screen.Set($x + 2 + [Math]::Min($text.Length, $width - 5), $y + 2, ' ',
            [byte]$t.CmdBg, [byte]$t.CmdFg, $script:AttrNone)
        $Screen.Flush()

        $ev = [Mc.Native.Input]::Read(200)
        if ($null -eq $ev) { continue }
        if ($ev.Kind -ne [Mc.Native.InputKind]::Key) { continue }

        switch ($ev.Key) {
            'enter'     { return $text }
            'esc'       { return $null }
            'backspace' { if ($text.Length -gt 0) { $text = $text.Substring(0, $text.Length - 1) } }
            'space'     { $text += ' ' }
            default {
                if ($ev.Key.Length -eq 1) { $text += $ev.Key }
            }
        }
    }
}
