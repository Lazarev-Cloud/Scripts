<#
.SYNOPSIS
    Repairs the Windows component store with DISM, then repairs protected system
    files with SFC, and reports the real exit codes and log paths.

.DESCRIPTION
    Runs the servicing tools in the order Microsoft documents:

      1. DISM /Online /Cleanup-Image /RestoreHealth   repairs the component store
      2. sfc.exe /scannow                             repairs protected system
                                                      files FROM that store

    The order matters and is the defect this script exists to avoid. SFC replaces
    damaged system files with copies taken from the component store, so if the
    store itself is damaged, SFC has nothing good to copy from. Running SFC first,
    or running SFC alone, is the most common mistake in Windows repair scripts.

    Blast radius: DISM /RestoreHealth rewrites files inside the component store
    ($env:SystemRoot\WinSxS) and may download replacement payloads from Windows
    Update. SFC /scannow replaces protected system files. Both are Microsoft's own
    repair tools and both are designed to be safe to re-run, but they are not
    read-only. Use -Stage Check or -Stage Scan for a read-only assessment first.

    Deliberately NOT done:
      * /StartComponentCleanup /ResetBase is never run. Microsoft's own warning:
        "All existing update packages can't be uninstalled after this command is
        completed." That permanently removes your ability to roll back every
        currently installed update, including one that just broke the machine.
        It has no place in a repair script.
      * Nothing is deleted from WinSxS directly. Microsoft: deleting files from
        the WinSxS folder "may severely damage your system".
      * SFC is not run repeatedly. One pass after a successful DISM RestoreHealth
        is the documented procedure. A second pass is only warranted when the
        first reported corruption it could not fix.
      * chkdsk is not run. It is a response to observed disk corruption, not
        maintenance, and /r can take hours.

    Tool exit-code handling (this is about what DISM and SFC return, not about
    what this script returns; for that see the exit-code table in NOTES):
      * DISM: 0 is success and 3010 means success plus reboot required. Both are
        treated as success. A pending restart is reported in the result object's
        Status property, never as a bespoke process exit code.
      * A read-only stage (Check or Scan) that reports "the component store is
        repairable" has found corruption and repaired nothing, so it exits 1, not
        0. DISM returns 0 for any scan that completed; taking that as a clean
        result would be a health claim the scan never made.
      * SFC: sfc.exe has NO documented exit-code contract. This script therefore
        never concludes "your system is clean" from an exit code. It parses the
        console text into an explicit verdict, and reports Unknown rather than
        guessing when no known phrase matches.

    Every environment variable a user may set is named LZC_REPAIRSYSTEMFILES_*,
    so `Get-ChildItem env:LZC_*` shows everything configurable in this
    repository. A variable is consulted only when the matching parameter is not
    passed, and an unusable value is a usage error (exit 2) rather than a silent
    default.

.PARAMETER Stage
    Check    DISM /CheckHealth. Read-only and fast. Reports whether corruption has
             already been flagged; does not scan.
    Scan     DISM /ScanHealth. Read-only, slow. Scans the store for corruption.
    Repair   DISM /RestoreHealth then sfc /scannow. The default. State-changing.
    Environment variable: LZC_REPAIRSYSTEMFILES_STAGE.

.PARAMETER Source
    Path to a known-good source for DISM, such as an extracted install.wim mount
    ("D:\mount\Windows") or a WIM ("WIM:D:\sources\install.wim:1"). Use this when
    Windows Update is unreachable or itself broken. Implies /LimitAccess, so DISM
    will not contact Windows Update. Environment variable:
    LZC_REPAIRSYSTEMFILES_SOURCE.

.PARAMETER SkipDism
    Skip the DISM stage and run SFC only. Off by default, and rarely correct: it
    reintroduces the ordering problem this script exists to solve. Environment
    variable: LZC_REPAIRSYSTEMFILES_SKIP_DISM
    (1, true, yes, on / 0, false, no, off).

.PARAMETER SkipSfc
    Skip the SFC stage and run DISM only. Environment variable:
    LZC_REPAIRSYSTEMFILES_SKIP_SFC (1, true, yes, on / 0, false, no, off).

