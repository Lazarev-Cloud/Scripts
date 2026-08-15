#Requires -Version 5.1
#
# ResetFirewall.ps1 -- export, reset or restore the Windows Defender Firewall policy.
#
# License: MIT
# Origin:  https://github.com/Lazarev-Cloud/Scripts
#
# Error model: linear script. Set-StrictMode 3.0 and $ErrorActionPreference = 'Stop'. Native
# tools do not raise PowerShell errors, so every netsh call is checked through its exit code
# explicitly. Deliberate refusals (not elevated, remote session, unverified export) are reported
# with Write-Error -ErrorAction Continue and a distinct exit code, not thrown.
#
# Every mutation is gated by $PSCmdlet.ShouldProcess immediately before the native call, so
# -WhatIf is a complete and truthful dry run. netsh knows nothing about -WhatIf on its own.

<#
.SYNOPSIS
    Exports, resets or restores the Windows Defender Firewall policy, never resetting without a
    verified backup.

.DESCRIPTION
    Wraps 'netsh advfirewall' with the safety the bare command lacks.

    BLAST RADIUS - read before running:

    'netsh advfirewall reset' restores every Windows Defender Firewall setting to its
    out-of-the-box defaults and DELETES EVERY LOCALLY CREATED RULE. That includes rules added
    by applications at install time, so line-of-business software, game servers, database
    listeners, remote administration tools and inbound Remote Desktop exceptions can all stop
    working until each product is reinstalled or reconfigured.

    What comes back and what does not:
      - Rules delivered by Group Policy or Intune/MDM are stored separately and return at the
        next policy refresh.
      - Locally authored rules and rules written by application installers are stored in the
        local policy store and are GONE PERMANENTLY once reset, unless you restore the export
        this script takes.

    Because of that, Reset always exports the current policy first, verifies that the export
    file exists and is non-empty, and ABORTS the reset if it is not. An export that was never
    checked is not a backup. Use -SkipBackup to override deliberately.

    A firewall reset can also drop an inbound Remote Desktop exception, so the destructive
    actions refuse to run over RDP or SSH unless -AllowRemoteSession is passed.

    This script never disables the firewall. 'netsh advfirewall set allprofiles state off' is
    not implemented and will not be added: a script that restores connectivity by turning off
    the firewall is a vulnerability, not a repair tool.

.PARAMETER Action
    Report  Read-only. Shows profile state and local rule counts. Default; needs no elevation.
    Export  Writes the current policy to a .wfw file and stops.
    Reset   Exports, verifies the export, then resets the firewall to defaults.
    Import  Restores a previously exported .wfw file, replacing the current policy.
    Environment: LZC_RESETFIREWALL_ACTION.

.PARAMETER BackupPath
    Directory for .wfw exports. Created if missing.
    Defaults to %ProgramData%\LazarevScripts\ResetFirewall. Environment: LZC_RESETFIREWALL_BACKUP_PATH.

.PARAMETER ImportFile
    The .wfw file to restore. Required by -Action Import. Environment: LZC_RESETFIREWALL_IMPORT_FILE.

.PARAMETER SkipBackup
    Reset without exporting first. This makes the reset irreversible.
    Environment: LZC_RESETFIREWALL_SKIP_BACKUP.

.PARAMETER AllowRemoteSession
    Permit destructive actions even though this looks like an RDP or SSH session.
    Environment: LZC_RESETFIREWALL_ALLOW_REMOTE_SESSION.

.PARAMETER TimeoutSeconds
    Bounds ONE netsh invocation, not the whole run: the export, the reset and the import are
    separate calls and each gets this allowance in full. Range 10-600, default 120.
    Environment: LZC_RESETFIREWALL_TIMEOUT_SECONDS.

.PARAMETER Force
    Suppress confirmation prompts, for unattended use. -WhatIf still wins over -Force.
    Environment: LZC_RESETFIREWALL_FORCE.

    The boolean flags above accept 1, true, yes, on, 0, false, no or off in any case. Any other
    value is a usage error and exits 2.

.PARAMETER Version
    Print the script version and exit.

.EXAMPLE
    PS> .\ResetFirewall.ps1

    Reports the current firewall profile state and local rule counts. Changes nothing.

.EXAMPLE
    PS> .\ResetFirewall.ps1 -Action Reset -WhatIf

    Shows exactly what a reset would do, including where the export would be written.

