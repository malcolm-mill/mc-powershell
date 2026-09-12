# ---------------------------------------------------------------------------
# Panel state and the operations on it.
#
# Everything here is pure state manipulation -- no drawing, no key reading.
# That split is what makes the panel testable without a terminal: feed it
# operations, assert on the resulting state.
# ---------------------------------------------------------------------------

function New-McPanel {
    param(
        [string] $Location = (Get-Location).Path
    )

    $panel = @{
        Location   = $Location
        Source     = $null
        Entries    = @()
        Columns    = @()
        Index      = 0          # cursor position within Entries
        Top        = 0          # first visible row
        Rows       = 1          # visible row count, set by the renderer
        Sort       = [Mc.Native.SortField]::Name
        SortExplicit = $false   # the user chose Sort; a source's DefaultSort no longer applies
        Descending = $false
        ShowHidden = $false
        Marked     = @{}        # Key -> $true
        Error      = $null      # listing failed at the current location
        NavError   = $null      # the last navigation was refused; why
    }

    Update-McPanel $panel
    $panel
}

function Update-McPanel {
    param([Parameter(Mandatory)][hashtable] $Panel)

    $Panel.Error = $null
    try {
        $Panel.Source = Get-McPanelSource $Panel.Location
        $entries = & $Panel.Source.GetChildren $Panel.Location $Panel.ShowHidden
        if ($null -eq $entries) { $entries = @() }
        $entries = [Mc.Native.PanelEntry[]]@($entries)

        # A source may ask for its own order (a JSON document in document
        # order) until the user picks a sort for this panel.
        $sort = $Panel.Sort
        if (-not $Panel.SortExplicit -and $Panel.Source.ContainsKey('DefaultSort')) { $sort = $Panel.Source.DefaultSort }
        [Mc.Native.Fs]::Sort($entries, $sort, $Panel.Descending, $true)

        # Re-apply marks across a reload.
        foreach ($e in $entries) {
            if ($e.Key -and $Panel.Marked.ContainsKey($e.Key)) { $e.Marked = $true }
        }

        $Panel.Entries = $entries
        $Panel.Columns = if ($Panel.Source.Columns) { & $Panel.Source.Columns $Panel.Location } else { @() }
    } catch {
        $Panel.Entries = [Mc.Native.PanelEntry[]]@()
        $Panel.Columns = @()
        $Panel.Error = $_.Exception.Message
    }

    Set-McPanelCursor $Panel $Panel.Index
}

function Set-McPanelCursor {
    param(
        [Parameter(Mandatory)][hashtable] $Panel,
        [int] $Index
    )

    $count = $Panel.Entries.Count
    if ($count -eq 0) { $Panel.Index = 0; $Panel.Top = 0; return }

    if ($Index -lt 0) { $Index = 0 }
    if ($Index -ge $count) { $Index = $count - 1 }
    $Panel.Index = $Index

    # Keep the cursor inside the viewport.
    $rows = [Math]::Max(1, $Panel.Rows)
    if ($Panel.Index -lt $Panel.Top) { $Panel.Top = $Panel.Index }
    if ($Panel.Index -ge $Panel.Top + $rows) { $Panel.Top = $Panel.Index - $rows + 1 }

    $maxTop = [Math]::Max(0, $count - $rows)
    if ($Panel.Top -gt $maxTop) { $Panel.Top = $maxTop }
    if ($Panel.Top -lt 0) { $Panel.Top = 0 }
}

function Move-McPanelCursor {
    param(
        [Parameter(Mandatory)][hashtable] $Panel,
        [int] $Delta
    )
    Set-McPanelCursor $Panel ($Panel.Index + $Delta)
}

function Get-McPanelCurrent {
    param([Parameter(Mandatory)][hashtable] $Panel)
    if ($Panel.Entries.Count -eq 0) { return $null }
    $Panel.Entries[$Panel.Index]
}

function Get-McPanelLeafName {
    <# What the parent listing calls the panel's location; the source may know better than the path. #>
    param([Parameter(Mandatory)][hashtable] $Panel)
    if ($Panel.Source -and $Panel.Source.ContainsKey('LeafName')) {
        try { return [string](& $Panel.Source.LeafName $Panel.Location) } catch { }
    }
    Get-McLeafName $Panel.Location
}