.PARAMETER TimeoutMinutes
    Wall-clock limit for each tool invocation separately -- DISM and SFC each get
    the full allowance, so a Repair stage can take twice this long. Defaults to
    120, which is generous for DISM /RestoreHealth on a slow disk; accepted range
    1 to 1440. There is no "wait forever" value: an unbounded DISM is exactly the
    hang the bound exists to prevent. On timeout the tool is terminated and the
    run is reported as failed. Terminating DISM mid-repair can leave a pending
    servicing operation; the fix is to reboot and re-run, which the script tells
    you. A zero-padded value such as 08 is read as decimal 8. Environment
    variable: LZC_REPAIRSYSTEMFILES_TIMEOUT_MINUTES.

.PARAMETER Force
    Suppress confirmation prompts, for scheduled and unattended runs. -WhatIf
    still takes precedence over -Force. Environment variable:
    LZC_REPAIRSYSTEMFILES_FORCE (1, true, yes, on / 0, false, no, off).

.PARAMETER ExtraArgument
    Collects anything that is not a parameter of this script. Passing something
    here is a typo, so the run stops with exit code 2 and names what it did not
    understand. Do not pass it deliberately.

.EXAMPLE
    PS> .\RepairSystemFiles.ps1 -Stage Scan

    Read-only assessment. Reports whether the component store is repairable
    without changing anything.

.EXAMPLE
    PS> .\RepairSystemFiles.ps1 -WhatIf

    Shows exactly which commands the default Repair stage would run, in order,
    and executes none of them.

.EXAMPLE
    PS> .\RepairSystemFiles.ps1 -Force -Verbose

    Unattended repair: DISM /RestoreHealth then sfc /scannow.

.EXAMPLE
    PS> .\RepairSystemFiles.ps1 -Source 'WIM:D:\sources\install.wim:1' -Force

    Repairs from a local WIM instead of Windows Update. Useful on a machine whose
    update client is the thing that is broken.

.INPUTS
    None. This script does not accept pipeline input.

.OUTPUTS
    System.Management.Automation.PSCustomObject, one per tool that ran, with
    Tool, Operation, CommandLine, ExitCode, Verdict, DurationSeconds, LogPath and
    Status properties.

.NOTES
    Exit codes (the repository-wide table; every script in this repository uses
    the same numbers):
      0     success: every stage that ran reported success and no corruption
            remains. A pending restart is still exit 0 -- read the Status
            property of the result objects, which reports RebootRequired
      1     the work ran but something in it failed: a tool failed, timed out,
            reported corruption it could not repair, or produced output this
            script could not classify
      2     usage error: an unknown argument, or a parameter or
            LZC_REPAIRSYSTEMFILES_* value that is missing or invalid (including
            a -Source that does not exist, and -SkipDism with -SkipSfc)
      3     unsupported platform or missing prerequisite (not Windows,
            PowerShell older than 5.1, or Dism.exe/sfc.exe not present)
      4     not running as Administrator
      5     refused: the run needs confirmation, there is no terminal to confirm
            on, and neither -Force nor -Confirm:$false was given
      75    another instance holds the lock Global\lzc-repairsystemfiles
            (EX_TEMPFAIL, so cron and scheduled tasks treat it as "retry later")
      130   interrupted (Ctrl-C or cancellation)

    Checks run in that order with one deliberate exception: arguments and
    settings are validated BEFORE the elevation check, so a typo is discoverable
    from an ordinary shell without an elevated one.

    A pending restart is NOT signalled with a bespoke exit code. Deployment tools
    that key on 3010 must read the result objects instead: any object whose
    Status is RebootRequired means a restart finishes the work.

    Log files, which hold far more detail than the console:
      $env:SystemRoot\Logs\CBS\CBS.log     SFC and servicing detail
      $env:SystemRoot\Logs\DISM\dism.log   DISM detail
    To read just the SFC findings:
      findstr /c:"[SR]" %windir%\Logs\CBS\CBS.log > "%userprofile%\Desktop\sfc.txt"

    Verdict parsing matches the ENGLISH console strings that SFC and DISM emit.
    On a non-English Windows the tools still run correctly and the exit code is
    still reported accurately, but the verdicts degrade differently:

      * SFC has no exit-code fallback, so an unmatched verdict is Unknown, which
        maps to exit 1. An unreadable SFC outcome is never taken as healthy.
      * DISM does have an exit-code contract, so unmatched output with exit code 0
        falls back to Completed, not Unknown. The consequence is that a read-only
        -Stage Check or -Stage Scan on a localized Windows CANNOT detect "the
        component store is repairable" and will report Success and exit 0 even
        when corruption was found. Do not read exit 0 from a localized read-only
        scan as a clean store; read dism.log, or run -Stage Repair, which repairs
        regardless of the console language.

    This script emits no colour of its own; the host renders the information,
    warning and error streams. NO_COLOR (https://no-color.org, any non-empty
    value) is honoured: on PowerShell 7 it forces $PSStyle.OutputRendering to
    PlainText for the run, and Windows PowerShell 5.1 renders those streams
    without ANSI sequences already.

    Scheduled task invocation (use -File, never -Command):
      powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass
        -File "C:\path\RepairSystemFiles.ps1" -Force

    License: MIT
    Origin:  https://github.com/Lazarev-Cloud/Scripts