.EXAMPLE
    PS> .\ResetFirewall.ps1 -Action Export -BackupPath D:\Backups

    Writes a timestamped .wfw snapshot of the current policy and exits.

.EXAMPLE
    PS> .\ResetFirewall.ps1 -Action Import -ImportFile D:\Backups\firewall-20260815-101500.wfw -Force

    Restores a previously exported policy, replacing everything currently configured.

.INPUTS
    None. This script does not accept pipeline input.

.OUTPUTS
    System.Management.Automation.PSCustomObject describing each operation performed.

.NOTES
    Version : 2.0
    License : MIT
    Origin  : https://github.com/Lazarev-Cloud/Scripts
    Tested  : Windows PowerShell 5.1 on Windows 11.

    Exit codes (the repo-wide table; this script can return the subset below):
      0  success, or a -WhatIf dry run
      1  the work ran but something in it failed, including the export that Reset depends on
      2  usage error: an invalid parameter or environment variable value, -Action Import with no
         -ImportFile, or a remote session without -AllowRemoteSession
      4  must be run as administrator
      5  refused: confirmation was needed, the session cannot prompt, and -Force was not given

    Rollback after a reset:
      .\ResetFirewall.ps1 -Action Import -ImportFile <BackupPath>\firewall-<stamp>.wfw

.LINK
    https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/netsh-advfirewall
#>

[CmdletBinding(DefaultParameterSetName = 'Run', SupportsShouldProcess, ConfirmImpact = 'High')]
[OutputType([pscustomobject])]
param(
    [Parameter(ParameterSetName = 'Run', Position = 0)]
    [ValidateSet('Report', 'Export', 'Reset', 'Import')]
    [string] $Action,

    [Parameter(ParameterSetName = 'Run')]
    [ValidateNotNullOrEmpty()]
    [string] $BackupPath,

    [Parameter(ParameterSetName = 'Run')]
    [ValidateNotNullOrEmpty()]
    [string] $ImportFile,

    [Parameter(ParameterSetName = 'Run')]
    [switch] $SkipBackup,

    [Parameter(ParameterSetName = 'Run')]
    [switch] $AllowRemoteSession,

    [Parameter(ParameterSetName = 'Run')]
    [ValidateRange(10, 600)]
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
        who writes SKIP_BACKUP=banana in a scheduled task has made a mistake, and quietly running
        with the flag disabled hides it until the day the flag mattered.
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

function Test-RemoteSession {
    <#
    .SYNOPSIS
        Returns $true when this looks like an RDP or SSH session, whose inbound rule a firewall
        reset may remove.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    if (-not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable('SSH_CONNECTION'))) { return $true }
    if (-not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable('SSH_CLIENT'))) { return $true }

    $sessionName = [Environment]::GetEnvironmentVariable('SESSIONNAME')
    if (-not [string]::IsNullOrWhiteSpace($sessionName) -and $sessionName -like 'RDP-*') { return $true }

    return $false
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
        [ValidateRange(10, 600)]
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

function Get-FirewallReport {
    <#
    .SYNOPSIS
        Returns the current firewall profile state and local rule counts. Read-only.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()

    $profiles = 'unavailable'
    try {
        $profiles = @(Get-NetFirewallProfile -ErrorAction Stop | Select-Object Name,
            @{ Name = 'Enabled'; Expression = { [string] $_.Enabled } },
            @{ Name = 'DefaultInboundAction'; Expression = { [string] $_.DefaultInboundAction } },
            @{ Name = 'DefaultOutboundAction'; Expression = { [string] $_.DefaultOutboundAction } })
    } catch {
        Write-Warning "Could not read firewall profiles: $($_.Exception.Message)"
    }

    # PersistentStore is the locally authored policy: exactly what a reset destroys. Counting it
    # tells the user how much they stand to lose, which the bare netsh command never does.
    $localRules = 'unavailable'
    try {
        $rules = @(Get-NetFirewallRule -PolicyStore PersistentStore -ErrorAction Stop)
        $localRules = [pscustomobject]@{
            Total    = $rules.Count
            Enabled  = @($rules | Where-Object { $_.Enabled -eq 'True' }).Count
            Inbound  = @($rules | Where-Object { $_.Direction -eq 'Inbound' }).Count
            Outbound = @($rules | Where-Object { $_.Direction -eq 'Outbound' }).Count
        }
    } catch {
        Write-Warning "Could not enumerate local firewall rules: $($_.Exception.Message)"
    }

    return [pscustomobject]@{
        Operation      = 'Report firewall state'
        Target         = 'Windows Defender Firewall'
        Profiles       = $profiles
        LocalRuleStore = $localRules
        Status         = 'Succeeded'
    }
}

