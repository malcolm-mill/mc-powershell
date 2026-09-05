# ---------------------------------------------------------------------------
# Safety modes.
#
# ReadOnly is the default and is never persisted -- every start is read-only
# until the user deliberately says otherwise.
#
# There are two very different guarantees here, and it matters not to conflate
# them:
#
#   1. mc's OWN operations (F5 copy, F8 delete, ...) go through
#      Assert-McWritable. That is a single choke point, enforced by
#      construction, and it is airtight: an operation that does not call it
#      does not exist.
#
#   2. The COMMAND LINE runs arbitrary PowerShell. Test-McCommandMutates
#      screens it by parsing the AST, which catches every ordinary way of
#      changing something -- but screening arbitrary code is best-effort, not
#      a sandbox. It is a seatbelt against mistakes, not a security boundary
#      against a determined user.
# ---------------------------------------------------------------------------

$script:McMode = 'ReadOnly'

function Get-McMode {
    <# Current safety mode: 'ReadOnly' or 'ReadWrite'. #>
    $script:McMode
}

function Set-McMode {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('ReadOnly', 'ReadWrite')]
        [string] $Mode
    )
    $script:McMode = $Mode
    $Mode
}

function Test-McWritable {
    <# $true when mutations are permitted. #>
    $script:McMode -eq 'ReadWrite'
}

function Assert-McWritable {
    <#
      The choke point for every mutating operation mc performs itself.
      Throws in read-only mode; returns silently otherwise.
    #>
    param(
        [string] $Operation = 'This operation',
        [string] $Target
    )
    if (Test-McWritable) { return }
    $message = "Read-only mode: $Operation refused"
    if ($Target) { $message += " on $Target" }
    throw $message
}

# ---------------------------------------------------------------------------
# Command-line screening
# ---------------------------------------------------------------------------

# Explicitly safe: these carry a mutating verb but change nothing on disk,
# in the registry, or in the environment. Checked first, so it wins.
$script:McSafeCommands = @{}
foreach ($c in @(
    'Set-Location', 'Push-Location', 'Pop-Location', 'Set-StrictMode',
    'Write-Host', 'Write-Output', 'Write-Verbose', 'Write-Debug',
    'Write-Warning', 'Write-Error', 'Write-Information', 'Write-Progress',
    'Out-Host', 'Out-String', 'Out-Null', 'Out-Default',
    'Format-Table', 'Format-List', 'Format-Wide', 'Format-Custom',
    'New-Object', 'New-TimeSpan', 'New-Guid', 'New-Variable',
    'Join-Path', 'Split-Path', 'Join-String', 'Import-Module',
    'Measure-Object', 'Compare-Object', 'Group-Object', 'Sort-Object',
    'Select-Object', 'Select-String', 'Where-Object', 'ForEach-Object',
    'Start-Sleep', 'help', 'man', 'more',
    'Import-Csv', 'Import-Clixml', 'ConvertFrom-Json', 'ConvertTo-Json',
    'ConvertFrom-Csv', 'ConvertTo-Csv', 'ConvertFrom-StringData'
)) { $script:McSafeCommands[$c] = $true }

# Explicitly unsafe, regardless of verb heuristics.
$script:McMutatingCommands = @{}
foreach ($c in @(
    'Remove-Item', 'Remove-ItemProperty', 'Rename-Item', 'Rename-ItemProperty',
    'New-Item', 'New-ItemProperty', 'Set-Item', 'Set-ItemProperty',
    'Clear-Item', 'Clear-ItemProperty', 'Copy-Item', 'Move-Item',
    'Set-Content', 'Add-Content', 'Clear-Content', 'Out-File',
    'Set-Acl', 'New-PSDrive', 'Remove-PSDrive',
    'mkdir', 'md',   # functions, not aliases: no verb to screen on
    'Export-Csv', 'Export-Clixml'
)) { $script:McMutatingCommands[$c] = $true }

# Verb-level catch-all for anything not named above.
$script:McMutatingVerbs = @{}
foreach ($v in @(
    'Remove', 'Set', 'New', 'Clear', 'Move', 'Rename', 'Copy', 'Add',
    'Out', 'Export', 'Write', 'Install', 'Uninstall', 'Update', 'Save',
    'Register', 'Unregister', 'Enable', 'Disable', 'Start', 'Stop',
    'Restart', 'Initialize', 'Format', 'Reset', 'Restore', 'Backup',
    'Compress', 'Expand', 'Mount', 'Dismount', 'Grant', 'Revoke',
    'Block', 'Unblock', 'Protect', 'Unprotect', 'Publish', 'Unpublish',
    'Import', 'Send', 'Submit', 'Invoke'
)) { $script:McMutatingVerbs[$v] = $true }

# .NET methods that write, whatever the type.
$script:McMutatingMethods = @{}
foreach ($m in @(
    'Delete', 'Create', 'CreateDirectory', 'CreateSubKey', 'DeleteSubKey',
    'DeleteSubKeyTree', 'DeleteValue', 'SetValue', 'SetAccessControl',
    'WriteAllText', 'WriteAllLines', 'WriteAllBytes', 'AppendAllText',
    'AppendAllLines', 'MoveTo', 'CopyTo', 'Replace', 'Encrypt', 'Decrypt',
    'SetEnvironmentVariable'
)) { $script:McMutatingMethods[$m] = $true }

