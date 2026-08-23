#Requires -Version 5.1
#
# WingetFix.ps1 -- diagnose winget, clean up stale PATH entries, reset sources, upgrade packages.
#
# License: MIT
# Origin:  https://github.com/Lazarev-Cloud/Scripts
#
# Error model: linear script. Set-StrictMode 3.0 and $ErrorActionPreference = 'Stop'. winget is a
# native program, so its result is read from $LASTEXITCODE, never from $? -- $? only reports
# whether PowerShell managed to launch the process. Deliberate refusals are reported with
# Write-Error -ErrorAction Continue and a distinct exit code, not thrown.
#
# Every mutation is gated by $PSCmdlet.ShouldProcess immediately before the call, so -WhatIf is a
# complete and truthful dry run. winget knows nothing about -WhatIf on its own.

<#
.SYNOPSIS
    Reports on winget, removes stale App Installer directories from the system PATH, resets
    package sources, and optionally upgrades installed packages.

.DESCRIPTION
    Diagnoses and repairs the Windows Package Manager without the folklore.

    Two things this script deliberately does NOT do, because they are actively harmful:

      1. It never adds a versioned '%ProgramFiles%\WindowsApps\Microsoft.DesktopAppInstaller_*'
         directory to PATH. winget is reached through the per-user App Execution Alias at
         '%LOCALAPPDATA%\Microsoft\WindowsApps\winget.exe', which is already on PATH by default.
         The versioned directory name changes with every App Installer update, so a script that
         appends it leaves a dead entry behind on each run and the system PATH grows until it
         hits the registry value size limit. The CleanPath action exists to undo exactly that
         damage.

      2. It never upgrades packages unless you ask for it by name. 'winget upgrade --all' is an
         unattended mass software upgrade, not maintenance: it can restart browsers, replace
         developer toolchains and reboot or log out for some installers.

    BLAST RADIUS:
      Report      Read-only. Safe.
      CleanPath   Rewrites the machine PATH registry value. Backed up to a file first, and by
                  default only entries whose directory no longer exists are removed.
      SourceReset Resets winget sources to defaults; custom or private sources are removed.
      Upgrade     Upgrades installed packages. This can restart applications and prompt for
                  reboots. Not the default, and requires explicit confirmation.

.PARAMETER Action
    Report       Read-only diagnosis: winget location, version, sources, stale PATH entries. Default.
    CleanPath    Remove stale App Installer directories from the machine PATH.
    SourceReset  Run 'winget source reset --force'.
    Upgrade      Run 'winget upgrade --all'.
    Environment: LZC_WINGET_ACTION.

.PARAMETER BackupPath
    Directory for the PATH backup written before CleanPath changes anything.
    Defaults to %ProgramData%\LazarevScripts\WingetFix. Environment: LZC_WINGET_BACKUP_PATH.

.PARAMETER RemoveExistingAppInstallerPath
    With CleanPath, also remove App Installer directories that still exist on disk. Off by
    default: a directory that exists is harmless, and removing it is a judgement call rather than
    an obvious repair. Environment: LZC_WINGET_REMOVE_EXISTING.

.PARAMETER IncludeUnknown
    With Upgrade, also upgrade packages whose installed version winget cannot determine. This is
    more likely to replace something unexpectedly. Environment: LZC_WINGET_INCLUDE_UNKNOWN.

.PARAMETER TimeoutSeconds
    Bounds ONE winget invocation, not the whole run: each 'winget' call the script makes gets
    this allowance separately, so a Report that lists sources and version spends it twice. It
    does not bound an individual package install inside 'winget upgrade --all'; that whole
    command is one invocation. Range 30-7200, default 1800. Upgrades are slow; the default is
    generous on purpose. Environment: LZC_WINGET_TIMEOUT_SECONDS.

.PARAMETER Force
    Suppress confirmation prompts, for unattended use. -WhatIf still wins over -Force.
    Environment: LZC_WINGET_FORCE.

    The boolean flags above accept 1, true, yes, on, 0, false, no or off in any case. Any other
    value is a usage error and exits 2.

.PARAMETER Version
    Print the script version and exit.

.EXAMPLE
    PS> .\WingetFix.ps1

    Read-only report: where winget is, what version, configured sources, and any dead App
    Installer directories left on the system PATH.

