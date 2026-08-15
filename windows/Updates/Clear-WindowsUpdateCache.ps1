<#
.SYNOPSIS
    Clears the Windows Update download cache and reports the space freed.

.DESCRIPTION
    Stops the services that hold handles inside SoftwareDistribution, clears the
    cache, and restarts exactly the services that were running beforehand.

    Two modes:

      Default          Deletes the contents of SoftwareDistribution\Download.
                       This is the cache of downloaded update payloads. Windows
                       Update re-downloads what it still needs on the next scan.
                       Update history and the update database are left intact.

      -ResetDataStore  Renames the whole SoftwareDistribution directory aside to
                       SoftwareDistribution.bak-<timestamp>. Windows rebuilds it
                       on the next scan. This is Microsoft's documented reset for
                       a broken update client. It DISCARDS THE VISIBLE UPDATE
                       HISTORY. The directory is renamed rather than deleted so
                       the change is reversible; no space is reclaimed until you
                       delete the .bak directory yourself, and the script tells
                       you where it is.

    Blast radius: only $env:SystemRoot\SoftwareDistribution (overridable with
    -SoftwareDistributionPath), plus a stop and restart of the services named by
    -ServiceName. Nothing else is touched.

    Deliberately NOT done, because these are last-resort steps that break more
    than they fix in a routine cache clear:
      * catroot2 is not renamed and cryptsvc is not stopped. Those affect
        certificate and catalog validation well beyond Windows Update.
      * Service security descriptors are not reset with sc.exe sdset. Microsoft
        documents that as a last resort; it overwrites the existing service ACLs.
      * No regsvr32 block. Those DLL registrations are Windows XP and Vista era;
        several of the DLLs do not exist on Windows 10 or 11, and component
        registration on modern Windows is managed by servicing.
      * netsh winsock reset is not run. It removes third-party Winsock layered
        service providers and breaks VPN and endpoint-security products.

    Safety properties:
      * Nothing is stopped or deleted without passing $PSCmdlet.ShouldProcess, so
        -WhatIf produces a complete dry run and changes nothing.
      * Services are restarted from a finally block, so a failure part way through
        can never leave Windows Update permanently stopped.
      * Only services that were actually running are restarted, and running
        dependent services are stopped first and restarted in reverse order.
      * BytesFreed counts only files whose deletion returned without error.
      * A run that will change something takes a machine-wide lock
        (Global\lzc-updates) and exits 75 if another instance holds it, so two
        runs never fight over the same services and directory.
      * A run that would prompt, on a host with no terminal to prompt on and
        without -Force, is refused with exit 5 before any service is stopped.

    Every environment variable a user may set is named LZC_UPDATES_*, so
    `Get-ChildItem env:LZC_*` shows everything configurable in this repository.
    A variable is consulted only when the matching parameter is not passed, and
    an unusable value is a usage error (exit 2) rather than a silent default.

.PARAMETER SoftwareDistributionPath
    The SoftwareDistribution directory. Defaults to
    $env:SystemRoot\SoftwareDistribution. Environment variable:
    LZC_UPDATES_PATH.

.PARAMETER ServiceName
    Services to stop for the duration of the operation. Defaults to wuauserv and
    bits, which are the two that hold handles in Download. Add UsoSvc if files
    remain locked on Windows 10 and 11. A name that does not exist on this system
    is reported and ignored rather than treated as a failure. Environment
    variable: LZC_UPDATES_SERVICES (comma separated).

.PARAMETER ServiceTimeoutSeconds
    How long to wait for each service to reach the requested state before giving
    up. Defaults to 60, accepted range 5 to 3600. The bound is per service and
    per transition, so a run that stops two services and restarts them can wait
    up to four times this value. A zero-padded value such as 08 is read as
    decimal 8. Environment variable: LZC_UPDATES_SERVICE_TIMEOUT.

.PARAMETER ResetDataStore
    Rename the whole SoftwareDistribution directory aside instead of clearing
    only Download. Discards the visible Windows Update history. Environment
    variable: LZC_UPDATES_RESET_DATASTORE (1, true, yes, on / 0, false, no, off).

.PARAMETER Force
    Suppress confirmation prompts, for scheduled and unattended runs. -WhatIf
    still takes precedence over -Force. Environment variable: LZC_UPDATES_FORCE
    (1, true, yes, on / 0, false, no, off).

