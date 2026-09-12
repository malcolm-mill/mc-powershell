# mc-powershell : Midnight Commander's UI over PowerShell's object model.
# Copyright (C) 2026  Malcolm Mill
# Licensed under the GNU General Public License v3 or later. See COPYING.

# ---------------------------------------------------------------------------
# Markdown for the viewer: source lines -> formatted lines.
#
# Pure: no screen, no keys, so it is testable headlessly. A formatted line is
#
#   @{ Source = <source line index>; Kind = <string>; Text = <plain text>
#      Segs = @( @{ Text; Fg; Attr } ... ); Rule = <bool> }
#
# Fg is a palette index or $null for the viewer's default. The viewer paints
# the segments; wrap, horizontal scroll and search work on Text. A Rule line
# has no fixed text: the viewer draws it across whatever width it has.
#
# The subset: ATX and setext headings, fenced and indented code, block
# quotes, bullet and numbered lists, rules, tables (pipes dimmed, separator
# rows drawn as lines), and inline bold, italic, code, links and images.
# Italic is drawn underlined, as mc's nroff mode does, because the cell grid
# has no italic attribute. Anything not understood passes through verbatim,
# so a file never loses text by being formatted.
# ---------------------------------------------------------------------------

function New-McSeg {
    param([string] $Text, $Fg = $null, [byte] $Attr = 0)
    @{ Text = $Text; Fg = $Fg; Attr = $Attr }
}

$script:McLinkRegex = [regex]::new('\G!?\[([^\]]*)\]\(\s*[^)\s]*(?:\s+"[^"]*")?\s*\)')

function Get-McInlineSegments {
    <#
      Inline markdown: **bold**, __bold__, *italic*, _italic_, `code`,
      [text](url), ![alt](src), and backslash escapes. Returns segments.
      $Fg and $Attr are inherited from the enclosing block.
    #>
    param([string] $Text, $Fg = $null, [byte] $Attr = 0)

    $t = $script:McTheme
    $segs = [System.Collections.Generic.List[hashtable]]::new()
    $sb = [System.Text.StringBuilder]::new()
    $n = $Text.Length
    $i = 0
    $escapable = '\`*_{}[]()#+-.!|><'

    while ($i -lt $n) {
        $c = $Text[$i]

        if ($c -eq '\' -and $i + 1 -lt $n -and $escapable.IndexOf($Text[$i + 1]) -ge 0) {
            [void]$sb.Append($Text[$i + 1]); $i += 2; continue
        }

        if ($c -eq '`') {
            $run = 1
            while ($i + $run -lt $n -and $Text[$i + $run] -eq '`') { $run++ }
            $fence = [string]::new('`', $run)
            $close = $Text.IndexOf($fence, $i + $run)
            if ($close -ge 0) {
                if ($sb.Length -gt 0) { $segs.Add((New-McSeg $sb.ToString() $Fg $Attr)); [void]$sb.Clear() }
                $code = $Text.Substring($i + $run, $close - $i - $run).Trim()
                $segs.Add((New-McSeg $code $t.ViewCodeFg $Attr))
                $i = $close + $run
                continue
            }
            [void]$sb.Append($fence); $i += $run; continue
        }

        if ($c -eq '[' -or ($c -eq '!' -and $i + 1 -lt $n -and $Text[$i + 1] -eq '[')) {
            # The instance overload takes a start index; the static one would
            # read $i as RegexOptions.
            $m = $script:McLinkRegex.Match($Text, $i)
            if ($m.Success) {
                if ($sb.Length -gt 0) { $segs.Add((New-McSeg $sb.ToString() $Fg $Attr)); [void]$sb.Clear() }
                $inner = Get-McInlineSegments $m.Groups[1].Value $t.ViewLinkFg ($Attr -bor $script:AttrUnderline)
                foreach ($s in $inner) { $segs.Add($s) }
                $i += $m.Length
                continue
            }
        }

        if ($c -eq '*' -or $c -eq '_') {
            $run = 1
            while ($i + $run -lt $n -and $Text[$i + $run] -eq $c) { $run++ }
            $len = [Math]::Min($run, 3)
            $marker = [string]::new($c, $len)

            # An underscore inside a word is a word character, not emphasis.
            $wordBefore = ($c -eq '_' -and $i -gt 0 -and [char]::IsLetterOrDigit($Text[$i - 1]))
            $opensOnSpace = ($i + $len -ge $n -or [char]::IsWhiteSpace($Text[$i + $len]))

            $close = -1
            if (-not $wordBefore -and -not $opensOnSpace) {
                $from = $i + $len
                while ($from -lt $n) {
                    $k = $Text.IndexOf($marker, $from)
                    if ($k -lt 0) { break }
                    $spaceBefore = [char]::IsWhiteSpace($Text[$k - 1])
                    $longerRun = ($k + $len -lt $n -and $Text[$k + $len] -eq $c)
                    $wordAfter = ($c -eq '_' -and $k + $len -lt $n -and [char]::IsLetterOrDigit($Text[$k + $len]))
                    if (-not $spaceBefore -and -not $longerRun -and -not $wordAfter) { $close = $k; break }
                    $from = $k + 1
                }
            }

            if ($close -gt $i + $len) {
                if ($sb.Length -gt 0) { $segs.Add((New-McSeg $sb.ToString() $Fg $Attr)); [void]$sb.Clear() }
                # Variable names are case-insensitive, so this must not be $attr.
                $spanAttr = $Attr
                if ($len -ge 2) { $spanAttr = $spanAttr -bor $script:AttrBold }
                if ($len % 2 -eq 1) { $spanAttr = $spanAttr -bor $script:AttrUnderline }
                $inner = Get-McInlineSegments $Text.Substring($i + $len, $close - $i - $len) $Fg $spanAttr
                foreach ($s in $inner) { $segs.Add($s) }
                $i = $close + $len
                continue
            }

            [void]$sb.Append([string]::new($c, $run)); $i += $run; continue
        }

        [void]$sb.Append($c); $i++
    }

    if ($sb.Length -gt 0) { $segs.Add((New-McSeg $sb.ToString() $Fg $Attr)) }
    # Unwrapped on purpose: callers use @(...) to collect, and a comma-wrapped
    # array inside @(...) becomes one nested element, which then crashes the
    # viewer's slicer. Convert-McMarkdown and Get-McSegmentSlice keep the
    # comma because their callers index the result directly.
    $segs.ToArray()
}

