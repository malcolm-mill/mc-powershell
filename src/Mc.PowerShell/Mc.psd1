@{
    RootModule        = 'Mc.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = '5f2a9c31-7e4b-4a1d-9c66-1b0d8e3a7f42'
    Author            = 'Malcolm Mill'
    Description       = "Midnight Commander's two-panel UI over PowerShell's object model."
    PowerShellVersion = '7.2'
    FunctionsToExport = @(
        'Start-Mc'
        'Register-McPanelSource'
        'Get-McPanelSource'
        'New-McEntry'
        'New-McPanel'
        'Update-McPanel'
        'Write-McFrame'
        'Get-McColumnLayout'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
    PrivateData = @{
        PSData = @{
            Tags       = @('file-manager', 'tui', 'midnight-commander', 'console')
            LicenseUri = 'https://www.gnu.org/licenses/gpl-3.0.html'
            ProjectUri = 'https://github.com/malcolm-mill/mc-powershell'
        }
    }
}
