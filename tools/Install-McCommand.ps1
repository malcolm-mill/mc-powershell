#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Make `mc` work from any PowerShell prompt.

.DESCRIPTION
    Adds a small `mc` function to your PowerShell profile, pointing at this
    checkout's mc.ps1. The panels open in whatever directory you are in, and any
    arguments are forwarded, so `mc -Left C:\projects -Right HKLM:\SOFTWARE`
    works exactly as it does from the repo.

    A profile function rather than PATH, deliberately:
      - nothing is added to PATH, so nothing else is shadowed
      - arguments forward cleanly, including named ones
      - it is one clearly delimited block, easy to read and easy to remove

    The block is delimited and rewritten in place, so running this twice does
    not duplicate anything. The launcher path is absolute and resolved now, so
    moving this checkout means running the script again.

.PARAMETER Name
    The command name to define. Defaults to 'mc'.

.PARAMETER ProfilePath
    Which profile to edit. Defaults to the current user's all-hosts profile,
    so it works in the terminal, VS Code and anywhere else.

.PARAMETER Uninstall
    Remove the block instead of adding it.

.EXAMPLE
    ./tools/Install-McCommand.ps1
    Then open a new PowerShell window and type: mc

.EXAMPLE
    ./tools/Install-McCommand.ps1 -Uninstall
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string] $Name = 'mc',
    [string] $ProfilePath = $PROFILE.CurrentUserAllHosts,
    [switch] $Uninstall
)

$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$launcher = Join-Path $repoRoot 'mc.ps1'
if (-not (Test-Path -LiteralPath $launcher)) {
    throw "Launcher not found at $launcher. Run this from the mc-powershell checkout."
}

$beginMark = '# >>> mc-powershell >>>'
$endMark = '# <<< mc-powershell <<<'

$block = @"
$beginMark
# Added by tools/Install-McCommand.ps1 in $repoRoot
# Remove this block, or run that script with -Uninstall, to undo.
function $Name {
    & '$launcher' @args
}
$endMark
"@

# --- read the existing profile ---------------------------------------------

$existing = ''
if (Test-Path -LiteralPath $ProfilePath) {
    $existing = Get-Content -LiteralPath $ProfilePath -Raw
    if ($null -eq $existing) { $existing = '' }
}

# Strip any block we previously added, so this is idempotent rather than
# additive. Everything else in the profile is left exactly as it was.
$pattern = [regex]::Escape($beginMark) + '.*?' + [regex]::Escape($endMark)
$stripped = [regex]::Replace($existing, $pattern, '', 'Singleline')
$stripped = $stripped.TrimEnd()

if ($Uninstall) {
    if (-not (Test-Path -LiteralPath $ProfilePath)) {
        Write-Host "Nothing to do: $ProfilePath does not exist." -ForegroundColor Yellow
        return
    }
    if ($existing -eq $stripped) {
        Write-Host "Nothing to do: no mc-powershell block in $ProfilePath." -ForegroundColor Yellow
        return
    }
    if ($PSCmdlet.ShouldProcess($ProfilePath, 'Remove the mc-powershell block')) {
        Set-Content -LiteralPath $ProfilePath -Value ($stripped + [Environment]::NewLine) -Encoding utf8
        Write-Host "Removed the mc-powershell block from $ProfilePath" -ForegroundColor Green
        Write-Host 'Open a new PowerShell window for it to take effect.' -ForegroundColor DarkGray
    }
    return
}

# --- install ----------------------------------------------------------------

$updated = if ($stripped) { $stripped + [Environment]::NewLine * 2 + $block } else { $block }

if ($PSCmdlet.ShouldProcess($ProfilePath, "Define '$Name' pointing at $launcher")) {
    # -LiteralPath cannot be combined with -Parent; bare -LiteralPath already
    # yields the parent. See tests/Lint.ps1.
    $dir = Split-Path -LiteralPath $ProfilePath
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        [void](New-Item -ItemType Directory -Path $dir -Force)
    }
    Set-Content -LiteralPath $ProfilePath -Value ($updated + [Environment]::NewLine) -Encoding utf8

    $verb = if ($existing -eq $stripped) { 'Added' } else { 'Updated' }
    Write-Host "$verb '$Name' in $ProfilePath" -ForegroundColor Green
    Write-Host "  -> $launcher" -ForegroundColor DarkGray
    Write-Host ''
    Write-Host "Open a new PowerShell window, then type: $Name" -ForegroundColor Yellow
}

# --- things that would stop it working --------------------------------------

$policy = Get-ExecutionPolicy
if ($policy -in 'Restricted', 'AllSigned') {
    Write-Host ''
    Write-Warning @"
Execution policy is '$policy', which stops PowerShell running your profile, so
the $Name command will not appear. Changing it is your call, not this script's:

    Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
"@
}

$conflict = Get-Command $Name -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandType -ne 'Function' } |
    Select-Object -First 1
if ($conflict) {
    Write-Host ''
    Write-Warning "'$Name' also resolves to $($conflict.CommandType) at $($conflict.Source). The function defined in your profile takes precedence."
}
