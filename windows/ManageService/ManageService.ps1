#Requires -Version 5.1
#
# ManageService.ps1 -- inspect, start, stop or restart a Windows service.
#
# License: MIT
# Origin:  https://github.com/Lazarev-Cloud/Scripts
#
# Error model: linear script. Set-StrictMode 3.0 and $ErrorActionPreference = 'Stop'. Deliberate
# refusals (not elevated, protected service, running dependents) are reported with
# Write-Error -ErrorAction Continue and a distinct exit code, not thrown. Anything unexpected
# aborts and is reported by the outer handler.
#
# Every state change is gated by $PSCmdlet.ShouldProcess immediately before the call, so -WhatIf
# is a complete and truthful dry run.

<#
.SYNOPSIS
    Reports on or changes the state of a single named Windows service, with protection for
    services the system depends on.

.DESCRIPTION
    Replaces the common "restart the stuck service" one-liner with something safe to hand to
    someone else.

    What it does differently from the naive version:

      - The service name is validated and must be exact. Wildcards are rejected, so a typo
        cannot fan out across dozens of services.
      - Status is the default action, is read-only, and needs no elevation.
      - Before stopping or restarting, running dependent services are enumerated and listed.
        Stopping a service with running dependents requires -Force, because that is what
        actually cascades the stop, and the naive script hides which services get taken down
        with it.
      - A list of protected services is checked before any stop or restart. Stopping these
        breaks servicing, logon, networking or security, so they additionally require
        -AllowProtectedService. -Force alone is deliberately not enough: an unattended run must
        not be able to stop TrustedInstaller by accident.

    BLAST RADIUS: stopping or restarting a service interrupts everything that depends on it.
    With -Force, dependent services are stopped too, and NEITHER Stop NOR Restart starts them
    again. Restart brings back only the service you named; its dependents stay stopped. They are
    listed by name in the warning before the stop, so start them again yourself. Stopping
    servicing services (TrustedInstaller, msiserver, wuauserv) while an update is applying can
    leave the component store in a pending state that makes later DISM runs fail.

.PARAMETER Name
    Exact service name (the short name, for example 'Spooler', not the display name).
    Wildcards, quotes and path separators are rejected. Environment: LZC_MANAGESERVICE_NAME.

.PARAMETER Action
    Status   Read-only. Reports state, start type, and dependencies. Default, no elevation needed.
    Start    Starts the service if it is not already running.
    Stop     Stops the service.
    Restart  Stops then starts the service; starts it if it was not running.
    Environment: LZC_MANAGESERVICE_ACTION.

.PARAMETER TimeoutSeconds
    Bounds ONE thing: how long to wait for the service to report the requested state after the
    start or stop has been issued. It does not bound the whole script, and for Restart the stop
    and the following start each get the full allowance. Range 5-600, default 60.
    Environment: LZC_MANAGESERVICE_TIMEOUT_SECONDS.

.PARAMETER ProtectedService
    Service names that require -AllowProtectedService before they can be stopped or restarted.
    Replaces the built-in list entirely when supplied.
    Environment: LZC_MANAGESERVICE_PROTECTED_SERVICES (comma separated).

.PARAMETER AllowProtectedService
    Permit stopping or restarting a service on the protected list.
    Environment: LZC_MANAGESERVICE_ALLOW_PROTECTED.

.PARAMETER Force
    Allow the stop to cascade to running dependent services, and suppress confirmation prompts.
    -WhatIf still wins over -Force. Environment: LZC_MANAGESERVICE_FORCE.

    Both flags accept 1, true, yes, on, 0, false, no or off in any case. Any other value is a
    usage error and exits 2.

.PARAMETER Version
    Print the script version and exit.

.EXAMPLE
    PS> .\ManageService.ps1 -Name Spooler

    Reports the Print Spooler's state, start type, dependencies and dependents. Changes nothing
    and needs no elevation.

.EXAMPLE
    PS> .\ManageService.ps1 -Name Spooler -Action Restart -WhatIf

    Shows what a restart would do, including which dependent services would be affected.

