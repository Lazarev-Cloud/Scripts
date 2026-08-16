<#
.SYNOPSIS
    Lists, enables and disables Windows optional features, with confirmation.

.DESCRIPTION
    With no arguments the script is read-only: it lists the optional features on
    this machine and their current state. Changing a feature requires naming both
    -Action and -FeatureName, and every change is gated by $PSCmdlet.ShouldProcess,
    so it prompts unless -Force is given and does nothing under -WhatIf.

    Blast radius: only the features you name. Enabling or disabling an optional
    feature is a servicing transaction against the running Windows image, and most
    features need a restart to finish. This script always passes -NoRestart and
    never reboots.

    Two behaviours are explicit opt-ins, because both do considerably more than
    their names suggest:

      -RemovePayload   Disable with DISM's -Remove, which deletes the feature's
                       files from the image, not just its registration. The state
                       becomes DisabledWithPayloadRemoved and re-enabling it later
                       needs Windows Update or an installation source. Off by
                       default; a plain disable is fully reversible offline.

      -IncludeParent   Enable with DISM's -All, which also enables every parent
                       feature the named one depends on. Convenient, but it turns
                       on components you did not name. Off by default; when an
                       enable fails because a parent is disabled, the script says
                       so and suggests this switch.

    Safety properties:
      * Nothing changes without passing $PSCmdlet.ShouldProcess, so -WhatIf
        produces a complete dry run and changes nothing.
      * Features already in the requested state are reported and skipped, so no
        servicing transaction runs for a no-op.
      * The resulting state is read back from the system rather than assumed. A
        change that did not happen is reported as a failure, not as success.
      * A feature is reported as NotFound only when absence was established. A
        query that could not run at all proves nothing about whether the feature
        exists, and is reported as a failure with the real reason.
      * A run that will change something takes a machine-wide lock
        (Global\lzc-features) and exits 75 if another instance holds it, so two
        DISM feature transactions never overlap on one image.
      * A run that would prompt, on a host with no terminal to prompt on and
        without -Force, is refused with exit 5 before any transaction starts.

    Every environment variable a user may set is named LZC_WINDOWSFEATURES_*, so
    `Get-ChildItem env:LZC_*` shows everything configurable in this repository.
    A variable is consulted only when the matching parameter is not passed, and
    an unusable value is a usage error (exit 2) rather than a silent default.

.PARAMETER Action
    Enable or Disable. Required to change anything. Omit it, or pass -List, to
    stay in read-only listing mode. Case does not matter. Environment variable:
    LZC_WINDOWSFEATURES_ACTION.

.PARAMETER FeatureName
    One or more feature names, exactly as Get-WindowsOptionalFeature reports them
    (for example NetFx3, Microsoft-Windows-Subsystem-Linux, TelnetClient).
    Required with -Action. A comma-separated list is accepted as one value
    ('TelnetClient,TFTP'), which is the form that also works through
    powershell.exe -File. Environment variable: LZC_WINDOWSFEATURES_NAMES (comma
    separated).

.PARAMETER List
    List optional features and exit. This is already the default when -Action is
    omitted, so it is only needed to be explicit. Passing it together with
    -Action is a contradiction and is refused with exit 2.

.PARAMETER Filter
    Wildcard applied to the feature name when listing, for example '*Hyper*'.
    Ignored when changing a feature. Defaults to '*'. Environment variable:
    LZC_WINDOWSFEATURES_FILTER.

.PARAMETER RemovePayload
    When disabling, also remove the feature's files from the image. Re-enabling
    afterwards requires Windows Update or an installation source. Environment
    variable: LZC_WINDOWSFEATURES_REMOVE_PAYLOAD
    (1, true, yes, on / 0, false, no, off).

.PARAMETER IncludeParent
    When enabling, also enable any parent features the named feature depends on.
    Environment variable: LZC_WINDOWSFEATURES_INCLUDE_PARENT
    (1, true, yes, on / 0, false, no, off).

.PARAMETER Force
    Suppress confirmation prompts, for scheduled and unattended runs. -WhatIf
    still takes precedence over -Force. Environment variable:
    LZC_WINDOWSFEATURES_FORCE (1, true, yes, on / 0, false, no, off).

.PARAMETER ExtraArgument
    Collects anything that is not a parameter of this script. Passing something
    here is a typo, so the run stops with exit code 2 and names what it did not
    understand. Do not pass it deliberately.

.EXAMPLE
    PS> .\WindowsFeatures.ps1

    Lists every optional feature and its current state. Changes nothing.

.EXAMPLE
    PS> .\WindowsFeatures.ps1 -Filter '*Hyper-V*'

    Lists only the Hyper-V related features.

.EXAMPLE
    PS> .\WindowsFeatures.ps1 -Action Enable -FeatureName NetFx3 -WhatIf

    Shows that NetFx3 would be enabled, and does not enable it.

