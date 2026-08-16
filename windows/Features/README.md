# WindowsFeatures

Lists, enables and disables Windows optional features. Read-only by default; every
change is confirmed.

## Safe by default

With no arguments the script only **lists** features and their current state. Nothing
changes until you name both `-Action` and `-FeatureName`, and even then every change
passes `$PSCmdlet.ShouldProcess`, so it prompts unless `-Force` is given and does
nothing at all under `-WhatIf`.

Features already in the requested state are reported and skipped, so a no-op request
never starts a servicing transaction.

## Blast radius

Only the features you name. Enabling or disabling an optional feature is a servicing
transaction against the running Windows image, and most features need a restart to
finish. The script always passes `-NoRestart` and never reboots; a pending restart is
reported as `RestartNeeded` on the result object.

A run that will change a feature holds a machine-wide named mutex
(`Global\lzc-features`), so two DISM feature transactions cannot overlap on one image;
a second run exits `75`. A read-only listing and a `-WhatIf` preview never take it, and
so are never blocked by a run in progress.

Two behaviours are explicit opt-ins because both do considerably more than their
names suggest:

### `-RemovePayload` (disable)

Maps to DISM's `-Remove`. Deletes the feature's **files** from the image, not just
its registration. The state becomes `DisabledWithPayloadRemoved`, and re-enabling it
later requires Windows Update or an installation source.

Off by default. A plain disable is fully reversible offline, which is what you almost
always want.

### `-IncludeParent` (enable)

Maps to DISM's `-All`. Also enables every parent feature the named one depends on.
Convenient, but it turns on components you did not name.

Off by default. When an enable fails because a parent is disabled, the script tells
you to re-run with this switch.

## Requirements

- Windows. Any other platform exits `3`.
- Windows PowerShell 5.1 or PowerShell 7.x. Older exits `3`. The DISM cmdlets are
  natively compatible with PowerShell 7; no compatibility layer is needed. If the
  DISM PowerShell module is unavailable the run exits `3`.
- Administrator; a non-elevated run exits `4`. This applies to `-List` and `-WhatIf`
  as well as to a real change: `Get-WindowsOptionalFeature -Online` cannot read a
  feature's state unelevated, so without the check the run would degrade into a
  per-feature `Failed` whose actual cause is an elevation error rather than a missing
  feature.

Elevation is checked at run time rather than with `#Requires -RunAsAdministrator`,
which fails the script before it starts and exits `1`. The runtime check is what makes
the documented exit `4` reachable.

Arguments and `LZC_WINDOWSFEATURES_*` values are validated **before** the elevation
check, so a typo can be found from an ordinary shell.

## Usage

```powershell
# List every optional feature and its state. Changes nothing.
.\WindowsFeatures.ps1

# List only the Hyper-V related features.
.\WindowsFeatures.ps1 -Filter '*Hyper-V*'

# Show that NetFx3 would be enabled, without enabling it.
.\WindowsFeatures.ps1 -Action Enable -FeatureName NetFx3 -WhatIf

# Enable Hyper-V and its parents, unattended.
.\WindowsFeatures.ps1 -Action Enable -FeatureName 'Microsoft-Hyper-V' -IncludeParent -Force

# Disable the Telnet client but keep its files, so it can come back offline.
.\WindowsFeatures.ps1 -Action Disable -FeatureName TelnetClient -Force

# Several features in one run.
.\WindowsFeatures.ps1 -Action Disable -FeatureName TelnetClient,TFTP -Force

Get-Help .\WindowsFeatures.ps1 -Full
```

Feature names must match exactly what `Get-WindowsOptionalFeature` reports:

```powershell
Get-WindowsOptionalFeature -Online | Select-Object FeatureName, State
```

## Parameters

Every parameter has an environment variable, so the script can be driven entirely
from the environment in a scheduled task. Every variable is named
`LZC_WINDOWSFEATURES_*`, so `Get-ChildItem env:LZC_*` lists everything configurable in
this repository.

| Parameter | Environment variable | Default | Meaning |
| --- | --- | --- | --- |
| `-Action <Enable\|Disable>` | `LZC_WINDOWSFEATURES_ACTION` | none (listing mode) | The change to make. Case does not matter. Omit it to stay read-only. |
| `-FeatureName <string[]>` | `LZC_WINDOWSFEATURES_NAMES` (comma separated) | none | One or more feature names. Required with `-Action`. |
| `-List` | - | implied when `-Action` is omitted | Ask for listing mode explicitly. Passing it together with `-Action` is a contradiction and exits `2`. |
| `-Filter <string>` | `LZC_WINDOWSFEATURES_FILTER` | `*` | Wildcard applied to the feature name when listing. Ignored when changing. |
| `-RemovePayload` | `LZC_WINDOWSFEATURES_REMOVE_PAYLOAD` | off | On disable, also remove the feature's files from the image. |
| `-IncludeParent` | `LZC_WINDOWSFEATURES_INCLUDE_PARENT` | off | On enable, also enable parent features. |
| `-Force` | `LZC_WINDOWSFEATURES_FORCE` | off | Suppress confirmation prompts. Required for unattended runs. |

