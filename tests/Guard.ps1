#!/usr/bin/env pwsh
<#
    Safety-mode tests.

    Two separate guarantees are checked, because they are not the same strength:
      - Assert-McWritable, the choke point for mc's own operations, is absolute.
      - Test-McCommandMutates, the command-line screen, is best-effort. The
        tests below record exactly what it does and does not catch, so the
        limits are documented rather than assumed.
#>
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '../src/Mc.PowerShell/Mc.psd1') -Force

$script:pass = 0
$script:fail = 0

function Assert-That {
    param([string] $What, [scriptblock] $Condition)
    $ok = $false
    try { $ok = [bool](& $Condition) } catch { $ok = $false }
    if ($ok) { $script:pass++; Write-Host "  PASS  $What" -ForegroundColor Green }
    else { $script:fail++; Write-Host "  FAIL  $What" -ForegroundColor Red }
}

function Assert-Refused {
    param([string] $Command)
    Assert-That "refuses: $Command" { @(Test-McCommandMutates $Command).Count -gt 0 }
}

function Assert-Allowed {
    param([string] $Command)
    Assert-That "allows:  $Command" { @(Test-McCommandMutates $Command).Count -eq 0 }
}

Write-Host "`nDefault mode" -ForegroundColor Cyan
Assert-That 'starts in read-only mode'   { (Get-McMode) -eq 'ReadOnly' }
Assert-That 'read-only is not writable'  { -not (Test-McWritable) }

Write-Host "`nThe choke point" -ForegroundColor Cyan
Assert-That 'Assert-McWritable throws in read-only' {
    try { Assert-McWritable -Operation 'Delete' -Target 'x.txt'; $false } catch { $true }
}
Assert-That 'the refusal names the operation and target' {
    try { Assert-McWritable -Operation 'Delete' -Target 'x.txt'; '' }
    catch { $_.Exception.Message -match 'Delete' -and $_.Exception.Message -match 'x.txt' }
}
[void](Set-McMode -Mode ReadWrite)
Assert-That 'Assert-McWritable passes in read-write' {
    try { Assert-McWritable -Operation 'Delete'; $true } catch { $false }
}
[void](Set-McMode -Mode ReadOnly)
Assert-That 'mode switches back to read-only' { (Get-McMode) -eq 'ReadOnly' }

Write-Host "`nCommand screen: files" -ForegroundColor Cyan
Assert-Refused 'Remove-Item foo.txt'
Assert-Refused 'rm foo.txt'
Assert-Refused 'del foo.txt'
Assert-Refused 'ri foo.txt'
Assert-Refused 'New-Item -ItemType Directory bar'
Assert-Refused 'mkdir bar'
Assert-Refused 'Set-Content foo.txt hello'
Assert-Refused 'Add-Content foo.txt hello'
Assert-Refused 'Copy-Item a b'
Assert-Refused 'Move-Item a b'
Assert-Refused 'Rename-Item a b'
Assert-Refused 'Get-ChildItem | Out-File list.txt'

Write-Host "`nCommand screen: redirection" -ForegroundColor Cyan
Assert-Refused 'Get-Date > stamp.txt'
Assert-Refused 'Get-Date >> stamp.txt'
Assert-Allowed 'Get-ChildItem nosuch 2>$null'

Write-Host "`nCommand screen: registry and environment" -ForegroundColor Cyan
Assert-Refused 'Set-ItemProperty HKCU:\Console FontSize 20'
Assert-Refused 'New-ItemProperty HKCU:\Console Test 1'
Assert-Refused 'Remove-Item HKCU:\Console\Test'
Assert-Refused '$env:FOO = "bar"'
Assert-Refused '[Environment]::SetEnvironmentVariable("FOO", "bar")'

Write-Host "`nCommand screen: .NET and native" -ForegroundColor Cyan
Assert-Refused '[System.IO.File]::Delete("foo.txt")'
Assert-Refused '[System.IO.File]::WriteAllText("foo.txt", "x")'
Assert-Refused '[System.IO.Directory]::CreateDirectory("bar")'
Assert-Refused 'cmd /c del foo.txt'
# Pick a real application present on this platform rather than assuming one.
$nativeExe = (Get-Command -CommandType Application -ErrorAction SilentlyContinue |
    Select-Object -First 1)
