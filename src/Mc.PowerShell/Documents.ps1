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

# ---------------------------------------------------------------------------
# XML. The location is file.xml::/project/dependencies/dependency[2]: element
# names as written in the document, with [n] only where siblings share a
# name (XPath's positional predicate). Resolved by walking the tree rather
# than by XPath, so a default namespace needs no prefix mapping.
#
# PowerShell's XML adapter exposes child elements as properties, so a child
# called <name> shadows an element's own .Name. Every property below is read
# through its getter method, which the adapter cannot shadow.
#
# Under an element: its attributes first as @name rows, then its child nodes
# in document order. Elements are always containers, even <version>1.0</version>;
# the Value column shows the text of a simple element, and inside it is a
# #text row. Comments, CDATA and processing instructions are leaves too.
# ---------------------------------------------------------------------------

$script:McXmlExtensions = @(
    'xml', 'xsd', 'xsl', 'xslt', 'xaml', 'svg', 'csproj', 'vbproj', 'fsproj', 'props', 'targets',
    'config', 'nuspec', 'resx', 'manifest', 'wxs', 'plist', 'pom', 'rss', 'atom', 'opml', 'kml', 'gpx'
)

function Test-McXmlFile {
    param([string] $Path)
    $ext = [System.IO.Path]::GetExtension($Path).TrimStart('.').ToLowerInvariant()
    $ext -in $script:McXmlExtensions
}

function Get-McXmlDocument {
    <# The parsed XmlDocument, from the cache when it is current. #>
    param([string] $File)

    $info = [System.IO.FileInfo]::new($File)
    if (-not $info.Exists) { throw "File not found: $File" }
    if ($info.Length -gt $script:McDocumentMaxBytes) {
        throw "$($info.Name) is $([Mc.Native.Fs]::FormatSize($info.Length)); documents over $([Mc.Native.Fs]::FormatSize($script:McDocumentMaxBytes)) are not opened as panels"
    }

    $cached = $script:McDocumentCache[$info.FullName]
    if ($cached -and $cached.Time -eq $info.LastWriteTimeUtc -and $cached.Length -eq $info.Length) { return ,$cached.Root }

    $settings = [System.Xml.XmlReaderSettings]::new()
    $settings.DtdProcessing = [System.Xml.DtdProcessing]::Ignore   # never fetch an external DTD
    $settings.XmlResolver = $null
    $settings.IgnoreWhitespace = $true
    $doc = [System.Xml.XmlDocument]::new()
    $reader = [System.Xml.XmlReader]::Create($info.FullName, $settings)
    try { $doc.Load($reader) } finally { $reader.Dispose() }

    $script:McDocumentCache[$info.FullName] = @{ Time = $info.LastWriteTimeUtc; Length = $info.Length; Root = $doc }
    ,$doc
}

function Get-McXmlChildren {
    <#
      A node's rows: attributes first, then child nodes in document order,
      each as @{ Name; Node; Kind }. Names get [n] where siblings repeat.
    #>
    param($Node)

    $rows = [System.Collections.Generic.List[hashtable]]::new()
    if ($Node.get_Attributes()) {
        foreach ($a in $Node.get_Attributes()) {
            $rows.Add(@{ Name = "@$($a.get_Name())"; Node = $a; Kind = 'attribute' })
        }
    }

    $raw = [System.Collections.Generic.List[hashtable]]::new()
    foreach ($c in $Node.get_ChildNodes()) {
        $kind = $null
        $name = $null
        switch ([string]$c.get_NodeType()) {
            'Element'               { $kind = 'element';  $name = $c.get_Name() }
            'Text'                  { $kind = 'text';     $name = '#text' }
            'CDATA'                 { $kind = 'cdata';    $name = '#cdata' }
            'Comment'               { $kind = 'comment';  $name = '#comment' }
            'ProcessingInstruction' { $kind = 'pi';       $name = "?$($c.get_Name())" }
            'XmlDeclaration'        { $kind = 'xml';      $name = '?xml' }
            default                 { }
        }
        if ($kind) { $raw.Add(@{ Name = $name; Node = $c; Kind = $kind }) }
    }

    $counts = @{}
    foreach ($r in $raw) { $counts[$r.Name] = 1 + [int]$counts[$r.Name] }
    $seen = @{}
    foreach ($r in $raw) {
        $n = 1 + [int]$seen[$r.Name]
        $seen[$r.Name] = $n
        if ($counts[$r.Name] -gt 1) { $r.Name = "$($r.Name)[$n]" }
        $rows.Add($r)
    }
    ,$rows.ToArray()
}

function Get-McXmlNode {
    <# The node a /a/b[2] path names, walking from the document node. Throws if absent. #>
    param($Doc, [string] $Path)

    $node = $Doc
    if ([string]::IsNullOrEmpty($Path)) { return ,$node }
    foreach ($seg in ($Path.TrimStart('/') -split '/')) {
        $hit = $null
        foreach ($r in (Get-McXmlChildren $node)) {
            if ($r.Name -eq $seg -and $r.Kind -eq 'element') { $hit = $r.Node; break }
        }
        if ($null -eq $hit) { throw "No such element '$seg'" }
        $node = $hit
    }
    ,$node
}

