<#
.SYNOPSIS
    Deletes stale files from temporary directories and reports the space freed.

.DESCRIPTION
    Clean-Disk enumerates every file under the requested directories, removes the
    ones older than a minimum age, and reports exactly how many bytes it freed.

    Blast radius: files and now-empty subdirectories underneath the paths given by
    -Path. Nothing outside those paths is touched. The default paths are the
    machine temp directory ($env:SystemRoot\Temp) and the temp directory of the
    account running the script ($env:TEMP). The Recycle Bin is only emptied when
    -IncludeRecycleBin is given, because that is user data.

    Safety properties:
      * Nothing is deleted without passing $PSCmdlet.ShouldProcess, so -WhatIf
        produces a complete, accurate dry run and changes nothing.
      * Files newer than -MinimumAgeHours are left alone, so a running installer's
        working files survive.
      * A directory root that is a drive root, or a protected system directory such
        as $env:SystemRoot or $env:ProgramFiles, is refused.
      * Every file is checked to be inside its root before deletion, and reparse
        points are skipped, so a junction or symlink inside a temp directory cannot
        be used to escape the target.
      * Files that are locked or access-denied are counted and reported; they never
        abort the run.
      * BytesFreed counts only files whose deletion actually returned without
        error, so it never claims space a locked file still occupies.
      * A run that would delete something takes a machine-wide lock
        (Global\lzc-clean-disk) and exits 75 if another instance holds it, so two
        runs never sweep the same directory at once.
      * A run that would prompt, on a host with no terminal to prompt on and
        without -Force, is refused with exit 5 instead of failing part way in.

    The Windows Update download cache is deliberately NOT cleaned here. Deleting it
    while wuauserv and BITS hold handles only half works. Use
    windows/Updates/Clear-WindowsUpdateCache.ps1, which stops the services first.

    Every environment variable a user may set is named LZC_CLEAN_DISK_*, so
    `Get-ChildItem env:LZC_*` shows everything configurable in this repository.
    A variable is consulted only when the matching parameter is not passed, and
    an unusable value is a usage error (exit 2) rather than a silent default.

.PARAMETER Path
    One or more directories to clean. Defaults to the machine and user temp
    directories. Environment variable: LZC_CLEAN_DISK_PATHS (semicolon
    separated).

.PARAMETER MinimumAgeHours
    Only files whose LastWriteTime is at least this many hours in the past are
    removed. 0 removes everything found. Defaults to 24, accepted range 0 to
    87600 (ten years). A zero-padded value such as 08 is read as decimal 8.
    Environment variable: LZC_CLEAN_DISK_MIN_AGE_HOURS.

.PARAMETER IncludeRecycleBin
    Also empty the Recycle Bin on every drive. Off by default: the Recycle Bin
    holds user data, not machine junk. Environment variable:
    LZC_CLEAN_DISK_INCLUDE_RECYCLE_BIN (1, true, yes, on / 0, false, no, off).

.PARAMETER KeepEmptyDirectory
    Leave behind subdirectories that become empty. By default they are removed.
    The root directories given by -Path are never removed. Environment variable:
    LZC_CLEAN_DISK_KEEP_EMPTY_DIR (1, true, yes, on / 0, false, no, off).

.PARAMETER Force
    Suppress confirmation prompts, for scheduled and unattended runs. -WhatIf
    still takes precedence over -Force. Environment variable:
    LZC_CLEAN_DISK_FORCE (1, true, yes, on / 0, false, no, off).

.PARAMETER ExtraArgument
    Collects anything that is not a parameter of this script. Passing something
    here is a typo, so the run stops with exit code 2 and names what it did not
    understand. Do not pass it deliberately.

.EXAMPLE
    PS> .\Clean-Disk.ps1 -WhatIf

    Reports how many files and bytes would be removed from the default temp
    directories. Deletes nothing.

.EXAMPLE
    PS> .\Clean-Disk.ps1 -MinimumAgeHours 0 -Force -Verbose

    Unattended run that removes every file in the default temp directories
    regardless of age, narrating each deletion.

.EXAMPLE
    PS> .\Clean-Disk.ps1 -Path 'D:\BuildCache','E:\Scratch' -MinimumAgeHours 168 -Force

    Removes files older than a week from two build scratch directories.

.INPUTS
    None. This script does not accept pipeline input.