.LINK
    https://github.com/Lazarev-Cloud/Scripts

.LINK
    https://support.microsoft.com/en-us/topic/use-the-system-file-checker-tool-to-repair-missing-or-corrupted-system-files-79aa86cb-ca52-166a-92a3-966e85d4094e

.LINK
    https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/clean-up-the-winsxs-folder
#>

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
[OutputType([pscustomobject])]
param(
    # Values are deliberately NOT resolved from the environment here, and carry
    # no ValidateRange/ValidateSet attributes. A failure inside the parameter
    # binder ends the process with exit code 1 before a single line of this
    # script runs, which would make the documented exit-code table a lie. Every
    # value is therefore validated in Start-SystemFileRepair, which can report a
    # clear message and exit 2. ArgumentCompleter keeps tab-completion for
    # -Stage without handing the binder a value it can reject.
    [Parameter(Position = 0)]
    [ArgumentCompleter({ 'Check', 'Scan', 'Repair' })]
    [AllowEmptyString()]
    [string] $Stage = '',

    [Parameter()]
    [AllowEmptyString()]
    [string] $Source = '',

    [Parameter()]
    [switch] $SkipDism,

    [Parameter()]
    [switch] $SkipSfc,

    [Parameter()]
    [AllowEmptyString()]
    [string] $TimeoutMinutes = '',

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
$ScriptLockName = 'lzc-repairsystemfiles'
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

function Resolve-ChoiceSetting {
    <#
    .SYNOPSIS
        Resolves a parameter that accepts a fixed set of words, then the
        environment variable, then the documented default.
    .DESCRIPTION
        Matching is case-insensitive and the canonical spelling is returned, so
        'repair' and 'REPAIR' both come back as 'Repair'.
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

function Get-ToolPath {
    <#
    .SYNOPSIS
        Returns the absolute path to a System32 executable, or nothing.
    .DESCRIPTION
        Always absolute, never a bare name: PATH is influenceable and differs
        between Windows PowerShell and PowerShell 7.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $FileName
    )

    $candidate = Join-Path -Path (Join-Path -Path $env:SystemRoot -ChildPath 'System32') -ChildPath $FileName
    if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }

    Write-Warning -Message "Executable not found: $candidate"
    return
}

function ConvertFrom-ConsoleOutput {
    <#
    .SYNOPSIS
        Reads a redirected console capture into plain text.
    .DESCRIPTION
        sfc.exe writes UTF-16LE when its output is redirected, DISM writes 8-bit
        text. Reading raw and stripping NUL bytes yields correct ASCII from both
        without having to guess the encoding per tool.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $LiteralPath
    )

    if (-not (Test-Path -LiteralPath $LiteralPath -PathType Leaf)) { return '' }

    $raw = Get-Content -LiteralPath $LiteralPath -Raw -ErrorAction SilentlyContinue
    if ([string]::IsNullOrEmpty($raw)) { return '' }

    return ($raw -replace "`0", '' -replace "`r", '')
}

