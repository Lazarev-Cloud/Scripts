#Requires -Version 5.1
#
# RestartGraphicsDriver.ps1 -- report graphics adapter state, or restart the desktop compositor.
#
# License: MIT
# Origin:  https://github.com/Lazarev-Cloud/Scripts
#
# Error model: linear script. Set-StrictMode 3.0 and $ErrorActionPreference = 'Stop'. Deliberate
# refusals (not elevated, no compositor in this session) are reported with
# Write-Error -ErrorAction Continue and a distinct exit code, not thrown.
#
# The state change is gated by $PSCmdlet.ShouldProcess immediately before the kill, so -WhatIf is
# a complete and truthful dry run.

<#
.SYNOPSIS
    Reports graphics adapter and display-driver-recovery state, and can restart the Desktop
    Window Manager for the current session.

.DESCRIPTION
    READ THIS FIRST: STOPPING dwm.exe IS NOT A GRAPHICS DRIVER RESTART.

    dwm.exe is the Desktop Window Manager, the compositor that draws the desktop. Killing it
    makes Windows restart it, which rebuilds the composition tree. That can clear some visual
    corruption, but it does not reload, reset or restart the display driver, and it will not fix
    a driver-level fault.

    The real "restart the graphics driver" gesture is Win+Ctrl+Shift+B, which triggers a
    Timeout Detection and Recovery (TDR) reset of the graphics stack. Windows exposes no
    supported public API for that, so it cannot be scripted. There is no PowerShell equivalent,
    and any script claiming to restart the graphics driver by stopping a process is mislabelled.

    Because of that, this script leads with a read-only report: adapter names, driver versions
    and dates, and any recent TDR recovery events (System log, Event ID 4101, "display driver
    stopped responding and has recovered"). Those events are the actual evidence of a driver
    problem, and a repeated 4101 for the same driver points at a driver update or a hardware
    fault, not at anything a compositor restart will fix.

    BLAST RADIUS of -Action RestartDwm: the screen goes black for roughly a second and every
    window is redrawn. Applications keep running and nothing is closed, but full-screen games and
    some capture, remote-control or overlay software react badly to losing the compositor and can
    crash. On rare configurations the session does not recover cleanly and needs a sign-out. Only
    the CURRENT session's compositor is stopped; other signed-in users are not disturbed.

.PARAMETER Action
    Report      Read-only. Adapters, driver versions, and recent TDR recovery events. Default.
    RestartDwm  Stop this session's Desktop Window Manager so Windows restarts it.
    Environment: LZC_GRAPHICSDRIVER_ACTION.

.PARAMETER SinceDays
    How far back to look for display-driver recovery events, in days. Range 1-365, default 7.
    Environment: LZC_GRAPHICSDRIVER_SINCE_DAYS.

.PARAMETER Force
    Suppress confirmation prompts, for unattended use. -WhatIf still wins over -Force.
    Environment: LZC_GRAPHICSDRIVER_FORCE, which accepts 1, true, yes, on, 0, false, no or off
    in any case. Any other value is a usage error and exits 2.

.PARAMETER Version
    Print the script version and exit.

.EXAMPLE
    PS> .\RestartGraphicsDriver.ps1

    Reports every display adapter with its driver version and date, plus any display driver
    recovery events from the last 7 days. Changes nothing and needs no elevation.

.EXAMPLE
    PS> .\RestartGraphicsDriver.ps1 -SinceDays 30

    Same report, looking 30 days back for recovery events.

.EXAMPLE
    PS> .\RestartGraphicsDriver.ps1 -Action RestartDwm -WhatIf

    Shows which compositor process would be stopped, and changes nothing.

.INPUTS
    None. This script does not accept pipeline input.

.OUTPUTS
    System.Management.Automation.PSCustomObject describing the report or the action taken.

.NOTES
    Version : 2.0
    License : MIT
    Origin  : https://github.com/Lazarev-Cloud/Scripts
    Tested  : Windows PowerShell 5.1 on Windows 11.

    Exit codes (the repo-wide table; this script can return the subset below):
      0  success, or a -WhatIf dry run
      1  the work ran but something in it failed
      2  usage error: an unknown or invalid value for a parameter or environment variable
      3  unsupported platform or missing prerequisite: no Desktop Window Manager in this session
      4  must be run as administrator
      5  refused: confirmation was needed, the session cannot prompt, and -Force was not given

    If the report shows repeated Event ID 4101 for the same adapter, the useful next steps are a
    clean driver reinstall, checking temperatures and power delivery, and testing memory - not
    restarting the compositor.

.LINK
    https://learn.microsoft.com/en-us/windows-hardware/drivers/display/timeout-detection-and-recovery
#>

[CmdletBinding(DefaultParameterSetName = 'Run', SupportsShouldProcess, ConfirmImpact = 'High')]
[OutputType([pscustomobject])]
param(
    [Parameter(ParameterSetName = 'Run', Position = 0)]
    [ValidateSet('Report', 'RestartDwm')]
    [string] $Action,

    [Parameter(ParameterSetName = 'Run')]
    [ValidateRange(1, 365)]
    [int] $SinceDays,

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

# Import-Module has no -WhatIf or -Confirm parameter of its own, so both preferences are
# neutralised around the call instead. They are neutralised at GLOBAL scope because a module's own
# Set-Alias calls run in module scope, whose parent is the global scope; a local override would not
# reach them. ConfirmPreference matters as much as WhatIfPreference: under -Confirm the module's
# 'Set-Alias -Name gcim -Option ReadOnly, AllScope' asks to confirm, which is an artefact of
# importing a module and has nothing to do with the operation the user asked about. In a
# non-interactive session that prompt cannot be answered and the script dies before it starts.
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

function Get-DisplayAdapter {
    <#
    .SYNOPSIS
        Returns the installed display adapters with driver version and date.
    .DESCRIPTION
        Uses Get-CimInstance rather than Get-WmiObject, which does not exist in PowerShell 7.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param()

    $adapters = @()
    foreach ($controller in (Get-CimInstance -ClassName Win32_VideoController -ErrorAction Stop)) {
        $adapters += [pscustomobject]@{
            Name                = [string] $controller.Name
            DriverVersion       = [string] $controller.DriverVersion
            DriverDate          = $controller.DriverDate
            VideoProcessor      = [string] $controller.VideoProcessor
            CurrentResolution   = "$($controller.CurrentHorizontalResolution)x$($controller.CurrentVerticalResolution)"
            Status              = [string] $controller.Status
            PnpDeviceId         = [string] $controller.PNPDeviceID
        }
    }
    return [pscustomobject[]] $adapters
}

function Get-DisplayRecoveryEvent {
    <#
    .SYNOPSIS
        Returns recent display-driver Timeout Detection and Recovery events.
    .DESCRIPTION
        Event ID 4101 in the System log is "display driver stopped responding and has recovered".
        Get-WinEvent throws rather than returning nothing when no events match the filter, and an
        empty result is the good outcome here, so that specific case is caught and reported as an
        empty set.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory)]
        [ValidateRange(1, 365)]
        [int] $SinceDays
    )

    $events = @()
    try {
        $raw = Get-WinEvent -ErrorAction Stop -FilterHashtable @{
            LogName   = 'System'
            Id        = 4101
            StartTime = (Get-Date).AddDays(-$SinceDays)
        }
        foreach ($item in $raw) {
            $events += [pscustomobject]@{
                TimeCreated  = $item.TimeCreated
                ProviderName = [string] $item.ProviderName
                Message      = ([string] $item.Message).Trim()
            }
        }
    } catch [Exception] {
        # "No events were found that match the specified selection criteria" is not a failure.
        if ($_.Exception.Message -notmatch 'No events were found') {
            Write-Warning "Could not read display recovery events: $($_.Exception.Message)"
        }
    }
    return [pscustomobject[]] $events
}