.PARAMETER ExtraArgument
    Collects anything that is not a parameter of this script. Passing something
    here is a typo, so the run stops with exit code 2 and names what it did not
    understand. Do not pass it deliberately.

.EXAMPLE
    PS> .\Clear-WindowsUpdateCache.ps1 -WhatIf

    Reports which services would be stopped and how much the download cache
    would free. Changes nothing.

.EXAMPLE
    PS> .\Clear-WindowsUpdateCache.ps1 -Force

    Unattended clear of the download cache.

.EXAMPLE
    PS> .\Clear-WindowsUpdateCache.ps1 -ResetDataStore -Force -Verbose

    Full reset: renames SoftwareDistribution aside so Windows rebuilds it.
    Discards the visible update history.

.INPUTS
    None. This script does not accept pipeline input.

.OUTPUTS
    System.Management.Automation.PSCustomObject with Mode, Path, ItemCount,
    ByteCount, ItemsRemoved, BytesFreed, ItemsSkipped, BytesMovedAside,
    BackupPath, ServiceStopped, ServiceRestarted and Status properties.

.NOTES
    Exit codes (the repository-wide table; every script in this repository uses
    the same numbers):
      0     success: the cache was cleared and every stopped service restarted
      1     the work ran but something in it failed: a partial clear, or a
            service that would not stop or restart
      2     usage error: an unknown argument, or a parameter or LZC_UPDATES_*
            value that is missing or invalid (including a cache directory that
            does not exist)
      3     unsupported platform or missing prerequisite (not Windows, or
            PowerShell older than 5.1)
      4     not running as Administrator
      5     refused: the run needs confirmation, there is no terminal to confirm
            on, and neither -Force nor -Confirm:$false was given
      75    another instance holds the lock Global\lzc-updates (EX_TEMPFAIL, so
            cron and scheduled tasks treat it as "retry later")
      130   interrupted (Ctrl-C or cancellation)

    Checks run in that order with one deliberate exception: arguments and
    settings are validated BEFORE the elevation check, so a typo is discoverable
    from an ordinary shell without an elevated one.

    Some updates need a restart before Windows Update behaves normally again.
    This script never reboots and never asks Windows to reboot.

    Progress is written to the information stream and is visible by default. Add
    -InformationAction SilentlyContinue for a quiet run, or -Verbose for detail.

    This script emits no colour of its own; the host renders the information,
    warning and error streams. NO_COLOR (https://no-color.org, any non-empty
    value) is honoured: on PowerShell 7 it forces $PSStyle.OutputRendering to
    PlainText for the run, and Windows PowerShell 5.1 renders those streams
    without ANSI sequences already.

    Scheduled task invocation (use -File, never -Command):
      powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass
        -File "C:\path\Clear-WindowsUpdateCache.ps1" -Force

    License: MIT
    Origin:  https://github.com/Lazarev-Cloud/Scripts

.LINK
    https://github.com/Lazarev-Cloud/Scripts

.LINK
    https://learn.microsoft.com/en-us/troubleshoot/windows-client/installing-updates-features-roles/additional-resources-for-windows-update
#>

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
[OutputType([pscustomobject])]
param(
    # Values are deliberately NOT resolved from the environment here, and carry
    # no ValidateRange/ValidateSet attributes. A failure inside the parameter
    # binder ends the process with exit code 1 before a single line of this
    # script runs, which would make the documented exit-code table a lie. Every
    # value is therefore validated in Start-CacheClear, which can report a clear
    # message and exit 2.
    [Parameter(Position = 0)]
    [AllowEmptyString()]
    [string] $SoftwareDistributionPath = '',

    [Parameter()]
    [AllowEmptyCollection()]
    [string[]] $ServiceName = @(),

    [Parameter()]
    [AllowEmptyString()]
    [string] $ServiceTimeoutSeconds = '',

    [Parameter()]
    [switch] $ResetDataStore,

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

# Machine-wide lock, taken only by a run that will change something and released
# in the finally block at the end of the file.
$ScriptLockName = 'lzc-updates'
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

function Format-ByteSize {
    <#
    .SYNOPSIS
        Renders a byte count as a short human-readable string.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [long] $Byte
    )

    $unit = @('B', 'KB', 'MB', 'GB', 'TB', 'PB')
    $value = [double][Math]::Abs($Byte)
    $index = 0
    while ($value -ge 1024 -and $index -lt ($unit.Count - 1)) {
        $value = $value / 1024
        $index++
    }
    if ($Byte -lt 0) { $value = -$value }
    if ($index -eq 0) { return ('{0:N0} {1}' -f $value, $unit[$index]) }
    return ('{0:N2} {1}' -f $value, $unit[$index])
}