.OUTPUTS
    System.Management.Automation.PSCustomObject, one per cleaned directory, with
    Path, ItemCount, ByteCount, ItemsRemoved, BytesFreed, ItemsSkipped,
    BytesSkipped, DirectoriesRemoved, UnreadablePath and Status properties.

.NOTES
    Exit codes (the repository-wide table; every script in this repository uses
    the same numbers):
      0     success
      1     the work ran but something in it failed (a file would not delete)
      2     usage error: an unknown argument, or a parameter or LZC_CLEAN_DISK_*
            value that is missing or invalid
      3     unsupported platform or missing prerequisite (not Windows, or
            PowerShell older than 5.1)
      4     not running as Administrator
      5     refused: the run needs confirmation, there is no terminal to confirm
            on, and neither -Force nor -Confirm:$false was given
      75    another instance holds the lock Global\lzc-clean-disk (EX_TEMPFAIL,
            so cron and scheduled tasks treat it as "retry later")
      130   interrupted (Ctrl-C or cancellation)

    Checks run in that order with one deliberate exception: arguments and
    settings are validated BEFORE the elevation check, so a typo is discoverable
    from an ordinary shell without an elevated one.

    Because the script requires elevation, $env:TEMP is the temp directory of the
    ELEVATED account, not of the logged-on user. To clean a specific user's temp
    directory, name it explicitly with -Path.

    Progress is written to the information stream and is visible by default. Add
    -InformationAction SilentlyContinue for a quiet run, or -Verbose for per-file
    detail. Warnings and errors go to the warning and error streams, so the
    success stream carries only the result objects.

    This script emits no colour of its own; the host renders the information,
    warning and error streams. NO_COLOR (https://no-color.org, any non-empty
    value) is honoured: on PowerShell 7 it forces $PSStyle.OutputRendering to
    PlainText for the run, and Windows PowerShell 5.1 renders those streams
    without ANSI sequences already.

    Scheduled task invocation (use -File, never -Command; -Command collapses the
    exit code to 0 or 1):
      powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass
        -File "C:\path\Clean-Disk.ps1" -Force

    License: MIT
    Origin:  https://github.com/Lazarev-Cloud/Scripts

.LINK
    https://github.com/Lazarev-Cloud/Scripts

.LINK
    https://learn.microsoft.com/en-us/powershell/scripting/learn/deep-dives/everything-about-shouldprocess
