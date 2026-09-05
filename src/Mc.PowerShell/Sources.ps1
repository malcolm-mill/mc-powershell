# ---------------------------------------------------------------------------
# Panel sources: the plugin contract.
#
# A panel does not know about files. It knows about a *source* that can list a
# location as rows, say what the columns are, and navigate up and down. The
# filesystem is just the first implementation; any PSProvider is another.
#
# A source is a hashtable:
#   Name        [string]        identifier
#   Priority    [int]           higher wins when several sources match
#   Test        [scriptblock]   param($Location) -> [bool]
#   GetChildren [scriptblock]   param($Location, $ShowHidden) -> Mc.Native.PanelEntry[]
#   Parent      [scriptblock]   param($Location) -> location or $null
#   Descend     [scriptblock]   param($Location, $Entry) -> new location or $null
#   Title       [scriptblock]   param($Location) -> string
#   Columns     [scriptblock]   param($Location) -> column spec array
#
# A column spec is:
#   @{ Header = 'Size'; Width = 8; Align = 'Right'; Get = { param($e) ... } }
#   Width -1 means "flex": share whatever is left over.
# ---------------------------------------------------------------------------

$script:McSources = [System.Collections.Generic.List[hashtable]]::new()

function Register-McPanelSource {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable] $Source
    )
    foreach ($required in 'Name', 'Test', 'GetChildren') {
        if (-not $Source.ContainsKey($required)) {
            throw "Panel source is missing required key '$required'."
        }
    }
    if (-not $Source.ContainsKey('Priority')) { $Source.Priority = 0 }
    $script:McSources.Add($Source)
}

function Get-McPanelSource {
    param([Parameter(Mandatory)][string] $Location)

    $best = $null
    foreach ($s in $script:McSources) {
        try { $ok = & $s.Test $Location } catch { $ok = $false }
        if ($ok -and ($null -eq $best -or $s.Priority -gt $best.Priority)) { $best = $s }
    }
    if ($null -eq $best) { throw "No panel source can handle '$Location'." }
    $best
}

function New-McEntry {
    param(
        [string] $Name,
        [string] $Key,
        [bool] $IsContainer = $false,
        [bool] $IsUp = $false,
        [long] $Size = -1,
        [datetime] $Modified = [datetime]::MinValue,
        [string] $Tag = '',
        $Item = $null
    )
    $e = [Mc.Native.PanelEntry]::new()
    $e.Name = $Name
    $e.Key = $Key
    $e.IsContainer = $IsContainer
    $e.IsUp = $IsUp
    $e.Size = $Size
    $e.Modified = $Modified
    $e.Tag = $Tag
    $e.Item = $Item
    $e
}

function Get-McProp {
    <#
      Strict-mode-safe property read. Provider items are wildly inconsistent --
      Env: yields DictionaryEntry with no PSChildName, Registry yields
      RegistryKey, Cert: yields X509Certificate2 -- so every property access on
      an arbitrary provider object has to tolerate absence.
    #>
    param($Object, [string] $Name)
    if ($null -eq $Object) { return $null }
    $prop = $Object.PSObject.Properties[$Name]
    if ($null -eq $prop) { return $null }
    try { return $prop.Value } catch { return $null }
}

function Get-McParentPath {
    <#
      Parent of a provider path, or $null at a root.

      Note: "Split-Path -LiteralPath X -Parent" is NOT valid -- -LiteralPath
      cannot be combined with the -Parent/-Leaf switches, and PowerShell reports
      it as an unresolvable parameter set. -LiteralPath on its own already
      returns the parent, which is also what we want for Env:\ and HKLM:\.
    #>
    param([string] $Path)
    if ([string]::IsNullOrEmpty($Path)) { return $null }
    $parent = try { Split-Path -LiteralPath $Path } catch { $null }
    if ([string]::IsNullOrEmpty($parent)) { return $null }
    $parent
}

function Get-McLeafName {
    <# Last segment of a path, without Split-Path's wildcard expansion. #>
    param([string] $Path)
    if ([string]::IsNullOrEmpty($Path)) { return '' }
    $seps = [char[]]@([char]92, [char]47)   # backslash, forward slash
    $trimmed = $Path.TrimEnd($seps)
    $i = $trimmed.LastIndexOfAny($seps)
    if ($i -lt 0) { return $trimmed }
    $trimmed.Substring($i + 1)
}

