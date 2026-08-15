#Requires -Version 5.1
#
# ResetNetwork.ps1 -- reset selected Windows networking components.
#
# License: MIT
# Origin:  https://github.com/Lazarev-Cloud/Scripts
#
# Error model: linear script. Set-StrictMode 3.0 and $ErrorActionPreference = 'Stop', so an
# unexpected failure aborts rather than continuing against a half-reset stack. Native tools do
# not raise PowerShell errors, so every netsh call is checked through $LASTEXITCODE explicitly.
# Do not "fix" a failing run by wrapping the call site in -ErrorAction SilentlyContinue.
#
# Every mutation is gated by $PSCmdlet.ShouldProcess immediately before the native call, so
# -WhatIf is a complete and truthful dry run. netsh knows nothing about -WhatIf on its own.

<#
.SYNOPSIS
    Resets selected Windows networking components after saving a rollback snapshot.

.DESCRIPTION
    Resets one or more networking components: the DNS client cache, the Winsock catalog, and
    the IPv4/IPv6 stacks. Each component has a different blast radius, so each is selected
    explicitly instead of being bundled into a single "reset the network" button.

    BLAST RADIUS - read before running:

      DnsCache  Clears the local DNS resolver cache. Non-disruptive, no reboot, no
                configuration is lost. This is the default scope.

      Winsock   'netsh winsock reset' removes every third-party Layered Service Provider from
                the Winsock catalog. VPN clients, endpoint security/EDR filters, packet
                inspectors and parental-control products install LSPs and STOP WORKING until
                they are reinstalled. Requires a reboot.

      IPv4      'netsh interface ipv4 reset' rewrites TCP/IP configuration to clean-install
      IPv6      defaults. STATIC IP ADDRESSES, CUSTOM ROUTES AND MANUALLY SET DNS SERVERS ARE
                LOST and the adapter falls back to DHCP. On a machine you reach over RDP, SSH
                or a VPN, this can sever your access and you may not get back in. Requires a
                reboot.

    Before any destructive scope runs, the current configuration is written to a timestamped
    JSON snapshot (adapters, IP addresses, DNS servers, routes, interface DHCP state) plus a
    'netsh interface dump' script. If that snapshot cannot be written the run is ABORTED,
    because a reset with no rollback artefact is not a reversible operation. Use -SkipBackup to
    override that deliberately.

    Because the destructive scopes can cut remote access, the script refuses to run them when
    it detects an RDP or SSH session unless -AllowRemoteSession is passed.

.PARAMETER Scope
    Components to reset. One or more of: DnsCache, Winsock, IPv4, IPv6, All.
    Defaults to DnsCache, the only non-disruptive scope. Environment: LZC_RESETNETWORK_SCOPE
    (comma separated).

.PARAMETER BackupPath
    Directory for the rollback snapshot. Created if missing.
    Defaults to %ProgramData%\LazarevScripts\ResetNetwork. Environment: LZC_RESETNETWORK_BACKUP_PATH.

.PARAMETER SkipBackup
    Do not capture a rollback snapshot. Only meaningful with a destructive scope, and it removes
    your ability to restore the previous configuration. Environment: LZC_RESETNETWORK_SKIP_BACKUP.

.PARAMETER AllowRemoteSession
    Permit destructive scopes even though this looks like an RDP or SSH session.
    Environment: LZC_RESETNETWORK_ALLOW_REMOTE_SESSION.

.PARAMETER TimeoutSeconds
    Bounds ONE netsh invocation, not the whole run: the snapshot and each component reset are
    separate calls and each gets this allowance in full. Range 10-600, default 120.
    Environment: LZC_RESETNETWORK_TIMEOUT_SECONDS.

.PARAMETER Force
    Suppress confirmation prompts, for unattended use. -WhatIf still wins over -Force.
    Environment: LZC_RESETNETWORK_FORCE.

    The boolean flags above accept 1, true, yes, on, 0, false, no or off in any case. Any other
    value is a usage error and exits 2.