function Format-McXmlValue {
    <# One line for the Value column. #>
    param([hashtable] $Row)
    $n = $Row.Node
    switch ($Row.Kind) {
        'attribute' { return ([string]$n.get_Value() -replace '\s+', ' ') }
        'element' {
            $attrs = if ($n.get_Attributes()) { $n.get_Attributes().Count } else { 0 }
            $kids = @($n.get_ChildNodes() | Where-Object { $_.get_NodeType() -eq 'Element' }).Count
            if ($attrs -eq 0 -and $kids -eq 0) { return ([string]$n.get_InnerText() -replace '\s+', ' ').Trim() }
            $parts = @()
            if ($attrs) { $parts += "$attrs attribute$(if ($attrs -ne 1) { 's' })" }
            if ($kids) { $parts += "$kids element$(if ($kids -ne 1) { 's' })" }
            $text = ([string]$n.get_InnerText() -replace '\s+', ' ').Trim()
            if ($kids -eq 0 -and $text) { $parts += "`"$text`"" }
            return ($parts -join ', ')
        }
        'xml' { return ([string]$n.get_Value()) }
        default { return ([string]$n.get_Value() -replace '\s+', ' ').Trim() }
    }
}

function Get-McXmlContent {
    <# Viewer content: an element as indented XML, anything else as its text. #>
    param([hashtable] $Row)
    $n = $Row.Node
    $lines = [System.Collections.Generic.List[string]]::new()
    if ($Row.Kind -eq 'element') {
        $sw = [System.IO.StringWriter]::new()
        $settings = [System.Xml.XmlWriterSettings]::new()
        $settings.Indent = $true
        $settings.OmitXmlDeclaration = $true
        $xw = [System.Xml.XmlWriter]::Create($sw, $settings)
        try { $n.WriteTo($xw) } finally { $xw.Dispose() }
        foreach ($l in ($sw.ToString() -split "`r?`n")) { $lines.Add($l) }
    } else {
        foreach ($l in (([string]$n.get_Value()) -split "`r?`n")) { $lines.Add($l) }
    }
    @{ Lines = $lines; Encoding = "xml $($Row.Kind)"; Binary = $false; Truncated = $false; Length = 0 }
}

Register-McPanelSource -Source @{
    Name        = 'Xml'
    Priority    = 200
    DefaultSort = [Mc.Native.SortField]::Unsorted

    Open = {
        param($Path)
        if ((Test-McXmlFile $Path) -and [System.IO.File]::Exists($Path)) { return "$Path::/" }
        $null
    }

    Test = {
        param($Location)
        $loc = Split-McDocumentLocation $Location
        [bool]($loc -and (Test-McXmlFile $loc.File) -and [System.IO.File]::Exists($loc.File))
    }

    GetChildren = {
        param($Location, $ShowHidden)
        $loc = Split-McDocumentLocation $Location
        $doc = Get-McXmlDocument $loc.File
        $node = Get-McXmlNode $doc $loc.Pointer

        $entries = [System.Collections.Generic.List[Mc.Native.PanelEntry]]::new()
        $parent = if ($loc.Pointer -eq '') { Get-McParentPath $loc.File } else { "$($loc.File)::$(($loc.Pointer -replace '/[^/]*$', ''))" }
        if ($parent -eq "$($loc.File)::") { $parent += '/' }
        $entries.Add((New-McEntry -Name '..' -Key $parent -IsContainer $true -IsUp $true -Tag 'UP'))

        foreach ($row in (Get-McXmlChildren $node)) {
            $isContainer = $row.Kind -eq 'element'
            $size = if ($isContainer) { [long]$row.Node.get_ChildNodes().Count } else { [long]([string]$row.Node.get_Value()).Length }
            $item = [pscustomobject]@{ McXml = $true; Row = $row; Kind = $row.Kind }
            $entries.Add((New-McEntry -Name $row.Name -Key "$($loc.File)::$($loc.Pointer)/$($row.Name)" -IsContainer $isContainer -Size $size -Tag $row.Kind -Item $item))
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

    LeafName = {
        param($Location)
        $loc = Split-McDocumentLocation $Location
        if ($loc.Pointer -eq '') { return (Get-McLeafName $loc.File) }
        $loc.Pointer.Substring($loc.Pointer.LastIndexOf('/') + 1)
    }

    Descend = {
        param($Location, $Entry)
        if ($Entry.IsUp -or $Entry.IsContainer) { return $Entry.Key }
        $null
    }

    Title = {
        param($Location)
        $loc = Split-McDocumentLocation $Location
        "$(Get-McLeafName $loc.File)::$(if ($loc.Pointer) { $loc.Pointer } else { '/' })  [XML]"
    }

    Columns = {
        param($Location)
        @(
            @{ Header = 'Name'; Width = -1; Align = 'Left'
                Get = { param($e) if ($e.IsUp) { '..' } elseif ($e.IsContainer) { "/$($e.Name)" } else { $e.Name } } }
            @{ Header = 'Type'; Width = 9; Align = 'Left'
                Get = { param($e) if ($e.IsUp) { 'UP--' } else { $e.Tag } } }
            @{ Header = 'Value'; Width = -1; Align = 'Left'
                Get = { param($e) if ($e.IsUp) { '' } else { Format-McXmlValue $e.Item.Row } } }
        )
    }

    Content = {
        param($Location, $Entry)
        if ($null -eq $Entry.Item -or -not (Get-McProp $Entry.Item 'McXml')) { return $null }
        Get-McXmlContent $Entry.Item.Row
    }
}