.EXAMPLE
    PS> .\WindowsFeatures.ps1 -Action Enable -FeatureName 'Microsoft-Hyper-V' -IncludeParent -Force

    Enables Hyper-V together with the parent features it depends on, without
    prompting. Reports RestartNeeded on the result object if a restart is needed.

.EXAMPLE
    PS> .\WindowsFeatures.ps1 -Action Disable -FeatureName TelnetClient -Force

    Disables the Telnet client but keeps its files on disk, so it can be
    re-enabled later without an installation source.

.INPUTS
    None. This script does not accept pipeline input.

.OUTPUTS
    System.Management.Automation.PSCustomObject. In listing mode: FeatureName and
    State. In change mode: FeatureName, Action, PreviousState, ResultState,
    RestartNeeded, Status and Detail.

.NOTES
    Exit codes (the repository-wide table; every script in this repository uses
    the same numbers):
      0     success: every requested feature reached the requested state or was
            already there. A pending restart is still exit 0 -- read the
            RestartNeeded property of the result objects
      1     the work ran but something in it failed: a feature would not change,
            was not found, its state could not be read, or the feature list could
            not be enumerated
      2     usage error: an unknown argument, -Action without -FeatureName,
            -Action together with -List, or a parameter or
            LZC_WINDOWSFEATURES_* value that is invalid
      3     unsupported platform or missing prerequisite (not Windows, PowerShell
            older than 5.1, or the DISM PowerShell module is unavailable)
      4     not running as Administrator
      5     refused: the run needs confirmation, there is no terminal to confirm
            on, and neither -Force nor -Confirm:$false was given
      75    another instance holds the lock Global\lzc-features (EX_TEMPFAIL, so
            cron and scheduled tasks treat it as "retry later")
      130   interrupted (Ctrl-C or cancellation)

    Checks run in that order with one deliberate exception: arguments and
    settings are validated BEFORE the elevation check, so a typo is discoverable
    from an ordinary shell without an elevated one.

    A pending restart is NOT signalled with a bespoke exit code such as 3010.
    Deployment tools that key on a reboot must read the result objects instead:
    any object whose RestartNeeded is true means a restart finishes the work.

    Elevation is checked at run time rather than with
    `#Requires -RunAsAdministrator`, which fails the script before it starts and
    exits 1. The runtime check is what makes the documented exit 4 reachable.
    It applies to listing too: DISM cannot read a feature's state unelevated.

    List the exact names this script accepts with:
      Get-WindowsOptionalFeature -Online | Select-Object FeatureName, State

    On PowerShell 7 the DISM cmdlets are natively compatible; no compatibility
    layer is required.

    Progress is written to the information stream and is visible by default. Add
    -InformationAction SilentlyContinue for a quiet run, or -Verbose for detail.
    Warnings and errors go to the warning and error streams, so the success
    stream carries only the result objects.

    This script emits no colour of its own; the host renders the information,
    warning and error streams. NO_COLOR (https://no-color.org, any non-empty
    value) is honoured: on PowerShell 7 it forces $PSStyle.OutputRendering to
    PlainText for the run, and Windows PowerShell 5.1 renders those streams
    without ANSI sequences already.

    Scheduled task invocation (use -File, never -Command; -Command collapses the
    exit code to 0 or 1):
      powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass
        -File "C:\path\WindowsFeatures.ps1" -Action Enable -FeatureName NetFx3 -Force

    License: MIT
    Origin:  https://github.com/Lazarev-Cloud/Scripts

.LINK
    https://github.com/Lazarev-Cloud/Scripts

.LINK
    https://learn.microsoft.com/en-us/powershell/module/dism/enable-windowsoptionalfeature
#>

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
[OutputType([pscustomobject])]
param(
    # Values are deliberately NOT resolved from the environment here, and carry
    # no ValidateSet/ValidateNotNullOrEmpty attributes. A validation attribute is
    # not applied to a parameter's DEFAULT value, so an invalid
    # LZC_WINDOWSFEATURES_ACTION resolved here would sail past the binder and
    # detonate later; and a failure inside the binder ends the process with exit
    # code 1 before a single line of this script runs, which would make the
    # documented exit-code table a lie. Every value is therefore resolved and
    # validated in Start-FeatureManagement, which can report a clear message and
    # exit 2. ArgumentCompleter keeps tab-completion for -Action without handing
    # the binder a value it can reject.
    [Parameter(Position = 0)]
    [ArgumentCompleter({ 'Enable', 'Disable' })]
    [AllowEmptyString()]
    [string] $Action = '',

    [Parameter(Position = 1)]
    [AllowEmptyCollection()]
    [string[]] $FeatureName = @(),

    [Parameter()]
    [switch] $List,

    [Parameter()]
    [AllowEmptyString()]
    [string] $Filter = '',

    [Parameter()]
    [switch] $RemovePayload,

    [Parameter()]
    [switch] $IncludeParent,

    [Parameter()]
    [switch] $Force,

    # Anything the binder could not match. Without this an unknown argument is a
    # binding error (exit 1); with it the run reports the typo and exits 2.
    [Parameter(ValueFromRemainingArguments)]
    [AllowEmptyCollection()]
    [string[]] $ExtraArgument = @()
)