.EXAMPLE
    PS> .\ManageService.ps1 -Name Spooler -Action Restart -Force

    Unattended restart, cascading to dependent services.

.INPUTS
    None. This script does not accept pipeline input.

.OUTPUTS
    System.Management.Automation.PSCustomObject describing the service and the action taken.

.NOTES
    Version : 2.0
    License : MIT
    Origin  : https://github.com/Lazarev-Cloud/Scripts
    Tested  : Windows PowerShell 5.1 on Windows 11.

    Exit codes (the repo-wide table; this script can return the subset below):
      0  success, or a -WhatIf dry run
      1  the work ran but something in it failed, including the service not reaching the
         requested state within -TimeoutSeconds
      2  usage error: an invalid parameter or environment variable value, no service with that
         name, a protected service without -AllowProtectedService, running dependents without
         -Force, or a service that reports it cannot be stopped
      4  must be run as administrator
      5  refused: confirmation was needed, the session cannot prompt, and -Force was not given

.LINK
    https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.management/restart-service
#>

[CmdletBinding(DefaultParameterSetName = 'Run', SupportsShouldProcess, ConfirmImpact = 'High')]
[OutputType([pscustomobject])]
param(
    [Parameter(ParameterSetName = 'Run', Position = 0)]
    [ValidateNotNullOrEmpty()]
    [ValidateLength(1, 256)]
    # Service names are limited to 256 chars and may not contain '/' or '\'. Wildcards are
    # excluded on purpose: Get-Service would happily expand 'w*' to every matching service.
    # Quotes are excluded because Get-ServiceDetail interpolates this value into a WQL -Filter
    # string, where an embedded quote would terminate the literal early; rejecting the character
    # here is the invariant that makes that call site safe.
    [ValidatePattern('^[^\*\?/\\''"]+$')]
    [string] $Name,

    [Parameter(ParameterSetName = 'Run', Position = 1)]
    [ValidateSet('Status', 'Start', 'Stop', 'Restart')]
    [string] $Action,

    [Parameter(ParameterSetName = 'Run')]
    [ValidateRange(5, 600)]
    [int] $TimeoutSeconds,

    [Parameter(ParameterSetName = 'Run')]
    [ValidateNotNullOrEmpty()]
    [string[]] $ProtectedService,

    [Parameter(ParameterSetName = 'Run')]
    [switch] $AllowProtectedService,

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

# How often Wait-ServiceState re-checks the service while waiting. An implementation detail, not
# a user-facing threshold: the user-facing wait budget is -TimeoutSeconds.
$script:ServicePollIntervalMs = 500

# Stopping any of these breaks servicing, logon, networking or security in ways that are not
# obvious from the service name alone. Overridable in full with -ProtectedService.
$script:DefaultProtectedServices = @(
    'TrustedInstaller', 'msiserver', 'wuauserv', 'CryptSvc', 'BFE', 'MpsSvc', 'WinDefend',
    'RpcSs', 'DcomLaunch', 'EventLog', 'SamSs', 'LSM', 'gpsvc', 'ProfSvc', 'Schedule',
    'PlugPlay', 'Power', 'nsi', 'Dhcp', 'Dnscache', 'LanmanServer', 'LanmanWorkstation',
    'TermService', 'WinRM', 'NlaSvc', 'netprofm'
)

if (-not $PSBoundParameters.ContainsKey('InformationAction')) {
    $InformationPreference = 'Continue'
}

# Load CimCmdlets up front, explicitly outside -WhatIf. Left to auto-loading it would be imported
# on the first Get-CimInstance call, and the aliases the module defines at import time surface in
# a -WhatIf run as a dozen bogus 'What if: Set Alias' lines that have nothing to do with this
# script and obscure the operations the user actually asked to preview.
# Import-Module has no -WhatIf or -Confirm parameter of its own, so both preferences are
# neutralised around the call instead and restored immediately afterwards. They are neutralised at
# GLOBAL scope because a module's own Set-Alias calls run in module scope, whose parent is the
# global scope; a local override would not reach them. ConfirmPreference matters as much as
# WhatIfPreference: under -Confirm the module's 'Set-Alias -Name gcim -Option ReadOnly, AllScope'
# asks to confirm, which is an artefact of importing a module and has nothing to do with the
# operation the user asked about. In a non-interactive session that prompt cannot be answered and
# the script dies before it starts.
if (-not (Get-Module -Name CimCmdlets)) {
    $previousWhatIfPreference = $global:WhatIfPreference
    $previousConfirmPreference = $global:ConfirmPreference
    $global:WhatIfPreference = $false
    $global:ConfirmPreference = 'None'
    try {
        Import-Module -Name CimCmdlets -Verbose:$false
    } finally {
        $global:WhatIfPreference = $previousWhatIfPreference
        $global:ConfirmPreference = $previousConfirmPreference
    }
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

function Get-ServiceDetail {
    <#
    .SYNOPSIS
        Returns a flat, serialisable description of a service, including its dependencies.
    .DESCRIPTION
        StartType and the executable path come from the CIM Win32_Service class, which Get-Service
        does not expose. Get-CimInstance is used rather than Get-WmiObject, which does not exist
        in PowerShell 7.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        # Deliberately untyped. [System.ServiceProcess.ServiceController] does not resolve in a
        # fresh session until something loads the assembly - Get-Service is what does that - so
        # naming it here would make these helpers depend on call order and fail with "Unable to
        # find type" if one were ever reached first. The object always comes from Get-Service.
        $Service
    )

    $startMode = 'unknown'
    $account = 'unknown'
    $path = 'unknown'
    try {
        # -Filter with a literal is safe here: Name has already been validated to contain no
        # wildcards, quotes or path separators.
        $cim = Get-CimInstance -ClassName Win32_Service -Filter "Name='$($Service.Name)'" -ErrorAction Stop
        if ($cim) {
            $startMode = [string] $cim.StartMode
            $account = [string] $cim.StartName
            $path = [string] $cim.PathName
        }
    } catch {
        Write-Verbose "Could not read Win32_Service for '$($Service.Name)': $($_.Exception.Message)"
    }

    return [pscustomobject]@{
        Name              = $Service.Name
        DisplayName       = $Service.DisplayName
        Status            = [string] $Service.Status
        StartMode         = $startMode
        StartAccount      = $account
        ExecutablePath    = $path
        CanStop           = $Service.CanStop
        RunningDependents = @(Get-RunningDependent -Service $Service)
        DependsOn         = @($Service.ServicesDependedOn | ForEach-Object { $_.Name })
    }
}

function Get-RunningDependent {
    <#
    .SYNOPSIS
        Returns the names of dependent services that are currently running.
    .DESCRIPTION
        These are exactly the services a forced stop would take down as collateral. Stop-Service
        -Force stops them without naming them, which is the behaviour this script exists to make
        visible.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        # Deliberately untyped. [System.ServiceProcess.ServiceController] does not resolve in a
        # fresh session until something loads the assembly - Get-Service is what does that - so
        # naming it here would make these helpers depend on call order and fail with "Unable to
        # find type" if one were ever reached first. The object always comes from Get-Service.
        $Service
    )

    # Compared as a string rather than against the ServiceControllerStatus enum so the check does
    # not depend on that enum type being resolvable on the running edition.
    [string[]] $names = @()
    foreach ($dependent in $Service.DependentServices) {
        if ([string] $dependent.Status -ne 'Stopped') {
            $names += $dependent.Name
        }
    }
    return [string[]] $names
}