An explicitly passed parameter always wins over its environment variable.

**Booleans** (`LZC_WINDOWSFEATURES_REMOVE_PAYLOAD`, `..._INCLUDE_PARENT`, `..._FORCE`)
accept `1`, `true`, `yes`, `on`, `0`, `false`, `no`, `off`, in any case. Anything else
is a usage error with a message naming the variable, not a silent "off".

`NO_COLOR` (any non-empty value, per [no-color.org](https://no-color.org)) is
honoured. The script emits no colour of its own — progress, warnings and errors go to
PowerShell's streams and the host renders them — and on PowerShell 7 `NO_COLOR`
additionally forces `$PSStyle.OutputRendering` to `PlainText` for the run.

Standard PowerShell parameters also apply:

| Parameter | Effect |
| --- | --- |
| `-WhatIf` | Full dry run. Takes precedence over `-Force`. |
| `-Confirm` | Prompt before each feature change. |
| `-Verbose` | Extra detail. |
| `-InformationAction SilentlyContinue` | Quiet run. Progress goes to the information stream, which is on by default. |

## Output

In listing mode, one object per feature with `FeatureName` and `State`.

In change mode, one object per requested feature:

| Property | Meaning |
| --- | --- |
| `FeatureName` | The feature. |
| `Action` | `Enable` or `Disable`. |
| `PreviousState` | State before the change. |
| `ResultState` | State after the change, re-read from the system rather than assumed. |
| `RestartNeeded` | Whether DISM reported that a restart is required. |
| `Status` | `Success`, `AlreadyInState`, `Skipped` (`-WhatIf` or declined), `NotFound`, or `Failed`. |
| `Detail` | The underlying error message when something failed. |

`Status` is `NotFound` only when absence was actually established: the query ran and
returned nothing, or DISM reported the name as unknown. A query that could not run at
all (not elevated, servicing busy) proves nothing about whether the feature exists, so
it is reported as `Failed` with the real reason, never as a missing feature.

`ResultState` is read back from the system after the operation. If no restart was
requested and the state did not actually change, the result is reported as `Failed`
rather than presented as a success.

Possible states: `Enabled`, `Disabled`, `DisabledWithPayloadRemoved`,
`EnablePending`, `DisablePending`.

## Exit codes

The repository-wide table. Every script in this repository uses these numbers and no
others.

| Code | Meaning here |
| --- | --- |
| `0` | Every requested feature reached the requested state, or was already there. **A pending restart is still `0`** — see below. |
| `1` | The work ran but part of it failed: a feature would not change, was not found, its state could not be read, or the feature list could not be enumerated. |
| `2` | Usage error: an unknown argument, `-Action` without `-FeatureName`, `-Action` together with `-List`, or an invalid `LZC_WINDOWSFEATURES_*` value. |
| `3` | Not Windows, PowerShell older than 5.1, or the DISM PowerShell module is unavailable. |
| `4` | Not running as Administrator. |
| `5` | A change needs confirmation, there is no terminal to confirm on, and `-Force` was not given. |
| `75` | Another instance holds `Global\lzc-features` (`EX_TEMPFAIL`: retry later, not a fault). See the [repo-wide table](../../docs/exit-codes.md) for why `75` rather than a generic failure. |
| `130` | Interrupted. Features already changed stay changed. |

An enumeration failure is reported as a failure, never as an empty list with exit `0`.

**A pending restart is not signalled with a bespoke exit code such as `3010`.** The
work succeeded, so the exit code is `0`; the signal is carried on the result objects,
which is also the only place it can be per-feature:

```powershell
$r = .\WindowsFeatures.ps1 -Action Enable -FeatureName NetFx3 -Force
if ($r | Where-Object RestartNeeded) { <# schedule the restart #> }
```

## Scheduled task

Use `-File`, never `-Command`. `-Command` collapses the exit code to 0 or 1.

```
Program:   C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe
Arguments: -NoProfile -NonInteractive -ExecutionPolicy Bypass
           -File "C:\Scripts\windows\Features\WindowsFeatures.ps1"
           -Action Enable -FeatureName NetFx3 -Force
```

`-Force` is not optional: without it the task has nothing to confirm on and the run is
refused with exit `5`. Set `LZC_WINDOWSFEATURES_FORCE=1` if you prefer to carry it in
the environment.

**Passing several features through `-File`: use the comma form, in one token.**
`powershell.exe -File` hands each argument to the script as one literal string, so
`-FeatureName TelnetClient,TFTP` arrives as the single string `TelnetClient,TFTP`
— which this script splits on commas, so it does the right thing. The
space-separated form is silently wrong: `-FeatureName TelnetClient TFTP` binds only
`TelnetClient`, and `TFTP` falls through to the unknown-argument catch-all, which
exits `2`.

`LZC_WINDOWSFEATURES_NAMES=TelnetClient,TFTP` works the same way and is the tidier
choice when the task already carries other settings in the environment.