Set-StrictMode -Version 3.0
# 'Stop' makes an unexpected cmdlet failure loud instead of leaving the script
# running on half-built state. It also escalates Write-Error into a
# statement-terminating error, which would abandon the line that sets the exit
# code; the deliberate Write-Error calls below therefore pass
# -ErrorAction Continue so the reported exit code is the one documented in help.
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# Captured here, at script scope, because $PSBoundParameters inside a function
# describes that function's arguments, not the script's.
$ScriptBoundParameter = $PSBoundParameters
$ExitCode = 0

# Set by Get-FeatureState when the state query itself fails, so the caller can
# tell "no such feature" from "the query could not run". Read it immediately
# after the call that produced it; the next call overwrites it.
$LastFeatureStateError = $null

# Machine-wide lock, taken only by a run that will change something and released
# in the finally block at the end of the file.
$ScriptLockName = 'lzc-features'
$ScriptLock = $null

if (-not $ScriptBoundParameter.ContainsKey('InformationAction')) {
    $InformationPreference = 'Continue'
}

# NO_COLOR (https://no-color.org): any non-empty value disables colour. This
# script writes none itself -- everything goes through the information, warning
# and error streams -- but PowerShell 7 colourises those streams through
# $PSStyle, so rendering is forced to plain text for the run. Windows PowerShell
# 5.1 has no $PSStyle and needs nothing; Get-Variable rather than a bare $PSStyle
# because Set-StrictMode makes reading an undefined variable an error.
if (-not [string]::IsNullOrEmpty($env:NO_COLOR)) {
    $StyleVariable = Get-Variable -Name 'PSStyle' -ErrorAction SilentlyContinue
    if ($null -ne $StyleVariable -and $null -ne $StyleVariable.Value) {
        $StyleVariable.Value.OutputRendering = 'PlainText'
    }
}

function ConvertTo-BooleanSetting {
    <#
    .SYNOPSIS
        Converts a user-supplied boolean setting to $true or $false.
    .DESCRIPTION
        Accepts 1/true/yes/on and 0/false/no/off, case-insensitively, and throws
        on anything else. Rejecting loudly is the point: a value that is neither
        affirmative nor negative silently meaning "off" is how a scheduled task
        ends up not doing what its author wrote.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Source,

        [Parameter(Mandatory)]
        [AllowNull()]
        [AllowEmptyString()]
        [string] $Value
    )

    $text = ''
    if ($null -ne $Value) { $text = $Value.Trim().ToLowerInvariant() }

    if ($text -in @('1', 'true', 'yes', 'on')) { return $true }
    if ($text -in @('0', 'false', 'no', 'off')) { return $false }

    throw [ArgumentException]::new(
        "$Source must be one of 1, true, yes, on, 0, false, no or off (case does not matter). Got: '$Value'.")
}

function Resolve-BooleanSetting {
    <#
    .SYNOPSIS
        Resolves a switch, falling back to an environment variable only when the
        switch was not passed explicitly.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Name,

        [Parameter(Mandatory)]
        [switch] $Switch,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $EnvironmentName
    )

    if ($ScriptBoundParameter.ContainsKey($Name)) { return [bool]$Switch }

    $value = [Environment]::GetEnvironmentVariable($EnvironmentName)
    if ([string]::IsNullOrWhiteSpace($value)) { return $false }
    return (ConvertTo-BooleanSetting -Source $EnvironmentName -Value $value)
}

function Resolve-ChoiceSetting {
    <#
    .SYNOPSIS
        Resolves a parameter that accepts a fixed set of words, then the
        environment variable, then the documented default.
    .DESCRIPTION
        Matching is case-insensitive and the canonical spelling is returned, so
        'enable' and 'ENABLE' both come back as 'Enable'.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Name,

        [Parameter(Mandatory)]
        [AllowNull()]
        [AllowEmptyString()]
        [string] $Value,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $EnvironmentName,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string[]] $Allowed,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Default
    )

    $source = $EnvironmentName
    $text = [Environment]::GetEnvironmentVariable($EnvironmentName)
    if ($ScriptBoundParameter.ContainsKey($Name)) {
        $source = "-$Name"
        $text = $Value
    }

    if ([string]::IsNullOrWhiteSpace($text)) { return $Default }

    $trimmed = $text.Trim()
    foreach ($choice in $Allowed) {
        if ($trimmed -eq $choice) { return $choice }
    }

    throw [ArgumentException]::new(
        "$source must be one of: $($Allowed -join ', '). Got: '$text'.")
}