function Get-SessionCompositor {
    <#
    .SYNOPSIS
        Returns the dwm.exe processes belonging to the current session only.
    .DESCRIPTION
        Scoping to the current session is the point. 'Stop-Process -Name dwm' matches every
        compositor on the machine, so on a multi-session box it blanks the desktop of every other
        signed-in user as well.
    #>
    [CmdletBinding()]
    [OutputType([System.Diagnostics.Process[]])]
    param()

    $sessionId = (Get-Process -Id $PID).SessionId
    $processes = @(Get-Process -Name 'dwm' -ErrorAction SilentlyContinue |
            Where-Object { $_.SessionId -eq $sessionId })
    if ($processes.Count -eq 0) {
        Write-Verbose "No dwm.exe found in session $sessionId."
    }
    return [System.Diagnostics.Process[]] $processes
}

function Invoke-CompositorRestart {
    <#
    .SYNOPSIS
        Stops this session's Desktop Window Manager behind a ShouldProcess gate.
    .DESCRIPTION
        Windows restarts dwm.exe automatically; this does not start it again itself. Note again
        that this restarts the compositor, not the display driver.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [System.Diagnostics.Process] $Process
    )

    $target = "dwm.exe (PID $($Process.Id), session $($Process.SessionId))"
    $operation = 'Stop the Desktop Window Manager so Windows restarts it (screen blanks briefly; this is NOT a graphics driver restart)'

    if (-not $PSCmdlet.ShouldProcess($target, $operation)) {
        return [pscustomobject]@{
            Operation = $operation; Target = $target; Status = 'Skipped'
        }
    }

    Stop-Process -Id $Process.Id -Force -Confirm:$false -ErrorAction Stop

    return [pscustomobject]@{
        Operation = $operation; Target = $target; Status = 'Succeeded'
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
    [OutputType([pscustomobject], [pscustomobject[]])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $ScriptBoundParameter
    )

    if ($Version) {
        Write-Information -MessageData "RestartGraphicsDriver.ps1 version $script:ScriptVersion"
        return
    }

    # Guard order, identical across every script in this repo: configuration (2), platform and
    # prerequisites (3), elevation (4), interactivity (5), then the work itself (0 or 1).
    # $script:ExitCode is set to 2 before each validation throw so the catch at the bottom
    # reports a usage error rather than the generic failure code.
    if (-not $ScriptBoundParameter.ContainsKey('Action')) {
        $Action = Get-EnvironmentValue -Name 'LZC_GRAPHICSDRIVER_ACTION' -Fallback 'Report'
        if (@('Report', 'RestartDwm') -notcontains $Action) {
            $script:ExitCode = 2
            throw "LZC_GRAPHICSDRIVER_ACTION must be Report or RestartDwm, got '$Action'."
        }
    }
    if (-not $ScriptBoundParameter.ContainsKey('SinceDays')) {
        $raw = Get-EnvironmentValue -Name 'LZC_GRAPHICSDRIVER_SINCE_DAYS' -Fallback '7'
        $parsed = 0
        # TryParse reads '08' as decimal 8, so a zero-padded value in a cron or scheduled-task
        # definition means what it looks like rather than becoming an invalid octal literal.
        if (-not [int]::TryParse($raw, [ref] $parsed)) {
            $script:ExitCode = 2
            throw "LZC_GRAPHICSDRIVER_SINCE_DAYS must be an integer, got '$raw'."
        }
        if ($parsed -lt 1 -or $parsed -gt 365) {
            $script:ExitCode = 2
            throw "LZC_GRAPHICSDRIVER_SINCE_DAYS must be between 1 and 365, got $parsed."
        }
        $SinceDays = $parsed
    }
    if (-not $ScriptBoundParameter.ContainsKey('Force')) {
        $fromEnv = Resolve-EnvironmentFlag -Name 'LZC_GRAPHICSDRIVER_FORCE'
        if ($null -ne $fromEnv) { $Force = [switch] $fromEnv }
    }

    # -Force must not short-circuit ShouldProcess itself, or -WhatIf would stop working. Lower
    # the confirmation threshold instead, and only when the caller did not ask for -Confirm.
    if ($Force -and -not $ScriptBoundParameter.ContainsKey('Confirm')) {
        $ConfirmPreference = 'None'
    }

    Write-Information -MessageData "Action: $Action"

    if ($Action -eq 'Report') {
        $adapters = @(Get-DisplayAdapter)
        $recovery = @(Get-DisplayRecoveryEvent -SinceDays $SinceDays)

        Write-Information -MessageData "Display adapters: $($adapters.Count)"
        if ($recovery.Count -eq 0) {
            Write-Information -MessageData "No display driver recovery (Event ID 4101) events in the last $SinceDays day(s)."
        } else {
            Write-Warning "$($recovery.Count) display driver recovery event(s) (Event ID 4101) in the last $SinceDays day(s). Repeated events point at a driver or hardware fault; restarting the compositor will not fix that."
        }

        return [pscustomobject]@{
            Operation      = 'Report graphics state'
            Target         = $env:COMPUTERNAME
            Adapters       = $adapters
            RecoveryEvents = $recovery
            LookbackDays   = $SinceDays
            Status         = 'Succeeded'
        }
    }

    Write-Warning 'Stopping dwm.exe restarts the desktop compositor, NOT the graphics driver. The screen will blank briefly and every window will be redrawn. Full-screen games and some capture or overlay software can crash. The real driver restart is Win+Ctrl+Shift+B, which has no scriptable equivalent.'

    # Prerequisite before elevation: enumerating processes needs no rights, and "there is no
    # compositor here at all" is the more fundamental answer than "you are not an administrator".
    $compositors = @(Get-SessionCompositor)
    if ($compositors.Count -eq 0) {
        Write-Error -ErrorAction Continue -Message "No dwm.exe process was found for this session. That is expected under SYSTEM, in Windows Server Core, or in a session with no desktop; there is nothing to restart here."
        $script:ExitCode = 3
        return
    }

    if (-not $WhatIfPreference -and -not (Test-Elevated)) {
        Write-Error -ErrorAction Continue -Message 'Stopping the Desktop Window Manager needs administrator rights, because dwm.exe runs as a virtual service account. Re-run from an elevated PowerShell session, or use -WhatIf to preview without elevation.'
        $script:ExitCode = 4
        return
    }

    # $ConfirmPreference is 'None' only when -Force lowered it above or the caller passed
    # -Confirm:$false. Anything else means ShouldProcess is about to prompt, and a host that
    # cannot answer would turn that into an exception reported as a generic failure.
    if (-not $WhatIfPreference -and $ConfirmPreference -ne 'None' -and (Test-NonInteractiveSession)) {
        Write-Error -ErrorAction Continue -Message 'Refusing to restart the Desktop Window Manager: this action needs confirmation, but the session cannot prompt (it is non-interactive). Pass -Force to confirm in advance, or set LZC_GRAPHICSDRIVER_FORCE=1.'
        $script:ExitCode = 5
        return
    }

    $results = @()
    foreach ($compositor in $compositors) {
        $results += Invoke-CompositorRestart -Process $compositor
    }
    return [pscustomobject[]] $results
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