function Resolve-McCommandName {
    <# Follow aliases to the real command name; returns the input if unknown. #>
    param([string] $Name)

    $cmd = Get-Command -Name $Name -ErrorAction SilentlyContinue | Select-Object -First 1
    # Always the same shape. Returning a bare string here used to make the
    # caller read .Name off a string, which threw instead of screening.
    if ($null -eq $cmd) { return @{ Name = $Name; Type = 'Unknown' } }

    $guard = 0
    while ($cmd.CommandType -eq 'Alias' -and $guard -lt 10) {
        $resolved = $null
        try { $resolved = $cmd.ResolvedCommand } catch { $resolved = $null }
        if ($null -eq $resolved) { break }
        $cmd = $resolved
        $guard++
    }
    @{ Name = $cmd.Name; Type = [string]$cmd.CommandType }
}

function Test-McCommandMutates {
    <#
    .SYNOPSIS
        Screen a command line for anything that would change state.
    .DESCRIPTION
        Returns an array of human-readable reasons. An empty array means the
        command looks read-only. Callers must wrap the result in @() because
        PowerShell unrolls an empty array to $null on return.

        Best-effort by design: it parses the AST and recognises cmdlets (via
        alias resolution), file redirections, $env: assignments, and mutating
        .NET method calls. It cannot reason about a native executable's
        arguments, so native executables are refused outright rather than
        guessed at, and the same goes for a command name computed at run time.

        Known limit: a function body is NOT analysed. Screening is by command
        name and verb, so a function called Get-Something that deletes files
        internally will pass. The convention is reliable for built-in cmdlets
        and catches every ordinary typo-level mistake, which is the threat this
        is built for -- it is a seatbelt, not a sandbox.
    #>
    param([string] $Command)

    $reasons = [System.Collections.Generic.List[string]]::new()
    if ([string]::IsNullOrWhiteSpace($Command)) { return $reasons.ToArray() }

    $parseErrors = $null
    $tokens = $null
    $ast = $null
    try {
        $ast = [System.Management.Automation.Language.Parser]::ParseInput(
            $Command, [ref]$tokens, [ref]$parseErrors)
    } catch {
        $reasons.Add('the command could not be parsed')
        return $reasons.ToArray()
    }
    if ($parseErrors -and $parseErrors.Count -gt 0) {
        $reasons.Add('the command could not be parsed')
        return $reasons.ToArray()
    }

    # --- commands ----------------------------------------------------------
    $commandAsts = $ast.FindAll({
        param($n) $n -is [System.Management.Automation.Language.CommandAst]
    }, $true)

    foreach ($c in $commandAsts) {
        $first = $c.CommandElements[0]
        if ($first -isnot [System.Management.Automation.Language.StringConstantExpressionAst]) {
            $reasons.Add('the command name is computed at run time and cannot be screened')
            continue
        }

        $typed = $first.Value
        $info = $null
        try { $info = Resolve-McCommandName $typed } catch { $info = $null }
        if ($null -eq $info) { $info = @{ Name = $typed; Type = 'Unknown' } }
        $name = [string]$info.Name
        $type = [string]$info.Type

        if ($script:McSafeCommands.ContainsKey($name)) { continue }

        if ($type -eq 'Application') {
            $reasons.Add("'$typed' is a native executable and cannot be screened")
            continue
        }

        # Refuse what cannot be resolved rather than assuming it is harmless.
        if ($type -eq 'Unknown') {
            $reasons.Add("'$typed' cannot be resolved, so it cannot be screened")
            continue
        }

        if ($script:McMutatingCommands.ContainsKey($name)) {
            $reasons.Add("'$typed' resolves to $name, which changes state")
            continue
        }

        $verb = ($name -split '-')[0]
        if ($script:McMutatingVerbs.ContainsKey($verb)) {
            $reasons.Add("'$typed' resolves to $name, whose verb '$verb' changes state")
        }
    }

    # --- redirection to a file ---------------------------------------------
    $redirections = $ast.FindAll({
        param($n) $n -is [System.Management.Automation.Language.FileRedirectionAst]
    }, $true)

    foreach ($r in $redirections) {
        # 2>$null and friends discard output rather than writing a file.
        $target = $r.Location
        $isNull = $false
        if ($target -is [System.Management.Automation.Language.VariableExpressionAst]) {
            $isNull = ($target.VariablePath.UserPath -eq 'null')
        }
        if (-not $isNull) { $reasons.Add('output is redirected to a file') }
    }

    # --- environment (and other provider) variable assignment ---------------
    $assignments = $ast.FindAll({
        param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst]
    }, $true)

    foreach ($a in $assignments) {
        $left = $a.Left
        if ($left -is [System.Management.Automation.Language.VariableExpressionAst]) {
            $drive = $left.VariablePath.DriveName
            if ($drive -and $drive.ToLowerInvariant() -eq 'env') {
                $reasons.Add("assigns to the environment variable '$($left.VariablePath.UserPath)'")
            }
        }
    }

    # --- mutating .NET calls ------------------------------------------------
    $invocations = $ast.FindAll({
        param($n) $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst]
    }, $true)

    foreach ($i in $invocations) {
        $member = $i.Member
        if ($member -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
            if ($script:McMutatingMethods.ContainsKey($member.Value)) {
                $reasons.Add("calls the .NET method $($member.Value)(), which writes")
            }
        }
    }

    $reasons.ToArray()
}
