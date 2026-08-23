# Clear-WindowsUpdateCache

Clears the Windows Update download cache and reports the space freed, stopping the
services that hold the files open first and restarting exactly the ones that were
running.

## What it does

Two modes.

### Default: clear `SoftwareDistribution\Download`

Deletes the cache of downloaded update payloads. Windows Update re-downloads
whatever it still needs on the next scan. The update database and the visible update
history in `DataStore` are left intact.

### `-ResetDataStore`: rename the whole directory aside

Renames `SoftwareDistribution` to `SoftwareDistribution.bak-<timestamp>` next to it.
Windows rebuilds the directory on the next scan. This is Microsoft's documented reset
for a broken update client.

- It **discards the visible Windows Update history**, which lives in `DataStore`.
- It is renamed rather than deleted, so the change is reversible: move the `.bak`
  directory back to undo it.
- No space is reclaimed until you delete the `.bak` directory yourself. The script
  prints its path and its size, and reports the size as `BytesMovedAside`, not as
  `BytesFreed`.

## Blast radius

Only `%SystemRoot%\SoftwareDistribution` (overridable with
`-SoftwareDistributionPath`), plus a stop and restart of the services named by
`-ServiceName`. Nothing else is touched.

Safety properties:

- **The directory is validated before anything is stopped or touched.** That one
  value decides what gets deleted, and in `-ResetDataStore` mode what gets renamed
  aside wholesale, so it is checked first. Refused with exit `2`:
  - a drive root (`C:\`, `D:\`, ...);
  - `%SystemRoot%`, `%SystemRoot%\System32`, `%SystemRoot%\SysWOW64`,
    `%SystemRoot%\WinSxS`, `%ProgramFiles%`, `%ProgramFiles(x86)%`, `%ProgramData%`,
    `%SystemDrive%\Users`;
  - anything that is not an existing directory;
  - with `-ResetDataStore`, any directory whose name is not `SoftwareDistribution` —
    renaming an arbitrary directory aside is not what that mode is for.
- Nothing is stopped or deleted without passing `$PSCmdlet.ShouldProcess`, so
  `-WhatIf` is a complete dry run that changes nothing.
- Services are restarted from a `finally` block. A failure part way through can never
  leave Windows Update permanently stopped, which is the classic failure mode of the
  three-line version of this script.
- Only services that were **actually running** are restarted. Running dependent
  services are enumerated and stopped first, then restarted in reverse order. This is
  why the script does not simply use `Stop-Service -Force`, which stops dependents
  without telling you which.
- A service is recorded for restart **before** the stop is attempted, not after it
  succeeds. A stop whose wait times out may still complete a moment later; recording
  it only on a confirmed stop would leave exactly that service down forever.
- Service waits are bounded by `-ServiceTimeoutSeconds`; a service that will not stop
  is reported and the run continues, rather than hanging.
- `BytesFreed` counts only files whose deletion returned without error.
- A run that will change something holds a machine-wide named mutex
  (`Global\lzc-updates`); a second run exits `75` instead of fighting over the same
  services and directory. `-WhatIf` takes no lock, so a preview is never blocked.
- A run that would prompt, on a host with no terminal to prompt on and without
  `-Force`, is refused with exit `5` before any service is stopped.

## Deliberately not done

These appear in copy-pasted "reset Windows Update" scripts. They break more than they
fix in a routine cache clear, so this script does none of them:

| Omitted step | Why |
| --- | --- |
| Renaming `catroot2` / stopping `cryptsvc` | Affects certificate and catalog validation well beyond Windows Update. Documented by Microsoft as a later, last-resort step. |
| `sc.exe sdset bits ...` / `sc.exe sdset wuauserv ...` | Overwrites the existing service ACLs with defaults. Microsoft says to skip it unless everything else has failed. |
| The 30-plus `regsvr32.exe` block | Windows XP and Vista era. Several of those DLLs do not exist on Windows 10 or 11, so it just emits a wall of errors. Component registration is servicing-managed now. |
| `netsh winsock reset` | Removes third-party Winsock layered service providers, breaking VPN and endpoint-security products. Requires a reboot. Unrelated to the update cache. |
| `bitsadmin /reset` | Deprecated in favour of the `BitsTransfer` module; the step was Vista-specific. |
| `rd /s /q SoftwareDistribution` | Replaced by a rename, which is reversible. |

## Requirements

- Windows. Any other platform exits `3`.
- Windows PowerShell 5.1 or PowerShell 7.x. Older exits `3`.
- Administrator; a non-elevated run exits `4`. Elevation is required even for
  `-WhatIf`, because without it the cache cannot be measured and the service state
  cannot be read, so the preview would be wrong.

Elevation is checked at run time rather than with `#Requires -RunAsAdministrator`,
which fails the script before it starts and exits `1`. The runtime check is what
makes the documented exit `4` reachable.

Arguments and `LZC_UPDATES_*` values are validated **before** the elevation check, so
a typo can be found from an ordinary shell.

## Usage

```powershell
# Dry run: what would be stopped, what would be freed. Changes nothing.
.\Clear-WindowsUpdateCache.ps1 -WhatIf

# Interactive clear of the download cache.
.\Clear-WindowsUpdateCache.ps1

# Unattended.
.\Clear-WindowsUpdateCache.ps1 -Force

# Full reset: rename SoftwareDistribution aside. Discards update history.
.\Clear-WindowsUpdateCache.ps1 -ResetDataStore -Force -Verbose

# Files stayed locked? Add the Update Orchestrator service.
.\Clear-WindowsUpdateCache.ps1 -ServiceName wuauserv,bits,UsoSvc -Force

Get-Help .\Clear-WindowsUpdateCache.ps1 -Full
```

## Parameters

Every parameter has an environment variable, so the script can be driven entirely
from the environment in a scheduled task. Every variable is named `LZC_UPDATES_*`, so
`Get-ChildItem env:LZC_*` lists everything configurable in this repository.

| Parameter | Environment variable | Default | Meaning |
| --- | --- | --- | --- |
| `-SoftwareDistributionPath <string>` | `LZC_UPDATES_PATH` | `%SystemRoot%\SoftwareDistribution` | The directory to operate on. Validated as described under Blast radius. |
| `-ServiceName <string[]>` | `LZC_UPDATES_SERVICES` (comma separated) | `wuauserv`, `bits` | Services to stop for the duration. These two hold the handles inside `Download`. Add `UsoSvc` if files remain locked. A name that does not exist is reported and ignored. |
| `-ServiceTimeoutSeconds <int>` | `LZC_UPDATES_SERVICE_TIMEOUT` | `60` | How long to wait for each service to reach the requested state. Range 5-3600. The bound is per service and per transition. |
| `-ResetDataStore` | `LZC_UPDATES_RESET_DATASTORE` | off | Rename the whole directory aside instead of clearing only `Download`. Discards update history. |
| `-Force` | `LZC_UPDATES_FORCE` | off | Suppress confirmation prompts. Required for unattended runs. |

An explicitly passed parameter always wins over its environment variable.

Value rules, enforced with a clear message and exit `2` rather than a default or a
crash:

- **Booleans** (`LZC_UPDATES_RESET_DATASTORE`, `LZC_UPDATES_FORCE`) accept `1`,
  `true`, `yes`, `on`, `0`, `false`, `no`, `off`, in any case. Anything else is a
  usage error.
- **Numbers** (`LZC_UPDATES_SERVICE_TIMEOUT`, `-ServiceTimeoutSeconds`) are digits
  only, within the documented range. `0x10`, `+5`, `5.0` and `-1` are rejected; a
  zero-padded value such as `08` is read as decimal `8`, never as octal.

`NO_COLOR` (any non-empty value, per [no-color.org](https://no-color.org)) is
honoured. The script emits no colour of its own — progress, warnings and errors go to
PowerShell's streams and the host renders them — and on PowerShell 7 `NO_COLOR`
additionally forces `$PSStyle.OutputRendering` to `PlainText` for the run.

Standard PowerShell parameters also apply:

| Parameter | Effect |
| --- | --- |
| `-WhatIf` | Full dry run. Takes precedence over `-Force`. |
| `-Confirm` | Prompt before the stop-clear-restart operation. |
| `-Verbose` | One line per file removed or skipped, and per service transition. |
| `-InformationAction SilentlyContinue` | Quiet run. Progress goes to the information stream, which is on by default. |

## Output

One result object on the success stream:

| Property | Meaning |
| --- | --- |
| `Mode` | `Download` or `ResetDataStore`. |
| `Path` | The directory that was measured. |
| `ItemCount` / `ByteCount` | Files found and their total size. |
| `ItemsRemoved` / `BytesFreed` | What was actually deleted. Always 0 in `ResetDataStore` mode. |
| `ItemsSkipped` | Files that could not be removed. |
| `BytesMovedAside` / `BackupPath` | `ResetDataStore` only: how much was renamed aside, and to where. |
| `ServiceStopped` / `ServiceRestarted` | The services that were running when the run started (so the script owns restoring them), and the ones it brought back. Compare them: if they differ, a service did not restart and a warning names it. |
| `Status` | `Success`, `Partial`, `Failed`, `NothingToDo` or `Skipped` (`-WhatIf`, or declined at the prompt). |

## Exit codes

The repository-wide table. Every script in this repository uses these numbers and no
others.

| Code | Meaning here |
| --- | --- |
| `0` | The cache was cleared and every stopped service was restarted. |
| `1` | The work ran but part of it failed: a partial clear, or a service that would not stop or restart. |
| `2` | Usage error: an unknown argument, or an invalid parameter or `LZC_UPDATES_*` value — including a cache directory that does not exist, is a drive root, is a protected system directory, or is not named `SoftwareDistribution` while `-ResetDataStore` is in use. |
| `3` | Not Windows, or PowerShell older than 5.1. |
| `4` | Not running as Administrator. |
| `5` | Refused: the run needs confirmation, there is no terminal to confirm on, and neither `-Force` nor `-Confirm:$false` was given. |
| `75` | Another instance holds `Global\lzc-updates` (`EX_TEMPFAIL`: retry later, not a fault). |
| `130` | Interrupted (Ctrl-C or cancellation). Services stopped by the run are restarted before it unwinds. |

A scheduled task should treat `75` as "retry later", not as a failure. See the
[repo-wide table](../../docs/exit-codes.md).

Some updates need a restart before Windows Update behaves normally again. This script
never reboots and never asks Windows to reboot.

## Scheduled task

Use `-File`, never `-Command`. `-Command` collapses the exit code to 0 or 1.

```
Program:   C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe
Arguments: -NoProfile -NonInteractive -ExecutionPolicy Bypass
           -File "C:\Scripts\windows\Updates\Clear-WindowsUpdateCache.ps1" -Force
```

`-NoProfile` is not optional: a user profile that changes `$ErrorActionPreference` or
defines aliases would change how the script behaves.

`-Force` is not optional either. Without it the task has nothing to confirm on and the
run is refused with exit `5`; set `LZC_UPDATES_FORCE=1` if you prefer to carry it in
the environment.

**Passing several services through `-File`: use the comma form, in one token.**
`powershell.exe -File` hands each argument to the script as one literal string, so
`-ServiceName wuauserv,bits,UsoSvc` arrives as the single string
`wuauserv,bits,UsoSvc` — which this script splits on commas, so it does the right
thing. The space-separated form is silently wrong: `-ServiceName wuauserv bits` binds
only `wuauserv`, and `bits` falls through to the positional
`-SoftwareDistributionPath`, so the run then fails on a cache directory called
`bits`.

`LZC_UPDATES_SERVICES=wuauserv,bits,UsoSvc` works the same way and is the tidier
choice when the task already carries other settings in the environment.
