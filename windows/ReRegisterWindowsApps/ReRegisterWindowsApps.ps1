#Requires -Version 5.1
#
# ReRegisterWindowsApps.ps1 -- repair ONE named Store app for the CURRENT user.
#
# License: MIT
# Origin:  https://github.com/Lazarev-Cloud/Scripts
#
# Error model: linear script. Set-StrictMode 3.0 and $ErrorActionPreference = 'Stop'. Deliberate
# refusals (elevated session, ambiguous or missing package) are reported with
# Write-Error -ErrorAction Continue and a distinct exit code, not thrown.
#
# Every mutation is gated by $PSCmdlet.ShouldProcess immediately before the call, per package, so
# -WhatIf is a complete and truthful dry run.

<#
.SYNOPSIS
    Repairs a single named Microsoft Store app for the current user, using the supported
    Reset-AppxPackage path.

.DESCRIPTION
    This script deliberately does NOT do what most "re-register Windows apps" snippets do.

    The widely copied one-liner is:

        Get-AppxPackage -AllUsers | Foreach {Add-AppxPackage -DisableDevelopmentMode -Register "$($_.InstallLocation)\AppXManifest.xml"}

    That is harmful, and this script will not reproduce it:

      - '-AllUsers' iterates packages belonging to every profile on the machine. Deployment for
        another user's context usually fails with access-denied and can leave partial
        registrations behind.
      - It re-registers packages that are staged but not installed for the current user, which
        REINSTALLS APPS THE USER DELIBERATELY REMOVED.
      - Framework packages and packages with a null InstallLocation make it throw part way
        through, so it half-completes silently.
      - 'Add-AppxPackage -Register <manifest>' is a developer-mode sideload. It bypasses the
        normal deployment path and can leave a package in a state the Store can no longer
        service, producing the well-known 0x80073CF6 and 0x80073D02 errors that often end in a
        machine reset.

    What this script does instead:

      - Acts on ONE package that you name. No wildcards that fan out, no unfiltered enumeration.
      - Acts only on the CURRENT user's packages. Never -AllUsers.
      - Prefers Reset-AppxPackage, the supported cmdlet for returning an app to its
        freshly-installed state (Windows 10 build 20175+ and Windows 11). Falls back to the
        -Register sideload only if you ask for it explicitly with -Action Reregister, and warns
        about what that costs.

    RUN THIS AS THE AFFECTED USER, NOT AS ADMINISTRATOR. AppX registration is per-user: run from
    an elevated session it operates on the administrator's profile, so it will not fix the app
    for the person who reported the problem. The script refuses to run elevated unless
    -AllowElevated is passed.

    BLAST RADIUS: Reset returns the named app to its freshly-installed state. THE APP'S LOCAL
    DATA AND SETTINGS ARE DISCARDED - sign-ins, preferences and cached content in the package's
    local store are lost. It does not touch other apps or other users.

.PARAMETER Name
    The package to act on, matched against the current user's installed packages. An exact
    Name match wins; otherwise a single substring match is accepted. If several packages match,
    the script lists them and stops rather than guessing. Environment: LZC_REREGISTERWINDOWSAPPS_NAME.

.PARAMETER Action
    Report      Read-only. Lists the current user's packages, filtered by -Name if given. Default.
    Reset       Reset-AppxPackage: the supported repair. Discards the app's local data.
    Reregister  Add-AppxPackage -Register: the developer-mode sideload. Last resort only.
    Environment: LZC_REREGISTERWINDOWSAPPS_ACTION.

.PARAMETER AllowElevated
    Proceed even though the session is elevated, accepting that the repair applies to the
    administrator's profile. Environment: LZC_REREGISTERWINDOWSAPPS_ALLOW_ELEVATED.

.PARAMETER Force
    Suppress confirmation prompts, for unattended use. -WhatIf still wins over -Force.
    Environment: LZC_REREGISTERWINDOWSAPPS_FORCE.

    Both flags accept 1, true, yes, on, 0, false, no or off in any case. Any other value is a
    usage error and exits 2.

.PARAMETER Version
    Print the script version and exit.

.EXAMPLE
    PS> .\ReRegisterWindowsApps.ps1

    Lists the Store apps installed for the current user, so you can find the exact name.

.EXAMPLE
    PS> .\ReRegisterWindowsApps.ps1 -Name Microsoft.WindowsStore -Action Reset -WhatIf

    Shows precisely which package would be reset, and changes nothing.

.EXAMPLE
    PS> .\ReRegisterWindowsApps.ps1 -Name Microsoft.WindowsCalculator -Action Reset -Force

    Resets Calculator to its freshly-installed state without prompting.

.INPUTS
    None. This script does not accept pipeline input.