function Invoke-NativeTool {
    <#
    .SYNOPSIS
        Runs a native executable under a ShouldProcess gate, with a bounded wait
        and explicit exit-code checking.
    .DESCRIPTION
        try/catch does not catch a native program's failure, so the exit code is
        read explicitly. -WhatIf does not reach a native program either, which is
        why the ShouldProcess gate is here rather than around the caller.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $FilePath,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string[]] $ArgumentList,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Target,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Operation,

        [Parameter(Mandatory)]
        [ValidateRange(0, 1440)]
        [int] $TimeoutMinute
    )

    $commandLine = '{0} {1}' -f $FilePath, ($ArgumentList -join ' ')

    if (-not $PSCmdlet.ShouldProcess($Target, "$Operation :: $commandLine")) {
        return [pscustomobject]@{
            CommandLine     = $commandLine
            ExitCode        = $null
            Output          = ''
            DurationSeconds = 0
            TimedOut        = $false
            Started         = $false
        }
    }

    $stdoutFile = [IO.Path]::GetTempFileName()
    $stderrFile = [IO.Path]::GetTempFileName()
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    $timedOut = $false
    $exitCode = $null

    try {
        Write-Information -MessageData "Running: $commandLine"
        $process = Start-Process -FilePath $FilePath -ArgumentList $ArgumentList `
            -NoNewWindow -PassThru `
            -RedirectStandardOutput $stdoutFile -RedirectStandardError $stderrFile

        # Touching .Handle caches the process handle, without which .ExitCode can
        # come back null after a timed WaitForExit.
        $null = $process.Handle

        if ($TimeoutMinute -gt 0) {
            if (-not $process.WaitForExit([int]([TimeSpan]::FromMinutes($TimeoutMinute).TotalMilliseconds))) {
                $timedOut = $true
                Write-Warning -Message "$Operation exceeded $TimeoutMinute minute(s); terminating it."
                try { $process.Kill() } catch { Write-Warning -Message "Could not terminate the process: $($_.Exception.Message)" }
                $null = $process.WaitForExit(30000)
            }
        }
        else {
            $process.WaitForExit()
        }

        if (-not $timedOut) { $exitCode = $process.ExitCode }
        $stopwatch.Stop()

        $output = ConvertFrom-ConsoleOutput -LiteralPath $stdoutFile
        $errorText = ConvertFrom-ConsoleOutput -LiteralPath $stderrFile
        if (-not [string]::IsNullOrWhiteSpace($errorText)) {
            $output = $output + [Environment]::NewLine + $errorText
        }

        foreach ($line in ($output -split "`n")) {
            if (-not [string]::IsNullOrWhiteSpace($line)) { Write-Verbose -Message $line.Trim() }
        }

        return [pscustomobject]@{
            CommandLine     = $commandLine
            ExitCode        = $exitCode
            Output          = $output
            DurationSeconds = [Math]::Round($stopwatch.Elapsed.TotalSeconds, 1)
            TimedOut        = $timedOut
            Started         = $true
        }
    }
    finally {
        Remove-Item -LiteralPath $stdoutFile, $stderrFile -Force -ErrorAction SilentlyContinue
    }
}

function Get-DismVerdict {
    <#
    .SYNOPSIS
        Turns DISM console output plus its exit code into an explicit verdict.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Text,

        [Parameter()]
        [AllowNull()]
        [object] $ExitCode
    )

    switch -Regex ($Text) {
        'No component store corruption detected' { return 'NoCorruption' }
        'The component store is repairable' { return 'Repairable' }
        'The restore operation completed successfully' { return 'Repaired' }
        'The component store corruption was repaired' { return 'Repaired' }
        'source files could not be found' { return 'SourceMissing' }
        '0x800f081f' { return 'SourceMissing' }
        'The operation completed successfully' { return 'Completed' }
    }

    if ($null -ne $ExitCode -and [int]$ExitCode -eq 0) { return 'Completed' }
    return 'Unknown'
}

function Get-SfcVerdict {
    <#
    .SYNOPSIS
        Turns SFC console output into an explicit verdict.
    .DESCRIPTION
        sfc.exe has no documented exit-code contract, so the exit code is never
        used to decide this. Unknown is returned rather than a guess.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Text
    )

    switch -Regex ($Text) {
        'did not find any integrity violations' { return 'Clean' }
        'found corrupt files and successfully repaired them' { return 'Repaired' }
        'found corrupt files but was unable to fix some' { return 'RepairFailed' }
        'could not perform the requested operation' { return 'ScanFailed' }
        'There is a system repair pending' { return 'RebootRequired' }
        'must have administrative privileges' { return 'NotElevated' }
    }

    return 'Unknown'
}

