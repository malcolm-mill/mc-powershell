# mc-powershell : Midnight Commander's UI over PowerShell's object model.
# Copyright (C) 2026  Malcolm Mill
# Licensed under the GNU General Public License v3 or later. See COPYING.

# ---------------------------------------------------------------------------
# Documents as panels: Enter on a .json file descends into its structure, as
# mc's VFS descends into an archive. The location inside a file is
#
#     C:\path\file.json::/servers/0
#
# The part after "::" is a JSON Pointer (RFC 6901). A colon cannot occur in a
# Windows path after the drive letter, so "::" never collides with a real
# path. Ctrl+PgUp from the root comes back out to the directory with the
# cursor on the file, which is mc's behaviour for an archive.
#
# Documents are parsed once and cached by path and modification time, so
# navigation is a lookup. System.Text.Json.Nodes keeps key order, which is
# why it is used rather than ConvertFrom-Json.
# ---------------------------------------------------------------------------

$script:McDocumentCache = @{}
$script:McDocumentMaxBytes = 64MB

function Split-McDocumentLocation {
    <# "C:\x\a.json::/b/0" -> @{ File = 'C:\x\a.json'; Pointer = '/b/0' }, or $null. #>
    param([string] $Location)
    if ([string]::IsNullOrEmpty($Location)) { return $null }
    $i = $Location.IndexOf('::')
    if ($i -lt 1) { return $null }
    $pointer = $Location.Substring($i + 2)
    if ($pointer -eq '' -or $pointer -eq '/') { $pointer = '' }
    @{ File = $Location.Substring(0, $i); Pointer = $pointer }
}

function ConvertTo-McPointerSegment {
    param([string] $Key)
    $Key.Replace('~', '~0').Replace('/', '~1')
}

function ConvertFrom-McPointerSegment {
    param([string] $Segment)
    $Segment.Replace('~1', '/').Replace('~0', '~')
}

function Get-McJsonDocument {
    <# The parsed root node of a JSON file, from the cache when it is current. #>
    param([string] $File)

    $info = [System.IO.FileInfo]::new($File)
    if (-not $info.Exists) { throw "File not found: $File" }
    if ($info.Length -gt $script:McDocumentMaxBytes) {
        throw "$($info.Name) is $([Mc.Native.Fs]::FormatSize($info.Length)); documents over $([Mc.Native.Fs]::FormatSize($script:McDocumentMaxBytes)) are not opened as panels"
    }

    # JsonObject and JsonArray are enumerable, and PowerShell unrolls an
    # enumerable function result into its elements. The leading comma wraps
    # the node so the caller receives the node itself, not its children.
    $cached = $script:McDocumentCache[$info.FullName]
    if ($cached -and $cached.Time -eq $info.LastWriteTimeUtc -and $cached.Length -eq $info.Length) { return ,$cached.Root }

    $text = [System.IO.File]::ReadAllText($info.FullName)
    $docOptions = [System.Text.Json.JsonDocumentOptions]::new()
    $docOptions.CommentHandling = [System.Text.Json.JsonCommentHandling]::Skip
    $docOptions.AllowTrailingCommas = $true
    $root = [System.Text.Json.Nodes.JsonNode]::Parse($text, $null, $docOptions)

    $script:McDocumentCache[$info.FullName] = @{ Time = $info.LastWriteTimeUtc; Length = $info.Length; Root = $root }
    ,$root
}

function Get-McJsonNode {
    <# The node a JSON Pointer names, or throws. $null is a valid node (JSON null). #>
    param($Root, [string] $Pointer)

    $node = $Root
    if ([string]::IsNullOrEmpty($Pointer)) { return ,$node }
    foreach ($seg in ($Pointer.TrimStart('/') -split '/')) {
        $key = ConvertFrom-McPointerSegment $seg
        if ($node -is [System.Text.Json.Nodes.JsonObject]) {
            if (-not $node.ContainsKey($key)) { throw "No such key '$key'" }
            $node = $node[$key]
        } elseif ($node -is [System.Text.Json.Nodes.JsonArray]) {
            $n = 0
            if (-not [int]::TryParse($key, [ref]$n) -or $n -lt 0 -or $n -ge $node.Count) { throw "No such index '$key'" }
            $node = $node[$n]
        } else {
            throw "'$key' is below a value, not a container"
        }
    }
    ,$node   # see Get-McJsonDocument
}

function Get-McJsonKind {
    <# object | array | string | number | bool | null #>
    param($Node)
    if ($null -eq $Node) { return 'null' }
    if ($Node -is [System.Text.Json.Nodes.JsonObject]) { return 'object' }
    if ($Node -is [System.Text.Json.Nodes.JsonArray]) { return 'array' }
    $kind = $Node.GetValueKind()
    switch ([string]$kind) {
        'String' { 'string' }
        'Number' { 'number' }
        'True'   { 'bool' }
        'False'  { 'bool' }
        'Null'   { 'null' }
        default  { ([string]$kind).ToLowerInvariant() }
    }
}

function Format-McJsonValue {
    <# One line for the Value column. #>
    param($Node)
    switch (Get-McJsonKind $Node) {
        'object' { "{$($Node.Count) key$(if ($Node.Count -ne 1) { 's' })}" }
        'array'  { "[$($Node.Count) item$(if ($Node.Count -ne 1) { 's' })]" }
        'null'   { 'null' }
        default  { $Node.ToJsonString() -replace '\s+', ' ' }
    }
}