.PARAMETER Version
    Print the script version and exit.

.EXAMPLE
    PS> .\ResetNetwork.ps1 -Scope All -WhatIf

    Shows every operation that a full reset would perform, and changes nothing. Run this first.

.EXAMPLE
    PS> .\ResetNetwork.ps1

    Clears the DNS client cache only. Nothing else is touched.

.EXAMPLE
    PS> .\ResetNetwork.ps1 -Scope Winsock -Force

    Unattended Winsock catalog reset. The snapshot is written first, and the returned object
    carries RebootRequired = $true.

.INPUTS
    None. This script does not accept pipeline input.

.OUTPUTS
    System.Management.Automation.PSCustomObject, one per operation, with Operation, Target,
    ExitCode, Status and RebootRequired properties. RebootRequired is $true only on an operation
    that actually ran and needs a reboot to take effect.

.NOTES
    Version : 2.0
    License : MIT
    Origin  : https://github.com/Lazarev-Cloud/Scripts
    Tested  : Windows PowerShell 5.1 on Windows 11.

    Exit codes (the repo-wide table; this script can return the subset below):
      0     success, or a -WhatIf dry run
      1     the work ran but something in it failed, including the rollback snapshot that a
            destructive scope depends on
      2     usage error: an invalid parameter or environment variable value, no component
            selected, or a remote session without -AllowRemoteSession
      4     must be run as administrator
      5     refused: confirmation was needed, the session cannot prompt, and -Force was not given

    A reboot requirement is NOT signalled through the exit code. A successful Winsock, IPv4 or
    IPv6 reset exits 0 and sets RebootRequired = $true on the returned object, alongside a
    warning. Read that property rather than testing for a magic number.

    Rollback: re-apply the saved 'netsh interface dump' with
      netsh -f <BackupPath>\netsh-interface-dump-<stamp>.txt
    Winsock LSPs are not restored by that dump; reinstall the affected VPN or security product.

.LINK
    https://learn.microsoft.com/en-us/powershell/scripting/learn/deep-dives/everything-about-shouldprocess
#>

[CmdletBinding(DefaultParameterSetName = 'Run', SupportsShouldProcess, ConfirmImpact = 'High')]
[OutputType([pscustomobject])]
param(
    [Parameter(ParameterSetName = 'Run', Position = 0)]
    [ValidateSet('DnsCache', 'Winsock', 'IPv4', 'IPv6', 'All')]
    [string[]] $Scope,

    [Parameter(ParameterSetName = 'Run')]
    [ValidateNotNullOrEmpty()]
    [string] $BackupPath,

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

# Human-facing narration goes to the information stream, which is capturable and suppressible
# with -InformationAction. An explicit -InformationAction from the caller must win.
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
        Returns $true when this looks like an RDP or SSH session, whose connectivity a network
        reset would sever.
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

function Resolve-RequestedScope {
    <#
    .SYNOPSIS
        Expands the -Scope selection into a concrete, de-duplicated, ordered component list.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]] $Requested
    )

    [string[]] $order = @('DnsCache', 'Winsock', 'IPv4', 'IPv6')
    if ($Requested -contains 'All') { return [string[]] $order }

    [string[]] $selected = @()
    foreach ($item in $order) {
        if ($Requested -contains $item) { $selected += $item }
    }
    return [string[]] $selected
}

function Test-ScopeIsDestructive {
    <#
    .SYNOPSIS
        Returns $true when the resolved scope contains a component that loses configuration.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]] $Components
    )

    foreach ($item in $Components) {
        if (@('Winsock', 'IPv4', 'IPv6') -contains $item) { return $true }
    }
    return $false
}