function Invoke-DismStage {
    <#
    .SYNOPSIS
        Runs one DISM /Cleanup-Image operation and reports a result object.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('CheckHealth', 'ScanHealth', 'RestoreHealth')]
        [string] $Operation,

        [Parameter(Mandatory)]
        [ValidateRange(0, 1440)]
        [int] $TimeoutMinute,

        [Parameter()]
        [AllowEmptyString()]
        [string] $SourcePath = ''
    )

    $dism = Get-ToolPath -FileName 'Dism.exe'
    if ([string]::IsNullOrWhiteSpace($dism)) { return }

    $argument = @('/Online', '/Cleanup-Image', "/$Operation")
    if (-not [string]::IsNullOrWhiteSpace($SourcePath)) {
        # Start-Process joins ArgumentList entries with spaces and does not quote
        # them, so a source path containing a space has to be quoted here.
        $quoted = if ($SourcePath -match '\s') { '"{0}"' -f $SourcePath } else { $SourcePath }
        # /LimitAccess stops DISM falling back to Windows Update, which is the
        # whole point of naming an explicit source.
        $argument += "/Source:$quoted"
        $argument += '/LimitAccess'
    }

    $run = Invoke-NativeTool -FilePath $dism -ArgumentList $argument `
        -Target 'Windows component store' -Operation "DISM $Operation" `
        -TimeoutMinute $TimeoutMinute

    $dismLog = Join-Path -Path $env:SystemRoot -ChildPath 'Logs\DISM\dism.log'

    if (-not $run.Started) {
        return [pscustomobject]@{
            Tool            = 'DISM'
            Operation       = $Operation
            CommandLine     = $run.CommandLine
            ExitCode        = $null
            Verdict         = 'Skipped'
            DurationSeconds = 0
            LogPath         = $dismLog
            Status          = 'Skipped'
        }
    }

    if ($run.TimedOut) {
        Write-Warning -Message "DISM $Operation was terminated after $TimeoutMinute minute(s). Reboot and re-run; check $dismLog."
        return [pscustomobject]@{
            Tool            = 'DISM'
            Operation       = $Operation
            CommandLine     = $run.CommandLine
            ExitCode        = $null
            Verdict         = 'TimedOut'
            DurationSeconds = $run.DurationSeconds
            LogPath         = $dismLog
            Status          = 'Failed'
        }
    }

    $verdict = Get-DismVerdict -Text $run.Output -ExitCode $run.ExitCode

    # CheckHealth and ScanHealth are read-only, so "the component store is
    # repairable" from either of them means corruption was found AND still
    # remains. DISM returns exit code 0 for a scan that completed, so trusting
    # the exit code alone would report Success and exit 0 -- a clean bill of
    # health the scan never gave. Only the read-only operations are treated this
    # way: Get-DismVerdict returns the first phrase that matches, and a
    # successful RestoreHealth capture can carry the "repairable" line ahead of
    # its own success line, so applying this to RestoreHealth would turn a real
    # repair into a failure.
    $corruptionRemains = ($verdict -eq 'Repairable') -and ($Operation -in @('CheckHealth', 'ScanHealth'))

    # 0 is success. 3010 is success plus "restart required" and must not be
    # treated as a failure. A null exit code means the code could not be read at
    # all, which is a failure, not a silent zero.
    $success = ($null -ne $run.ExitCode) -and (@(0, 3010) -contains [int]$run.ExitCode)
    $status = if (-not $success) { 'Failed' }
    elseif ($corruptionRemains) { 'Failed' }
    elseif ([int]$run.ExitCode -eq 3010) { 'RebootRequired' }
    elseif ($verdict -eq 'SourceMissing') { 'Failed' }
    else { 'Success' }

    if ($corruptionRemains) {
        Write-Warning -Message "DISM $Operation found component store corruption. The store is repairable, but $Operation is read-only and repaired nothing."
        Write-Warning -Message "Re-run with -Stage Repair to fix it. Detail: $dismLog"
    }
    elseif ($status -eq 'Failed') {
        Write-Warning -Message "DISM $Operation exited with code $($run.ExitCode) (verdict: $verdict). Detail: $dismLog"
        if ($verdict -eq 'SourceMissing') {
            Write-Warning -Message 'DISM could not obtain replacement files. Supply a known-good image with -Source.'
        }
    }
    else {
        Write-Information -MessageData "DISM $Operation : exit code $($run.ExitCode), verdict $verdict, $($run.DurationSeconds)s."
    }

    return [pscustomobject]@{
        Tool            = 'DISM'
        Operation       = $Operation
        CommandLine     = $run.CommandLine
        ExitCode        = $run.ExitCode
        Verdict         = $verdict
        DurationSeconds = $run.DurationSeconds
        LogPath         = $dismLog
        Status          = $status
    }
}