# ---------------------------------------------------------------------------
# Source 1: the filesystem. Enumeration happens in C# because this is the one
# listing that has to stay fast on a 50k-entry directory.
# ---------------------------------------------------------------------------

Register-McPanelSource -Source @{
    Name     = 'FileSystem'
    Priority = 100

    Test = {
        param($Location)
        if ([string]::IsNullOrWhiteSpace($Location)) { return $false }
        # A real filesystem path, not Env:\ or HKLM:\
        return ($Location -match '^[A-Za-z]:[\\/]' -or $Location -match '^[\\/]{2}' -or $Location -match '^/')
    }

    GetChildren = {
        param($Location, $ShowHidden)
        [Mc.Native.Fs]::List($Location, [bool]$ShowHidden)
    }

    Parent = {
        param($Location)
        Get-McParentPath $Location
    }

    Descend = {
        param($Location, $Entry)
        if ($Entry.IsUp) { return $Entry.Key }
        if ($Entry.IsContainer) { return $Entry.Key }
        return $null
    }

    Title = { param($Location) $Location }

    Columns = {
        param($Location)
        @(
            @{ Header = 'Name'; Width = -1; Align = 'Left'
                Get = { param($e) if ($e.IsContainer -and -not $e.IsUp) { "/$($e.Name)" } else { $e.Name } }
            }
            @{ Header = 'Size'; Width = 8; Align = 'Right'
                Get = { param($e)
                    if ($e.IsUp) { 'UP--' }
                    elseif ($e.IsContainer) { 'DIR' }
                    else { [Mc.Native.Fs]::FormatSize($e.Size) }
                }
            }
            @{ Header = 'Modify time'; Width = 15; Align = 'Left'
                Get = { param($e)
                    if ($e.Modified -eq [datetime]::MinValue) { '' }
                    else { $e.Modified.ToString('MMM dd HH:mm', [cultureinfo]::InvariantCulture) }
                }
            }
        )
    }
}

# ---------------------------------------------------------------------------
# Source 2: any PowerShell provider. This is the whole point of the project --
# the same two-panel UI over Env:, HKLM:, Cert:, Function:, or anything a
# third-party module mounts as a PSDrive.
# ---------------------------------------------------------------------------

function Get-McProviderColumns {
    param([string] $ProviderName)

    switch ($ProviderName) {
        'Environment' {
            return @(
                @{ Header = 'Name'; Width = 24; Align = 'Left'; Get = { param($e) $e.Name } }
                @{ Header = 'Value'; Width = -1; Align = 'Left'; Get = { param($e) ([string](Get-McProp $e.Item 'Value')) -replace '\s+', ' ' } }
            )
        }
        'Registry' {
            return @(
                @{ Header = 'Key'; Width = -1; Align = 'Left'
                    Get = { param($e) if ($e.IsUp) { '..' } else { "/$($e.Name)" } } }
                @{ Header = 'Values'; Width = 7; Align = 'Right'
                    Get = { param($e) if ($e.IsUp) { 'UP--' } else { [string](Get-McProp $e.Item 'ValueCount') } } }
                @{ Header = 'Subkeys'; Width = 8; Align = 'Right'
                    Get = { param($e) if ($e.IsUp) { '' } else { [string](Get-McProp $e.Item 'SubKeyCount') } } }
            )
        }
        'Certificate' {
            return @(
                @{ Header = 'Name'; Width = -1; Align = 'Left'; Get = { param($e) $e.Name } }
                @{ Header = 'Expires'; Width = 12; Align = 'Left'
                    Get = { param($e) $d = Get-McProp $e.Item 'NotAfter'; if ($d -is [datetime]) { $d.ToString('yyyy-MM-dd') } else { '' } } }
            )
        }
        'Function' {
            return @(
                @{ Header = 'Name'; Width = 28; Align = 'Left'; Get = { param($e) $e.Name } }
                @{ Header = 'Definition'; Width = -1; Align = 'Left'
                    Get = { param($e) ([string](Get-McProp $e.Item 'Definition')) -replace '\s+', ' ' } }
            )
        }
        'Alias' {
            return @(
                @{ Header = 'Name'; Width = 28; Align = 'Left'; Get = { param($e) $e.Name } }
                @{ Header = 'Definition'; Width = -1; Align = 'Left'
                    Get = { param($e) ([string](Get-McProp $e.Item 'Definition')) -replace '\s+', ' ' } }
            )
        }
        'Variable' {
            return @(
                @{ Header = 'Name'; Width = 24; Align = 'Left'; Get = { param($e) $e.Name } }
                @{ Header = 'Value'; Width = -1; Align = 'Left'
                    Get = { param($e) ([string](Get-McProp $e.Item 'Value')) -replace '\s+', ' ' } }
            )
        }
    }

    # Anything we have never seen: name plus the .NET type, which is always useful.
    @(
        @{ Header = 'Name'; Width = -1; Align = 'Left'; Get = { param($e) $e.Name } }
        @{ Header = 'Type'; Width = 22; Align = 'Left'
            Get = { param($e) if ($e.Item) { $e.Item.GetType().Name } else { '' } } }
    )
}