function Get-NetworkSnapshot {
    <#
    .SYNOPSIS
        Collects the current network configuration as a plain, serialisable object.
    .DESCRIPTION
        Every section is captured independently so one unavailable cmdlet degrades that section
        to an error string instead of losing the whole snapshot.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()

    $snapshot = [ordered]@{
        CapturedUtc     = (Get-Date).ToUniversalTime().ToString('o')
        ComputerName    = $env:COMPUTERNAME
        ScriptVersion   = $script:ScriptVersion
        Adapters        = 'not collected'
        IPAddresses     = 'not collected'
        DnsServers      = 'not collected'
        Routes          = 'not collected'
        IPInterfaces    = 'not collected'
    }

    try {
        $snapshot['Adapters'] = @(Get-NetAdapter -ErrorAction Stop |
                Select-Object Name, InterfaceIndex, InterfaceDescription, Status, MacAddress, LinkSpeed)
    } catch {
        $snapshot['Adapters'] = "error: $($_.Exception.Message)"
    }

    try {
        $snapshot['IPAddresses'] = @(Get-NetIPAddress -ErrorAction Stop |
                Select-Object InterfaceIndex, InterfaceAlias, IPAddress, PrefixLength,
                @{ Name = 'AddressFamily'; Expression = { [string] $_.AddressFamily } },
                @{ Name = 'PrefixOrigin'; Expression = { [string] $_.PrefixOrigin } },
                @{ Name = 'SuffixOrigin'; Expression = { [string] $_.SuffixOrigin } })
    } catch {
        $snapshot['IPAddresses'] = "error: $($_.Exception.Message)"
    }

    try {
        $snapshot['DnsServers'] = @(Get-DnsClientServerAddress -ErrorAction Stop |
                Select-Object InterfaceIndex, InterfaceAlias,
                @{ Name = 'AddressFamily'; Expression = { [string] $_.AddressFamily } },
                @{ Name = 'ServerAddresses'; Expression = { @($_.ServerAddresses) } })
    } catch {
        $snapshot['DnsServers'] = "error: $($_.Exception.Message)"
    }

    try {
        $snapshot['Routes'] = @(Get-NetRoute -ErrorAction Stop |
                Select-Object InterfaceIndex, InterfaceAlias, DestinationPrefix, NextHop, RouteMetric,
                @{ Name = 'AddressFamily'; Expression = { [string] $_.AddressFamily } })
    } catch {
        $snapshot['Routes'] = "error: $($_.Exception.Message)"
    }

    try {
        $snapshot['IPInterfaces'] = @(Get-NetIPInterface -ErrorAction Stop |
                Select-Object InterfaceIndex, InterfaceAlias,
                @{ Name = 'AddressFamily'; Expression = { [string] $_.AddressFamily } },
                @{ Name = 'Dhcp'; Expression = { [string] $_.Dhcp } },
                @{ Name = 'ConnectionState'; Expression = { [string] $_.ConnectionState } })
    } catch {
        $snapshot['IPInterfaces'] = "error: $($_.Exception.Message)"
    }

    return [pscustomobject] $snapshot
}