function Export-FirewallPolicy {
    <#
    .SYNOPSIS
        Exports the current firewall policy to a .wfw file and verifies the result.
    .DESCRIPTION
        Verification is the point: netsh can exit 0 having written nothing useful, and an
        unverified export is not a rollback. Returns the export path.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $NetshPath,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Directory,

        [Parameter(Mandatory)]
        [ValidateRange(10, 600)]
        [int] $TimeoutSeconds
    )

    if (-not (Test-Path -LiteralPath $Directory -PathType Container)) {
        New-Item -Path $Directory -ItemType Directory -Force | Out-Null
    }

    $stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')
    $target = Join-Path $Directory "firewall-$stamp.wfw"

    if (-not $PSCmdlet.ShouldProcess($target, 'Export Windows Firewall policy')) {
        return ''
    }

    # netsh refuses to overwrite an existing export file, so a stale file must not be left.
    if (Test-Path -LiteralPath $target) {
        Remove-Item -LiteralPath $target -Force
    }

    $result = Invoke-NativeCommand -FilePath $NetshPath `
        -ArgumentList @('advfirewall', 'export', $target) -TimeoutSeconds $TimeoutSeconds

    if ($result.ExitCode -ne 0) {
        $detail = ($result.Output -join [Environment]::NewLine).Trim()
        throw "Firewall export failed: netsh exited with code $($result.ExitCode). $detail"
    }
    if (-not (Test-Path -LiteralPath $target -PathType Leaf)) {
        throw "Firewall export reported success but '$target' does not exist."
    }
    if ((Get-Item -LiteralPath $target).Length -le 0) {
        throw "Firewall export reported success but '$target' is empty."
    }

    Write-Information -MessageData "Firewall policy exported and verified: $target"
    return $target
}

function Invoke-FirewallReset {
    <#
    .SYNOPSIS
        Resets the firewall to defaults behind a ShouldProcess gate.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $NetshPath,

        [Parameter(Mandatory)]
        [ValidateRange(10, 600)]
        [int] $TimeoutSeconds
    )

    $operation = 'Reset firewall to defaults (deletes every locally created rule)'
    if (-not $PSCmdlet.ShouldProcess('Windows Defender Firewall', $operation)) {
        return [pscustomobject]@{
            Operation = $operation; Target = 'Windows Defender Firewall'
            ExitCode = $null; Status = 'Skipped'
        }
    }

    $result = Invoke-NativeCommand -FilePath $NetshPath -ArgumentList @('advfirewall', 'reset') `
        -TimeoutSeconds $TimeoutSeconds
    if ($result.ExitCode -ne 0) {
        $detail = ($result.Output -join [Environment]::NewLine).Trim()
        throw "Firewall reset failed: netsh exited with code $($result.ExitCode). $detail"
    }

    return [pscustomobject]@{
        Operation = $operation; Target = 'Windows Defender Firewall'
        ExitCode = $result.ExitCode; Status = 'Succeeded'
    }
}