function Set-McPanelLocation {
    param(
        [Parameter(Mandatory)][hashtable] $Panel,
        [Parameter(Mandatory)][string] $Location,
        [string] $SelectName
    )

    $previous = $Panel.Location
    $previousSource = $Panel.Source
    $Panel.NavError = $null
    $Panel.Location = $Location
    $Panel.Index = 0
    $Panel.Top = 0
    $Panel.Marked = @{}
    Update-McPanel $Panel

    if ($Panel.Error) {
        # Navigation failed: stay where we were rather than stranding the
        # user, but keep the reason. Reverting clears Panel.Error, and a
        # navigation that fails without saying why is how the registry
        # descend bug stayed hidden.
        $Panel.NavError = "Cannot open $($Location): $($Panel.Error)"
        $Panel.Location = $previous
        Update-McPanel $Panel
        return $false
    }

    # Entering a different source: its DefaultSort applies again.
    if ($Panel.Source -ne $previousSource) {
        $Panel.SortExplicit = $false
        if ($Panel.Source.ContainsKey('DefaultSort')) { Update-McPanel $Panel }
    }

    if ($SelectName) {
        for ($i = 0; $i -lt $Panel.Entries.Count; $i++) {
            if ($Panel.Entries[$i].Name -eq $SelectName) { Set-McPanelCursor $Panel $i; break }
        }
    }
    return $true
}

function Invoke-McPanelEnter {
    param([Parameter(Mandatory)][hashtable] $Panel)

    $entry = Get-McPanelCurrent $Panel
    if ($null -eq $entry) { return $null }

    $target = if ($Panel.Source.Descend) { & $Panel.Source.Descend $Panel.Location $entry } else { $null }
    if ([string]::IsNullOrEmpty($target)) { return $entry }   # a leaf: caller decides what to do

    # Going up: put the cursor on the directory we came from.
    $selectName = $null
    if ($entry.IsUp) { $selectName = Get-McPanelLeafName $Panel }

    [void](Set-McPanelLocation $Panel $target -SelectName $selectName)
    return $null
}

function Invoke-McPanelUp {
    param([Parameter(Mandatory)][hashtable] $Panel)
    if (-not $Panel.Source.Parent) { return }
    $parent = & $Panel.Source.Parent $Panel.Location
    if ([string]::IsNullOrEmpty($parent)) { return }
    $leaf = Get-McPanelLeafName $Panel
    [void](Set-McPanelLocation $Panel $parent -SelectName $leaf)
}

function Switch-McPanelMark {
    param(
        [Parameter(Mandatory)][hashtable] $Panel,
        [switch] $Advance
    )

    $entry = Get-McPanelCurrent $Panel
    if ($null -ne $entry -and -not $entry.IsUp) {
        $entry.Marked = -not $entry.Marked
        if ($entry.Marked) { $Panel.Marked[$entry.Key] = $true }
        else { $Panel.Marked.Remove($entry.Key) }
    }
    if ($Advance) { Move-McPanelCursor $Panel 1 }
}

function Set-McPanelSort {
    param(
        [Parameter(Mandatory)][hashtable] $Panel,
        [Mc.Native.SortField] $Field
    )
    $Panel.SortExplicit = $true
    if ($Panel.Sort -eq $Field) { $Panel.Descending = -not $Panel.Descending }
    else { $Panel.Sort = $Field; $Panel.Descending = $false }

    $current = Get-McPanelCurrent $Panel
    Update-McPanel $Panel
    if ($current) {
        for ($i = 0; $i -lt $Panel.Entries.Count; $i++) {
            if ($Panel.Entries[$i].Key -eq $current.Key) { Set-McPanelCursor $Panel $i; break }
        }
    }
}

function Get-McPanelStats {
    param([Parameter(Mandatory)][hashtable] $Panel)

    $markedCount = 0
    $markedBytes = 0L
    foreach ($e in $Panel.Entries) {
        if ($e.Marked) {
            $markedCount++
            if ($e.Size -gt 0) { $markedBytes += $e.Size }
        }
    }
    @{ Count = $Panel.Entries.Count; MarkedCount = $markedCount; MarkedBytes = $markedBytes }
}
