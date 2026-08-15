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
finish. The script always passes `-NoRestart`, never reboots, and returns exit code
`3010` when a restart is pending.

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

- Windows PowerShell 5.1 or PowerShell 7.x. The DISM cmdlets are natively compatible
  with PowerShell 7; no compatibility layer is needed.
- Administrator. Enforced by `#Requires -RunAsAdministrator`. `Get-WindowsOptionalFeature
  -Online` itself requires elevation, so even listing needs it.

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

| Parameter | Environment variable | Default | Meaning |
| --- | --- | --- | --- |
| `-Action <Enable\|Disable>` | `WINFEATURE_ACTION` | none (listing mode) | The change to make. Omit it to stay read-only. |
| `-FeatureName <string[]>` | `WINFEATURE_NAMES` (comma separated) | none | One or more feature names. Required with `-Action`. |
| `-List` | - | implied when `-Action` is omitted | Force listing mode. |
| `-Filter <string>` | `WINFEATURE_FILTER` | `*` | Wildcard applied to the feature name when listing. Ignored when changing. |
| `-RemovePayload` | `WINFEATURE_REMOVE_PAYLOAD` | off | On disable, also remove the feature's files from the image. |
| `-IncludeParent` | `WINFEATURE_INCLUDE_PARENT` | off | On enable, also enable parent features. |
| `-Force` | `WINFEATURE_FORCE` | off | Suppress confirmation prompts. Required for unattended runs. |

An explicitly passed switch always wins over its environment variable. `-WhatIf`,
`-Confirm`, `-Verbose` and `-InformationAction` work as usual; `-WhatIf` takes
precedence over `-Force`.

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

| Code | Meaning |
| --- | --- |
| `0` | Every requested feature reached the requested state, or was already there. |
| `1` | At least one feature failed to change, was not found, or its state could not be read. |
| `2` | Usage or precondition failure: `-Action` given without `-FeatureName`, the DISM cmdlets are unavailable, or the feature list could not be enumerated. |
| `3` | Not Windows, or PowerShell older than 5.1. Nothing was changed. |
| `4` | Not running as Administrator. |
| `5` | A change needs confirmation, there is no terminal to confirm on, and `-Force` was not given. |
| `75` | Another instance holds the lock. Retry later; nothing is wrong. |
| `130` | Interrupted. Features already changed stay changed. |
| `3010` | Success, and a restart is required to finish. |

An enumeration failure is reported as exit `2`, never as an empty list with exit `0`.

Administrator rights are checked up front, for `-List` and `-WhatIf` as well as
for a real change: DISM cannot read a feature's state unelevated, so without that
check the run degrades into a per-feature `Failed` whose actual cause is an
elevation error rather than a missing feature.

A run that changes a feature takes a machine-wide named mutex
(`Global\lzc-features`), so two DISM feature transactions cannot overlap on one
image. A read-only listing and a `-WhatIf` preview never take it, and so are
never blocked by a run in progress. See the [repo-wide
table](../../docs/exit-codes.md) for why `75` rather than a generic failure.

## Scheduled task

Use `-File`, never `-Command`.

```
Program:   C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe
Arguments: -NoProfile -NonInteractive -ExecutionPolicy Bypass
           -File "C:\Scripts\windows\Features\WindowsFeatures.ps1"
           -Action Enable -FeatureName NetFx3 -Force
```

When passing `-FeatureName` through `-File`, list multiple values space separated
(`-FeatureName TelnetClient TFTP`); `-File` binds array parameters from separate
tokens.