function Invoke-SfcStage {
    <#
    .SYNOPSIS
        Runs sfc /scannow and reports a result object with a parsed verdict.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateRange(0, 1440)]
        [int] $TimeoutMinute
    )

    $sfc = Get-ToolPath -FileName 'sfc.exe'
    if ([string]::IsNullOrWhiteSpace($sfc)) { return }

    $run = Invoke-NativeTool -FilePath $sfc -ArgumentList @('/scannow') `
        -Target 'Protected system files' -Operation 'SFC scan' `
        -TimeoutMinute $TimeoutMinute

    $cbsLog = Join-Path -Path $env:SystemRoot -ChildPath 'Logs\CBS\CBS.log'

    if (-not $run.Started) {
        return [pscustomobject]@{
            Tool            = 'SFC'
            Operation       = 'scannow'
            CommandLine     = $run.CommandLine
            ExitCode        = $null
            Verdict         = 'Skipped'
            DurationSeconds = 0
            LogPath         = $cbsLog
            Status          = 'Skipped'
        }
    }

    if ($run.TimedOut) {
        Write-Warning -Message "SFC was terminated after $TimeoutMinute minute(s). Reboot and re-run; check $cbsLog."
        return [pscustomobject]@{
            Tool            = 'SFC'
            Operation       = 'scannow'
            CommandLine     = $run.CommandLine
            ExitCode        = $null
            Verdict         = 'TimedOut'
            DurationSeconds = $run.DurationSeconds
            LogPath         = $cbsLog
            Status          = 'Failed'
        }
    }

    $verdict = Get-SfcVerdict -Text $run.Output
    $status = switch ($verdict) {
        'Clean' { 'Success' }
        'Repaired' { 'Success' }
        'RebootRequired' { 'RebootRequired' }
        'RepairFailed' { 'Failed' }
        'ScanFailed' { 'Failed' }
        'NotElevated' { 'Failed' }
        default { 'Unknown' }
    }

    switch ($verdict) {
        'Clean' { Write-Information -MessageData 'SFC found no integrity violations.' }
        'Repaired' { Write-Information -MessageData "SFC repaired corrupt files. Detail: $cbsLog" }
        'RepairFailed' {
            Write-Warning -Message "SFC found corruption it could not repair. Detail: $cbsLog"
            Write-Warning -Message 'Re-run DISM /RestoreHealth (add -Source if Windows Update cannot supply the files), then run SFC again.'
        }
        'RebootRequired' { Write-Warning -Message 'A system repair is already pending. Reboot, then re-run this script.' }
        'ScanFailed' { Write-Warning -Message "SFC could not complete the scan. Detail: $cbsLog" }
        default {
            Write-Warning -Message "SFC exited with code $($run.ExitCode) but its output matched no known result phrase."
            Write-Warning -Message "sfc.exe has no documented exit-code contract, so no conclusion is drawn. Read: $cbsLog"
            Write-Warning -Message 'Extract just the SFC findings with: findstr /c:"[SR]" %windir%\Logs\CBS\CBS.log'
        }
    }

    return [pscustomobject]@{
        Tool            = 'SFC'
        Operation       = 'scannow'
        CommandLine     = $run.CommandLine
        ExitCode        = $run.ExitCode
        Verdict         = $verdict
        DurationSeconds = $run.DurationSeconds
        LogPath         = $cbsLog
        Status          = $status
    }
}