function Get-McLocationProvider {
    param([string] $Location)
    try {
        $qualifier = ($Location -split ':')[0]
        $drive = Get-PSDrive -Name $qualifier -ErrorAction Stop
        return $drive.Provider.Name
    } catch { return $null }
}

Register-McPanelSource -Source @{
    Name     = 'PSProvider'
    Priority = 10

    Test = {
        param($Location)
        if ([string]::IsNullOrWhiteSpace($Location)) { return $false }
        try { return [bool](Test-Path -LiteralPath $Location -ErrorAction Stop) } catch { return $false }
    }

    GetChildren = {
        param($Location, $ShowHidden)

        $entries = [System.Collections.Generic.List[Mc.Native.PanelEntry]]::new()

        $parent = Get-McParentPath $Location
        if (-not [string]::IsNullOrEmpty($parent)) {
            $entries.Add((New-McEntry -Name '..' -Key $parent -IsContainer $true -IsUp $true -Tag 'UP'))
        }

        $items = @()
        try {
            $items = Get-ChildItem -LiteralPath $Location -Force:$ShowHidden -ErrorAction SilentlyContinue
        } catch { }

        foreach ($item in $items) {
            $isContainer = [bool](Get-McProp $item 'PSIsContainer')

            $name = [string](Get-McProp $item 'PSChildName')
            foreach ($fallback in 'Name', 'Key', 'Subject') {
                if (-not [string]::IsNullOrEmpty($name)) { break }
                $name = [string](Get-McProp $item $fallback)
            }
            if ([string]::IsNullOrEmpty($name)) { $name = [string]$item }

            $key = [string](Get-McProp $item 'PSPath')
            if ([string]::IsNullOrEmpty($key)) { $key = Join-Path $Location $name }

            $modified = [datetime]::MinValue
            foreach ($prop in 'LastWriteTime', 'NotAfter', 'CreationTime') {
                $v = Get-McProp $item $prop
                if ($v -is [datetime]) { $modified = $v; break }
            }

            $size = -1L
            $len = Get-McProp $item 'Length'
            if ($len -is [long]) { $size = $len }

            $entries.Add((New-McEntry -Name $name -Key $key -IsContainer $isContainer -Size $size -Modified $modified -Item $item))
        }

        $entries.ToArray()
    }

    Parent = {
        param($Location)
        Get-McParentPath $Location
    }

    Descend = {
        param($Location, $Entry)
        if ($Entry.IsUp) { return $Entry.Key }
        if (-not $Entry.IsContainer) { return $null }
        # PSPath is provider-qualified; convert it back to a display path.
        try { return (Convert-Path -LiteralPath $Entry.Key -ErrorAction Stop) }
        catch { return (Join-Path $Location $Entry.Name) }
    }

    Title = {
        param($Location)
        $p = Get-McLocationProvider $Location
        if ($p) { "$Location  [$p]" } else { $Location }
    }

    Columns = {
        param($Location)
        Get-McProviderColumns (Get-McLocationProvider $Location)
    }
}