function Wait-ServiceState {
    <#
    .SYNOPSIS
        Waits for a service to reach a status, throwing a readable error if it does not.
    .DESCRIPTION
        Polls rather than calling ServiceController.WaitForStatus. WaitForStatus signals failure
        by throwing System.ServiceProcess.TimeoutException, and naming that type in a catch clause
        makes the handler depend on an assembly that is not loaded by default on every edition; if
        it failed to resolve, the timeout would surface as an unhandled error instead of the clear
        message below. Comparing the status as a string keeps this working the same way on
        Windows PowerShell 5.1 and PowerShell 7.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        # Deliberately untyped. [System.ServiceProcess.ServiceController] does not resolve in a
        # fresh session until something loads the assembly - Get-Service is what does that - so
        # naming it here would make these helpers depend on call order and fail with "Unable to
        # find type" if one were ever reached first. The object always comes from Get-Service.
        $Service,

        [Parameter(Mandatory)]
        [ValidateSet('Running', 'Stopped')]
        [string] $Status,

        [Parameter(Mandatory)]
        [ValidateRange(5, 600)]
        [int] $TimeoutSeconds
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $Service.Refresh()
        if ([string] $Service.Status -eq $Status) { return }
        Start-Sleep -Milliseconds $script:ServicePollIntervalMs
    }

    $Service.Refresh()
    throw "Service '$($Service.Name)' did not reach state '$Status' within $TimeoutSeconds seconds (current state: $($Service.Status))."
}