.EXAMPLE
    PS> .\WingetFix.ps1 -Action CleanPath -WhatIf

    Shows which PATH entries would be removed, and changes nothing.

.EXAMPLE
    PS> .\WingetFix.ps1 -Action Upgrade -Force

    Unattended upgrade of all packages with a known installed version.

.INPUTS
    None. This script does not accept pipeline input.

.OUTPUTS
    System.Management.Automation.PSCustomObject describing the report or the action taken.

.NOTES
    Version : 2.0
    License : MIT
    Origin  : https://github.com/Lazarev-Cloud/Scripts
    Tested  : Windows PowerShell 5.1 on Windows 11, winget 1.29.

    Exit codes (the repo-wide table; this script can return the subset below):
      0  success, or a -WhatIf dry run
      1  the work ran but something in it failed
      2  usage error: an unknown or invalid parameter or environment variable value
      3  missing prerequisite or unsupported context: winget was not found, or the session is
         LocalSystem, where the per-user App Execution Alias does not resolve
      4  must be run as administrator (CleanPath writes the machine PATH)
      5  refused: confirmation was needed, the session cannot prompt, and -Force was not given

    Repairing winget itself is out of scope and is not attempted here. The documented route is
    the Microsoft.WinGet.Client module:
      Install-Module Microsoft.WinGet.Client -Scope CurrentUser
      Repair-WinGetPackageManager -Latest
    That command is known to be unreliable across releases, so it is left as a deliberate manual
    step rather than something this script runs on your behalf.

.LINK
    https://learn.microsoft.com/en-us/windows/package-manager/winget/troubleshooting
#>

[CmdletBinding(DefaultParameterSetName = 'Run', SupportsShouldProcess, ConfirmImpact = 'High')]
[OutputType([pscustomobject])]
param(
    [Parameter(ParameterSetName = 'Run', Position = 0)]
    [ValidateSet('Report', 'CleanPath', 'SourceReset', 'Upgrade')]
    [string] $Action,

    [Parameter(ParameterSetName = 'Run')]
    [ValidateNotNullOrEmpty()]
    [string] $BackupPath,

    [Parameter(ParameterSetName = 'Run')]
    [switch] $RemoveExistingAppInstallerPath,

    [Parameter(ParameterSetName = 'Run')]
    [switch] $IncludeUnknown,

    [Parameter(ParameterSetName = 'Run')]
    [ValidateRange(30, 7200)]
    [int] $TimeoutSeconds,

    [Parameter(ParameterSetName = 'Run')]
    [switch] $Force,

    [Parameter(ParameterSetName = 'Version', Mandatory)]
    [switch] $Version
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$script:ScriptVersion = '2.0'
$script:ExitCode = 0
$script:MachineEnvironmentKey = 'HKLM:\System\CurrentControlSet\Control\Session Manager\Environment'
# Same key without the PowerShell provider prefix, for the .NET registry API used when writing.
$script:MachineEnvironmentSubKey = 'System\CurrentControlSet\Control\Session Manager\Environment'

if (-not $PSBoundParameters.ContainsKey('InformationAction')) {
    $InformationPreference = 'Continue'
}

function Resolve-EnvironmentFlag {
    <#
    .SYNOPSIS
        Resolves a boolean environment variable to $true or $false, or $null when it is unset.
    .DESCRIPTION
        Accepts 1, true, yes and on for true, and 0, false, no and off for false, in any case.
        Any other value is a usage error that exits 2, rather than being read as "off". A user
        who writes FORCE=banana in a scheduled task has made a mistake, and quietly running with
        the flag disabled hides it until the day the flag mattered.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Name
    )

    $value = [Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrWhiteSpace($value)) { return $null }

    $normalised = $value.Trim().ToLowerInvariant()
    if (@('1', 'true', 'yes', 'on') -contains $normalised) { return $true }
    if (@('0', 'false', 'no', 'off') -contains $normalised) { return $false }

    $script:ExitCode = 2
    throw "$Name must be one of 1, true, yes, on, 0, false, no or off (case-insensitive), got '$value'."
}