function Resolve-ListSetting {
    <#
    .SYNOPSIS
        Resolves a list-valued setting from a parameter, then a separated
        environment variable, then an empty list.
    .DESCRIPTION
        Every element is also split on commas, so -FeatureName means the same
        thing however the script was started. powershell.exe -File passes each
        argument as one literal string: '-FeatureName A,B' arrives as the single
        string 'A,B', and '-FeatureName A B' binds only A and lets B fall through
        to another parameter. Splitting here makes the comma form correct in both
        an interactive session and a scheduled task. A feature name never
        contains a comma, so nothing legitimate is split.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Name,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [AllowNull()]
        [string[]] $Value,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $EnvironmentName
    )

    $raw = @()
    if ($ScriptBoundParameter.ContainsKey($Name)) {
        $raw = @($Value)
    }
    else {
        $fromEnvironment = [Environment]::GetEnvironmentVariable($EnvironmentName)
        if (-not [string]::IsNullOrWhiteSpace($fromEnvironment)) {
            $raw = @($fromEnvironment -split ',')
        }
    }

    # Cast, not just @(): the declared OutputType has to be the type actually
    # returned, and an unconstrained array pipeline yields Object[].
    return [string[]]@($raw |
            Where-Object { $_ } |
            ForEach-Object { $_ -split ',' } |
            Where-Object { $_ -and $_.Trim() } |
            ForEach-Object { $_.Trim() })
}

function Test-WindowsHost {
    <#
    .SYNOPSIS
        Returns true when this is Windows.
    .DESCRIPTION
        PowerShell 7 defines $IsWindows on every platform; Windows PowerShell 5.1
        does not define it and only exists on Windows.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    $variable = Get-Variable -Name 'IsWindows' -ErrorAction SilentlyContinue
    if ($null -eq $variable) { return $true }
    return [bool]$variable.Value
}

function Test-Elevated {
    <#
    .SYNOPSIS
        Returns true when the current process is elevated.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-InteractiveHost {
    <#
    .SYNOPSIS
        Returns true when there is somebody to answer a confirmation prompt.
    .DESCRIPTION
        Without this, a run that needs confirmation under -NonInteractive dies
        inside ShouldProcess with "Read and Prompt functionality is not
        available" and exit code 1. Detecting it first turns that into the
        documented refusal, exit 5.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    if (-not [Environment]::UserInteractive) { return $false }

    foreach ($argument in [Environment]::GetCommandLineArgs()) {
        # PowerShell accepts any unambiguous prefix, so -noni, -nonin and
        # -noninteractive all mean the same switch.
        if ($argument -match '^-{1,2}noni') { return $false }
    }

    try {
        if ([Console]::IsInputRedirected) { return $false }
    }
    catch {
        # No console is attached to read the property from. Some hosts can still
        # prompt, so this is not treated as proof of a non-interactive run.
        Write-Verbose -Message "Could not determine whether input is redirected: $($_.Exception.Message)"
    }

    return $true
}

function Enter-ScriptLock {
    <#
    .SYNOPSIS
        Takes the machine-wide lock, or returns nothing if another run holds it.
    .DESCRIPTION
        A named mutex is the Windows equivalent of the flock(2) the Linux scripts
        in this repository take: the kernel owns it, so it is released even if
        this process is killed.
    #>
    [CmdletBinding()]
    [OutputType([Threading.Mutex])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Name
    )

    $mutex = $null
    try {
        $mutex = [Threading.Mutex]::new($false, "Global\$Name")
    }
    catch {
        # Typically another user's elevated run already owns the object and its
        # DACL keeps this process out. That is "somebody else is running it",
        # which is exactly what the lock is for.
        Write-Warning -Message "Could not open the lock object Global\$Name : $($_.Exception.Message)"
        return
    }

    try {
        if ($mutex.WaitOne(0)) { return $mutex }
    }
    catch [System.Threading.AbandonedMutexException] {
        # A previous run was killed while holding the lock. The wait succeeded
        # and this process now owns the mutex, so carry on rather than refuse.
        Write-Verbose -Message "Took over the abandoned lock Global\$Name."
        return $mutex
    }

    $mutex.Dispose()
    return
}

function Exit-ScriptLock {
    <#
    .SYNOPSIS
        Releases the machine-wide lock if this run holds it.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter()]
        [AllowNull()]
        [Threading.Mutex] $Mutex
    )

    if ($null -eq $Mutex) { return }

    try {
        $Mutex.ReleaseMutex()
    }
    catch {
        # Releasing a mutex this thread does not own throws. Nothing can be done
        # about it here and the handle is disposed either way.
        Write-Verbose -Message "Could not release the lock: $($_.Exception.Message)"
    }
    $Mutex.Dispose()
}

