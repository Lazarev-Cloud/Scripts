<#
.SYNOPSIS
    Lists, enables and disables Windows optional features, with confirmation.

.DESCRIPTION
    With no arguments the script is read-only: it lists the optional features on
    this machine and their current state. Changing a feature requires naming both
    -Action and -FeatureName, and every change is gated by $PSCmdlet.ShouldProcess,
    so it prompts unless -Force is given and does nothing under -WhatIf.

    Blast radius: only the named features. Enabling or disabling an optional
    feature is a servicing transaction against the running Windows image, and most
    features need a restart to finish. This script always passes -NoRestart and
    never reboots; it reports exit code 3010 when a restart is pending.

    Two behaviours that were previously silent and are now explicit opt-ins,
    because both do considerably more than their names suggest:

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

    Features already in the requested state are reported and skipped, so no
    servicing transaction runs for a no-op.

.PARAMETER Action
    Enable or Disable. Required to change anything. Omit it, or pass -List, to
    stay in read-only listing mode. Environment variable: WINFEATURE_ACTION.

.PARAMETER FeatureName
    One or more feature names, exactly as Get-WindowsOptionalFeature reports them
    (for example NetFx3, Microsoft-Windows-Subsystem-Linux, TelnetClient). Required
    with -Action. Environment variable: WINFEATURE_NAMES (comma separated).

.PARAMETER List
    List optional features and exit. This is the default when -Action is omitted.

.PARAMETER Filter
    Wildcard applied to the feature name when listing, for example '*Hyper*'.
    Ignored when changing a feature. Environment variable: WINFEATURE_FILTER.

.PARAMETER RemovePayload
    When disabling, also remove the feature's files from the image. Re-enabling
    afterwards requires Windows Update or an installation source. Environment
    variable: WINFEATURE_REMOVE_PAYLOAD (1, true, yes or on to enable).

.PARAMETER IncludeParent
    When enabling, also enable any parent features the named feature depends on.
    Environment variable: WINFEATURE_INCLUDE_PARENT (1, true, yes or on to enable).

.PARAMETER Force
    Suppress confirmation prompts, for scheduled and unattended runs. -WhatIf
    still takes precedence over -Force. Environment variable: WINFEATURE_FORCE
    (1, true, yes or on to enable).

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
    prompting. Reports exit code 3010 if a restart is needed.

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
    Exit codes:
      0     every requested feature reached the requested state, or was already there
      1     at least one feature failed to change, was not found, or its state
            could not be read
      2     usage or precondition failure (-Action given without -FeatureName, the
            DISM cmdlets are unavailable, or the feature list could not be
            enumerated)
      3010  success, and a restart is required to finish

    List the exact names this script accepts with:
      Get-WindowsOptionalFeature -Online | Select-Object FeatureName, State

    On PowerShell 7 the DISM cmdlets are natively compatible; no compatibility
    layer is required.

    Scheduled task invocation (use -File, never -Command):
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
    [Parameter(Position = 0)]
    [ValidateSet('Enable', 'Disable')]
    [string] $Action = $(
        if ($env:WINFEATURE_ACTION) { $env:WINFEATURE_ACTION } else { '' }
    ),

    [Parameter(Position = 1)]
    [ValidateNotNullOrEmpty()]
    [string[]] $FeatureName = $(
        if ($env:WINFEATURE_NAMES) {
            $env:WINFEATURE_NAMES -split ',' | Where-Object { $_ -and $_.Trim() }
        }
        else { @() }
    ),

    [Parameter()]
    [switch] $List,

    [Parameter()]
    [AllowEmptyString()]
    [string] $Filter = $(
        if ($env:WINFEATURE_FILTER) { $env:WINFEATURE_FILTER } else { '*' }
    ),

    [Parameter()]
    [switch] $RemovePayload,

    [Parameter()]
    [switch] $IncludeParent,

    [Parameter()]
    [switch] $Force
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

function ConvertTo-IntegerSetting {
    <#
    .SYNOPSIS
        Converts a user-supplied numeric setting to a bounded integer.
    .DESCRIPTION
        Digits only, so '0x10', '+5', '5.0', '1e3' and '-1' are rejected with a
        message naming the setting instead of a .NET parse exception. A
        zero-padded value such as 08 is read as decimal 8, never as octal.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Source,

        [Parameter(Mandatory)]
        [AllowNull()]
        [AllowEmptyString()]
        [string] $Value,

        [Parameter(Mandatory)]
        [int] $Minimum,

        [Parameter(Mandatory)]
        [int] $Maximum
    )

    $text = ''
    if ($null -ne $Value) { $text = $Value.Trim() }

    $number = 0
    if ($text -notmatch '^[0-9]+$' -or -not [int]::TryParse($text, [ref] $number)) {
        throw [ArgumentException]::new(
            "$Source must be a whole number between $Minimum and $Maximum. Got: '$Value'.")
    }
    if ($number -lt $Minimum -or $number -gt $Maximum) {
        throw [ArgumentException]::new(
            "$Source must be between $Minimum and $Maximum. Got: '$Value'.")
    }
    return $number
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