function Convert-McMarkdown {
    <#
      Block-level markdown. Takes the source lines, returns formatted lines
      (see the header). One formatted line per source line, so line numbers
      and "go to line" keep meaning what they mean in the file.
    #>
    param([Parameter(Mandatory)] $Lines)

    $t = $script:McTheme
    $out = [System.Collections.Generic.List[hashtable]]::new()
    $count = $Lines.Count

    $inFence = $false
    $fenceChar = ''
    $fenceLen = 0

    function Add-Line {
        param([int] $Source, [string] $Kind, $Segs, [switch] $Rule)
        $segs = @($Segs)
        $text = -join ($segs | ForEach-Object { $_.Text })
        $out.Add(@{ Source = $Source; Kind = $Kind; Text = $text; Segs = $segs; Rule = [bool]$Rule })
    }

    for ($i = 0; $i -lt $count; $i++) {
        $line = ([string]$Lines[$i]) -replace "`t", '    '
        $trim = $line.TrimStart()
        $indent = $line.Length - $trim.Length
        $prevKind = if ($out.Count -gt 0) { $out[$out.Count - 1].Kind } else { 'blank' }

        if ($inFence) {
            if ($indent -lt 4 -and $trim.TrimEnd() -match "^$([regex]::Escape($fenceChar)){$fenceLen,}$") {
                $inFence = $false
                Add-Line $i 'fence' (New-McSeg ([string]::new([char]0x2500, 3)) $t.ViewLineNoFg)
            } else {
                Add-Line $i 'code' (New-McSeg $line $t.ViewCodeFg)
            }
            continue
        }

        if ($indent -lt 4 -and $trim -match '^(`{3,}|~{3,})\s*(\S*)') {
            $inFence = $true
            $fenceChar = [string]$matches[1][0]
            $fenceLen = $matches[1].Length
            $label = [string]::new([char]0x2500, 3)
            if ($matches[2]) { $label += " $($matches[2])" }
            Add-Line $i 'fence' (New-McSeg $label $t.ViewLineNoFg)
            continue
        }

        if ($trim.Trim() -eq '') { Add-Line $i 'blank' @(); continue }

        if ($indent -lt 4 -and $trim -match '^(#{1,6})\s+(.*?)\s*(?:\s#+)?\s*$') {
            $level = $matches[1].Length
            $fg = switch ($level) { 1 { $t.ViewHeadingFg } 2 { $t.ViewSubheadingFg } default { $t.ViewLinkFg } }
            Add-Line $i 'heading' (Get-McInlineSegments $matches[2] $fg $script:AttrBold)
            continue
        }

        # Setext: a paragraph line followed by === or --- is a heading.
        if ($indent -lt 4 -and $prevKind -eq 'para' -and $trim.TrimEnd() -match '^(=+|-+)$') {
            $prev = $out[$out.Count - 1]
            $fg = if ($matches[1][0] -eq '=') { $t.ViewHeadingFg } else { $t.ViewSubheadingFg }
            $prev.Kind = 'heading'
            $prev.Segs = @(Get-McInlineSegments $prev.Raw $fg $script:AttrBold)
            $prev.Text = -join ($prev.Segs | ForEach-Object { $_.Text })
            Add-Line $i 'underline' (New-McSeg ([string]::new([char]0x2500, [Math]::Max(1, $prev.Text.Length))) $t.ViewLineNoFg)
            continue
        }

        if ($indent -lt 4 -and $trim -match '^([-*_])(\s*\1){2,}\s*$') {
            Add-Line $i 'rule' @() -Rule
            continue
        }

        # Indented code cannot interrupt a paragraph (CommonMark), so only
        # after a blank line or more code.
        if ($indent -ge 4 -and $prevKind -in 'blank', 'code', 'fence') {
            Add-Line $i 'code' (New-McSeg $line $t.ViewCodeFg)
            continue
        }

        if ($trim -match '^>\s?(.*)$') {
            $bar = New-McSeg ((' ' * $indent) + [string][char]0x2502 + ' ') $t.ViewLineNoFg
            Add-Line $i 'quote' (@($bar) + @(Get-McInlineSegments $matches[1] $t.ViewQuoteFg))
            continue
        }

        if ($trim -match '^([-*+])\s+(.*)$') {
            $bullet = New-McSeg ((' ' * $indent) + [string][char]0x2022 + ' ') $t.ViewSubheadingFg
            Add-Line $i 'list' (@($bullet) + @(Get-McInlineSegments $matches[2]))
            continue
        }

        if ($trim -match '^(\d{1,9}[.)])\s+(.*)$') {
            $num = New-McSeg ((' ' * $indent) + $matches[1] + ' ') $t.ViewSubheadingFg
            Add-Line $i 'list' (@($num) + @(Get-McInlineSegments $matches[2]))
            continue
        }

        if ($trim.StartsWith('|')) {
            $cells = [regex]::Split($trim, '(?<!\\)\|')
            $isSeparator = $true
            foreach ($cell in $cells) {
                if ($cell.Trim() -ne '' -and $cell.Trim() -notmatch '^:?-+:?$') { $isSeparator = $false; break }
            }
            if ($isSeparator) {
                $drawn = $trim -replace '-', [string][char]0x2500 -replace '\|', [string][char]0x253C -replace ':', [string][char]0x2500
                Add-Line $i 'table' (New-McSeg ((' ' * $indent) + $drawn) $t.ViewLineNoFg)
            } else {
                $segs = [System.Collections.Generic.List[hashtable]]::new()
                $segs.Add((New-McSeg (' ' * $indent)))
                for ($c = 0; $c -lt $cells.Count; $c++) {
                    if ($c -gt 0) { $segs.Add((New-McSeg ([string][char]0x2502) $t.ViewLineNoFg)) }
                    foreach ($s in (Get-McInlineSegments $cells[$c])) { $segs.Add($s) }
                }
                Add-Line $i 'table' $segs.ToArray()
            }
            continue
        }

        Add-Line $i 'para' (Get-McInlineSegments $line)
        $out[$out.Count - 1].Raw = $line.Trim()
    }

    ,$out.ToArray()
}

function Get-McSegmentSlice {
    <# The segments covering characters [$Start, $Start + $Length) of a line. #>
    param($Segs, [int] $Start, [int] $Length)

    $result = [System.Collections.Generic.List[hashtable]]::new()
    $pos = 0
    $end = $Start + $Length
    foreach ($s in $Segs) {
        $segStart = $pos
        $segEnd = $pos + $s.Text.Length
        $pos = $segEnd
        $a = [Math]::Max($Start, $segStart)
        $b = [Math]::Min($end, $segEnd)
        if ($b -gt $a) {
            $result.Add(@{ Text = $s.Text.Substring($a - $segStart, $b - $a); Fg = $s.Fg; Attr = $s.Attr })
        }
    }
    ,$result.ToArray()
}