function Save-NetworkSnapshot {
    <#
    .SYNOPSIS
        Writes the rollback snapshot to disk and returns the JSON file path.
    .DESCRIPTION
        Writes a JSON snapshot plus a 'netsh interface dump' script. The JSON is mandatory: if
        it cannot be written, this throws, because the caller must not proceed to a reset
        without a rollback artefact. The netsh dump is best effort and only warns on failure.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Directory,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $NetshPath,

        [Parameter(Mandatory)]
        [ValidateRange(10, 600)]
        [int] $TimeoutSeconds
    )

    if (-not (Test-Path -LiteralPath $Directory -PathType Container)) {
        New-Item -Path $Directory -ItemType Directory -Force | Out-Null
    }

    $stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')
    $jsonPath = Join-Path $Directory "network-snapshot-$stamp.json"
    $dumpPath = Join-Path $Directory "netsh-interface-dump-$stamp.txt"

    $snapshot = Get-NetworkSnapshot
    # Depth 6 covers the nested ServerAddresses arrays without dragging in CIM plumbing.
    $snapshot | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $jsonPath -Encoding UTF8

    $written = Get-Item -LiteralPath $jsonPath
    if ($written.Length -le 0) {
        throw "Rollback snapshot '$jsonPath' was created but is empty."
    }
    Write-Information -MessageData "Snapshot written: $jsonPath"

    # netsh's own dump is directly re-applicable with 'netsh -f', which the JSON is not, so it is
    # worth having as well. It is advisory: a failure here does not block a warned-about reset.
    try {
        $dump = Invoke-NativeCommand -FilePath $NetshPath -ArgumentList @('interface', 'dump') `
            -TimeoutSeconds $TimeoutSeconds
        if ($dump.ExitCode -eq 0 -and $dump.Output.Count -gt 0) {
            $dump.Output | Set-Content -LiteralPath $dumpPath -Encoding UTF8
            Write-Information -MessageData "Restorable netsh dump written: $dumpPath"
        } else {
            Write-Warning "netsh interface dump returned exit code $($dump.ExitCode); no dump file written."
        }
    } catch {
        Write-Warning "Could not capture a netsh interface dump: $($_.Exception.Message)"
    }

    return $jsonPath
}

function Invoke-NativeCommand {
    <#
    .SYNOPSIS
        Runs a native executable under a hard timeout and returns its exit code and stdout.
    .DESCRIPTION
        Ungated on purpose: this is the plumbing. Callers that mutate state must place their own
        ShouldProcess gate immediately before calling this. stderr is deliberately not merged
        into stdout, because in Windows PowerShell 5.1 '2>&1' on a native command wraps each
        stderr line in a NativeCommandError record and flips $? to $false on a clean exit 0.
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
        # Start-Process with -Wait cannot be interrupted, so wait explicitly with a timeout and
        # kill the process if it wedges. netsh can block indefinitely on a sick TCP/IP stack.
        $startArgs = @{
            FilePath               = $FilePath
            NoNewWindow            = $true
            PassThru               = $true
            RedirectStandardOutput = $stdoutFile
        }
        if ($ArgumentList.Count -gt 0) { $startArgs['ArgumentList'] = $ArgumentList }

        $process = Start-Process @startArgs
        # Touching Handle forces the object to cache it; without this, ExitCode can come back
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
            if ($null -eq $output) { $output = @() }
        }

        return [pscustomobject]@{
            FilePath = $FilePath
            Arguments = $ArgumentList -join ' '
            ExitCode = $exitCode
            Output   = $output
        }
    } finally {
        Remove-Item -LiteralPath $stdoutFile -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-GatedNetsh {
    <#
    .SYNOPSIS
        Runs a netsh reset behind a ShouldProcess gate and validates its exit code.
    .DESCRIPTION
        The gate sits immediately before the native call, which is what makes -WhatIf truthful:
        netsh itself has no dry-run mode.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $NetshPath,

        [Parameter(Mandatory)]
        [string[]] $ArgumentList,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Target,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Operation,

        [Parameter(Mandatory)]
        [ValidateRange(10, 600)]
        [int] $TimeoutSeconds
    )

    if (-not $PSCmdlet.ShouldProcess($Target, $Operation)) {
        return [pscustomobject]@{
            Operation = $Operation
            Target    = $Target
            ExitCode  = $null
            Status    = 'Skipped'
        }
    }

    $result = Invoke-NativeCommand -FilePath $NetshPath -ArgumentList $ArgumentList `
        -TimeoutSeconds $TimeoutSeconds

    # Abort rather than continue to the next component: if resetting Winsock failed, going on to
    # discard the IPv4 configuration as well only widens the damage.
    if ($result.ExitCode -ne 0) {
        $detail = ($result.Output -join [Environment]::NewLine).Trim()
        throw "$Operation failed: netsh exited with code $($result.ExitCode). $detail"
    }

    return [pscustomobject]@{
        Operation = $Operation
        Target    = $Target
        ExitCode  = $result.ExitCode
        Status    = 'Succeeded'
    }
}