function Import-FirewallPolicy {
    <#
    .SYNOPSIS
        Restores a previously exported .wfw policy file behind a ShouldProcess gate.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $NetshPath,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Path,

        [Parameter(Mandatory)]
        [ValidateRange(10, 600)]
        [int] $TimeoutSeconds
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Import file not found: $Path"
    }
    if ((Get-Item -LiteralPath $Path).Length -le 0) {
        throw "Import file is empty: $Path"
    }

    $operation = 'Import firewall policy (replaces the entire current policy)'
    if (-not $PSCmdlet.ShouldProcess($Path, $operation)) {
        return [pscustomobject]@{
            Operation = $operation; Target = $Path; ExitCode = $null; Status = 'Skipped'
        }
    }

    $result = Invoke-NativeCommand -FilePath $NetshPath `
        -ArgumentList @('advfirewall', 'import', $Path) -TimeoutSeconds $TimeoutSeconds
    if ($result.ExitCode -ne 0) {
        $detail = ($result.Output -join [Environment]::NewLine).Trim()
        throw "Firewall import failed: netsh exited with code $($result.ExitCode). $detail"
    }

    return [pscustomobject]@{
        Operation = $operation; Target = $Path
        ExitCode = $result.ExitCode; Status = 'Succeeded'
    }
}

function Invoke-Main {
    <#
    .SYNOPSIS
        Resolves configuration, enforces the safety preconditions, and runs the chosen action.
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
        Write-Information -MessageData "ResetFirewall.ps1 version $script:ScriptVersion"
        return
    }

    # Guard order, identical across every script in this repo: configuration (2), platform and
    # prerequisites (3), elevation (4), interactivity (5), then the work itself (0 or 1).
    # $script:ExitCode is set to 2 before each validation throw so the catch at the bottom
    # reports a usage error rather than the generic failure code.
    if (-not $ScriptBoundParameter.ContainsKey('Action')) {
        $Action = Get-EnvironmentValue -Name 'LZC_RESETFIREWALL_ACTION' -Fallback 'Report'
        if (@('Report', 'Export', 'Reset', 'Import') -notcontains $Action) {
            $script:ExitCode = 2
            throw "LZC_RESETFIREWALL_ACTION must be Report, Export, Reset or Import, got '$Action'."
        }
    }
    if (-not $ScriptBoundParameter.ContainsKey('BackupPath')) {
        $BackupPath = Get-EnvironmentValue -Name 'LZC_RESETFIREWALL_BACKUP_PATH' `
            -Fallback (Join-Path $env:ProgramData 'LazarevScripts\ResetFirewall')
    }
    if (-not $ScriptBoundParameter.ContainsKey('ImportFile')) {
        $ImportFile = Get-EnvironmentValue -Name 'LZC_RESETFIREWALL_IMPORT_FILE' -Fallback ''
    }
    if (-not $ScriptBoundParameter.ContainsKey('TimeoutSeconds')) {
        $raw = Get-EnvironmentValue -Name 'LZC_RESETFIREWALL_TIMEOUT_SECONDS' -Fallback '120'
        $parsed = 0
        # TryParse reads '08' as decimal 8, so a zero-padded value in a scheduled-task definition
        # means what it looks like rather than becoming an invalid octal literal. The floor of 10
        # matches the -TimeoutSeconds ValidateRange and keeps the value well clear of 0, which a
        # caller would reasonably read as "no limit" and which would remove the bound entirely.
        if (-not [int]::TryParse($raw, [ref] $parsed)) {
            $script:ExitCode = 2
            throw "LZC_RESETFIREWALL_TIMEOUT_SECONDS must be an integer, got '$raw'."
        }
        if ($parsed -lt 10 -or $parsed -gt 600) {
            $script:ExitCode = 2
            throw "LZC_RESETFIREWALL_TIMEOUT_SECONDS must be between 10 and 600, got $parsed."
        }
        $TimeoutSeconds = $parsed
    }
    if (-not $ScriptBoundParameter.ContainsKey('SkipBackup')) {
        $fromEnv = Resolve-EnvironmentFlag -Name 'LZC_RESETFIREWALL_SKIP_BACKUP'
        if ($null -ne $fromEnv) { $SkipBackup = [switch] $fromEnv }
    }
    if (-not $ScriptBoundParameter.ContainsKey('AllowRemoteSession')) {
        $fromEnv = Resolve-EnvironmentFlag -Name 'LZC_RESETFIREWALL_ALLOW_REMOTE_SESSION'
        if ($null -ne $fromEnv) { $AllowRemoteSession = [switch] $fromEnv }
    }
    if (-not $ScriptBoundParameter.ContainsKey('Force')) {
        $fromEnv = Resolve-EnvironmentFlag -Name 'LZC_RESETFIREWALL_FORCE'
        if ($null -ne $fromEnv) { $Force = [switch] $fromEnv }
    }

    # -Force must not short-circuit ShouldProcess itself, or -WhatIf would stop working. Lower
    # the confirmation threshold instead, and only when the caller did not ask for -Confirm.
    if ($Force -and -not $ScriptBoundParameter.ContainsKey('Confirm')) {
        $ConfirmPreference = 'None'
    }

    Write-Information -MessageData "Action: $Action"

    if ($Action -eq 'Report') {
        return Get-FirewallReport
    }

    $mutating = @('Reset', 'Import') -contains $Action

    if ($Action -eq 'Import' -and [string]::IsNullOrWhiteSpace($ImportFile)) {
        $script:ExitCode = 2
        throw '-Action Import requires -ImportFile (or LZC_RESETFIREWALL_IMPORT_FILE).'
    }

    if ($mutating) {
        Write-Warning 'Destructive action selected. A reset deletes every locally created firewall rule, including rules added by application installers; an import replaces the entire current policy. Group Policy and Intune rules return at the next policy refresh, local rules do not.'
    }

    # Elevation and the remote-session guard are preconditions for mutating. A -WhatIf preview is
    # read-only, so it stays usable from an ordinary shell. Export needs elevation too.
    if (-not $WhatIfPreference) {
        if (-not (Test-Elevated)) {
            Write-Error -ErrorAction Continue -Message "Action '$Action' needs administrator rights. Re-run from an elevated PowerShell session, use -Action Report, or use -WhatIf to preview without elevation."
            $script:ExitCode = 4
            return
        }
        if ($mutating -and (Test-RemoteSession) -and -not $AllowRemoteSession) {
            Write-Error -ErrorAction Continue -Message 'Refusing to change firewall policy: this looks like an RDP or SSH session, and resetting the firewall can remove the inbound rule that keeps it open, leaving the machine unreachable. Run from the console, or pass -AllowRemoteSession if you accept losing this session.'
            $script:ExitCode = 2
            return
        }
        # Last gate before the change. $ConfirmPreference is 'None' only when -Force lowered it
        # above or the caller passed -Confirm:$false. Anything else means ShouldProcess is about
        # to prompt, and a host that cannot answer would turn that into an exception reported as
        # a plain failure.
        if ($ConfirmPreference -ne 'None' -and (Test-NonInteractiveSession)) {
            Write-Error -ErrorAction Continue -Message "Refusing to run '$Action': this action needs confirmation, but the session cannot prompt (it is non-interactive). Pass -Force to confirm in advance, or set LZC_RESETFIREWALL_FORCE=1."
            $script:ExitCode = 5
            return
        }
    }

    $netsh = Join-Path $env:SystemRoot 'System32\netsh.exe'
    $results = @()

    switch ($Action) {
        'Export' {
            $exported = Export-FirewallPolicy -NetshPath $netsh -Directory $BackupPath `
                -TimeoutSeconds $TimeoutSeconds
            $status = 'Succeeded'
            if ([string]::IsNullOrEmpty($exported)) { $status = 'Skipped' }
            $results += [pscustomobject]@{
                Operation = 'Export firewall policy'; Target = $BackupPath
                ExitCode = 0; Status = $status; BackupFile = $exported
            }
        }
        'Reset' {
            $backupFile = ''
            if ($SkipBackup) {
                Write-Warning 'Running without an export because -SkipBackup was passed. Every locally created firewall rule will be permanently unrecoverable.'
            } elseif ($WhatIfPreference) {
                Write-Information -MessageData "What if: would export the current policy to $BackupPath before resetting"
            } else {
                try {
                    $backupFile = Export-FirewallPolicy -NetshPath $netsh -Directory $BackupPath `
                        -TimeoutSeconds $TimeoutSeconds
                } catch {
                    # A failed export is a runtime failure of work this script performed, not a
                    # mistake in how it was called, so it is 1 rather than a usage error.
                    Write-Error -ErrorAction Continue -Message "Could not export the firewall policy to '$BackupPath': $($_.Exception.Message). Refusing to reset without a verified backup; fix the path or pass -SkipBackup to proceed anyway."
                    $script:ExitCode = 1
                    return
                }
                if ([string]::IsNullOrEmpty($backupFile)) {
                    Write-Error -ErrorAction Continue -Message 'The export step was declined, so there is no backup. Refusing to reset.'
                    $script:ExitCode = 1
                    return
                }
            }

            $reset = Invoke-FirewallReset -NetshPath $netsh -TimeoutSeconds $TimeoutSeconds
            $results += $reset | Add-Member -NotePropertyName BackupFile -NotePropertyValue $backupFile -PassThru

            if ($reset.Status -eq 'Succeeded') {
                # Verify rather than assert: report the post-reset profile state instead of
                # printing a success banner the script never checked.
                $results += Get-FirewallReport
                if (-not [string]::IsNullOrEmpty($backupFile)) {
                    Write-Information -MessageData "Rollback: .\ResetFirewall.ps1 -Action Import -ImportFile `"$backupFile`""
                }
            }
        }
        'Import' {
            $results += Import-FirewallPolicy -NetshPath $netsh -Path $ImportFile `
                -TimeoutSeconds $TimeoutSeconds
        }
        default {
            throw "Internal error: unhandled action '$Action'."
        }
    }

    return $results
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
