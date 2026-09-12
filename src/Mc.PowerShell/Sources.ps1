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
#   Content     [scriptblock]   param($Location, $Entry) -> viewer content or $null
#                               (optional: what Enter/F3 shows for a leaf that
#                               is not a file -- a registry value, a variable)
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

function Get-McChildPath {
    <#
      Drive-qualified path of an entry under a location, for descending.

      Not Convert-Path: that returns the provider-internal form, which is
      right for the filesystem and wrong for everything else --
      HKEY_LOCAL_MACHINE\SOFTWARE\X for the registry, the bare name for
      Env:, and an error for Cert:. Nothing can navigate to those. Joining
      the child name onto the location we are already on stays in whatever
      drive notation got us here.
    #>
    param([string] $Location, $Entry)
    $child = [string](Get-McProp $Entry.Item 'PSChildName')
    if ([string]::IsNullOrEmpty($child)) { $child = $Entry.Name }
    Join-Path $Location $child
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

# --- registry values as rows ------------------------------------------------
# The registry provider's child items are keys only; values are properties of
# a key. A registry browser has to show both, as mc shows files under
# directories, so the PSProvider source appends one leaf row per value.

$script:McRegistryKindNames = @{
    'String'       = 'REG_SZ'
    'ExpandString' = 'REG_EXPAND_SZ'
    'Binary'       = 'REG_BINARY'
    'DWord'        = 'REG_DWORD'
    'MultiString'  = 'REG_MULTI_SZ'
    'QWord'        = 'REG_QWORD'
    'None'         = 'REG_NONE'
}

function Get-McRegistryValueRows {
    <# One leaf PanelEntry per value of the key at $Location. #>
    param([string] $Location)

    $rows = [System.Collections.Generic.List[Mc.Native.PanelEntry]]::new()
    $key = $null
    try { $key = Get-Item -LiteralPath $Location -ErrorAction Stop } catch { return $rows.ToArray() }
    if ($null -eq $key -or -not ($key.PSObject.Methods['GetValueNames'])) { return $rows.ToArray() }

    foreach ($name in $key.GetValueNames()) {
        $kind = 'Unknown'
        $data = $null
        try { $kind = [string]$key.GetValueKind($name) } catch { }
        try { $data = $key.GetValue($name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames) } catch { }

        $display = if ([string]::IsNullOrEmpty($name)) { '(default)' } else { $name }
        $kindName = if ($script:McRegistryKindNames.ContainsKey($kind)) { $script:McRegistryKindNames[$kind] } else { $kind }
        $item = [pscustomobject]@{
            McRegistryValue = $true
            Key             = $Location
            Name            = $display
            Kind            = $kindName
            Data            = $data
        }
        $rows.Add((New-McEntry -Name $display -Key "$Location::$display" -IsContainer $false -Tag $kindName -Item $item))
    }
    $rows.ToArray()
}

function Format-McRegistryData {
    <# A registry value's data on one line, for the Data column. #>
    param([string] $Kind, $Data)

    if ($null -eq $Data) { return '' }
    switch ($Kind) {
        'REG_DWORD'    { return ('0x{0:x8} ({0})' -f [uint32]$Data) }
        'REG_QWORD'    { return ('0x{0:x16} ({0})' -f [uint64]$Data) }
        'REG_MULTI_SZ' { return (@($Data) -join ' | ') }
        'REG_BINARY'   {
            $bytes = [byte[]]$Data
            $head = @($bytes | Select-Object -First 16 | ForEach-Object { '{0:x2}' -f $_ }) -join ' '
            if ($bytes.Length -gt 16) { $head += ' ...' }
            return "$head ($($bytes.Length) bytes)"
        }
        default        { return (([string]$Data) -replace '\s+', ' ') }
    }
}

function Get-McRegistryValueContent {
    <# Viewer content for a registry value: what it is, then its data. #>
    param($Item)

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("Key:  $($Item.Key)")
    $lines.Add("Name: $($Item.Name)")
    $lines.Add("Type: $($Item.Kind)")
    $lines.Add('')

    $data = $Item.Data
    switch ($Item.Kind) {
        'REG_MULTI_SZ' { foreach ($s in @($data)) { $lines.Add([string]$s) } }
        'REG_DWORD'    { $lines.Add(('{0}  (0x{0:x8})' -f [uint32]$data)) }
        'REG_QWORD'    { $lines.Add(('{0}  (0x{0:x16})' -f [uint64]$data)) }
        'REG_BINARY'   {
            $bytes = [byte[]]$data
            $lines.Add("$($bytes.Length) bytes")
            $lines.Add('')
            for ($o = 0; $o -lt $bytes.Length; $o += 16) {
                $chunk = $bytes[$o..([Math]::Min($o + 15, $bytes.Length - 1))]
                $hex = @($chunk | ForEach-Object { '{0:x2}' -f $_ }) -join ' '
                $ascii = -join ($chunk | ForEach-Object { if ($_ -ge 32 -and $_ -lt 127) { [char]$_ } else { '.' } })
                $lines.Add(('{0:x8}  {1,-47}  {2}' -f $o, $hex, $ascii))
            }
        }
        'REG_EXPAND_SZ' {
            $lines.Add([string]$data)
            $expanded = [Environment]::ExpandEnvironmentVariables([string]$data)
            if ($expanded -ne [string]$data) { $lines.Add(''); $lines.Add("Expanded: $expanded") }
        }
        default        { if ($null -ne $data) { foreach ($l in (([string]$data) -split "`r?`n")) { $lines.Add($l) } } }
    }

    @{ Lines = $lines; Encoding = $Item.Kind; Binary = $false; Truncated = $false; Length = 0 }
}

# --- certificates ------------------------------------------------------------
# The certificate provider names each certificate by its thumbprint, a SHA-1
# hash of the bytes that identifies it and says nothing about it. The panel
# shows what the certificate says instead, and keeps the thumbprint as the key.

function Test-McCertificate {
    param($Item)
    $null -ne $Item -and $Item -is [System.Security.Cryptography.X509Certificates.X509Certificate2]
}

function Get-McCertificateName {
    <# Friendly name, else the subject's common name, else the thumbprint. #>
    param($Cert)
    $name = [string](Get-McProp $Cert 'FriendlyName')
    if ([string]::IsNullOrWhiteSpace($name)) {
        try { $name = $Cert.GetNameInfo([System.Security.Cryptography.X509Certificates.X509NameType]::SimpleName, $false) } catch { $name = '' }
    }
    if ([string]::IsNullOrWhiteSpace($name)) { $name = [string]$Cert.Thumbprint }
    $name
}

function Get-McCertificateIssuer {
    <# The issuer's common name, or "self-signed" when it issued itself. #>
    param($Cert)
    if ($Cert.Subject -eq $Cert.Issuer) { return 'self-signed' }
    try { return $Cert.GetNameInfo([System.Security.Cryptography.X509Certificates.X509NameType]::SimpleName, $true) } catch { return [string]$Cert.Issuer }
}

function Get-McCertificateContent {
    <# Viewer content: everything the certificate says about itself. #>
    param($Cert, [string] $Location)

    $l = [System.Collections.Generic.List[string]]::new()
    $l.Add("Store:         $Location")
    $l.Add("Friendly name: $($Cert.FriendlyName)")
    $l.Add("Subject:       $($Cert.Subject)")
    $l.Add("Issuer:        $($Cert.Issuer)$(if ($Cert.Subject -eq $Cert.Issuer) { '  (self-signed)' })")
    $l.Add("Valid from:    $($Cert.NotBefore.ToString('yyyy-MM-dd HH:mm'))")
    $l.Add("Valid to:      $($Cert.NotAfter.ToString('yyyy-MM-dd HH:mm'))$(if ($Cert.NotAfter -lt [datetime]::Now) { '  EXPIRED' })")
    $l.Add("Private key:   $(if ($Cert.HasPrivateKey) { 'yes' } else { 'no' })")
    $l.Add("Serial number: $($Cert.SerialNumber)")
    $l.Add("Thumbprint:    $($Cert.Thumbprint)")
    $l.Add("Version:       $($Cert.Version)")
    $l.Add("Signature:     $($Cert.SignatureAlgorithm.FriendlyName)")
    try { $l.Add("Public key:    $($Cert.PublicKey.Oid.FriendlyName) $($Cert.PublicKey.Key.KeySize) bits") } catch { }

    $purposes = @()
    try { $purposes = @($Cert.EnhancedKeyUsageList | ForEach-Object { $_.FriendlyName }) } catch { }
    $l.Add('')
    $l.Add('Purposes:      ' + $(if ($purposes.Count) { $purposes -join ', ' } else { '(none stated -- any)' }))

    $sans = @()
    foreach ($ext in $Cert.Extensions) {
        if ($ext.Oid.Value -eq '2.5.29.17') { try { $sans += ($ext.Format($false) -split ', ') } catch { } }
    }
    if ($sans.Count) { $l.Add('Alt names:     ' + ($sans -join ', ')) }

    @{ Lines = $l; Encoding = 'certificate'; Binary = $false; Truncated = $false; Length = 0 }
}

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
            # Keys and values share the listing, as directories and files do.
            return @(
                @{ Header = 'Name'; Width = -1; Align = 'Left'
                    Get = { param($e) if ($e.IsUp) { '..' } elseif ($e.IsContainer) { "/$($e.Name)" } else { $e.Name } } }
                @{ Header = 'Type'; Width = 13; Align = 'Left'
                    Get = { param($e) if ($e.IsUp) { 'UP--' } elseif ($e.IsContainer) { 'KEY' } else { $e.Tag } } }
                @{ Header = 'Data'; Width = -1; Align = 'Left'
                    Get = { param($e)
                        if ($e.IsUp) { '' }
                        elseif ($e.IsContainer) { "$(Get-McProp $e.Item 'SubKeyCount') subkeys, $(Get-McProp $e.Item 'ValueCount') values" }
                        else { Format-McRegistryData $e.Tag (Get-McProp $e.Item 'Data') }
                    } }
            )
        }
        'Certificate' {
            # Locations and stores are containers; certificates are leaves
            # named by what they say, not by their thumbprint.
            return @(
                @{ Header = 'Name'; Width = -1; Align = 'Left'
                    Get = { param($e) if ($e.IsUp) { '..' } elseif ($e.IsContainer) { "/$($e.Name)" } else { $e.Name } } }
                @{ Header = 'Issued by'; Width = -1; Align = 'Left'
                    Get = { param($e) if (Test-McCertificate $e.Item) { Get-McCertificateIssuer $e.Item } else { '' } } }
                @{ Header = 'Expires'; Width = 10; Align = 'Left'
                    Get = { param($e)
                        if ($e.IsUp) { 'UP--' }
                        elseif (-not (Test-McCertificate $e.Item)) { '' }
                        else { $e.Item.NotAfter.ToString('yyyy-MM-dd') }
                    } }
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

        # An empty listing with errors is a failure, not an empty container:
        # a registry key this account cannot read lists nothing and says
        # "access is not allowed" on the error stream. Surface that, so the
        # panel refuses to enter rather than showing a blank key.
        $items = @()
        $listErrors = @()
        try {
            $items = @(Get-ChildItem -LiteralPath $Location -Force:$ShowHidden -ErrorAction SilentlyContinue -ErrorVariable listErrors)
        } catch { $listErrors = @($_) }
        if ($items.Count -eq 0 -and $listErrors.Count -gt 0) {
            throw ([string]$listErrors[0].Exception.Message)
        }

        foreach ($item in $items) {
            $isContainer = [bool](Get-McProp $item 'PSIsContainer')

            $name = [string](Get-McProp $item 'PSChildName')
            foreach ($fallback in 'Name', 'Key', 'Subject') {
                if (-not [string]::IsNullOrEmpty($name)) { break }
                $name = [string](Get-McProp $item $fallback)
            }
            if ([string]::IsNullOrEmpty($name)) { $name = [string]$item }
            if (Test-McCertificate $item) { $name = Get-McCertificateName $item }

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

        if ((Get-McLocationProvider $Location) -eq 'Registry') {
            foreach ($row in (Get-McRegistryValueRows $Location)) { $entries.Add($row) }
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
        Get-McChildPath $Location $Entry
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

    Content = {
        param($Location, $Entry)
        if ($null -eq $Entry.Item) { return $null }
        if (Get-McProp $Entry.Item 'McRegistryValue') { return (Get-McRegistryValueContent $Entry.Item) }
        if (Test-McCertificate $Entry.Item) { return (Get-McCertificateContent $Entry.Item $Location) }
        # Anything with a Value or Definition (Env:, Variable:, Function:,
        # Alias:) shows it; better than "not a file on disk".
        foreach ($prop in 'Definition', 'Value') {
            $v = Get-McProp $Entry.Item $prop
            if ($null -ne $v) {
                $lines = [string[]](([string]$v) -split "`r?`n")
                return @{ Lines = $lines; Encoding = $prop.ToLowerInvariant(); Binary = $false; Truncated = $false; Length = 0 }
            }
        }
        $null
    }
}