function Test-NonInteractiveSession {
    <#
    .SYNOPSIS
        Returns $true when nothing in this session could answer a confirmation prompt.
    .DESCRIPTION
        Three independent signals, because no single one covers every host:
          * -NonInteractive on the powershell.exe command line, which is what scheduled tasks and
            RMM agents pass. [Environment]::UserInteractive stays $true under it (verified), so
            that flag cannot be detected any other way.
          * No interactive user at all, which is the service and SYSTEM case.
          * Redirected stdin, where a prompt reads EOF instead of an answer.
        Without this check a prompt in a non-interactive host throws, and the resulting failure
        is indistinguishable from the operation itself failing.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    foreach ($argument in [Environment]::GetCommandLineArgs()) {
        if ($argument -match '^-{1,2}noni') { return $true }
    }

    if (-not [Environment]::UserInteractive) { return $true }

    try {
        if ([Console]::IsInputRedirected) { return $true }
    } catch {
        # Hosts with no real console attached (the ISE) throw here. That is not evidence either
        # way, so fall through to the interactive answer rather than refusing to run.
        Write-Verbose "Could not determine whether stdin is redirected: $($_.Exception.Message)"
    }

    return $false
}

function Get-EnvironmentValue {
    <#
    .SYNOPSIS
        Returns an environment variable's value, or a fallback when it is unset or blank.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Name,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Fallback
    )

    $value = [Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrWhiteSpace($value)) { return $Fallback }
    return $value.Trim()
}

function Test-Elevated {
    <#
    .SYNOPSIS
        Returns $true when the current process holds the built-in Administrators role.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-RunningAsSystem {
    <#
    .SYNOPSIS
        Returns $true when running as the LocalSystem account.
    .DESCRIPTION
        winget is a per-user MSIX app alias and generally does not resolve under SYSTEM, which is
        the usual reason a scheduled task calling winget fails with a confusing error.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    return $identity.User.Value -eq 'S-1-5-18'
}

function Get-WingetPath {
    <#
    .SYNOPSIS
        Returns the resolved path to winget.exe, or an empty string when it is not available.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $command = Get-Command -Name 'winget.exe' -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($command) { return [string] $command.Source }

    # Fall back to the App Execution Alias location directly, which is where winget actually
    # lives, rather than to a versioned WindowsApps directory.
    $alias = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\winget.exe'
    if (Test-Path -LiteralPath $alias -PathType Leaf) { return $alias }

    return ''
}

function Invoke-NativeCommand {
    <#
    .SYNOPSIS
        Runs a native executable under a hard timeout and returns its exit code and stdout.
    .DESCRIPTION
        Ungated on purpose: callers that mutate state place their own ShouldProcess gate
        immediately before calling this. stderr is deliberately not merged into stdout, because
        in Windows PowerShell 5.1 '2>&1' on a native command wraps each stderr line in a
        NativeCommandError record and flips $? to $false even on a clean exit 0.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $FilePath,

        [Parameter()]
        [string[]] $ArgumentList = @(),

        [Parameter(Mandatory)]
        [ValidateRange(30, 7200)]
        [int] $TimeoutSeconds
    )

    if (-not (Test-Path -LiteralPath $FilePath -PathType Leaf)) {
        throw "Executable not found: $FilePath"
    }

    Write-Verbose "Running: $FilePath $($ArgumentList -join ' ')"

    $stdoutFile = [IO.Path]::GetTempFileName()
    try {
        $startArgs = @{
            FilePath               = $FilePath
            NoNewWindow            = $true
            PassThru               = $true
            RedirectStandardOutput = $stdoutFile
        }
        if ($ArgumentList.Count -gt 0) { $startArgs['ArgumentList'] = $ArgumentList }

        $process = Start-Process @startArgs
        # Touching Handle forces the object to cache it; without this ExitCode can come back
        # $null after the process has already exited.
        $null = $process.Handle
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            try { $process.Kill() } catch { Write-Verbose "Kill failed: $($_.Exception.Message)" }
            throw "'$FilePath $($ArgumentList -join ' ')' did not finish within $TimeoutSeconds seconds."
        }
        $exitCode = $process.ExitCode

        $output = @()
        if (Test-Path -LiteralPath $stdoutFile) {
            $output = @(Get-Content -LiteralPath $stdoutFile -ErrorAction SilentlyContinue)
        }

        return [pscustomobject]@{
            FilePath  = $FilePath
            Arguments = $ArgumentList -join ' '
            ExitCode  = $exitCode
            Output    = $output
        }
    } finally {
        Remove-Item -LiteralPath $stdoutFile -Force -ErrorAction SilentlyContinue
    }
}