.OUTPUTS
    System.Management.Automation.PSCustomObject describing the packages found or the action taken.

.NOTES
    Version : 2.0
    License : MIT
    Origin  : https://github.com/Lazarev-Cloud/Scripts
    Tested  : Windows PowerShell 5.1 on Windows 11.

    Exit codes (the repo-wide table; this script can return the subset below):
      0  success, or a -WhatIf dry run
      1  the work ran but something in it failed
      2  usage error: an invalid parameter or environment variable value, no package matched the
         name, the name matched several packages, or the session is elevated without
         -AllowElevated
      3  unsupported platform: Reset-AppxPackage is unavailable on this Windows build
      5  refused: confirmation was needed, the session cannot prompt, and -Force was not given

    Code 4 (must be run as administrator) is never returned: this script is the opposite case and
    refuses an elevated session unless -AllowElevated says otherwise.

    If a single app is broken, try these in order before reaching for this script:
      1. Settings > Apps > Installed apps > Advanced options > Repair (non-destructive)
      2. the same screen's Reset (equivalent to -Action Reset here)
      3. wsreset.exe, for Microsoft Store cache problems specifically

    On PowerShell 7 the Appx module needs the Windows PowerShell compatibility layer; the script
    loads it automatically. Objects returned through that layer are deserialised, so this script
    reads properties only and never calls methods on them.

.LINK
    https://learn.microsoft.com/en-us/powershell/module/appx/reset-appxpackage
#>

[CmdletBinding(DefaultParameterSetName = 'Run', SupportsShouldProcess, ConfirmImpact = 'High')]
[OutputType([pscustomobject])]
param(
    [Parameter(ParameterSetName = 'Run', Position = 0)]
    [ValidateNotNullOrEmpty()]
    [ValidateLength(1, 256)]
    # Wildcards are rejected on purpose: the whole failure mode this script exists to avoid is a
    # pattern that quietly expands to every installed package.
    [ValidatePattern('^[^\*\?]+$')]
    [string] $Name,

    [Parameter(ParameterSetName = 'Run', Position = 1)]
    [ValidateSet('Report', 'Reset', 'Reregister')]
    [string] $Action,

    [Parameter(ParameterSetName = 'Run')]
    [switch] $AllowElevated,

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

function Import-AppxSupport {
    <#
    .SYNOPSIS
        Makes the Appx cmdlets available on both Windows PowerShell 5.1 and PowerShell 7.
    .DESCRIPTION
        On PowerShell 7 the Appx module does not load natively and needs the Windows PowerShell
        compatibility layer, which proxies the cmdlets through a background 5.1 runspace. Objects
        returned that way are deserialised, so callers must read properties and not call methods.
        Import-Module has no -WhatIf of its own, so the preference is neutralised around the call.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param()

    if (Get-Module -Name Appx) { return }

    # The preferences are neutralised at GLOBAL scope, not locally. The Appx module defines its
    # aliases with Set-Alias in its own module scope, whose parent is the global scope, so a
    # function-local or script-local override would not reach it and the import would emit ~45
    # bogus 'What if: Set Alias' lines that bury the operation the user asked to preview.
    # ConfirmPreference is neutralised for the same reason: under -Confirm the module's own
    # Set-Alias calls ask to confirm, which is an artefact of importing a module rather than
    # anything the user asked for, and in a non-interactive session that unanswerable prompt kills
    # the script before it starts.
    $previousWhatIfPreference = $global:WhatIfPreference
    $previousConfirmPreference = $global:ConfirmPreference
    $global:WhatIfPreference = $false
    $global:ConfirmPreference = 'None'
    try {
        # Splatted so the PowerShell 7-only -UseWindowsPowerShell parameter appears exactly where
        # it applies, in one call site. Naming it in a literal call would make the command
        # reference a parameter that does not exist on 5.1, even though the branch never runs
        # there.
        $importArgument = @{ Name = 'Appx'; Verbose = $false }
        if ($PSVersionTable.PSEdition -eq 'Core') {
            $importArgument['UseWindowsPowerShell'] = $true
            $importArgument['WarningAction'] = 'SilentlyContinue'
        }
        Import-Module @importArgument
    } finally {
        $global:WhatIfPreference = $previousWhatIfPreference
        $global:ConfirmPreference = $previousConfirmPreference
    }
}

function Get-CurrentUserPackage {
    <#
    .SYNOPSIS
        Returns the current user's installed packages, optionally narrowed by name.
    .DESCRIPTION
        Never uses -AllUsers. Packages belonging to other profiles are not this script's business
        and cannot be repaired safely from here.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter()]
        [AllowEmptyString()]
        [string] $Filter = ''
    )

    $packages = @(Get-AppxPackage -ErrorAction Stop)

    if (-not [string]::IsNullOrWhiteSpace($Filter)) {
        $exact = @($packages | Where-Object { $_.Name -eq $Filter })
        if ($exact.Count -gt 0) {
            $packages = $exact
        } else {
            $packages = @($packages | Where-Object { $_.Name -like "*$Filter*" })
        }
    }

    $result = @()
    foreach ($package in $packages) {
        $result += [pscustomobject]@{
            Name            = [string] $package.Name
            PackageFullName = [string] $package.PackageFullName
            Version         = [string] $package.Version
            InstallLocation = [string] $package.InstallLocation
            Status          = [string] $package.Status
            IsFramework     = [bool] $package.IsFramework
        }
    }
    return $result
}

