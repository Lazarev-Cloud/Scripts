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

- Windows PowerShell 5.1 or PowerShell 7.x.
- Administrator. Enforced by `#Requires -RunAsAdministrator`.

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

| Parameter | Environment variable | Default | Meaning |
| --- | --- | --- | --- |
| `-SoftwareDistributionPath <string>` | `WU_CACHE_PATH` | `%SystemRoot%\SoftwareDistribution` | The directory to operate on. |
| `-ServiceName <string[]>` | `WU_CACHE_SERVICES` (comma separated) | `wuauserv`, `bits` | Services to stop for the duration. These two hold the handles inside `Download`. Add `UsoSvc` if files remain locked. |
| `-ServiceTimeoutSeconds <int>` | `WU_CACHE_SERVICE_TIMEOUT` | `60` | How long to wait for each service to reach the requested state. Range 5-3600. |
| `-ResetDataStore` | `WU_CACHE_RESET_DATASTORE` | off | Rename the whole directory aside instead of clearing only `Download`. Discards update history. |
| `-Force` | `WU_CACHE_FORCE` | off | Suppress confirmation prompts. Required for unattended runs. |

An explicitly passed switch always wins over its environment variable. `-WhatIf`,
`-Confirm`, `-Verbose` and `-InformationAction` work as usual; `-WhatIf` takes
precedence over `-Force`.

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
| `Status` | `Success`, `Partial`, `Failed`, `NothingToDo` or `Skipped`. |

## Exit codes

| Code | Meaning |
| --- | --- |
| `0` | The cache was cleared and every stopped service was restarted. |
| `1` | The clear was partial, or a service failed to stop or restart. |
| `2` | Usage or precondition failure: the cache directory does not exist. |

Some updates need a restart before Windows Update behaves normally again. This script
never reboots and never asks Windows to reboot.

## Scheduled task

Use `-File`, never `-Command`.

```
Program:   C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe
Arguments: -NoProfile -NonInteractive -ExecutionPolicy Bypass
           -File "C:\Scripts\windows\Updates\Clear-WindowsUpdateCache.ps1" -Force
```

When passing `-ServiceName` through `-File`, list the values space separated
(`-ServiceName wuauserv bits UsoSvc`), not comma separated; `-File` binds array
parameters from separate tokens. The comma form shown in the examples above is for
interactive use. Alternatively set `WU_CACHE_SERVICES=wuauserv,bits,UsoSvc` in the
environment, which takes a comma-separated list either way.