#>

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
[OutputType([pscustomobject])]
param(
    # Values are deliberately NOT resolved from the environment here, and carry
    # no ValidateRange/ValidateSet attributes. A failure inside the parameter
    # binder ends the process with exit code 1 before a single line of this
    # script runs, which would make the documented exit-code table a lie. Every
    # value is therefore validated in Start-CleanDisk, which can report a clear
    # message and exit 2.
    [Parameter(Position = 0)]
    [AllowEmptyCollection()]
    [string[]] $Path = @(),

    [Parameter()]
    [AllowEmptyString()]
    [string] $MinimumAgeHours = '',

    [Parameter()]
    [switch] $IncludeRecycleBin,

    [Parameter()]
    [switch] $KeepEmptyDirectory,

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
$ScriptLockName = 'lzc-clean-disk'
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

function Resolve-CleanTarget {
    <#
    .SYNOPSIS
        Validates one requested directory and returns its canonical full path.
    .DESCRIPTION
        Refuses drive roots and protected system directories. Returns nothing and
        writes a warning when the directory is unusable, so a bad entry in -Path
        skips that entry instead of aborting the whole run.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Candidate
    )

    $expanded = [Environment]::ExpandEnvironmentVariables($Candidate).Trim()
    if ([string]::IsNullOrWhiteSpace($expanded)) {
        Write-Warning -Message 'Ignoring an empty path entry.'
        return
    }

    $full = $null
    try {
        $full = [IO.Path]::GetFullPath($expanded).TrimEnd('\')
    }
    catch {
        Write-Warning -Message "Ignoring '$expanded': not a valid filesystem path. $($_.Exception.Message)"
        return
    }

    if (-not (Test-Path -LiteralPath $full -PathType Container)) {
        Write-Warning -Message "Ignoring '$full': not an existing directory."
        return
    }

    $root = [IO.Path]::GetPathRoot($full).TrimEnd('\')
    if ($full -eq $root) {
        Write-Warning -Message "Refusing '$full': cleaning a drive root is never correct."
        return
    }

    $protected = @(
        $env:SystemRoot
        (Join-Path -Path $env:SystemRoot -ChildPath 'System32')
        (Join-Path -Path $env:SystemRoot -ChildPath 'SysWOW64')
        (Join-Path -Path $env:SystemRoot -ChildPath 'WinSxS')
        $env:ProgramFiles
        ${env:ProgramFiles(x86)}
        $env:ProgramData
        (Join-Path -Path $env:SystemDrive -ChildPath 'Users')
    ) | Where-Object { $_ } | ForEach-Object { $_.TrimEnd('\') }

    foreach ($entry in $protected) {
        if ($full -eq $entry) {
            Write-Warning -Message "Refusing '$full': protected system directory."
            return
        }
    }

    return $full
}

function Get-SafeDescendant {
    <#
    .SYNOPSIS
        Enumerates files or directories under a root without ever crossing a
        reparse point.
    .DESCRIPTION
        Get-ChildItem -Recurse follows directory junctions and symlinked
        directories on Windows PowerShell 5.1, so filtering reparse points out
        of its results is no protection: the junction is walked, and the files
        beneath it are ordinary files whose FullName still begins with the root,
        so they pass both the containment test and the reparse-point test.
        Deleting one then resolves through the junction and removes a file
        outside the tree the caller asked to clean.

        This walks explicitly and prunes any directory that is a reparse point,
        so nothing underneath one is ever returned. Iterative rather than
        recursive so a deep tree cannot exhaust the pipeline depth.
    .OUTPUTS
        System.IO.FileSystemInfo
    #>
    [CmdletBinding()]
    [OutputType([System.IO.FileSystemInfo])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Root,

        [Parameter(Mandatory)]
        [ValidateSet('File', 'Directory')]
        [string] $Kind,

        [Parameter()]
        [ref] $UnreadableCount
    )

    $pending = [System.Collections.Generic.Queue[string]]::new()
    $pending.Enqueue($Root)

    while ($pending.Count -gt 0) {
        $current = $pending.Dequeue()
        $childError = @()
        $children = @(Get-ChildItem -LiteralPath $current -Force `
                -ErrorAction SilentlyContinue -ErrorVariable +childError)

        if ($childError.Count -gt 0 -and $null -ne $UnreadableCount) {
            $UnreadableCount.Value += $childError.Count
        }

        foreach ($child in $children) {
            $isReparse = $child.Attributes.HasFlag([IO.FileAttributes]::ReparsePoint)
            if ($child.PSIsContainer) {
                if ($isReparse) {
                    Write-Verbose -Message "Reparse point, not descending: $($child.FullName)"
                    continue
                }
                $pending.Enqueue($child.FullName)
                if ($Kind -eq 'Directory') { $child }
            }
            elseif ($Kind -eq 'File' -and -not $isReparse) {
                $child
            }
        }
    }
}

function Get-CleanCandidate {
    <#
    .SYNOPSIS
        Enumerates the removable files under one root, with the age filter applied.
    .DESCRIPTION
        Enumerates once and returns that single snapshot. Sizes are taken from this
        snapshot so the reported figure describes exactly the files that were
        considered, rather than a before/after directory diff that a concurrently
        written temp directory would make wrong.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Root,

        [Parameter(Mandatory)]
        [int] $AgeHour
    )

    $cutoff = (Get-Date).AddHours(-$AgeHour)
    $prefix = $Root.TrimEnd('\') + '\'
    $enumerationError = @()

    # Get-SafeDescendant rather than Get-ChildItem -Recurse: the latter walks
    # through directory junctions, which is exactly the escape the DESCRIPTION
    # promises this script does not permit. Unreadable subtrees are counted and
    # reported rather than swallowed.
    $unreadable = 0
    $all = @(Get-SafeDescendant -Root $Root -Kind File -UnreadableCount ([ref] $unreadable))

    $eligible = [System.Collections.Generic.List[object]]::new()
    $tooNew = 0
    foreach ($item in $all) {
        if (-not $item.FullName.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
            Write-Verbose -Message "Outside root, skipping: $($item.FullName)"
            continue
        }
        if ($item.Attributes.HasFlag([IO.FileAttributes]::ReparsePoint)) {
            Write-Verbose -Message "Reparse point, skipping: $($item.FullName)"
            continue
        }
        if ($AgeHour -gt 0 -and $item.LastWriteTime -gt $cutoff) {
            $tooNew++
            continue
        }
        $eligible.Add($item)
    }

    $byte = 0L
    foreach ($item in $eligible) { $byte += $item.Length }

    return [pscustomobject]@{
        Root            = $Root
        File            = $eligible.ToArray()
        ByteCount       = $byte
        TooNewCount     = $tooNew
        UnreadableCount = $unreadable + @($enumerationError).Count
    }
}

function Remove-CleanCandidate {
    <#
    .SYNOPSIS
        Deletes a pre-enumerated file set and reports what was actually freed.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]] $File,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Root,

        [Parameter(Mandatory)]
        [long] $TotalByte
    )

    $skeleton = [pscustomobject]@{
        ItemsRemoved = 0
        BytesFreed   = 0L
        ItemsSkipped = 0
        BytesSkipped = 0L
        Reason       = $null
        Performed    = $false
    }

    if ($File.Count -eq 0) { return $skeleton }

    $operation = 'Delete {0:N0} file(s) totalling {1}' -f $File.Count, (Format-ByteSize -Byte $TotalByte)
    if (-not $PSCmdlet.ShouldProcess($Root, $operation)) { return $skeleton }

    $removed = 0
    $freed = 0L
    $skipped = 0
    $skippedByte = 0L
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
            $skippedByte += $item.Length
            if ($null -eq $firstReason) { $firstReason = $_.Exception.Message }
            Write-Verbose -Message "Could not remove '$($item.FullName)': $($_.Exception.Message)"
        }
    }

    return [pscustomobject]@{
        ItemsRemoved = $removed
        BytesFreed   = $freed
        ItemsSkipped = $skipped
        BytesSkipped = $skippedByte
        Reason       = $firstReason
        Performed    = $true
    }
}

function Remove-EmptyDirectory {
    <#
    .SYNOPSIS
        Removes subdirectories of a root that are empty, deepest first.
    .DESCRIPTION
        The root itself is never removed, and directories that are reparse points
        are left alone so a junction is never followed or deleted.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Root
    )

    $prefix = $Root.TrimEnd('\') + '\'
    $removed = 0

    # Same reasoning as the file pass: a -Recurse walk would enter a junction
    # and offer the directories inside it for removal, and filtering reparse
    # points out of the results does not undo having descended into one.
    $directory = @(Get-SafeDescendant -Root $Root -Kind Directory) |
        Where-Object {
            $_.FullName.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)
        } |
        Sort-Object -Property { $_.FullName.Length } -Descending

    foreach ($item in $directory) {
        $child = @(Get-ChildItem -LiteralPath $item.FullName -Force -ErrorAction SilentlyContinue)
        if ($child.Count -gt 0) { continue }
        if (-not $PSCmdlet.ShouldProcess($item.FullName, 'Remove empty directory')) { continue }
        try {
            Remove-Item -LiteralPath $item.FullName -Force -ErrorAction Stop
            $removed++
            Write-Verbose -Message "Removed empty directory: $($item.FullName)"
        }
        catch {
            Write-Verbose -Message "Could not remove directory '$($item.FullName)': $($_.Exception.Message)"
        }
    }

    return $removed
}

function Clear-RecycleBinContent {
    <#
    .SYNOPSIS
        Empties the Recycle Bin on every drive, gated by ShouldProcess.
    .DESCRIPTION
        Clear-RecycleBin has its own confirmation prompt, suppressed here because
        this function has already asked. No size is reported: the shell exposes no
        supported way to size the bin before emptying it.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType([string])]
    param()

    if (-not (Get-Command -Name 'Clear-RecycleBin' -ErrorAction SilentlyContinue)) {
        Write-Warning -Message 'Clear-RecycleBin is not available on this system; skipping the Recycle Bin.'
        return 'Unavailable'
    }

    if (-not $PSCmdlet.ShouldProcess('Recycle Bin (all drives)', 'Permanently delete all contents')) {
        return 'Skipped'
    }

    try {
        Clear-RecycleBin -Force -Confirm:$false -ErrorAction Stop
        Write-Information -MessageData 'Recycle Bin emptied.'
        return 'Emptied'
    }
    catch {
        # An already-empty bin raises a non-fatal error on some Windows builds.
        Write-Warning -Message "Recycle Bin was not emptied: $($_.Exception.Message)"
        return 'Failed'
    }
}

function Invoke-CleanDisk {
    <#
    .SYNOPSIS
        Cleans every requested directory and emits one result object per root.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string[]] $RequestedPath,

        [Parameter(Mandatory)]
        [int] $AgeHour,

        [Parameter(Mandatory)]
        [bool] $PruneEmptyDirectory
    )

    $seen = [System.Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase)

    foreach ($candidate in $RequestedPath) {
        $root = Resolve-CleanTarget -Candidate $candidate
        if ([string]::IsNullOrWhiteSpace($root)) { continue }
        if (-not $seen.Add($root)) {
            Write-Verbose -Message "Already handled, skipping duplicate: $root"
            continue
        }

        Write-Information -MessageData "Scanning $root (files older than $AgeHour hour(s))..."
        $scan = Get-CleanCandidate -Root $root -AgeHour $AgeHour
        $found = $scan.File.Count

        if ($scan.UnreadableCount -gt 0) {
            Write-Warning -Message "$root : $($scan.UnreadableCount) path(s) could not be enumerated (in use or access denied)."
        }
        if ($scan.TooNewCount -gt 0) {
            Write-Information -MessageData ("$root : {0:N0} file(s) kept for being newer than $AgeHour hour(s)." -f $scan.TooNewCount)
        }
        Write-Information -MessageData ("$root : {0:N0} file(s) eligible, {1}." -f $found, (Format-ByteSize -Byte $scan.ByteCount))

        $result = Remove-CleanCandidate -File $scan.File -Root $root -TotalByte $scan.ByteCount

        $status = 'Success'
        if ($found -gt 0 -and -not $result.Performed) {
            $status = 'Skipped'
        }
        elseif ($result.ItemsSkipped -gt 0) {
            $status = 'Partial'
            Write-Warning -Message ("$root : {0:N0} file(s) ({1}) could not be removed. First reason: {2}" -f `
                    $result.ItemsSkipped, (Format-ByteSize -Byte $result.BytesSkipped), $result.Reason)
        }

        $directoryRemoved = 0
        if ($PruneEmptyDirectory -and $result.Performed) {
            $directoryRemoved = Remove-EmptyDirectory -Root $root
        }

        if ($result.Performed) {
            Write-Information -MessageData ("$root : freed {0} across {1:N0} file(s); removed {2:N0} empty directory(ies)." -f `
                (Format-ByteSize -Byte $result.BytesFreed), $result.ItemsRemoved, $directoryRemoved)
        }
        else {
            Write-Information -MessageData ("$root : would free {0} across {1:N0} file(s)." -f `
                (Format-ByteSize -Byte $scan.ByteCount), $found)
        }

        [pscustomobject]@{
            Path               = $root
            ItemCount          = $found
            ByteCount          = $scan.ByteCount
            ItemsRemoved       = $result.ItemsRemoved
            BytesFreed         = $result.BytesFreed
            ItemsSkipped       = $result.ItemsSkipped
            BytesSkipped       = $result.BytesSkipped
            DirectoriesRemoved = $directoryRemoved
            UnreadablePath     = $scan.UnreadableCount
            Status             = $status
        }
    }
}

function Start-CleanDisk {
    <#
    .SYNOPSIS
        Entry point. Resolves options, runs the clean and prints the summary.
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
        Write-Error -Message ("Unknown argument(s): {0}. Run 'Get-Help .\Clean-Disk.ps1 -Full' for the parameters this script accepts." -f `
            ($ExtraArgument -join ' ')) -ErrorAction Continue
        $script:ExitCode = 2
        return
    }

    $forced = $false
    $includeBin = $false
    $keepEmpty = $false
    $ageHour = 0
    try {
        $forced = Resolve-BooleanSetting -Name 'Force' -Switch:$Force `
            -EnvironmentName 'LZC_CLEAN_DISK_FORCE'
        $includeBin = Resolve-BooleanSetting -Name 'IncludeRecycleBin' `
            -Switch:$IncludeRecycleBin -EnvironmentName 'LZC_CLEAN_DISK_INCLUDE_RECYCLE_BIN'
        $keepEmpty = Resolve-BooleanSetting -Name 'KeepEmptyDirectory' `
            -Switch:$KeepEmptyDirectory -EnvironmentName 'LZC_CLEAN_DISK_KEEP_EMPTY_DIR'
        $ageHour = Resolve-IntegerSetting -Name 'MinimumAgeHours' -Value $MinimumAgeHours `
            -EnvironmentName 'LZC_CLEAN_DISK_MIN_AGE_HOURS' -Default 24 -Minimum 0 -Maximum 87600
    }
    catch [ArgumentException] {
        Write-Error -Message $_.Exception.Message -ErrorAction Continue
        $script:ExitCode = 2
        return
    }

    $requested = @()
    if ($ScriptBoundParameter.ContainsKey('Path')) {
        $requested = @($Path)
    }
    elseif (-not [string]::IsNullOrWhiteSpace($env:LZC_CLEAN_DISK_PATHS)) {
        $requested = @($env:LZC_CLEAN_DISK_PATHS -split ';')
    }
    else {
        $requested = @((Join-Path -Path $env:SystemRoot -ChildPath 'Temp'), $env:TEMP)
    }
    $requested = @($requested | Where-Object { $_ -and $_.Trim() })

    if ($requested.Count -eq 0) {
        Write-Error -Message 'No directory was supplied. Use -Path or set LZC_CLEAN_DISK_PATHS.' -ErrorAction Continue
        $script:ExitCode = 2
        return
    }

    # --- Platform and prerequisites (exit 3) ---------------------------------
    if (-not (Test-WindowsHost)) {
        Write-Error -Message 'This script cleans Windows temp directories and only runs on Windows.' -ErrorAction Continue
        $script:ExitCode = 3
        return
    }
    if ($PSVersionTable.PSVersion -lt [version]'5.1') {
        Write-Error -Message "PowerShell 5.1 or newer is required; this host is $($PSVersionTable.PSVersion)." -ErrorAction Continue
        $script:ExitCode = 3
        return
    }

    # --- Elevation (exit 4) --------------------------------------------------
    # Required even for -WhatIf: without it the machine temp directory cannot be
    # enumerated, so the dry run would under-report what it would delete.
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

    # --- Confirmation (exit 5) -----------------------------------------------
    # -WhatIf changes nothing and never prompts, so it is always allowed.
    $willChange = -not $WhatIfPreference

    if ($willChange -and $ConfirmPreference -ne 'None' -and -not (Test-InteractiveHost)) {
        Write-Error -Message 'Refused: deleting files needs confirmation, there is no terminal to confirm on, and -Force was not given. Re-run with -Force (or set LZC_CLEAN_DISK_FORCE=1), or preview with -WhatIf.' -ErrorAction Continue
        $script:ExitCode = 5
        return
    }

    # --- Lock (exit 75) ------------------------------------------------------
    # Only a run that will delete something takes the lock, so a -WhatIf preview
    # is never blocked by a real run in progress.
    if ($willChange) {
        $script:ScriptLock = Enter-ScriptLock -Name $ScriptLockName
        if ($null -eq $script:ScriptLock) {
            Write-Error -Message "Another instance is already running (lock: Global\$ScriptLockName). Try again later." -ErrorAction Continue
            $script:ExitCode = 75
            return
        }
    }

    $result = @(Invoke-CleanDisk -RequestedPath $requested -AgeHour $ageHour `
            -PruneEmptyDirectory (-not $keepEmpty))

    if ($result.Count -eq 0) {
        Write-Error -Message 'None of the supplied paths was a usable directory. Nothing was cleaned.' -ErrorAction Continue
        $script:ExitCode = 2
        return
    }

    if ($includeBin) {
        $null = Clear-RecycleBinContent
    }

    $totalFreed = [long](($result | Measure-Object -Property BytesFreed -Sum).Sum)
    $totalFound = [long](($result | Measure-Object -Property ByteCount -Sum).Sum)
    $totalSkipped = [int](($result | Measure-Object -Property ItemsSkipped -Sum).Sum)

    if ($WhatIfPreference) {
        Write-Information -MessageData ('Dry run: would free {0} in total. Nothing was changed.' -f `
            (Format-ByteSize -Byte $totalFound))
    }
    else {
        Write-Information -MessageData ('Total freed: {0}. Files that could not be removed: {1:N0}.' -f `
            (Format-ByteSize -Byte $totalFreed), $totalSkipped)
    }

    if (@($result | Where-Object { $_.Status -eq 'Partial' }).Count -gt 0) {
        $script:ExitCode = 1
    }

    foreach ($item in $result) { $item }
}

try {
    Start-CleanDisk
}
catch [System.Management.Automation.PipelineStoppedException] {
    # Ctrl-C, or a caller stopping the pipeline.
    Write-Warning -Message 'Interrupted. Files already deleted stay deleted; nothing is half-written.'
    $ExitCode = 130
}
catch [System.OperationCanceledException] {
    Write-Warning -Message 'Cancelled. Files already deleted stay deleted; nothing is half-written.'
    $ExitCode = 130
}
finally {
    Exit-ScriptLock -Mutex $ScriptLock
}

exit $ExitCode