function Start-SystemFileRepair {
    <#
    .SYNOPSIS
        Entry point. Runs the requested stage in the documented order.
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
        Write-Error -Message ("Unknown argument(s): {0}. Run 'Get-Help .\RepairSystemFiles.ps1 -Full' for the parameters this script accepts." -f `
            ($ExtraArgument -join ' ')) -ErrorAction Continue
        $script:ExitCode = 2
        return
    }

    $forced = $false
    $noDism = $false
    $noSfc = $false
    $stageName = 'Repair'
    $timeoutMinute = 120
    try {
        $forced = Resolve-BooleanSetting -Name 'Force' -Switch:$Force `
            -EnvironmentName 'LZC_REPAIRSYSTEMFILES_FORCE'
        $noDism = Resolve-BooleanSetting -Name 'SkipDism' -Switch:$SkipDism `
            -EnvironmentName 'LZC_REPAIRSYSTEMFILES_SKIP_DISM'
        $noSfc = Resolve-BooleanSetting -Name 'SkipSfc' -Switch:$SkipSfc `
            -EnvironmentName 'LZC_REPAIRSYSTEMFILES_SKIP_SFC'
        $stageName = Resolve-ChoiceSetting -Name 'Stage' -Value $Stage `
            -EnvironmentName 'LZC_REPAIRSYSTEMFILES_STAGE' `
            -Allowed @('Check', 'Scan', 'Repair') -Default 'Repair'
        # Minimum 1 minute: there is no "no limit" value. An unbounded DISM is
        # the hang this bound exists to prevent, and a bound of 0 would remove
        # the protection while looking like a setting.
        $timeoutMinute = Resolve-IntegerSetting -Name 'TimeoutMinutes' -Value $TimeoutMinutes `
            -EnvironmentName 'LZC_REPAIRSYSTEMFILES_TIMEOUT_MINUTES' -Default 120 -Minimum 1 -Maximum 1440
    }
    catch [ArgumentException] {
        Write-Error -Message $_.Exception.Message -ErrorAction Continue
        $script:ExitCode = 2
        return
    }

    $sourcePath = ''
    if ($ScriptBoundParameter.ContainsKey('Source')) { $sourcePath = $Source }
    elseif (-not [string]::IsNullOrWhiteSpace($env:LZC_REPAIRSYSTEMFILES_SOURCE)) {
        $sourcePath = $env:LZC_REPAIRSYSTEMFILES_SOURCE
    }

    if ($noDism -and $noSfc) {
        Write-Error -Message 'Both -SkipDism and -SkipSfc were given, which leaves nothing to run.' -ErrorAction Continue
        $script:ExitCode = 2
        return
    }

    if (-not [string]::IsNullOrWhiteSpace($sourcePath) -and $sourcePath -notmatch '^WIM:' -and
        -not (Test-Path -LiteralPath $sourcePath)) {
        Write-Error -Message "-Source '$sourcePath' does not exist. Give a mounted image directory or a WIM: specifier." -ErrorAction Continue
        $script:ExitCode = 2
        return
    }

    # --- Platform and prerequisites (exit 3) ---------------------------------
    if (-not (Test-WindowsHost)) {
        Write-Error -Message 'This script drives DISM and SFC and only runs on Windows.' -ErrorAction Continue
        $script:ExitCode = 3
        return
    }
    if ($PSVersionTable.PSVersion -lt [version]'5.1') {
        Write-Error -Message "PowerShell 5.1 or newer is required; this host is $($PSVersionTable.PSVersion)." -ErrorAction Continue
        $script:ExitCode = 3
        return
    }

    # Only the tools the requested stage will actually use are required, so a
    # -SkipSfc run is not blocked by a missing sfc.exe.
    $neededTool = [System.Collections.Generic.List[string]]::new()
    if ($stageName -ne 'Repair' -or -not $noDism) { $neededTool.Add('Dism.exe') }
    if ($stageName -eq 'Repair' -and -not $noSfc) { $neededTool.Add('sfc.exe') }
    foreach ($tool in $neededTool) {
        if ([string]::IsNullOrWhiteSpace((Get-ToolPath -FileName $tool))) {
            Write-Error -Message "$tool is missing from System32; this script cannot repair anything without it." -ErrorAction Continue
            $script:ExitCode = 3
            return
        }
    }

    # --- Elevation (exit 4) --------------------------------------------------
    # Required even for -WhatIf and for the read-only stages: DISM /Online
    # refuses to run without it.
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
    # Every stage runs a tool behind a ShouldProcess gate, including the
    # read-only ones, so any stage can prompt. -WhatIf never prompts.
    if (-not $WhatIfPreference -and $ConfirmPreference -ne 'None' -and -not (Test-InteractiveHost)) {
        Write-Error -Message 'Refused: running DISM or SFC needs confirmation, there is no terminal to confirm on, and -Force was not given. Re-run with -Force (or set LZC_REPAIRSYSTEMFILES_FORCE=1), or preview with -WhatIf.' -ErrorAction Continue
        $script:ExitCode = 5
        return
    }

    # --- Lock (exit 75) ------------------------------------------------------
    # Only the state-changing stage takes the lock: two concurrent DISM
    # servicing operations fail on the servicing stack's own lock, with a far
    # less obvious error than this one. A read-only Check or Scan, and any
    # -WhatIf preview, are never blocked.
    if ($stageName -eq 'Repair' -and -not $WhatIfPreference) {
        $script:ScriptLock = Enter-ScriptLock -Name $ScriptLockName
        if ($null -eq $script:ScriptLock) {
            Write-Error -Message "Another instance is already running (lock: Global\$ScriptLockName). Try again later." -ErrorAction Continue
            $script:ExitCode = 75
            return
        }
    }

    if ($noDism) {
        Write-Warning -Message '-SkipDism was given. SFC repairs FROM the component store, so running it without repairing the store first is unlikely to fix anything.'
    }

    $result = [System.Collections.Generic.List[object]]::new()

    switch ($stageName) {
        'Check' {
            Write-Information -MessageData 'Stage Check: read-only DISM /CheckHealth.'
            $checkResult = Invoke-DismStage -Operation 'CheckHealth' -TimeoutMinute $timeoutMinute -SourcePath $sourcePath
            if ($null -ne $checkResult) { $result.Add($checkResult) }
        }
        'Scan' {
            Write-Information -MessageData 'Stage Scan: read-only DISM /ScanHealth. This can take a while.'
            $scanResult = Invoke-DismStage -Operation 'ScanHealth' -TimeoutMinute $timeoutMinute -SourcePath $sourcePath
            if ($null -ne $scanResult) { $result.Add($scanResult) }
        }
        'Repair' {
            # The documented order: repair the store first, then let SFC repair
            # protected system files FROM the repaired store.
            if (-not $noDism) {
                Write-Information -MessageData 'Step 1 of 2: DISM /RestoreHealth (repairs the component store).'
                $dismResult = Invoke-DismStage -Operation 'RestoreHealth' -TimeoutMinute $timeoutMinute -SourcePath $sourcePath
                if ($null -ne $dismResult) { $result.Add($dismResult) }

                if ($null -ne $dismResult -and $dismResult.Status -eq 'Failed' -and -not $noSfc) {
                    Write-Warning -Message 'DISM did not repair the component store. SFC will still run, but it may have nothing good to copy from.'
                }
            }

            if (-not $noSfc) {
                Write-Information -MessageData 'Step 2 of 2: sfc /scannow (repairs protected system files from the store).'
                $sfcResult = Invoke-SfcStage -TimeoutMinute $timeoutMinute
                if ($null -ne $sfcResult) { $result.Add($sfcResult) }
            }
        }
    }

    if ($result.Count -eq 0) {
        Write-Error -Message 'No repair tool could be run: DISM or SFC disappeared between the prerequisite check and the run. Check the warnings above.' -ErrorAction Continue
        $script:ExitCode = 3
        return
    }

    $failed = @($result | Where-Object { $_.Status -eq 'Failed' })
    $reboot = @($result | Where-Object { $_.Status -eq 'RebootRequired' })
    $unknown = @($result | Where-Object { $_.Status -eq 'Unknown' })

    Write-Information -MessageData 'Summary:'
    foreach ($entry in $result) {
        Write-Information -MessageData ('{0} {1}: exit {2}, verdict {3}, {4}s' -f `
                $entry.Tool, $entry.Operation, $entry.ExitCode, $entry.Verdict, $entry.DurationSeconds)
    }
    Write-Information -MessageData "Detailed logs: $(Join-Path -Path $env:SystemRoot -ChildPath 'Logs\CBS\CBS.log') and $(Join-Path -Path $env:SystemRoot -ChildPath 'Logs\DISM\dism.log')"

    if ($failed.Count -gt 0) {
        $script:ExitCode = 1
    }
    elseif ($unknown.Count -gt 0) {
        Write-Warning -Message 'At least one tool produced a result this script could not classify. Read the logs before concluding the system is healthy.'
        $script:ExitCode = 1
    }
    elseif ($reboot.Count -gt 0) {
        # The work succeeded, so this is exit 0. The pending restart is carried
        # on the result objects (Status = RebootRequired) instead of in a
        # bespoke exit code, because this repository allows one exit-code table
        # and no script-specific additions to it.
        Write-Information -MessageData 'A restart is required to finish. The run itself succeeded: exit code 0, Status RebootRequired.'
    }

    foreach ($item in $result) { $item }
}

try {
    Start-SystemFileRepair
}
catch [System.Management.Automation.PipelineStoppedException] {
    # Ctrl-C, or a caller stopping the pipeline. A DISM or SFC process already
    # running is not killed by this; wait for it, or reboot before re-running.
    Write-Warning -Message 'Interrupted. If DISM was mid-repair, reboot before running this script again.'
    $ExitCode = 130
}
catch [System.OperationCanceledException] {
    Write-Warning -Message 'Cancelled. If DISM was mid-repair, reboot before running this script again.'
    $ExitCode = 130
}
finally {
    Exit-ScriptLock -Mutex $ScriptLock
}

exit $ExitCode