function Invoke-PackageReset {
    <#
    .SYNOPSIS
        Resets one package to its freshly-installed state behind a ShouldProcess gate.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [pscustomobject] $Package
    )

    $operation = 'Reset app to freshly-installed state (discards its local data and settings)'
    if (-not $PSCmdlet.ShouldProcess($Package.PackageFullName, $operation)) {
        return [pscustomobject]@{
            Operation = $operation; Target = $Package.PackageFullName; Status = 'Skipped'
        }
    }

    # Piping the live package object is the documented form. Confirm is suppressed because this
    # call site has already prompted.
    Get-AppxPackage -Name $Package.Name | Reset-AppxPackage -Confirm:$false -ErrorAction Stop

    return [pscustomobject]@{
        Operation = $operation; Target = $Package.PackageFullName; Status = 'Succeeded'
    }
}

function Invoke-PackageReregister {
    <#
    .SYNOPSIS
        Re-registers one package from its manifest behind a ShouldProcess gate.
    .DESCRIPTION
        This is the developer-mode sideload path and is the last resort. It is scoped to a single
        named package for the current user, which is what makes it survivable; the copy-pasted
        version that loops over every package for every user is not.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [pscustomobject] $Package
    )

    if ([string]::IsNullOrWhiteSpace($Package.InstallLocation)) {
        throw "Package '$($Package.PackageFullName)' has no install location, so it cannot be re-registered. This is normal for some framework and staged packages."
    }
    $manifest = Join-Path $Package.InstallLocation 'AppXManifest.xml'
    if (-not (Test-Path -LiteralPath $manifest -PathType Leaf)) {
        throw "Manifest not found for '$($Package.PackageFullName)': $manifest"
    }

    $operation = 'Re-register app from its manifest (developer-mode sideload; can break Store servicing)'
    if (-not $PSCmdlet.ShouldProcess($Package.PackageFullName, $operation)) {
        return [pscustomobject]@{
            Operation = $operation; Target = $Package.PackageFullName; Status = 'Skipped'
        }
    }

    Add-AppxPackage -DisableDevelopmentMode -Register $manifest -ErrorAction Stop

    return [pscustomobject]@{
        Operation = $operation; Target = $Package.PackageFullName; Status = 'Succeeded'
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
    [OutputType([pscustomobject], [pscustomobject[]])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $ScriptBoundParameter
    )

    if ($Version) {
        Write-Information -MessageData "ReRegisterWindowsApps.ps1 version $script:ScriptVersion"
        return
    }

    # Guard order, identical across every script in this repo: configuration (2), platform and
    # prerequisites (3), elevation (4), interactivity (5), then the work itself (0 or 1).
    # $script:ExitCode is set to 2 before each validation throw so the catch at the bottom
    # reports a usage error rather than the generic failure code.
    if (-not $ScriptBoundParameter.ContainsKey('Name')) {
        $Name = Get-EnvironmentValue -Name 'LZC_REREGISTERWINDOWSAPPS_NAME' -Fallback ''
        if ($Name -match '[\*\?]') {
            $script:ExitCode = 2
            throw "LZC_REREGISTERWINDOWSAPPS_NAME must not contain wildcards, got '$Name'."
        }
    }
    if (-not $ScriptBoundParameter.ContainsKey('Action')) {
        $Action = Get-EnvironmentValue -Name 'LZC_REREGISTERWINDOWSAPPS_ACTION' -Fallback 'Report'
        if (@('Report', 'Reset', 'Reregister') -notcontains $Action) {
            $script:ExitCode = 2
            throw "LZC_REREGISTERWINDOWSAPPS_ACTION must be Report, Reset or Reregister, got '$Action'."
        }
    }
    if (-not $ScriptBoundParameter.ContainsKey('AllowElevated')) {
        $fromEnv = Resolve-EnvironmentFlag -Name 'LZC_REREGISTERWINDOWSAPPS_ALLOW_ELEVATED'
        if ($null -ne $fromEnv) { $AllowElevated = [switch] $fromEnv }
    }
    if (-not $ScriptBoundParameter.ContainsKey('Force')) {
        $fromEnv = Resolve-EnvironmentFlag -Name 'LZC_REREGISTERWINDOWSAPPS_FORCE'
        if ($null -ne $fromEnv) { $Force = [switch] $fromEnv }
    }

    # -Force must not short-circuit ShouldProcess itself, or -WhatIf would stop working. Lower
    # the confirmation threshold instead, and only when the caller did not ask for -Confirm.
    if ($Force -and -not $ScriptBoundParameter.ContainsKey('Confirm')) {
        $ConfirmPreference = 'None'
    }

    Import-AppxSupport
    Write-Information -MessageData "Action: $Action"

    $candidate = @(Get-CurrentUserPackage -Filter $Name)

    if ($Action -eq 'Report') {
        if ($candidate.Count -eq 0) {
            Write-Warning "No packages installed for $env:USERNAME match '$Name'."
        } else {
            Write-Information -MessageData "$($candidate.Count) package(s) installed for $env:USERNAME$(if ($Name) { " matching '$Name'" })."
        }
        return [pscustomobject[]] $candidate
    }

    # Prerequisite before the rest: Reset-AppxPackage arrived in Windows 10 build 20175, and on
    # older builds the cmdlet is simply absent. It is probed here, ahead of everything that could
    # mask it, so an unsupported build says so rather than failing later for a different reason.
    if ($Action -eq 'Reset' -and -not (Get-Command -Name 'Reset-AppxPackage' -ErrorAction SilentlyContinue)) {
        Write-Error -ErrorAction Continue -Message 'Reset-AppxPackage is not available on this Windows build (it needs Windows 10 build 20175 or later). Use Settings > Apps > Installed apps > Advanced options > Reset, or re-run with -Action Reregister accepting the risks described in the help.'
        $script:ExitCode = 3
        return
    }

    # Elevation is checked for the mutating actions only, and not under -WhatIf, so a preview is
    # available from any shell.
    if (-not $WhatIfPreference -and (Test-Elevated) -and -not $AllowElevated) {
        Write-Error -ErrorAction Continue -Message 'Refusing to run elevated. AppX packages are registered per user, so an elevated run repairs the administrator profile rather than the profile of the user whose app is broken. Re-run this from the affected user''s own session, or pass -AllowElevated if you really mean to repair the administrator profile.'
        $script:ExitCode = 2
        return
    }

    if ([string]::IsNullOrWhiteSpace($Name)) {
        $script:ExitCode = 2
        throw "-Action $Action requires -Name. Run with -Action Report first to find the exact package name."
    }

    if ($candidate.Count -eq 0) {
        Write-Error -ErrorAction Continue -Message "No package installed for $env:USERNAME matches '$Name'. Run with -Action Report to list what is installed."
        $script:ExitCode = 2
        return
    }
    if ($candidate.Count -gt 1) {
        Write-Error -ErrorAction Continue -Message "'$Name' matches $($candidate.Count) packages: $(($candidate.Name) -join ', '). Re-run with the exact package name; this script never acts on more than one package at a time."
        $script:ExitCode = 2
        return
    }

    $package = $candidate[0]
    Write-Information -MessageData "Target package: $($package.PackageFullName)"

    if ($package.IsFramework) {
        Write-Warning "'$($package.Name)' is a framework package. Framework packages are servicing-managed and are almost never the cause of an app failure."
    }

    # Last gate before the change. $ConfirmPreference is 'None' only when -Force lowered it above
    # or the caller passed -Confirm:$false. Anything else means ShouldProcess is about to prompt,
    # and a host that cannot answer would turn that into an exception reported as a plain failure.
    if (-not $WhatIfPreference -and $ConfirmPreference -ne 'None' -and (Test-NonInteractiveSession)) {
        Write-Error -ErrorAction Continue -Message "Refusing to $Action '$($package.Name)': this action needs confirmation, but the session cannot prompt (it is non-interactive). Pass -Force to confirm in advance, or set LZC_REREGISTERWINDOWSAPPS_FORCE=1."
        $script:ExitCode = 5
        return
    }

    if ($Action -eq 'Reset') {
        Write-Warning "Resetting '$($package.Name)' discards its local data: sign-ins, settings and cached content in the app's local store are lost."
        return Invoke-PackageReset -Package $package
    }

    Write-Warning 'Re-registering from a manifest is a developer-mode sideload. It bypasses the normal deployment path and can leave the package in a state the Store cannot service (0x80073CF6 / 0x80073D02). Prefer -Action Reset.'
    return Invoke-PackageReregister -Package $package
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
