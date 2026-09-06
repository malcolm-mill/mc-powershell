#!/usr/bin/env pwsh
<#
    Repo hygiene checks, all AST-based rather than grep so comments and strings
    do not produce false positives.

    Each rule here exists because the mistake it catches was actually made:
    a stray brace left by a scripted edit, a Split-Path parameter combination
    that is not valid, an export list that drifted from the functions, a new
    test suite that never got wired into CI.
#>
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path

$script:pass = 0
$script:fail = 0

function Assert-That {
    param([string] $What, [scriptblock] $Condition)
    $ok = $false
    try { $ok = [bool](& $Condition) } catch { $ok = $false }
    if ($ok) { $script:pass++; Write-Host "  PASS  $What" -ForegroundColor Green }
    else { $script:fail++; Write-Host "  FAIL  $What" -ForegroundColor Red }
}

$files = @(
    Get-ChildItem -LiteralPath $repo -Recurse -File -Include '*.ps1', '*.psm1', '*.psd1' |
        Where-Object { $_.FullName -notmatch '[\\/](\.git|bin|obj)[\\/]' }
)

Write-Host "`nEvery PowerShell file parses" -ForegroundColor Cyan
# A scripted edit that leaves an unbalanced brace should fail here, not four
# commits later when someone happens to run that file.
$broken = @()
foreach ($f in $files) {
    $errors = $null
    $tokens = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$errors)
    if ($errors -and $errors.Count -gt 0) {
        $broken += "$($f.Name): $($errors[0].Message)"
    }
}
Assert-That "all $($files.Count) files parse cleanly" { $broken.Count -eq 0 }
foreach ($b in $broken) { Write-Host "        $b" -ForegroundColor Red }

Write-Host "`nSplit-Path parameter combinations" -ForegroundColor Cyan
# "Split-Path -LiteralPath X -Parent" is not a valid parameter set. It broke
# Backspace on every provider once, then broke the profile installer months
# later. Bare -LiteralPath already returns the parent.
$offences = @()
foreach ($f in $files) {
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$errors)
    if ($null -eq $ast) { continue }

    $commands = $ast.FindAll({
        param($n) $n -is [System.Management.Automation.Language.CommandAst]
    }, $true)

    foreach ($c in $commands) {
        if ($c.GetCommandName() -ne 'Split-Path') { continue }
        $params = @($c.CommandElements |
            Where-Object { $_ -is [System.Management.Automation.Language.CommandParameterAst] } |
            ForEach-Object { $_.ParameterName.ToLowerInvariant() })

        $hasLiteral = @($params | Where-Object { 'literalpath'.StartsWith($_) }).Count -gt 0
        $hasSplit = @($params | Where-Object { 'parent'.StartsWith($_) -or 'leaf'.StartsWith($_) }).Count -gt 0

        if ($hasLiteral -and $hasSplit) {
            $offences += "$($f.Name):$($c.Extent.StartLineNumber)  $($c.Extent.Text)"
        }
    }
}
Assert-That 'no Split-Path combines -LiteralPath with -Parent or -Leaf' { $offences.Count -eq 0 }
foreach ($o in $offences) { Write-Host "        $o" -ForegroundColor Red }

Write-Host "`nManifest exports match the module" -ForegroundColor Cyan
Import-Module (Join-Path $repo 'src/Mc.PowerShell/Mc.psd1') -Force
$manifest = Import-PowerShellDataFile (Join-Path $repo 'src/Mc.PowerShell/Mc.psd1')
$exported = @(Get-Command -Module Mc | ForEach-Object Name)

$declaredMissing = @($manifest.FunctionsToExport | Where-Object { $_ -notin $exported })
Assert-That 'every function the manifest exports exists' { $declaredMissing.Count -eq 0 }
foreach ($m in $declaredMissing) { Write-Host "        declared but missing: $m" -ForegroundColor Red }

$psm1 = Get-Content -LiteralPath (Join-Path $repo 'src/Mc.PowerShell/Mc.psm1') -Raw
$notInManifest = @($exported | Where-Object { $_ -notin $manifest.FunctionsToExport })
Assert-That 'the manifest and the module agree on the export list' { $notInManifest.Count -eq 0 }
foreach ($m in $notInManifest) { Write-Host "        exported but not in manifest: $m" -ForegroundColor Red }

Write-Host "`nVersion is semver and the changelog knows it" -ForegroundColor Cyan
# The manifest is the single source of truth (docs/VERSIONING.md). A release
# with no changelog section, or a version that is not MAJOR.MINOR.PATCH, is
# caught here rather than after the tag is pushed.
$version = [string]$manifest.ModuleVersion
Assert-That "ModuleVersion '$version' is MAJOR.MINOR.PATCH" { $version -match '^\d+\.\d+\.\d+$' }
Assert-That 'Get-McVersion reports the manifest version' { (Get-McVersion) -eq $version }
$changelog = Get-Content -LiteralPath (Join-Path $repo 'CHANGELOG.md') -Raw
Assert-That "CHANGELOG.md has a section for $version" {
    $changelog -match "(?m)^## \[$([regex]::Escape($version))\] - \d{4}-\d{2}-\d{2}"
}
Assert-That 'CHANGELOG.md keeps an [Unreleased] section' { $changelog -match '(?m)^## \[Unreleased\]' }

Write-Host "`nTest suites are wired into CI" -ForegroundColor Cyan
# Adding a suite and forgetting the workflow means it silently never runs.
$ci = Get-Content -LiteralPath (Join-Path $repo '.github/workflows/ci.yml') -Raw
$suites = @(Get-ChildItem -LiteralPath (Join-Path $repo 'tests') -File -Filter '*.ps1')
$unwired = @($suites | Where-Object { $ci -notmatch [regex]::Escape($_.Name) })
Assert-That "all $($suites.Count) test suites run in CI" { $unwired.Count -eq 0 }
foreach ($u in $unwired) { Write-Host "        not in ci.yml: $($u.Name)" -ForegroundColor Red }

Write-Host ''
if ($script:fail -eq 0) {
    Write-Host "$script:pass passed, 0 failed" -ForegroundColor Green
    exit 0
} else {
    Write-Host "$script:pass passed, $script:fail FAILED" -ForegroundColor Red
    exit 1
}