function Get-StaleAppInstallerPathEntry {
    <#
    .SYNOPSIS
        Returns machine PATH entries that point at a versioned App Installer directory.
    .DESCRIPTION
        The raw, unexpanded registry value is read so that %VAR% references elsewhere in PATH are
        preserved: Get-ItemProperty would return the expanded string, and writing that back would
        bake machine-specific literals into a value meant to stay portable.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()

    $key = Get-Item -LiteralPath $script:MachineEnvironmentKey
    $raw = [string] $key.GetValue('Path', '', 'DoNotExpandEnvironmentNames')
    $kind = [string] $key.GetValueKind('Path')

    $entries = @()
    foreach ($entry in ($raw -split ';')) {
        if ([string]::IsNullOrWhiteSpace($entry)) { continue }
        if ($entry -notlike '*Microsoft.DesktopAppInstaller_*') { continue }
        $entries += [pscustomobject]@{
            Entry  = $entry
            Exists = Test-Path -LiteralPath ([Environment]::ExpandEnvironmentVariables($entry))
        }
    }

    return [pscustomobject]@{
        RawPath      = $raw
        ValueKind    = $kind
        AppInstaller = $entries
    }
}

function Invoke-PathCleanup {
    <#
    .SYNOPSIS
        Removes stale App Installer directories from the machine PATH behind a ShouldProcess gate.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Directory,

        [Parameter()]
        [switch] $RemoveExisting
    )

    $state = Get-StaleAppInstallerPathEntry
    $doomed = @($state.AppInstaller | Where-Object { $RemoveExisting -or -not $_.Exists })

    if ($doomed.Count -eq 0) {
        Write-Information -MessageData 'No stale App Installer directories on the machine PATH; nothing to clean.'
        return [pscustomobject]@{
            Operation = 'Clean machine PATH'; Target = 'HKLM Environment\Path'
            Removed = @(); Status = 'NoChange'; BackupFile = ''
        }
    }

    Write-Information -MessageData "Entries to remove: $($doomed.Count)"
    foreach ($item in $doomed) {
        Write-Information -MessageData ("  {0}  (directory exists: {1})" -f $item.Entry, $item.Exists)
    }

    $operation = "Remove $($doomed.Count) App Installer entr$(if ($doomed.Count -eq 1) { 'y' } else { 'ies' }) from the machine PATH"
    if (-not $PSCmdlet.ShouldProcess('HKLM Environment\Path', $operation)) {
        return [pscustomobject]@{
            Operation = $operation; Target = 'HKLM Environment\Path'
            Removed = @($doomed.Entry); Status = 'Skipped'; BackupFile = ''
        }
    }

    if (-not (Test-Path -LiteralPath $Directory -PathType Container)) {
        New-Item -Path $Directory -ItemType Directory -Force | Out-Null
    }
    $stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')
    $backupFile = Join-Path $Directory "machine-path-$stamp.txt"
    Set-Content -LiteralPath $backupFile -Value $state.RawPath -Encoding UTF8
    if (-not (Test-Path -LiteralPath $backupFile -PathType Leaf) -or (Get-Item -LiteralPath $backupFile).Length -le 0) {
        throw "PATH backup '$backupFile' could not be written; refusing to modify the machine PATH."
    }
    Write-Information -MessageData "Previous machine PATH saved to: $backupFile"

    $keep = @()
    foreach ($entry in ($state.RawPath -split ';')) {
        if ([string]::IsNullOrWhiteSpace($entry)) { continue }
        if ($doomed.Entry -contains $entry) { continue }
        $keep += $entry
    }
    $newPath = $keep -join ';'

    # Written through the .NET registry API rather than Set-ItemProperty so the value kind is
    # stated explicitly and preserved. PATH is normally REG_EXPAND_SZ; writing it back as a plain
    # REG_SZ would turn any %VAR% references elsewhere in PATH into literals that never expand
    # again. (Set-ItemProperty's -Type is a provider dynamic parameter, which is both less
    # explicit here and invisible to static analysis.)
    $subKey = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($script:MachineEnvironmentSubKey, $true)
    if ($null -eq $subKey) {
        throw "Could not open HKLM\$script:MachineEnvironmentSubKey for writing."
    }
    try {
        $subKey.SetValue('Path', $newPath, [Microsoft.Win32.RegistryValueKind] $state.ValueKind)
    } finally {
        $subKey.Close()
    }

    Write-Information -MessageData 'Machine PATH updated. Already-running processes keep the old value; sign out and back in for it to take effect everywhere.'

    return [pscustomobject]@{
        Operation = $operation; Target = 'HKLM Environment\Path'
        Removed = @($doomed.Entry); Status = 'Succeeded'; BackupFile = $backupFile
    }
}