function Test-DismCmdletAvailable {
    <#
    .SYNOPSIS
        Returns true when the DISM feature cmdlets are present.
    .DESCRIPTION
        The DISM module is imported explicitly rather than left to autoloading.
        Import-Module has no -WhatIf or -Confirm parameter of its own, and a
        module's own Set-Alias calls run in module scope, whose parent is the
        global scope -- so both preferences are neutralised at GLOBAL scope
        around the call; a local override would not reach them. Without this,
        every -WhatIf run prints a "What if: Performing the operation Set Alias"
        line for each alias the module defines, burying the preview the user
        actually asked for, and under -Confirm those prompts cannot be answered
        in a non-interactive session at all.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    if (-not (Get-Module -Name Dism)) {
        $previousWhatIfPreference = $global:WhatIfPreference
        $previousConfirmPreference = $global:ConfirmPreference
        $global:WhatIfPreference = $false
        $global:ConfirmPreference = 'None'
        try {
            Import-Module -Name Dism -Verbose:$false -ErrorAction SilentlyContinue
        }
        finally {
            $global:WhatIfPreference = $previousWhatIfPreference
            $global:ConfirmPreference = $previousConfirmPreference
        }
    }

    foreach ($name in @('Get-WindowsOptionalFeature', 'Enable-WindowsOptionalFeature', 'Disable-WindowsOptionalFeature')) {
        if (-not (Get-Command -Name $name -ErrorAction SilentlyContinue)) {
            Write-Error -Message "$name is not available. This script needs the DISM PowerShell module, which ships with Windows 8 and later." -ErrorAction Continue
            return $false
        }
    }
    return $true
}

function Get-FeatureState {
    <#
    .SYNOPSIS
        Returns the current state of one optional feature, or nothing if unknown.
    .DESCRIPTION
        On failure the underlying reason is left in $script:LastFeatureStateError.
        "No such feature" and "the query could not run at all" both come back as
        nothing, and only that variable tells them apart: an elevation or servicing
        error must never be reported to the user as a missing feature. Capture the
        variable before calling this function again.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Name
    )

    $script:LastFeatureStateError = $null
    try {
        $feature = Get-WindowsOptionalFeature -Online -FeatureName $Name -ErrorAction Stop
    }
    catch {
        # The underlying message is included because "not found" and "the query
        # itself failed" are different problems and must not be reported alike.
        $script:LastFeatureStateError = $_.Exception.Message
        Write-Warning -Message "Could not read the state of feature '$Name': $($_.Exception.Message)"
        Write-Warning -Message 'If the name is wrong, list the valid ones with: Get-WindowsOptionalFeature -Online'
        return
    }

    if ($null -eq $feature) { return }
    return [string]$feature.State
}

function Get-FeatureInventory {
    <#
    .SYNOPSIS
        Lists optional features matching a wildcard, sorted by name.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter()]
        [AllowEmptyString()]
        [string] $Pattern = '*'
    )

    $effective = if ([string]::IsNullOrWhiteSpace($Pattern)) { '*' } else { $Pattern }

    # Deliberately not wrapped in try/catch: an enumeration failure is not the
    # same as "no feature matched", and the caller has to be able to tell them
    # apart so it can report a failure instead of a successful empty list.
    $feature = @(Get-WindowsOptionalFeature -Online -ErrorAction Stop)

    $feature |
        Where-Object { $_.FeatureName -like $effective } |
        Sort-Object -Property FeatureName |
        ForEach-Object {
            [pscustomobject]@{
                FeatureName = $_.FeatureName
                State       = [string]$_.State
            }
        }
}

