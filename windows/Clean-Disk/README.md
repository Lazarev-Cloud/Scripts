# Clean-Disk

Deletes stale files from temporary directories and reports exactly how much space
was freed.

## What it does

Enumerates every file under the directories you name, removes the ones older than a
minimum age, then removes the subdirectories that became empty. It reports the byte
count it actually reclaimed, counting only files whose deletion succeeded.

By default it cleans two directories:

| Default target | Note |
| --- | --- |
| `%SystemRoot%\Temp` | The machine temp directory. |
| `%TEMP%` | The temp directory of the account running the script. Because elevation is required, this is the **elevated** account's temp directory, not the logged-on user's. Name a specific profile with `-Path` if you need someone else's. |

## Blast radius

Files and now-empty subdirectories underneath the paths given by `-Path`. Nothing
else. The root directories themselves are never removed.

Refused outright, with a warning:

- Drive roots (`C:\`, `D:\`, ...).
- `%SystemRoot%`, `%SystemRoot%\System32`, `%SystemRoot%\SysWOW64`,
  `%SystemRoot%\WinSxS`, `%ProgramFiles%`, `%ProgramFiles(x86)%`, `%ProgramData%`,
  `%SystemDrive%\Users`.
- Anything that is not an existing directory.

Other safety properties:

- Every deletion passes `$PSCmdlet.ShouldProcess`, so `-WhatIf` is a complete and
  accurate dry run that changes nothing.
- Files newer than `-MinimumAgeHours` are kept, so a running installer's working
  files survive. The default is 24 hours.
- Every file is checked to be inside its root before deletion, and reparse points
  (junctions and symlinks) are skipped. A junction planted inside a temp directory
  cannot be used to escape the target.
- Files that are locked or access-denied are counted, reported, and skipped. They
  never abort the run, and their size is never counted as freed.
- The Recycle Bin is user data and is only emptied with `-IncludeRecycleBin`.
- A run that will delete something holds a machine-wide lock
  (`Global\lzc-clean-disk`); a second run exits `75` instead of sweeping the same
  directory concurrently. `-WhatIf` takes no lock, so a preview is never blocked.
- A run that would prompt, on a host with no terminal to prompt on and without
  `-Force`, is refused with exit `5` before anything is deleted.

The Windows Update download cache is **not** cleaned here. Deleting it while
`wuauserv` and BITS hold handles only half works. Use
[`../Updates/Clear-WindowsUpdateCache.ps1`](../Updates/Clear-WindowsUpdateCache.ps1),
which stops the services first.

## Requirements

- Windows. Any other platform exits `3`.
- Windows PowerShell 5.1 or PowerShell 7.x. Older exits `3`.
- Administrator; a non-elevated run exits `4`. Elevation is required even for
  `-WhatIf`, because without it `%SystemRoot%\Temp` cannot be enumerated and the
  preview would under-report what it would delete.

Elevation is checked at run time rather than with `#Requires -RunAsAdministrator`,
which fails the script before it starts and exits `1`. The runtime check is what
makes the documented exit `4` reachable.

Arguments and `LZC_CLEAN_DISK_*` values are validated **before** the elevation
check, so a typo can be found from an ordinary shell.

## Usage

```powershell
# Dry run against the default targets. Changes nothing.
.\Clean-Disk.ps1 -WhatIf

# Interactive run. Prompts once per directory before deleting.
.\Clean-Disk.ps1

# Unattended, everything regardless of age, with per-file narration.
.\Clean-Disk.ps1 -MinimumAgeHours 0 -Force -Verbose

# Two build scratch directories, files older than a week.
.\Clean-Disk.ps1 -Path 'D:\BuildCache','E:\Scratch' -MinimumAgeHours 168 -Force

# Full help, including every example.
Get-Help .\Clean-Disk.ps1 -Full
```

## Parameters

Every parameter has an environment variable, so the script can be driven entirely
from the environment in a scheduled task or container. Every variable is named
`LZC_CLEAN_DISK_*`, so `Get-ChildItem env:LZC_*` lists everything configurable in
this repository.

| Parameter | Environment variable | Default | Meaning |
| --- | --- | --- | --- |
| `-Path <string[]>` | `LZC_CLEAN_DISK_PATHS` (semicolon separated) | `%SystemRoot%\Temp`, `%TEMP%` | Directories to clean. |
| `-MinimumAgeHours <int>` | `LZC_CLEAN_DISK_MIN_AGE_HOURS` | `24` | Only remove files whose `LastWriteTime` is at least this old. `0` removes everything found. Range 0-87600. |
| `-IncludeRecycleBin` | `LZC_CLEAN_DISK_INCLUDE_RECYCLE_BIN` | off | Also empty the Recycle Bin on every drive. |
| `-KeepEmptyDirectory` | `LZC_CLEAN_DISK_KEEP_EMPTY_DIR` | off | Leave behind subdirectories that became empty. |
| `-Force` | `LZC_CLEAN_DISK_FORCE` | off | Suppress confirmation prompts. Required for unattended runs. |

An explicitly passed parameter always wins over its environment variable.

Value rules, enforced with a clear message and exit `2` rather than a default or a
crash:

- **Booleans** (`LZC_CLEAN_DISK_INCLUDE_RECYCLE_BIN`, `LZC_CLEAN_DISK_KEEP_EMPTY_DIR`,
  `LZC_CLEAN_DISK_FORCE`) accept `1`, `true`, `yes`, `on`, `0`, `false`, `no`, `off`,
  in any case. Anything else is a usage error.
- **Numbers** (`LZC_CLEAN_DISK_MIN_AGE_HOURS`, `-MinimumAgeHours`) are digits only,
  within the documented range. `0x10`, `+5`, `5.0` and `-1` are rejected; a
  zero-padded value such as `08` is read as decimal `8`, never as octal.

`NO_COLOR` (any non-empty value, per [no-color.org](https://no-color.org)) is
honoured. The script emits no colour of its own — progress, warnings and errors go
to PowerShell's streams and the host renders them — and on PowerShell 7 `NO_COLOR`
additionally forces `$PSStyle.OutputRendering` to `PlainText` for the run.

Standard PowerShell parameters also apply:

| Parameter | Effect |
| --- | --- |
| `-WhatIf` | Full dry run. Takes precedence over `-Force`. |
| `-Confirm` | Prompt for every operation, including empty-directory removal. |
| `-Verbose` | One line per file removed or skipped, with the reason. |
| `-InformationAction SilentlyContinue` | Quiet run. Progress goes to the information stream, which is on by default. |

## Output

Progress goes to the information stream, warnings to the warning stream, errors to
the error stream. The success stream carries only result objects, one per cleaned
directory, so `.\Clean-Disk.ps1 -Force | Export-Csv report.csv` works:

| Property | Meaning |
| --- | --- |
| `Path` | The resolved directory. |
| `ItemCount` / `ByteCount` | Files eligible for removal, and their total size. |
| `ItemsRemoved` / `BytesFreed` | What was actually deleted. Only successful deletions are counted. |
| `ItemsSkipped` / `BytesSkipped` | Files that could not be removed, usually because they were locked. |
| `DirectoriesRemoved` | Subdirectories removed for being empty. |
| `UnreadablePath` | Paths that could not be enumerated at all. |
| `Status` | `Success`, `Partial` (something could not be removed) or `Skipped` (`-WhatIf`, or declined at the prompt). |

## Exit codes

The repository-wide table. Every script in this repository uses these numbers and
no others.

| Code | Meaning here |
| --- | --- |
| `0` | Every requested directory was processed without error. |
| `1` | The clean ran but at least one file could not be removed. |
| `2` | Usage error: an unknown argument, an invalid parameter or `LZC_CLEAN_DISK_*` value, or no usable directory. |
| `3` | Not Windows, or PowerShell older than 5.1. |
| `4` | Not running as Administrator. |
| `5` | Refused: deleting needs confirmation, there is no terminal to confirm on, and neither `-Force` nor `-Confirm:$false` was given. |
| `75` | Another instance holds `Global\lzc-clean-disk` (`EX_TEMPFAIL`: retry later, not a fault). |
| `130` | Interrupted (Ctrl-C or cancellation). |

A scheduled task should treat `75` as "retry later", not as a failure.

## Scheduled task

Use `-File`, never `-Command`. `-Command` collapses the exit code to 0 or 1.

```
Program:   C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe
Arguments: -NoProfile -NonInteractive -ExecutionPolicy Bypass
           -File "C:\Scripts\windows\Clean-Disk\Clean-Disk.ps1" -Force
```

`-NoProfile` is not optional: a user profile that changes `$ErrorActionPreference`
or defines aliases would change how the script behaves.

`-Force` is not optional either. Without it the task has nothing to confirm on and
the run is refused with exit `5`; set `LZC_CLEAN_DISK_FORCE=1` if you prefer to
carry it in the environment.

**Passing several directories through `-File`: use the environment variable.**
`powershell.exe -File` hands each argument to the script as one literal string, so
neither `-Path C:\a C:\b` nor `-Path C:\a,C:\b` does what it looks like: the first
binds only `C:\a` and lets `C:\b` fall through to the unknown-argument catch-all
(exit `2`), and the second arrives as a single path named `C:\a,C:\b`. A comma or a
semicolon is legal in a Windows directory name, so `-Path` is deliberately not split
on either.

Pass one `-Path` on the command line, or set
`LZC_CLEAN_DISK_PATHS=C:\a;C:\b` in the task's environment, which is split on
semicolons.

In an **interactive** PowerShell session the comma form `-Path C:\a,C:\b` does work,
because there the PowerShell parser itself builds the array before the script is
called. The space-separated form `-Path C:\a C:\b` works in neither host: `C:\b`
falls through to the unknown-argument catch-all and the run is refused with exit `2`.