function Invoke-GatedWinget {
    <#
    .SYNOPSIS
        Runs a winget subcommand behind a ShouldProcess gate and validates its exit code.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $WingetPath,

        [Parameter(Mandatory)]
        [string[]] $ArgumentList,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Target,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Operation,

        [Parameter(Mandatory)]
        [ValidateRange(30, 7200)]
        [int] $TimeoutSeconds,

        [Parameter()]
        [int[]] $SuccessExitCodes = @(0)
    )

    if (-not $PSCmdlet.ShouldProcess($Target, $Operation)) {
        return [pscustomobject]@{
            Operation = $Operation; Target = $Target; ExitCode = $null; Status = 'Skipped'; Output = @()
        }
    }

    $result = Invoke-NativeCommand -FilePath $WingetPath -ArgumentList $ArgumentList `
        -TimeoutSeconds $TimeoutSeconds

    # $LASTEXITCODE, never $?. For a native program $? only says whether PowerShell managed to
    # start it, so the original 'If ($?)' check reported success for every failed upgrade.
    if ($SuccessExitCodes -notcontains $result.ExitCode) {
        $detail = ($result.Output | Select-Object -Last 20) -join [Environment]::NewLine
        throw "$Operation failed: winget exited with code $($result.ExitCode).$([Environment]::NewLine)$detail"
    }

    return [pscustomobject]@{
        Operation = $Operation; Target = $Target
        ExitCode = $result.ExitCode; Status = 'Succeeded'; Output = $result.Output
    }
}

function Get-WingetReport {
    <#
    .SYNOPSIS
        Read-only diagnosis of the winget installation and the machine PATH.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $WingetPath,

        [Parameter(Mandatory)]
        [ValidateRange(30, 7200)]
        [int] $TimeoutSeconds
    )

    $versionText = 'unknown'
    try {
        $info = Invoke-NativeCommand -FilePath $WingetPath -ArgumentList @('--version') `
            -TimeoutSeconds $TimeoutSeconds
        if ($info.ExitCode -eq 0 -and $info.Output.Count -gt 0) {
            $versionText = ($info.Output | Where-Object { $_ } | Select-Object -First 1).Trim()
        } else {
            Write-Warning "winget --version exited with code $($info.ExitCode)."
        }
    } catch {
        Write-Warning "Could not run winget --version: $($_.Exception.Message)"
    }

    $sources = @()
    try {
        $src = Invoke-NativeCommand -FilePath $WingetPath -ArgumentList @('source', 'list') `
            -TimeoutSeconds $TimeoutSeconds
        if ($src.ExitCode -eq 0) {
            $sources = @($src.Output | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        }
    } catch {
        Write-Warning "Could not list winget sources: $($_.Exception.Message)"
    }

    $pathState = Get-StaleAppInstallerPathEntry
    $dead = @($pathState.AppInstaller | Where-Object { -not $_.Exists })
    if ($dead.Count -gt 0) {
        Write-Warning "The machine PATH contains $($dead.Count) App Installer director$(if ($dead.Count -eq 1) { 'y' } else { 'ies' }) that no longer exist. These are left behind by scripts that append the versioned WindowsApps path on every run. Remove them with -Action CleanPath."
    }

    return [pscustomobject]@{
        Operation           = 'Report winget state'
        Target              = 'winget'
        WingetPath          = $WingetPath
        WingetVersion       = $versionText
        Sources             = $sources
        PathValueKind       = $pathState.ValueKind
        AppInstallerOnPath  = @($pathState.AppInstaller)
        StalePathEntryCount = $dead.Count
        Status              = 'Succeeded'
    }
}

function Invoke-Main {
    <#
    .SYNOPSIS
        Resolves configuration, checks preconditions, and runs the chosen action.
    .PARAMETER ScriptBoundParameter
        The script's own $PSBoundParameters. It must be passed in: inside this function
        $PSBoundParameters would describe this function's arguments instead, so every explicitly
        supplied argument would be silently replaced by its environment-variable default.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $ScriptBoundParameter
    )

    if ($Version) {
        Write-Information -MessageData "WingetFix.ps1 version $script:ScriptVersion"
        return
    }

    # Guard order, identical across every script in this repo: configuration (2), platform and
    # prerequisites (3), elevation (4), interactivity (5), then the work itself (0 or 1).
    # $script:ExitCode is set to 2 before each validation throw so the catch at the bottom
    # reports a usage error rather than the generic failure code.
    if (-not $ScriptBoundParameter.ContainsKey('Action')) {
        $Action = Get-EnvironmentValue -Name 'LZC_WINGET_ACTION' -Fallback 'Report'
        if (@('Report', 'CleanPath', 'SourceReset', 'Upgrade') -notcontains $Action) {
            $script:ExitCode = 2
            throw "LZC_WINGET_ACTION must be Report, CleanPath, SourceReset or Upgrade, got '$Action'."
        }
    }
    if (-not $ScriptBoundParameter.ContainsKey('BackupPath')) {
        $BackupPath = Get-EnvironmentValue -Name 'LZC_WINGET_BACKUP_PATH' `
            -Fallback (Join-Path $env:ProgramData 'LazarevScripts\WingetFix')
    }
    if (-not $ScriptBoundParameter.ContainsKey('TimeoutSeconds')) {
        $raw = Get-EnvironmentValue -Name 'LZC_WINGET_TIMEOUT_SECONDS' -Fallback '1800'
        $parsed = 0
        # TryParse reads '08' as decimal 8, so a zero-padded value in a scheduled-task definition
        # means what it looks like rather than becoming an invalid octal literal. The floor of 30
        # matches the -TimeoutSeconds ValidateRange and keeps the value well clear of 0, which a
        # caller would reasonably read as "no limit" and which would remove the bound entirely.
        if (-not [int]::TryParse($raw, [ref] $parsed)) {
            $script:ExitCode = 2
            throw "LZC_WINGET_TIMEOUT_SECONDS must be an integer, got '$raw'."
        }
        if ($parsed -lt 30 -or $parsed -gt 7200) {
            $script:ExitCode = 2
            throw "LZC_WINGET_TIMEOUT_SECONDS must be between 30 and 7200, got $parsed."
        }
        $TimeoutSeconds = $parsed
    }
    if (-not $ScriptBoundParameter.ContainsKey('RemoveExistingAppInstallerPath')) {
        $fromEnv = Resolve-EnvironmentFlag -Name 'LZC_WINGET_REMOVE_EXISTING'
        if ($null -ne $fromEnv) { $RemoveExistingAppInstallerPath = [switch] $fromEnv }
    }
    if (-not $ScriptBoundParameter.ContainsKey('IncludeUnknown')) {
        $fromEnv = Resolve-EnvironmentFlag -Name 'LZC_WINGET_INCLUDE_UNKNOWN'
        if ($null -ne $fromEnv) { $IncludeUnknown = [switch] $fromEnv }
    }
    if (-not $ScriptBoundParameter.ContainsKey('Force')) {
        $fromEnv = Resolve-EnvironmentFlag -Name 'LZC_WINGET_FORCE'
        if ($null -ne $fromEnv) { $Force = [switch] $fromEnv }
    }

    # -Force must not short-circuit ShouldProcess itself, or -WhatIf would stop working. Lower
    # the confirmation threshold instead, and only when the caller did not ask for -Confirm.
    if ($Force -and -not $ScriptBoundParameter.ContainsKey('Confirm')) {
        $ConfirmPreference = 'None'
    }

    Write-Information -MessageData "Action: $Action"

    # CleanPath only touches the registry, so it does not need winget present and skips the
    # prerequisite checks below. Its own guards still run in the standard order.
    if ($Action -eq 'CleanPath') {
        if (-not $WhatIfPreference -and -not (Test-Elevated)) {
            Write-Error -ErrorAction Continue -Message 'CleanPath writes the machine PATH and needs administrator rights. Re-run from an elevated PowerShell session, or use -WhatIf to preview without elevation.'
            $script:ExitCode = 4
            return
        }
        if (-not $WhatIfPreference -and $ConfirmPreference -ne 'None' -and (Test-NonInteractiveSession)) {
            Write-Error -ErrorAction Continue -Message 'Refusing to rewrite the machine PATH: this action needs confirmation, but the session cannot prompt (it is non-interactive). Pass -Force to confirm in advance, or set LZC_WINGET_FORCE=1.'
            $script:ExitCode = 5
            return
        }
        return Invoke-PathCleanup -Directory $BackupPath -RemoveExisting:$RemoveExistingAppInstallerPath
    }

    if (Test-RunningAsSystem) {
        Write-Error -ErrorAction Continue -Message 'Running as LocalSystem. winget is a per-user App Execution Alias and generally does not resolve under SYSTEM, so this would fail with a confusing error. Run the task as an interactive user account instead.'
        $script:ExitCode = 3
        return
    }

    $winget = Get-WingetPath
    if ([string]::IsNullOrEmpty($winget)) {
        Write-Error -ErrorAction Continue -Message "winget.exe was not found. Install 'App Installer' from the Microsoft Store, or see https://learn.microsoft.com/en-us/windows/package-manager/. Note that installing App Installer with winget is circular and cannot work."
        $script:ExitCode = 3
        return
    }
    Write-Information -MessageData "winget: $winget"

    # Last gate before any change. Report is read-only and is exempt. $ConfirmPreference is
    # 'None' only when -Force lowered it above or the caller passed -Confirm:$false; anything
    # else means ShouldProcess is about to prompt, and a host that cannot answer would turn that
    # into an exception reported as a plain failure.
    if ($Action -ne 'Report' -and -not $WhatIfPreference -and $ConfirmPreference -ne 'None' -and
        (Test-NonInteractiveSession)) {
        Write-Error -ErrorAction Continue -Message "Refusing to run '$Action': this action needs confirmation, but the session cannot prompt (it is non-interactive). Pass -Force to confirm in advance, or set LZC_WINGET_FORCE=1."
        $script:ExitCode = 5
        return
    }

    switch ($Action) {
        'Report' {
            return Get-WingetReport -WingetPath $winget -TimeoutSeconds $TimeoutSeconds
        }
        'SourceReset' {
            return Invoke-GatedWinget -WingetPath $winget `
                -ArgumentList @('source', 'reset', '--force', '--disable-interactivity') `
                -Target 'winget sources' `
                -Operation 'Reset winget sources to defaults (removes custom and private sources)' `
                -TimeoutSeconds $TimeoutSeconds
        }
        'Upgrade' {
            Write-Warning 'Upgrading all packages replaces installed software. Some installers close running applications, and a few request a reboot or sign-out.'
            $arguments = @('upgrade', '--all', '--silent', '--disable-interactivity',
                '--accept-source-agreements', '--accept-package-agreements')
            if ($IncludeUnknown) { $arguments += '--include-unknown' }
            # winget returns a non-zero code when it finds nothing to upgrade; that is a normal
            # outcome, not a failure. 0x8A150014 = APPINSTALLER_CLI_ERROR_UPDATE_NOT_APPLICABLE.
            return Invoke-GatedWinget -WingetPath $winget -ArgumentList $arguments `
                -Target 'all upgradable packages' `
                -Operation 'Upgrade all installed packages' `
                -TimeoutSeconds $TimeoutSeconds `
                -SuccessExitCodes @(0, -1978335212)
        }
        default {
            throw "Internal error: unhandled action '$Action'."
        }
    }
}

try {
    Invoke-Main -ScriptBoundParameter $PSBoundParameters
} catch {
    # ScriptStackTrace names the frame that actually failed; InvocationInfo here would only point
    # back at the Invoke-Main call site. -ErrorAction Continue keeps this non-terminating so the
    # exit statement below is always reached.
    $origin = @($_.ScriptStackTrace -split "`r?`n") | Select-Object -First 1
    Write-Error -ErrorAction Continue -Message ("{0}{1}  {2}" -f $_.Exception.Message, [Environment]::NewLine, $origin)
    # A validation site that already classified the fault (2 for a usage error) keeps its code;
    # only an unclassified exception becomes the generic "work failed" 1.
    if ($script:ExitCode -eq 0) { $script:ExitCode = 1 }
}

exit $script:ExitCode