function Set-FeatureState {
    <#
    .SYNOPSIS
        Drives one optional feature to Enabled or Disabled, gated by ShouldProcess.
    .DESCRIPTION
        The DISM cmdlets do not implement -WhatIf, so the gate lives here. Nothing
        below the ShouldProcess call runs during a dry run.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Name,

        [Parameter(Mandatory)]
        [ValidateSet('Enable', 'Disable')]
        [string] $Operation,

        [Parameter(Mandatory)]
        [bool] $WithParent,

        [Parameter(Mandatory)]
        [bool] $WithPayloadRemoval
    )

    $previous = Get-FeatureState -Name $Name
    if ([string]::IsNullOrWhiteSpace($previous)) {
        # Captured before anything else can call Get-FeatureState and overwrite it.
        $reason = $script:LastFeatureStateError

        # Absence is only claimed when it was actually established: either the
        # query succeeded and returned nothing, or DISM said the name is unknown.
        # Any other failure -- not elevated, servicing busy, WMI broken -- proves
        # nothing about whether the feature exists, and saying it does not exist
        # would be an assertion this script never verified.
        $absent = [string]::IsNullOrWhiteSpace($reason) -or
        $reason -match 'is unknown' -or $reason -match '0x800f080c'

        if ($absent) {
            return [pscustomobject]@{
                FeatureName   = $Name
                Action        = $Operation
                PreviousState = $null
                ResultState   = $null
                RestartNeeded = $false
                Status        = 'NotFound'
                Detail        = if ([string]::IsNullOrWhiteSpace($reason)) {
                    'No optional feature with that name exists on this system.'
                }
                else { $reason }
            }
        }

        return [pscustomobject]@{
            FeatureName   = $Name
            Action        = $Operation
            PreviousState = $null
            ResultState   = $null
            RestartNeeded = $false
            Status        = 'Failed'
            Detail        = "The feature state could not be read, so it is not known whether this feature exists: $reason"
        }
    }

    $target = if ($Operation -eq 'Enable') { 'Enabled' } else { 'Disabled' }

    # Already in the requested state: report it and run no servicing transaction.
    if ($previous -eq $target) {
        Write-Information -MessageData "$Name is already $target; nothing to do."
        return [pscustomobject]@{
            FeatureName   = $Name
            Action        = $Operation
            PreviousState = $previous
            ResultState   = $previous
            RestartNeeded = $false
            Status        = 'AlreadyInState'
            Detail        = $null
        }
    }

    # A payload-removed feature is already disabled. Only a -RemovePayload disable
    # of a still-payloaded feature has anything left to do here.
    if ($Operation -eq 'Disable' -and $previous -eq 'DisabledWithPayloadRemoved') {
        Write-Information -MessageData "$Name is already disabled and its payload is already removed; nothing to do."
        return [pscustomobject]@{
            FeatureName   = $Name
            Action        = $Operation
            PreviousState = $previous
            ResultState   = $previous
            RestartNeeded = $false
            Status        = 'AlreadyInState'
            Detail        = $null
        }
    }

    $description = if ($Operation -eq 'Enable') {
        if ($WithParent) { 'Enable feature and every parent feature it depends on' } else { 'Enable feature' }
    }
    else {
        if ($WithPayloadRemoval) { 'Disable feature AND REMOVE ITS FILES from the image (re-enabling will need a source)' } else { 'Disable feature, keeping its files on disk' }
    }

    if (-not $PSCmdlet.ShouldProcess("$Name (currently $previous)", $description)) {
        return [pscustomobject]@{
            FeatureName   = $Name
            Action        = $Operation
            PreviousState = $previous
            ResultState   = $previous
            RestartNeeded = $false
            Status        = 'Skipped'
            Detail        = 'Not performed (-WhatIf, or declined at the prompt).'
        }
    }

    try {
        if ($Operation -eq 'Enable') {
            $outcome = Enable-WindowsOptionalFeature -Online -FeatureName $Name `
                -All:$WithParent -NoRestart -ErrorAction Stop
        }
        else {
            $outcome = Disable-WindowsOptionalFeature -Online -FeatureName $Name `
                -Remove:$WithPayloadRemoval -NoRestart -ErrorAction Stop
        }
    }
    catch {
        $message = $_.Exception.Message
        Write-Warning -Message "Could not $($Operation.ToLowerInvariant()) '$Name': $message"
        if ($Operation -eq 'Enable' -and -not $WithParent) {
            Write-Warning -Message 'If a parent feature is disabled, re-run with -IncludeParent to enable it too.'
        }
        return [pscustomobject]@{
            FeatureName   = $Name
            Action        = $Operation
            PreviousState = $previous
            ResultState   = (Get-FeatureState -Name $Name)
            RestartNeeded = $false
            Status        = 'Failed'
            Detail        = $message
        }
    }

    $restartNeeded = $false
    if ($null -ne $outcome -and $null -ne $outcome.RestartNeeded) {
        $restartNeeded = [bool]$outcome.RestartNeeded
    }

    $resulting = Get-FeatureState -Name $Name
    $status = 'Success'
    if ($restartNeeded) {
        Write-Information -MessageData "$Name : $Operation staged; a restart is required to finish."
    }
    elseif ($resulting -ne $target -and
        -not ($Operation -eq 'Disable' -and $resulting -eq 'DisabledWithPayloadRemoved')) {
        # No restart was requested and the state did not change: report it rather
        # than claim a success that did not happen. DisabledWithPayloadRemoved
        # only counts as reaching the target for a Disable; for an Enable it means
        # the feature is still off and its files are gone, which is a failure.
        $status = 'Failed'
        Write-Warning -Message "$Name : state is still '$resulting' after $Operation, and no restart was requested."
    }
    else {
        Write-Information -MessageData "$Name : now $resulting."
    }

    return [pscustomobject]@{
        FeatureName   = $Name
        Action        = $Operation
        PreviousState = $previous
        ResultState   = $resulting
        RestartNeeded = $restartNeeded
        Status        = $status
        Detail        = $null
    }
}