Assert-That 'native executables are refused by category' {
    if ($null -eq $nativeExe) { return $true }   # nothing to test against
    (@(Test-McCommandMutates "$($nativeExe.Name) --version") -join ' ') -match 'native executable'
}
Assert-Refused 'this-command-does-not-exist-xyz'

Write-Host "`nCommand screen: read-only commands still work" -ForegroundColor Cyan
Assert-Allowed 'Get-ChildItem'
Assert-Allowed 'gci | Measure-Object'
Assert-Allowed 'Get-Process | Sort-Object CPU | Select-Object -First 5'
Assert-Allowed 'Get-Content README.md | Select-String powershell'
Assert-Allowed 'Set-Location C:\'
Assert-Allowed 'Write-Host hello'
Assert-Allowed 'Get-ChildItem | Format-Table Name, Length'
Assert-Allowed 'Join-Path C:\ projects'
Assert-Allowed 'Get-ChildItem | ForEach-Object { $_.Name }'

Write-Host "`nCommand screen: unscreenable input is refused, not guessed" -ForegroundColor Cyan
Assert-Refused '& $someCommand'
Assert-Refused 'Get-ChildItem | ForEach-Object {'   # does not parse

Write-Host "`nDocumented limits (these SHOULD pass the screen)" -ForegroundColor Cyan
# Screening is by command name and verb; function bodies are not analysed.
# Recording this as a test means the limit is known rather than assumed, and
# the day it changes, this test tells us.
# Global scope, so Get-Command inside the module can resolve it -- otherwise
# this would be refused as unresolvable and prove nothing about the limit.
function global:Get-DeceptivelyNamedThing { Remove-Item nosuch -ErrorAction SilentlyContinue }
Assert-Allowed 'Get-DeceptivelyNamedThing'

Write-Host "`nInternal commands" -ForegroundColor Cyan
$screen = [Mc.Native.Screen]::new(100, 24)
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$state = New-McAppState -LeftPath $repo -RightPath 'Env:'

Assert-That 'mc.ps1.mode is handled internally' {
    Invoke-McInternalCommand $state $screen 'mc.ps1.mode'
}
Assert-That 'mc.ps1.mode reports the current mode' { $state.Message -match 'ReadOnly' }

[void](Set-McMode -Mode ReadWrite)
Assert-That 'mc.ps1.ro is handled internally' {
    Invoke-McInternalCommand $state $screen 'mc.ps1.ro'
}
Assert-That 'mc.ps1.ro returns to read-only' { (Get-McMode) -eq 'ReadOnly' }
Assert-That 'an ordinary command is not treated as internal' {
    -not (Invoke-McInternalCommand $state $screen 'Get-ChildItem')
}

Write-Host "`nGuarded operations" -ForegroundColor Cyan
Invoke-McKey $state $screen 'f8'
Assert-That 'F8 delete is refused in read-only' { $state.Message -match 'Read-only mode' }
Invoke-McKey $state $screen 'f5'
Assert-That 'F5 copy is refused in read-only'   { $state.Message -match 'Read-only mode' }

[void](Set-McMode -Mode ReadWrite)
Invoke-McKey $state $screen 'f8'
Assert-That 'F8 passes the guard in read-write' { $state.Message -match 'not implemented' }
[void](Set-McMode -Mode ReadOnly)

Write-Host "`nMode badge" -ForegroundColor Cyan
$state.Message = $null
Write-McFrame $screen $state
Assert-That 'the read-only badge is drawn' { $screen.Snapshot() -match 'RO' }
[void](Set-McMode -Mode ReadWrite)
Write-McFrame $screen $state
Assert-That 'the read-write badge is drawn' { $screen.Snapshot() -match 'RW' }
[void](Set-McMode -Mode ReadOnly)

Write-Host ''
if ($script:fail -eq 0) {
    Write-Host "$script:pass passed, 0 failed" -ForegroundColor Green
    exit 0
} else {
    Write-Host "$script:pass passed, $script:fail FAILED" -ForegroundColor Red
    exit 1
}