function Resolve-IntegerSetting {
    <#
    .SYNOPSIS
        Resolves a numeric parameter, then the environment variable, then the
        documented default, and validates whichever one supplied the value.
    #>
    [CmdletBinding()]
    [OutputType([int])]
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
        [int] $Default,

        [Parameter(Mandatory)]
        [int] $Minimum,

        [Parameter(Mandatory)]
        [int] $Maximum
    )

    if ($ScriptBoundParameter.ContainsKey($Name)) {
        return (ConvertTo-IntegerSetting -Source "-$Name" -Value $Value -Minimum $Minimum -Maximum $Maximum)
    }

    $fromEnvironment = [Environment]::GetEnvironmentVariable($EnvironmentName)
    if ([string]::IsNullOrWhiteSpace($fromEnvironment)) { return $Default }
    return (ConvertTo-IntegerSetting -Source $EnvironmentName -Value $fromEnvironment -Minimum $Minimum -Maximum $Maximum)
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
    # apart so it can report exit code 2 instead of a successful empty list.
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
        $script:ExitCode = 2
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
    # short-circuiting ShouldProcess is what keeps -WhatIf authoritative.
    if ((Resolve-BooleanSetting -Name 'Force' -Switch:$Force -EnvironmentName 'WINFEATURE_FORCE') -and
        -not $ScriptBoundParameter.ContainsKey('Confirm')) {
        $ConfirmPreference = 'None'
    }

    $wantList = $List.IsPresent -or [string]::IsNullOrWhiteSpace($Action)
    if ($wantList) {
        Write-Information -MessageData 'Read-only listing. Pass -Action Enable|Disable with -FeatureName to change a feature.'
        $inventory = @()
        try {
            $inventory = @(Get-FeatureInventory -Pattern $Filter)
        }
        catch {
            Write-Error -Message "Could not enumerate optional features: $($_.Exception.Message)" -ErrorAction Continue
            $script:ExitCode = 2
            return
        }
        if ($inventory.Count -eq 0) {
            Write-Warning -Message "No optional feature matched '$Filter'."
        }
        else {
            Write-Information -MessageData ('{0:N0} feature(s) matched.' -f $inventory.Count)
        }
        foreach ($item in $inventory) { $item }
        return
    }

    $requested = @($FeatureName | Where-Object { $_ -and $_.Trim() } | ForEach-Object { $_.Trim() })
    if ($requested.Count -eq 0) {
        Write-Error -Message "-Action $Action needs -FeatureName. List the valid names with: Get-WindowsOptionalFeature -Online" -ErrorAction Continue
        $script:ExitCode = 2
        return
    }

    $withParent = Resolve-BooleanSetting -Name 'IncludeParent' `
        -Switch:$IncludeParent -EnvironmentName 'WINFEATURE_INCLUDE_PARENT'
    $withPayloadRemoval = Resolve-BooleanSetting -Name 'RemovePayload' `
        -Switch:$RemovePayload -EnvironmentName 'WINFEATURE_REMOVE_PAYLOAD'

    if ($Action -eq 'Disable' -and $withPayloadRemoval) {
        Write-Warning -Message '-RemovePayload deletes the feature files from the image. Re-enabling will need Windows Update or an installation source.'
    }
    if ($Action -eq 'Enable' -and $withParent) {
        Write-Warning -Message '-IncludeParent also enables every parent feature the named feature depends on, including ones you did not name.'
    }

    # --- Confirmation (exit 5) -----------------------------------------------
    # -WhatIf changes nothing and never prompts, so it is always allowed.
    # Without this check a scheduled run dies inside ShouldProcess with "Read and
    # Prompt functionality is not available" and a bare exit 1.
    $willChange = -not $WhatIfPreference

    if ($willChange -and $ConfirmPreference -ne 'None' -and -not (Test-InteractiveHost)) {
        Write-Error -Message 'Refused: changing a feature needs confirmation, there is no terminal to confirm on, and -Force was not given. Re-run with -Force (or set WINFEATURE_FORCE=1), or preview with -WhatIf.' -ErrorAction Continue
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
        $result.Add((Set-FeatureState -Name $name -Operation $Action `
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
        Write-Information -MessageData 'A restart is required to finish. Exit code 3010.'
        $script:ExitCode = 3010
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