function Start-FeatureManagement {
    <#
    .SYNOPSIS
        Entry point. Lists features, or applies the requested change to each one.
    .DESCRIPTION
        Result objects go to the success stream. The process exit code is left in
        the script-scope $ExitCode variable, which the last line of the file reads.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType([pscustomobject])]
    param()

    # --- Usage (exit 2) ------------------------------------------------------
    # Arguments and settings are checked before elevation deliberately: a typo
    # must be discoverable from an ordinary shell, not only an elevated one.
    if ($ExtraArgument.Count -gt 0) {
        Write-Error -Message ("Unknown argument(s): {0}. Run 'Get-Help .\WindowsFeatures.ps1 -Full' for the parameters this script accepts." -f `
            ($ExtraArgument -join ' ')) -ErrorAction Continue
        $script:ExitCode = 2
        return
    }

    if ($List.IsPresent -and $ScriptBoundParameter.ContainsKey('Action')) {
        Write-Error -Message '-List and -Action contradict each other. -List only reports; drop one of them.' -ErrorAction Continue
        $script:ExitCode = 2
        return
    }

    $forced = $false
    $withParent = $false
    $withPayloadRemoval = $false
    $actionName = ''
    $requested = @()
    try {
        $forced = Resolve-BooleanSetting -Name 'Force' -Switch:$Force `
            -EnvironmentName 'LZC_WINDOWSFEATURES_FORCE'
        $withParent = Resolve-BooleanSetting -Name 'IncludeParent' `
            -Switch:$IncludeParent -EnvironmentName 'LZC_WINDOWSFEATURES_INCLUDE_PARENT'
        $withPayloadRemoval = Resolve-BooleanSetting -Name 'RemovePayload' `
            -Switch:$RemovePayload -EnvironmentName 'LZC_WINDOWSFEATURES_REMOVE_PAYLOAD'
        $actionName = Resolve-ChoiceSetting -Name 'Action' -Value $Action `
            -EnvironmentName 'LZC_WINDOWSFEATURES_ACTION' `
            -Allowed @('Enable', 'Disable') -Default ''
        # @() around the call, not just inside it: PowerShell unrolls a returned
        # array, so an empty result arrives as $null and Set-StrictMode then turns
        # the .Count test below into a runtime error instead of a usage message.
        $requested = @(Resolve-ListSetting -Name 'FeatureName' -Value $FeatureName `
                -EnvironmentName 'LZC_WINDOWSFEATURES_NAMES')
    }
    catch [ArgumentException] {
        Write-Error -Message $_.Exception.Message -ErrorAction Continue
        $script:ExitCode = 2
        return
    }

    $pattern = '*'
    if ($ScriptBoundParameter.ContainsKey('Filter')) { $pattern = $Filter }
    elseif (-not [string]::IsNullOrWhiteSpace($env:LZC_WINDOWSFEATURES_FILTER)) {
        $pattern = $env:LZC_WINDOWSFEATURES_FILTER
    }
    if ([string]::IsNullOrWhiteSpace($pattern)) { $pattern = '*' }

    # Listing is the default: a run that names no action only reports.
    $wantList = $List.IsPresent -or [string]::IsNullOrWhiteSpace($actionName)

    if (-not $wantList -and $requested.Count -eq 0) {
        Write-Error -Message "-Action $actionName needs -FeatureName (or LZC_WINDOWSFEATURES_NAMES). List the valid names with: Get-WindowsOptionalFeature -Online" -ErrorAction Continue
        $script:ExitCode = 2
        return
    }

    # --- Platform and prerequisites (exit 3) ---------------------------------
    if (-not (Test-WindowsHost)) {
        Write-Error -Message 'This script manages Windows optional features and only runs on Windows.' -ErrorAction Continue
        $script:ExitCode = 3
        return
    }
    if ($PSVersionTable.PSVersion -lt [version]'5.1') {
        Write-Error -Message "PowerShell 5.1 or newer is required; this host is $($PSVersionTable.PSVersion)." -ErrorAction Continue
        $script:ExitCode = 3
        return
    }
    if (-not (Test-DismCmdletAvailable)) {
        $script:ExitCode = 3
        return
    }

    # --- Elevation (exit 4) --------------------------------------------------
    # Required even for -List and -WhatIf: DISM cannot read a feature's state
    # unelevated, so without this the run degrades into a per-feature "Failed"
    # whose real cause is an elevation error rather than a missing feature.
    if (-not (Test-Elevated)) {
        Write-Error -Message 'This script must be run as Administrator. Start an elevated PowerShell and run it again.' -ErrorAction Continue
        $script:ExitCode = 4
        return
    }

    # -Force means "do not prompt". Lowering $ConfirmPreference rather than
    # short-circuiting ShouldProcess is what keeps -WhatIf authoritative, so
    # -Force -WhatIf still changes nothing.
    if ($forced -and -not $ScriptBoundParameter.ContainsKey('Confirm')) {
        $ConfirmPreference = 'None'
    }

    if ($wantList) {
        Write-Information -MessageData 'Read-only listing. Pass -Action Enable|Disable with -FeatureName to change a feature.'
        $inventory = @()
        try {
            $inventory = @(Get-FeatureInventory -Pattern $pattern)
        }
        catch {
            Write-Error -Message "Could not enumerate optional features: $($_.Exception.Message)" -ErrorAction Continue
            $script:ExitCode = 1
            return
        }
        if ($inventory.Count -eq 0) {
            Write-Warning -Message "No optional feature matched '$pattern'."
        }
        else {
            Write-Information -MessageData ('{0:N0} feature(s) matched.' -f $inventory.Count)
        }
        foreach ($item in $inventory) { $item }
        return
    }

    if ($actionName -eq 'Disable' -and $withPayloadRemoval) {
        Write-Warning -Message '-RemovePayload deletes the feature files from the image. Re-enabling will need Windows Update or an installation source.'
    }
    if ($actionName -eq 'Enable' -and $withParent) {
        Write-Warning -Message '-IncludeParent also enables every parent feature the named feature depends on, including ones you did not name.'
    }

    # --- Confirmation (exit 5) -----------------------------------------------
    # -WhatIf changes nothing and never prompts, so it is always allowed.
    # Without this check a scheduled run dies inside ShouldProcess with "Read and
    # Prompt functionality is not available" and a bare exit 1.
    $willChange = -not $WhatIfPreference

    if ($willChange -and $ConfirmPreference -ne 'None' -and -not (Test-InteractiveHost)) {
        Write-Error -Message 'Refused: changing a feature needs confirmation, there is no terminal to confirm on, and -Force was not given. Re-run with -Force (or set LZC_WINDOWSFEATURES_FORCE=1), or preview with -WhatIf.' -ErrorAction Continue
        $script:ExitCode = 5
        return
    }

    # --- Lock (exit 75) ------------------------------------------------------
    # Only a run that will change a feature takes the lock, so a -WhatIf preview
    # is never blocked by a real run in progress. The read-only listing path has
    # already returned above, so reaching here means this run intends to change
    # something. Two concurrent DISM feature transactions on one image is what
    # this prevents.
    if ($willChange) {
        $script:ScriptLock = Enter-ScriptLock -Name $ScriptLockName
        if ($null -eq $script:ScriptLock) {
            Write-Error -Message "Another instance is already running (lock: Global\$ScriptLockName). Try again later." -ErrorAction Continue
            $script:ExitCode = 75
            return
        }
    }

    $result = [System.Collections.Generic.List[object]]::new()
    foreach ($name in $requested) {
        $result.Add((Set-FeatureState -Name $name -Operation $actionName `
                    -WithParent $withParent -WithPayloadRemoval $withPayloadRemoval))
    }

    $failed = @($result | Where-Object { $_.Status -in @('Failed', 'NotFound') })
    $reboot = @($result | Where-Object { $_.RestartNeeded })

    Write-Information -MessageData 'Summary:'
    foreach ($entry in $result) {
        Write-Information -MessageData ('{0}: {1} -> {2} ({3})' -f `
                $entry.FeatureName, $entry.PreviousState, $entry.ResultState, $entry.Status)
    }

    if ($failed.Count -gt 0) {
        $script:ExitCode = 1
    }
    elseif ($reboot.Count -gt 0) {
        # The work succeeded, so this is exit 0. The pending restart is carried
        # on the result objects (RestartNeeded = $true) instead of in a bespoke
        # exit code such as 3010, because this repository allows one exit-code
        # table and no script-specific additions to it.
        Write-Information -MessageData 'A restart is required to finish. The run itself succeeded: exit code 0, RestartNeeded true.'
    }

    foreach ($item in $result) { $item }
}

try {
    Start-FeatureManagement
}
catch [System.Management.Automation.PipelineStoppedException] {
    # Ctrl-C, or a caller stopping the pipeline. A DISM transaction already
    # committed stays committed; the lock is released by the finally below.
    Write-Warning -Message 'Interrupted. Features already changed stay changed.'
    $ExitCode = 130
}
catch [System.OperationCanceledException] {
    Write-Warning -Message 'Cancelled. Features already changed stay changed.'
    $ExitCode = 130
}
finally {
    Exit-ScriptLock -Mutex $ScriptLock
}

exit $ExitCode