function Invoke-DnsCacheReset {
    <#
    .SYNOPSIS
        Clears the local DNS client cache. Non-destructive; nothing is unlearned but cached answers.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
    [OutputType([pscustomobject])]
    param()

    if (-not $PSCmdlet.ShouldProcess('DNS client cache', 'Clear cached DNS records')) {
        return [pscustomobject]@{
            Operation = 'Clear DNS client cache'; Target = 'DNS client cache'
            ExitCode = $null; Status = 'Skipped'
        }
    }

    # Errors propagate: $ErrorActionPreference is 'Stop' and the outer handler reports them.
    Clear-DnsClientCache -ErrorAction Stop

    return [pscustomobject]@{
        Operation = 'Clear DNS client cache'; Target = 'DNS client cache'
        ExitCode = 0; Status = 'Succeeded'
    }
}

function Invoke-Main {
    <#
    .SYNOPSIS
        Validates the request, captures a snapshot, and performs the selected resets.
    .DESCRIPTION
        Deliberately does not declare SupportsShouldProcess of its own: the gates live next to
        the native calls in Invoke-GatedNetsh, and $WhatIfPreference / $ConfirmPreference reach
        them through the scope chain. A second gate here would double-prompt.
    .PARAMETER ScriptBoundParameter
        The script's own $PSBoundParameters. It must be passed in: inside this function
        $PSBoundParameters describes *this function's* arguments, so testing it for 'Scope' or
        'Force' would always be false and every explicitly supplied argument would be silently
        replaced by its environment-variable default.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $ScriptBoundParameter
    )

    if ($Version) {
        Write-Information -MessageData "ResetNetwork.ps1 version $script:ScriptVersion"
        return
    }

    # Resolve flags that were not passed explicitly from the environment, so every flag has an
    # env var and the script is usable from a scheduled task with no command line edits.
    # Guard order, identical across every script in this repo: configuration (2), platform and
    # prerequisites (3), elevation (4), interactivity (5), then the work itself (0 or 1).
    # $script:ExitCode is set to 2 before each validation throw so the catch at the bottom
    # reports a usage error rather than the generic failure code.
    if (-not $ScriptBoundParameter.ContainsKey('Scope')) {
        $fromEnv = Get-EnvironmentValue -Name 'LZC_RESETNETWORK_SCOPE' -Fallback 'DnsCache'
        $Scope = [string[]] @($fromEnv -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        foreach ($candidate in $Scope) {
            if (@('DnsCache', 'Winsock', 'IPv4', 'IPv6', 'All') -notcontains $candidate) {
                $script:ExitCode = 2
                throw "LZC_RESETNETWORK_SCOPE contains an unknown component '$candidate'. Valid: DnsCache, Winsock, IPv4, IPv6, All."
            }
        }
    }
    if (-not $ScriptBoundParameter.ContainsKey('BackupPath')) {
        $BackupPath = Get-EnvironmentValue -Name 'LZC_RESETNETWORK_BACKUP_PATH' `
            -Fallback (Join-Path $env:ProgramData 'LazarevScripts\ResetNetwork')
    }
    if (-not $ScriptBoundParameter.ContainsKey('TimeoutSeconds')) {
        $raw = Get-EnvironmentValue -Name 'LZC_RESETNETWORK_TIMEOUT_SECONDS' -Fallback '120'
        $parsed = 0
        # TryParse reads '08' as decimal 8, so a zero-padded value in a scheduled-task definition
        # means what it looks like rather than becoming an invalid octal literal. The floor of 10
        # matches the -TimeoutSeconds ValidateRange and keeps the value well clear of 0, which a
        # caller would reasonably read as "no limit" and which would remove the bound entirely.
        if (-not [int]::TryParse($raw, [ref] $parsed)) {
            $script:ExitCode = 2
            throw "LZC_RESETNETWORK_TIMEOUT_SECONDS must be an integer, got '$raw'."
        }
        if ($parsed -lt 10 -or $parsed -gt 600) {
            $script:ExitCode = 2
            throw "LZC_RESETNETWORK_TIMEOUT_SECONDS must be between 10 and 600, got $parsed."
        }
        $TimeoutSeconds = $parsed
    }
    if (-not $ScriptBoundParameter.ContainsKey('SkipBackup')) {
        $fromEnvFlag = Resolve-EnvironmentFlag -Name 'LZC_RESETNETWORK_SKIP_BACKUP'
        if ($null -ne $fromEnvFlag) { $SkipBackup = [switch] $fromEnvFlag }
    }
    if (-not $ScriptBoundParameter.ContainsKey('AllowRemoteSession')) {
        $fromEnvFlag = Resolve-EnvironmentFlag -Name 'LZC_RESETNETWORK_ALLOW_REMOTE_SESSION'
        if ($null -ne $fromEnvFlag) { $AllowRemoteSession = [switch] $fromEnvFlag }
    }
    if (-not $ScriptBoundParameter.ContainsKey('Force')) {
        $fromEnvFlag = Resolve-EnvironmentFlag -Name 'LZC_RESETNETWORK_FORCE'
        if ($null -ne $fromEnvFlag) { $Force = [switch] $fromEnvFlag }
    }

    # -Force must not short-circuit ShouldProcess itself, or -WhatIf would stop working. Lower
    # the confirmation threshold instead, and only when the caller did not ask for -Confirm.
    if ($Force -and -not $ScriptBoundParameter.ContainsKey('Confirm')) {
        $ConfirmPreference = 'None'
    }

    $components = @(Resolve-RequestedScope -Requested $Scope)
    if ($components.Count -eq 0) {
        $script:ExitCode = 2
        throw 'No components selected. Use -Scope with DnsCache, Winsock, IPv4, IPv6 or All.'
    }
    $destructive = Test-ScopeIsDestructive -Components $components

    Write-Information -MessageData "Selected components: $($components -join ', ')"

    if ($destructive) {
        Write-Warning 'Destructive scope selected. Winsock removes third-party LSPs (VPN/EDR software will need reinstalling); IPv4/IPv6 discard static addresses, custom routes and manual DNS servers. A reboot is required.'
    }

    # Elevation and the remote-session guard are real preconditions for mutating, but a -WhatIf
    # preview is read-only, so it stays usable from an ordinary shell.
    if ($destructive -and -not $WhatIfPreference) {
        if (-not (Test-Elevated)) {
            # -ErrorAction Continue: this is a deliberate, reported refusal, not an exception. Without it
            # $ErrorActionPreference='Stop' would make Write-Error terminating and the exit code
            # below would never be set.
            Write-Error -ErrorAction Continue -Message 'This scope needs administrator rights. Re-run from an elevated PowerShell session, or use -WhatIf to preview without elevation.'
            $script:ExitCode = 4
            return
        }
        if ((Test-RemoteSession) -and -not $AllowRemoteSession) {
            Write-Error -ErrorAction Continue -Message 'Refusing to run a destructive network reset: this looks like an RDP or SSH session and the reset can sever it, leaving the machine unreachable. Run from the console, or pass -AllowRemoteSession if you accept losing this session.'
            $script:ExitCode = 2
            return
        }
        # Last gate before the change. $ConfirmPreference is 'None' only when -Force lowered it
        # above or the caller passed -Confirm:$false. Anything else means ShouldProcess is about
        # to prompt, and a host that cannot answer would turn that into an exception reported as
        # a plain failure.
        if ($ConfirmPreference -ne 'None' -and (Test-NonInteractiveSession)) {
            Write-Error -ErrorAction Continue -Message "Refusing to reset $($components -join ', '): this needs confirmation, but the session cannot prompt (it is non-interactive). Pass -Force to confirm in advance, or set LZC_RESETNETWORK_FORCE=1."
            $script:ExitCode = 5
            return
        }
    }

    $netsh = Join-Path $env:SystemRoot 'System32\netsh.exe'

    if ($destructive -and -not $SkipBackup -and -not $WhatIfPreference) {
        try {
            Save-NetworkSnapshot -Directory $BackupPath -NetshPath $netsh -TimeoutSeconds $TimeoutSeconds | Out-Null
        } catch {
            # A failed snapshot is a runtime failure of work this script performed, not a mistake
            # in how it was called, so it is 1 rather than a usage error.
            Write-Error -ErrorAction Continue -Message "Could not write the rollback snapshot to '$BackupPath': $($_.Exception.Message). Refusing to reset without a rollback artefact; fix the path or pass -SkipBackup to proceed anyway."
            $script:ExitCode = 1
            return
        }
    } elseif ($destructive -and $SkipBackup) {
        Write-Warning 'Running without a rollback snapshot because -SkipBackup was passed. The previous configuration will not be recoverable from this machine.'
    } elseif ($destructive -and $WhatIfPreference) {
        Write-Information -MessageData "What if: would write a rollback snapshot to $BackupPath"
    }

    $results = @()
    $rebootRequired = $false

    foreach ($component in $components) {
        switch ($component) {
            'DnsCache' {
                $results += Invoke-DnsCacheReset
            }
            # Each branch records "reboot required" only if its own reset actually ran. Setting the
            # flag merely because the component was requested would report 3010 after the user
            # declined the prompt, and a scheduler reading 3010 would reboot the machine for a
            # reset that never happened.
            'Winsock' {
                $outcome = Invoke-GatedNetsh -NetshPath $netsh -ArgumentList @('winsock', 'reset') `
                    -Target 'Winsock catalog' `
                    -Operation 'Reset Winsock catalog (removes third-party LSPs; reboot required)' `
                    -TimeoutSeconds $TimeoutSeconds
                $results += $outcome
                if ($outcome.Status -eq 'Succeeded') { $rebootRequired = $true }
            }
            'IPv4' {
                $outcome = Invoke-GatedNetsh -NetshPath $netsh -ArgumentList @('interface', 'ipv4', 'reset') `
                    -Target 'IPv4 stack' `
                    -Operation 'Reset IPv4 stack to defaults (discards static IP, routes and DNS; reboot required)' `
                    -TimeoutSeconds $TimeoutSeconds
                $results += $outcome
                if ($outcome.Status -eq 'Succeeded') { $rebootRequired = $true }
            }
            'IPv6' {
                $outcome = Invoke-GatedNetsh -NetshPath $netsh -ArgumentList @('interface', 'ipv6', 'reset') `
                    -Target 'IPv6 stack' `
                    -Operation 'Reset IPv6 stack to defaults (discards static IP, routes and DNS; reboot required)' `
                    -TimeoutSeconds $TimeoutSeconds
                $results += $outcome
                if ($outcome.Status -eq 'Succeeded') { $rebootRequired = $true }
            }
            default {
                throw "Internal error: unhandled component '$component'."
            }
        }
    }

    if ($rebootRequired -and -not $WhatIfPreference) {
        Write-Warning 'A reboot is required before the reset takes effect. Exit code 3010 signals this to schedulers and RMM tools.'
        $script:ExitCode = 3010
    }

    return $results
}

try {
    Invoke-Main -ScriptBoundParameter $PSBoundParameters
} catch {
    # Include the failing line: without it a one-line message from deep in a helper is very hard
    # to place, and this script is meant to be diagnosable by someone who did not write it.
    # ScriptStackTrace names the frame that actually failed; InvocationInfo here would only
    # point back at the Invoke-Main call site. -ErrorAction Continue keeps this non-terminating
    # so the exit statement below is always reached.
    $origin = @($_.ScriptStackTrace -split "`r?`n") | Select-Object -First 1
    Write-Error -ErrorAction Continue -Message ("{0}{1}  {2}" -f $_.Exception.Message, [Environment]::NewLine, $origin)
    $script:ExitCode = 1
}

exit $script:ExitCode