function Get-DirectorySize {
    <#
    .SYNOPSIS
        Returns the file list and total size under a directory in one enumeration.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $LiteralRoot
    )

    $enumerationError = @()
    # SilentlyContinue is paired with -ErrorVariable and the count is reported by
    # the caller, so an unreadable subtree is surfaced rather than swallowed.
    $file = @(Get-ChildItem -LiteralPath $LiteralRoot -Recurse -Force -File `
            -ErrorAction SilentlyContinue -ErrorVariable +enumerationError)

    $byte = 0L
    foreach ($item in $file) { $byte += $item.Length }

    return [pscustomobject]@{
        File            = $file
        ByteCount       = $byte
        UnreadableCount = @($enumerationError).Count
    }
}

function Get-ServiceStopPlan {
    <#
    .SYNOPSIS
        Builds the ordered list of services to stop, dependents first.
    .DESCRIPTION
        Stop-Service -Force stops dependent services without saying which. This
        enumerates them instead, so every service taken down can be brought back
        up afterwards in the reverse order.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string[]] $Name
    )

    $ordered = [System.Collections.Generic.List[object]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)

    foreach ($candidate in $Name) {
        $service = $null
        try {
            $service = Get-Service -Name $candidate.Trim() -ErrorAction Stop
        }
        catch {
            Write-Warning -Message "Service '$candidate' does not exist on this system; ignoring it."
            continue
        }

        # Dependents must stop before the service they depend on.
        $dependentService = @()
        try {
            $dependentService = @($service.DependentServices)
        }
        catch {
            Write-Warning -Message "Could not enumerate services dependent on '$($service.Name)': $($_.Exception.Message)"
        }

        foreach ($dependent in $dependentService) {
            if ($dependent.Status -ne 'Running') { continue }
            if (-not $seen.Add($dependent.Name)) { continue }
            $ordered.Add([pscustomobject]@{
                    Name        = $dependent.Name
                    DisplayName = $dependent.DisplayName
                    WasRunning  = $true
                    IsDependent = $true
                })
        }

        if (-not $seen.Add($service.Name)) { continue }
        $ordered.Add([pscustomobject]@{
                Name        = $service.Name
                DisplayName = $service.DisplayName
                WasRunning  = ($service.Status -eq 'Running')
                IsDependent = $false
            })
    }

    return $ordered.ToArray()
}

function Set-ServiceRunState {
    <#
    .SYNOPSIS
        Drives one service to Stopped or Running within a bounded wait.
    .DESCRIPTION
        Uses ServiceController.Stop/Start plus WaitForStatus so the wait is
        bounded, which Stop-Service on Windows PowerShell 5.1 cannot express.
        Returns true when the service reached the requested state.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Name,

        [Parameter(Mandatory)]
        [ValidateSet('Stopped', 'Running')]
        [string] $State,

        [Parameter(Mandatory)]
        [ValidateRange(5, 3600)]
        [int] $TimeoutSecond
    )

    $verb = if ($State -eq 'Stopped') { 'Stop service' } else { 'Start service' }
    if (-not $PSCmdlet.ShouldProcess($Name, $verb)) { return $false }

    $service = $null
    try {
        $service = Get-Service -Name $Name -ErrorAction Stop
    }
    catch {
        Write-Warning -Message "Cannot query service '$Name': $($_.Exception.Message)"
        return $false
    }

    $service.Refresh()
    if ($service.Status -eq $State) {
        Write-Verbose -Message "Service '$Name' is already $State."
        return $true
    }

    try {
        if ($State -eq 'Stopped') {
            if (-not $service.CanStop) {
                Write-Warning -Message "Service '$Name' reports that it cannot be stopped."
                return $false
            }
            $service.Stop()
        }
        else {
            $service.Start()
        }
        $service.WaitForStatus($State, [TimeSpan]::FromSeconds($TimeoutSecond))
        Write-Verbose -Message "Service '$Name' is now $State."
        return $true
    }
    catch {
        # Matched on the type name rather than with `catch [Type]`: the
        # System.ServiceProcess assembly is loaded on demand, and an unresolvable
        # catch type turns every exception into "Unable to find type", hiding the
        # real failure.
        if ($_.Exception.GetType().FullName -eq 'System.ServiceProcess.TimeoutException') {
            Write-Warning -Message "Service '$Name' did not reach '$State' within $TimeoutSecond second(s)."
        }
        else {
            Write-Warning -Message "Could not drive service '$Name' to '$State': $($_.Exception.Message)"
        }
        return $false
    }
}

function Clear-DownloadCache {
    <#
    .SYNOPSIS
        Deletes the contents of the Download directory and reports what was freed.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $DownloadPath,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]] $File
    )

    $removed = 0
    $freed = 0L
    $skipped = 0
    $firstReason = $null

    foreach ($item in $File) {
        try {
            Remove-Item -LiteralPath $item.FullName -Force -ErrorAction Stop
            $removed++
            $freed += $item.Length
            Write-Verbose -Message "Removed: $($item.FullName)"
        }
        catch {
            $skipped++
            if ($null -eq $firstReason) { $firstReason = $_.Exception.Message }
            Write-Verbose -Message "Could not remove '$($item.FullName)': $($_.Exception.Message)"
        }
    }

    # Sub-directories of Download are scratch space; the Download directory itself
    # stays so Windows Update does not have to recreate it. A sub-directory that
    # will not delete is counted, not merely traced: a file that appeared after
    # the enumeration, or a directory the caller cannot remove, leaves a subtree
    # on disk. Write-Verbose alone is invisible by default and reaches no counter,
    # so the run would report Success with part of the cache still there.
    $directorySkipped = 0
    $directory = @(Get-ChildItem -LiteralPath $DownloadPath -Force -Directory -ErrorAction SilentlyContinue)
    foreach ($item in $directory) {
        try {
            Remove-Item -LiteralPath $item.FullName -Recurse -Force -ErrorAction Stop
        }
        catch {
            $directorySkipped++
            if ($null -eq $firstReason) { $firstReason = $_.Exception.Message }
            Write-Verbose -Message "Could not remove directory '$($item.FullName)': $($_.Exception.Message)"
        }
    }

    return [pscustomobject]@{
        ItemsRemoved       = $removed
        BytesFreed         = $freed
        ItemsSkipped       = $skipped
        DirectoriesSkipped = $directorySkipped
        Reason             = $firstReason
    }
}

function Rename-SoftwareDistribution {
    <#
    .SYNOPSIS
        Renames SoftwareDistribution aside so Windows rebuilds it.
    .DESCRIPTION
        Renaming rather than deleting keeps the reset reversible: move the
        directory back to undo it. Returns the backup path, or nothing on failure.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $LiteralRoot
    )

    $newName = '{0}.bak-{1}' -f (Split-Path -Path $LiteralRoot -Leaf), (Get-Date -Format 'yyyyMMddHHmmss')
    try {
        Rename-Item -LiteralPath $LiteralRoot -NewName $newName -ErrorAction Stop
        return (Join-Path -Path (Split-Path -Path $LiteralRoot -Parent) -ChildPath $newName)
    }
    catch {
        Write-Warning -Message "Could not rename '$LiteralRoot': $($_.Exception.Message)"
        Write-Warning -Message 'A service or process still holds a handle inside it. Add UsoSvc to -ServiceName, or reboot and retry.'
        return
    }
}

function Start-CacheClear {
    <#
    .SYNOPSIS
        Entry point. Stops the services, clears the cache, restarts the services.
    .DESCRIPTION
        Result object goes to the success stream. The process exit code is left in
        the script-scope $ExitCode variable, which the last line of the file reads.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType([pscustomobject])]
    param()

    # --- Usage (exit 2) ------------------------------------------------------
    # Arguments and settings are checked before elevation deliberately: a typo
    # must be discoverable from an ordinary shell, not only an elevated one.
    if ($ExtraArgument.Count -gt 0) {
        Write-Error -Message ("Unknown argument(s): {0}. Run 'Get-Help .\Clear-WindowsUpdateCache.ps1 -Full' for the parameters this script accepts." -f `
            ($ExtraArgument -join ' ')) -ErrorAction Continue
        $script:ExitCode = 2
        return
    }

    $forced = $false
    $fullReset = $false
    $timeoutSecond = 60
    try {
        $forced = Resolve-BooleanSetting -Name 'Force' -Switch:$Force `
            -EnvironmentName 'LZC_UPDATES_FORCE'
        $fullReset = Resolve-BooleanSetting -Name 'ResetDataStore' `
            -Switch:$ResetDataStore -EnvironmentName 'LZC_UPDATES_RESET_DATASTORE'
        # Minimum 5 seconds: a shorter bound reports "the service did not stop"
        # for services that simply take a moment, and would then delete files
        # they still hold open.
        $timeoutSecond = Resolve-IntegerSetting -Name 'ServiceTimeoutSeconds' -Value $ServiceTimeoutSeconds `
            -EnvironmentName 'LZC_UPDATES_SERVICE_TIMEOUT' -Default 60 -Minimum 5 -Maximum 3600
    }
    catch [ArgumentException] {
        Write-Error -Message $_.Exception.Message -ErrorAction Continue
        $script:ExitCode = 2
        return
    }

    $requestedPath = ''
    if ($ScriptBoundParameter.ContainsKey('SoftwareDistributionPath')) {
        $requestedPath = $SoftwareDistributionPath
    }
    elseif (-not [string]::IsNullOrWhiteSpace($env:LZC_UPDATES_PATH)) {
        $requestedPath = $env:LZC_UPDATES_PATH
    }
    else {
        $requestedPath = Join-Path -Path $env:SystemRoot -ChildPath 'SoftwareDistribution'
    }
    if ([string]::IsNullOrWhiteSpace($requestedPath)) {
        Write-Error -Message 'No cache directory was supplied. Use -SoftwareDistributionPath or set LZC_UPDATES_PATH.' -ErrorAction Continue
        $script:ExitCode = 2
        return
    }

    $serviceList = @()
    if ($ScriptBoundParameter.ContainsKey('ServiceName')) {
        $serviceList = @($ServiceName)
    }
    elseif (-not [string]::IsNullOrWhiteSpace($env:LZC_UPDATES_SERVICES)) {
        $serviceList = @($env:LZC_UPDATES_SERVICES -split ',')
    }
    else {
        $serviceList = @('wuauserv', 'bits')
    }
    $serviceList = @($serviceList | Where-Object { $_ -and $_.Trim() })
    if ($serviceList.Count -eq 0) {
        Write-Error -Message 'No service was supplied. Use -ServiceName or set LZC_UPDATES_SERVICES.' -ErrorAction Continue
        $script:ExitCode = 2
        return
    }

    $root = [Environment]::ExpandEnvironmentVariables($requestedPath).TrimEnd('\')
    if (-not (Test-Path -LiteralPath $root -PathType Container)) {
        Write-Error -Message "'$root' is not an existing directory. Set -SoftwareDistributionPath or LZC_UPDATES_PATH." -ErrorAction Continue
        $script:ExitCode = 2
        return
    }

    # --- Platform and prerequisites (exit 3) ---------------------------------
    if (-not (Test-WindowsHost)) {
        Write-Error -Message 'This script clears the Windows Update cache and only runs on Windows.' -ErrorAction Continue
        $script:ExitCode = 3
        return
    }
    if ($PSVersionTable.PSVersion -lt [version]'5.1') {
        Write-Error -Message "PowerShell 5.1 or newer is required; this host is $($PSVersionTable.PSVersion)." -ErrorAction Continue
        $script:ExitCode = 3
        return
    }

    # --- Elevation (exit 4) --------------------------------------------------
    # Required even for -WhatIf: without it the cache cannot be measured and the
    # service state cannot be read, so the preview would be wrong.
    if (-not (Test-Elevated)) {
        Write-Error -Message 'This script must be run as Administrator. Start an elevated PowerShell and run it again.' -ErrorAction Continue
        $script:ExitCode = 4
        return
    }

    # -Force means "do not prompt". Lowering $ConfirmPreference rather than
    # short-circuiting ShouldProcess is what keeps -WhatIf authoritative.
    if ($forced -and -not $ScriptBoundParameter.ContainsKey('Confirm')) {
        $ConfirmPreference = 'None'
    }

    # --- Confirmation (exit 5) -----------------------------------------------
    # -WhatIf changes nothing and never prompts, so it is always allowed.
    $willChange = -not $WhatIfPreference

    if ($willChange -and $ConfirmPreference -ne 'None' -and -not (Test-InteractiveHost)) {
        Write-Error -Message 'Refused: stopping services and clearing the cache needs confirmation, there is no terminal to confirm on, and -Force was not given. Re-run with -Force (or set LZC_UPDATES_FORCE=1), or preview with -WhatIf.' -ErrorAction Continue
        $script:ExitCode = 5
        return
    }

    # --- Lock (exit 75) ------------------------------------------------------
    # Only a run that will stop services and delete files takes the lock, so a
    # -WhatIf preview is never blocked by a real run in progress.
    if ($willChange) {
        $script:ScriptLock = Enter-ScriptLock -Name $ScriptLockName
        if ($null -eq $script:ScriptLock) {
            Write-Error -Message "Another instance is already running (lock: Global\$ScriptLockName). Try again later." -ErrorAction Continue
            $script:ExitCode = 75
            return
        }
    }

    $mode = if ($fullReset) { 'ResetDataStore' } else { 'Download' }
    $measurePath = if ($fullReset) { $root } else { Join-Path -Path $root -ChildPath 'Download' }

    if (-not $fullReset -and -not (Test-Path -LiteralPath $measurePath -PathType Container)) {
        Write-Information -MessageData "'$measurePath' does not exist; there is no download cache to clear."
        [pscustomobject]@{
            Mode             = $mode
            Path             = $measurePath
            ItemCount        = 0
            ByteCount        = 0L
            ItemsRemoved     = 0
            BytesFreed       = 0L
            ItemsSkipped     = 0
            BytesMovedAside  = 0L
            BackupPath       = $null
            ServiceStopped   = @()
            ServiceRestarted = @()
            Status           = 'NothingToDo'
        }
        return
    }

    Write-Information -MessageData "Measuring $measurePath ..."
    $scan = Get-DirectorySize -LiteralRoot $measurePath
    $found = $scan.File.Count
    if ($scan.UnreadableCount -gt 0) {
        Write-Warning -Message "$($scan.UnreadableCount) path(s) under '$measurePath' could not be enumerated."
    }
    Write-Information -MessageData ('{0}: {1:N0} file(s), {2}.' -f $measurePath, $found, (Format-ByteSize -Byte $scan.ByteCount))

    $plan = @(Get-ServiceStopPlan -Name $serviceList)
    $toStop = @($plan | Where-Object { $_.WasRunning })
    if ($toStop.Count -gt 0) {
        Write-Information -MessageData ('Services to stop: {0}' -f (($toStop | ForEach-Object { $_.Name }) -join ', '))
    }

    $operation = if ($fullReset) {
        'Stop {0} service(s), rename the directory aside ({1}), restart the services' -f `
            $toStop.Count, (Format-ByteSize -Byte $scan.ByteCount)
    }
    else {
        'Stop {0} service(s), delete {1:N0} cached file(s) ({2}), restart the services' -f `
            $toStop.Count, $found, (Format-ByteSize -Byte $scan.ByteCount)
    }

    if (-not $PSCmdlet.ShouldProcess($root, $operation)) {
        Write-Information -MessageData ('Dry run: would free {0}. Nothing was changed.' -f (Format-ByteSize -Byte $scan.ByteCount))
        [pscustomobject]@{
            Mode             = $mode
            Path             = $measurePath
            ItemCount        = $found
            ByteCount        = $scan.ByteCount
            ItemsRemoved     = 0
            BytesFreed       = 0L
            ItemsSkipped     = 0
            BytesMovedAside  = 0L
            BackupPath       = $null
            ServiceStopped   = @($toStop | ForEach-Object { $_.Name })
            ServiceRestarted = @()
            Status           = 'Skipped'
        }
        return
    }

    $stopped = [System.Collections.Generic.List[string]]::new()
    $restarted = [System.Collections.Generic.List[string]]::new()
    $removedCount = 0
    $freedByte = 0L
    $skippedCount = 0
    $movedAside = 0L
    $backupPath = $null
    $status = 'Success'

    try {
        foreach ($entry in $toStop) {
            # Recorded BEFORE the attempt, not after it. Every service in $toStop was
            # running when this run started, so this script owns putting it back
            # whatever happens next. Recording only on a confirmed stop would lose
            # the service whose Stop() succeeded but whose wait timed out: it stops a
            # moment later and, never having been recorded, is never restarted --
            # which is precisely the "Windows Update left stopped" failure the
            # finally block exists to prevent.
            $stopped.Add($entry.Name)

            # -Confirm:$false: the umbrella operation above was already confirmed.
            if (-not (Set-ServiceRunState -Name $entry.Name -State 'Stopped' `
                        -TimeoutSecond $timeoutSecond -Confirm:$false)) {
                $status = 'Partial'
                Write-Warning -Message "'$($entry.Name)' did not confirm it stopped; files it holds open may be skipped. It will still be restarted."
            }
        }

        if ($fullReset) {
            $backupPath = Rename-SoftwareDistribution -LiteralRoot $root
            if ([string]::IsNullOrWhiteSpace($backupPath)) {
                $status = 'Failed'
            }
            else {
                $movedAside = $scan.ByteCount
                Write-Information -MessageData "Renamed aside to: $backupPath"
                Write-Information -MessageData ('Delete that directory to reclaim {0}.' -f (Format-ByteSize -Byte $movedAside))
            }
        }
        else {
            $result = Clear-DownloadCache -DownloadPath $measurePath -File $scan.File
            $removedCount = $result.ItemsRemoved
            $freedByte = $result.BytesFreed
            $skippedCount = $result.ItemsSkipped
            if ($skippedCount -gt 0) {
                $status = 'Partial'
                Write-Warning -Message ('{0:N0} file(s) could not be removed. First reason: {1}' -f $skippedCount, $result.Reason)
            }
            # A sub-directory that would not delete is not a skipped file, so it
            # never reaches ItemsSkipped -- but part of the cache is still on
            # disk, and the run must not claim Success.
            if ($result.DirectoriesSkipped -gt 0) {
                $status = 'Partial'
                Write-Warning -Message ('{0:N0} sub-directory(ies) of the download cache could not be removed; part of the cache is still on disk. First reason: {1}' -f `
                        $result.DirectoriesSkipped, $result.Reason)
            }
        }
    }
    finally {
        # Restoring service state is cleanup: it must run whatever happened above,
        # it must not be suppressed by a confirmation prompt, and it must undo the
        # stop order, so services come back in the reverse order they went down.
        for ($index = $stopped.Count - 1; $index -ge 0; $index--) {
            $name = $stopped[$index]
            if (Set-ServiceRunState -Name $name -State 'Running' `
                    -TimeoutSecond $timeoutSecond -Confirm:$false -WhatIf:$false) {
                $restarted.Add($name)
            }
            else {
                Write-Warning -Message "Service '$name' was stopped by this script and did NOT restart. Start it manually with: Start-Service -Name $name"
            }
        }
    }

    if ($stopped.Count -ne $restarted.Count) { $status = 'Partial' }

    if ($fullReset) {
        Write-Information -MessageData 'SoftwareDistribution will be rebuilt on the next Windows Update scan. The visible update history is gone.'
    }
    else {
        Write-Information -MessageData ('Freed {0} across {1:N0} file(s). Windows Update re-downloads what it still needs.' -f `
            (Format-ByteSize -Byte $freedByte), $removedCount)
    }

    if ($status -ne 'Success') { $script:ExitCode = 1 }

    [pscustomobject]@{
        Mode             = $mode
        Path             = $measurePath
        ItemCount        = $found
        ByteCount        = $scan.ByteCount
        ItemsRemoved     = $removedCount
        BytesFreed       = $freedByte
        ItemsSkipped     = $skippedCount
        BytesMovedAside  = $movedAside
        BackupPath       = $backupPath
        ServiceStopped   = $stopped.ToArray()
        ServiceRestarted = $restarted.ToArray()
        Status           = $status
    }
}

try {
    Start-CacheClear
}
catch [System.Management.Automation.PipelineStoppedException] {
    # Ctrl-C, or a caller stopping the pipeline. Services stopped by this run are
    # restarted by the finally block inside Start-CacheClear before it unwinds.
    Write-Warning -Message 'Interrupted. Check that wuauserv and bits are running: Get-Service wuauserv, bits'
    $ExitCode = 130
}
catch [System.OperationCanceledException] {
    Write-Warning -Message 'Cancelled. Check that wuauserv and bits are running: Get-Service wuauserv, bits'
    $ExitCode = 130
}
finally {
    Exit-ScriptLock -Mutex $ScriptLock
}

exit $ExitCode