function Invoke-ServiceAction {
    <#
    .SYNOPSIS
        Performs the requested state change behind a ShouldProcess gate and waits for the result.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        # Deliberately untyped. [System.ServiceProcess.ServiceController] does not resolve in a
        # fresh session until something loads the assembly - Get-Service is what does that - so
        # naming it here would make these helpers depend on call order and fail with "Unable to
        # find type" if one were ever reached first. The object always comes from Get-Service.
        $Service,

        [Parameter(Mandatory)]
        [ValidateSet('Start', 'Stop', 'Restart')]
        [string] $Action,

        [Parameter(Mandatory)]
        [ValidateRange(5, 600)]
        [int] $TimeoutSeconds,

        [Parameter()]
        [switch] $Cascade
    )

    $label = "$($Service.DisplayName) ($($Service.Name))"
    $operation = switch ($Action) {
        'Start' { 'Start service' }
        'Stop' { 'Stop service' }
        'Restart' { 'Restart service' }
        default { throw "Internal error: unhandled action '$Action'." }
    }
    if ($Cascade -and $Action -ne 'Start') {
        $operation += ' and its running dependents'
    }

    if (-not $PSCmdlet.ShouldProcess($label, $operation)) {
        return [pscustomobject]@{
            Operation = $operation; Target = $label; Status = 'Skipped'; FinalState = [string] $Service.Status
        }
    }

    # -Confirm:$false on the inner cmdlets: this call site has already prompted, and a second
    # prompt from Stop-Service would be a bug, not extra safety.
    switch ($Action) {
        'Start' {
            Start-Service -InputObject $Service -Confirm:$false
            Wait-ServiceState -Service $Service -Status Running -TimeoutSeconds $TimeoutSeconds
        }
        'Stop' {
            Stop-Service -InputObject $Service -Force:$Cascade -Confirm:$false
            Wait-ServiceState -Service $Service -Status Stopped -TimeoutSeconds $TimeoutSeconds
        }
        'Restart' {
            if ([string] $Service.Status -ne 'Stopped') {
                Stop-Service -InputObject $Service -Force:$Cascade -Confirm:$false
                Wait-ServiceState -Service $Service -Status Stopped -TimeoutSeconds $TimeoutSeconds
            }
            Start-Service -InputObject $Service -Confirm:$false
            Wait-ServiceState -Service $Service -Status Running -TimeoutSeconds $TimeoutSeconds
        }
        default { throw "Internal error: unhandled action '$Action'." }
    }

    $Service.Refresh()
    return [pscustomobject]@{
        Operation = $operation; Target = $label; Status = 'Succeeded'; FinalState = [string] $Service.Status
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
        Write-Information -MessageData "ManageService.ps1 version $script:ScriptVersion"
        return
    }

    # Guard order, identical across every script in this repo: configuration (2), platform and
    # prerequisites (3), elevation (4), interactivity (5), then the work itself (0 or 1).
    # $script:ExitCode is set to 2 before each validation throw so the catch at the bottom
    # reports a usage error rather than the generic failure code.
    if (-not $ScriptBoundParameter.ContainsKey('Name')) {
        $Name = Get-EnvironmentValue -Name 'LZC_MANAGESERVICE_NAME' -Fallback ''
        if ([string]::IsNullOrWhiteSpace($Name)) {
            $script:ExitCode = 2
            throw 'A service name is required. Pass -Name <service> or set LZC_MANAGESERVICE_NAME.'
        }
        # Kept character-for-character in step with the -Name ValidatePattern above. Two
        # validation paths that disagree would let the environment variable carry input the
        # parameter rejects, which is exactly the class of gap the pattern exists to close.
        if ($Name -match '[\*\?/\\''"]') {
            $script:ExitCode = 2
            throw "LZC_MANAGESERVICE_NAME must be an exact service name without wildcards, quotes or path separators, got '$Name'."
        }
    }
    if (-not $ScriptBoundParameter.ContainsKey('Action')) {
        $Action = Get-EnvironmentValue -Name 'LZC_MANAGESERVICE_ACTION' -Fallback 'Status'
        if (@('Status', 'Start', 'Stop', 'Restart') -notcontains $Action) {
            $script:ExitCode = 2
            throw "LZC_MANAGESERVICE_ACTION must be Status, Start, Stop or Restart, got '$Action'."
        }
    }
    if (-not $ScriptBoundParameter.ContainsKey('TimeoutSeconds')) {
        $raw = Get-EnvironmentValue -Name 'LZC_MANAGESERVICE_TIMEOUT_SECONDS' -Fallback '60'
        $parsed = 0
        # TryParse reads '08' as decimal 8, so a zero-padded value in a scheduled-task definition
        # means what it looks like rather than becoming an invalid octal literal. The floor of 5
        # matches the -TimeoutSeconds ValidateRange, and is well above the zero that would mean
        # "wait forever" to a caller expecting a bound.
        if (-not [int]::TryParse($raw, [ref] $parsed)) {
            $script:ExitCode = 2
            throw "LZC_MANAGESERVICE_TIMEOUT_SECONDS must be an integer, got '$raw'."
        }
        if ($parsed -lt 5 -or $parsed -gt 600) {
            $script:ExitCode = 2
            throw "LZC_MANAGESERVICE_TIMEOUT_SECONDS must be between 5 and 600, got $parsed."
        }
        $TimeoutSeconds = $parsed
    }
    if (-not $ScriptBoundParameter.ContainsKey('ProtectedService')) {
        $fromEnv = Get-EnvironmentValue -Name 'LZC_MANAGESERVICE_PROTECTED_SERVICES' -Fallback ''
        if ([string]::IsNullOrWhiteSpace($fromEnv)) {
            $ProtectedService = $script:DefaultProtectedServices
        } else {
            $ProtectedService = @($fromEnv -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        }
    }
    if (-not $ScriptBoundParameter.ContainsKey('AllowProtectedService')) {
        $fromEnvFlag = Resolve-EnvironmentFlag -Name 'LZC_MANAGESERVICE_ALLOW_PROTECTED'
        if ($null -ne $fromEnvFlag) { $AllowProtectedService = [switch] $fromEnvFlag }
    }
    if (-not $ScriptBoundParameter.ContainsKey('Force')) {
        $fromEnvFlag = Resolve-EnvironmentFlag -Name 'LZC_MANAGESERVICE_FORCE'
        if ($null -ne $fromEnvFlag) { $Force = [switch] $fromEnvFlag }
    }

    # -Force must not short-circuit ShouldProcess itself, or -WhatIf would stop working. Lower
    # the confirmation threshold instead, and only when the caller did not ask for -Confirm.
    if ($Force -and -not $ScriptBoundParameter.ContainsKey('Confirm')) {
        $ConfirmPreference = 'None'
    }

    # Get-Service throws when the service does not exist; that is a distinct, expected outcome
    # that deserves its own exit code rather than a generic failure.
    $service = $null
    try {
        $service = Get-Service -Name $Name -ErrorAction Stop
    } catch {
        Write-Error -ErrorAction Continue -Message "No service named '$Name' exists on $env:COMPUTERNAME. Service names are the short name, not the display name; run Get-Service to list them."
        $script:ExitCode = 2
        return
    }

    $detail = Get-ServiceDetail -Service $service
    Write-Information -MessageData "Service '$($detail.Name)' ($($detail.DisplayName)): $($detail.Status), start mode $($detail.StartMode)"

    if ($Action -eq 'Status') {
        return $detail
    }

    $stopsService = @('Stop', 'Restart') -contains $Action

    if (-not $WhatIfPreference -and -not (Test-Elevated)) {
        Write-Error -ErrorAction Continue -Message "Action '$Action' needs administrator rights. Re-run from an elevated PowerShell session, use -Action Status, or use -WhatIf to preview without elevation."
        $script:ExitCode = 4
        return
    }

    if ($stopsService) {
        if (($ProtectedService -contains $detail.Name) -and -not $AllowProtectedService) {
            Write-Error -ErrorAction Continue -Message "'$($detail.Name)' is on the protected list: stopping it breaks servicing, logon, networking or security. Pass -AllowProtectedService to override, or edit the list with -ProtectedService / LZC_MANAGESERVICE_PROTECTED_SERVICES."
            $script:ExitCode = 2
            return
        }

        if ($detail.RunningDependents.Count -gt 0) {
            Write-Warning "Stopping '$($detail.Name)' also stops these running dependent services: $($detail.RunningDependents -join ', '). Neither Stop nor Restart starts them again - Restart brings back only '$($detail.Name)'. Start them yourself afterwards."
            if (-not $Force) {
                Write-Error -ErrorAction Continue -Message "'$($detail.Name)' has running dependent services ($($detail.RunningDependents -join ', ')). Re-run with -Force to stop them as well; without it the stop would fail anyway."
                $script:ExitCode = 2
                return
            }
        }

        # Restart stops the service too, so it needs the same precheck. Gating
        # this on Stop alone meant a Restart of a service reporting CanStop
        # false skipped the clean exit 2 and instead ran into the Stop-Service
        # timeout, surfacing as a generic exit 1 -- while the help and the
        # README both list "a service that cannot be stopped" under exit 2
        # without qualifying it by action.
        if (-not $service.CanStop -and $Action -in @('Stop', 'Restart')) {
            Write-Error -ErrorAction Continue -Message "Service '$($detail.Name)' reports that it cannot be stopped."
            $script:ExitCode = 2
            return
        }
    }

    if ($Action -eq 'Start' -and $detail.Status -eq 'Running') {
        Write-Information -MessageData "Service '$($detail.Name)' is already running; nothing to do."
        return $detail
    }

    # Last gate before the change. $ConfirmPreference is 'None' only when -Force lowered it above
    # or the caller passed -Confirm:$false. Anything else means ShouldProcess is about to prompt,
    # and a host that cannot answer would turn that into an exception reported as a plain failure.
    if (-not $WhatIfPreference -and $ConfirmPreference -ne 'None' -and (Test-NonInteractiveSession)) {
        Write-Error -ErrorAction Continue -Message "Refusing to $Action '$($detail.Name)': this action needs confirmation, but the session cannot prompt (it is non-interactive). Pass -Force to confirm in advance, or set LZC_MANAGESERVICE_FORCE=1."
        $script:ExitCode = 5
        return
    }

    $result = Invoke-ServiceAction -Service $service -Action $Action `
        -TimeoutSeconds $TimeoutSeconds -Cascade:$Force

    if ($result.Status -eq 'Succeeded') {
        Write-Information -MessageData "Service '$($detail.Name)' is now $($result.FinalState)."
    }

    return $result
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