function Get-McJsonContent {
    <# Viewer content: a leaf's value as text, a container's subtree as JSON. #>
    param($Node, [string] $Location)

    $kind = Get-McJsonKind $Node
    $lines = [System.Collections.Generic.List[string]]::new()
    if ($kind -in 'object', 'array') {
        $opts = [System.Text.Json.JsonSerializerOptions]::new()
        $opts.WriteIndented = $true
        foreach ($l in ($Node.ToJsonString($opts) -split "`r?`n")) { $lines.Add($l) }
    } elseif ($kind -eq 'string') {
        foreach ($l in (([string]$Node.ToString()) -split "`r?`n")) { $lines.Add($l) }
    } else {
        $lines.Add((Format-McJsonValue $Node))
    }
    @{ Lines = $lines; Encoding = "json $kind"; Binary = $false; Truncated = $false; Length = 0 }
}

function Get-McJsonChildName {
    <# How a child is listed: its key for an object, [i] for an array. #>
    param($Parent, [string] $Segment)
    if ($Parent -is [System.Text.Json.Nodes.JsonArray]) { return "[$Segment]" }
    ConvertFrom-McPointerSegment $Segment
}

Register-McPanelSource -Source @{
    Name        = 'Json'
    Priority    = 200
    DefaultSort = [Mc.Native.SortField]::Unsorted   # document order; [10] must not sort before [2]

    # Enter on a .json file in a filesystem panel opens it here.
    Open = {
        param($Path)
        if ($Path -match '\.json$' -and [System.IO.File]::Exists($Path)) { return "$Path::/" }
        $null
    }

    Test = {
        param($Location)
        $loc = Split-McDocumentLocation $Location
        [bool]($loc -and $loc.File -match '\.json$' -and [System.IO.File]::Exists($loc.File))
    }

    GetChildren = {
        param($Location, $ShowHidden)
        $loc = Split-McDocumentLocation $Location
        $root = Get-McJsonDocument $loc.File
        $node = Get-McJsonNode $root $loc.Pointer

        $entries = [System.Collections.Generic.List[Mc.Native.PanelEntry]]::new()
        $parent = if ($loc.Pointer -eq '') { Get-McParentPath $loc.File } else { "$($loc.File)::$(($loc.Pointer -replace '/[^/]*$', ''))" }
        if ($parent -eq "$($loc.File)::") { $parent += '/' }
        $entries.Add((New-McEntry -Name '..' -Key $parent -IsContainer $true -IsUp $true -Tag 'UP'))

        $children = @()
        if ($node -is [System.Text.Json.Nodes.JsonObject]) {
            foreach ($kv in $node.GetEnumerator()) { $children += ,@($kv.Key, (ConvertTo-McPointerSegment $kv.Key), $kv.Value) }
        } elseif ($node -is [System.Text.Json.Nodes.JsonArray]) {
            for ($i = 0; $i -lt $node.Count; $i++) { $children += ,@("[$i]", [string]$i, $node[$i]) }
        }

        foreach ($c in $children) {
            $name, $seg, $child = $c
            $kind = Get-McJsonKind $child
            $isContainer = $kind -in 'object', 'array'
            $size = if ($isContainer) { [long]$child.Count } elseif ($kind -eq 'string') { [long]$child.ToString().Length } else { -1L }
            $item = [pscustomobject]@{ McJson = $true; Node = $child; Kind = $kind }
            $entries.Add((New-McEntry -Name $name -Key "$($loc.File)::$($loc.Pointer)/$seg" -IsContainer $isContainer -Size $size -Tag $kind -Item $item))
        }
        $entries.ToArray()
    }

    Parent = {
        param($Location)
        $loc = Split-McDocumentLocation $Location
        if ($loc.Pointer -eq '') { return (Get-McParentPath $loc.File) }
        $p = $loc.Pointer -replace '/[^/]*$', ''
        "$($loc.File)::$(if ($p -eq '') { '/' } else { $p })"
    }

    # What the parent listing calls this location, so going up lands on it.
    LeafName = {
        param($Location)
        $loc = Split-McDocumentLocation $Location
        if ($loc.Pointer -eq '') { return (Get-McLeafName $loc.File) }
        $parentPointer = $loc.Pointer -replace '/[^/]*$', ''
        $seg = $loc.Pointer.Substring($loc.Pointer.LastIndexOf('/') + 1)
        try {
            $parentNode = Get-McJsonNode (Get-McJsonDocument $loc.File) $parentPointer
            Get-McJsonChildName $parentNode $seg
        } catch { ConvertFrom-McPointerSegment $seg }
    }

    Descend = {
        param($Location, $Entry)
        if ($Entry.IsUp -or $Entry.IsContainer) { return $Entry.Key }
        $null
    }

    Title = {
        param($Location)
        $loc = Split-McDocumentLocation $Location
        "$(Get-McLeafName $loc.File)::$(if ($loc.Pointer) { $loc.Pointer } else { '/' })  [JSON]"
    }

    Columns = {
        param($Location)
        @(
            @{ Header = 'Name'; Width = -1; Align = 'Left'
                Get = { param($e) if ($e.IsUp) { '..' } elseif ($e.IsContainer) { "/$($e.Name)" } else { $e.Name } } }
            @{ Header = 'Type'; Width = 7; Align = 'Left'
                Get = { param($e) if ($e.IsUp) { 'UP--' } else { $e.Tag } } }
            @{ Header = 'Value'; Width = -1; Align = 'Left'
                Get = { param($e) if ($e.IsUp) { '' } else { Format-McJsonValue (Get-McProp $e.Item 'Node') } } }
        )
    }

    Content = {
        param($Location, $Entry)
        if ($null -eq $Entry.Item -or -not (Get-McProp $Entry.Item 'McJson')) { return $null }
        Get-McJsonContent $Entry.Item.Node $Entry.Key
    }
}
