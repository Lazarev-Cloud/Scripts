# RepairSystemFiles

Repairs the Windows component store with DISM, then repairs protected system files
with SFC, and reports the real exit codes and log paths.

## The order matters

```
1. Dism.exe /Online /Cleanup-Image /RestoreHealth   repairs the component store
2. sfc.exe /scannow                                 repairs protected system files
                                                    FROM that store
```

SFC replaces damaged system files with copies taken from the component store. If the
store itself is damaged, SFC has nothing good to copy from. Microsoft states it
plainly: run DISM before the System File Checker. Running SFC first, or running SFC
alone, is the single most common mistake in Windows repair scripts, and it is the
reason this script exists.

## Stages

| `-Stage` | What runs | Read-only? |
| --- | --- | --- |
| `Check` | `Dism /Online /Cleanup-Image /CheckHealth` | Yes. Fast. Reports whether corruption has already been flagged; does not scan. |
| `Scan` | `Dism /Online /Cleanup-Image /ScanHealth` | Yes. Slow. Scans the store for corruption. |
| `Repair` | `Dism /RestoreHealth`, then `sfc /scannow` | **No.** The default. |

Start with `-Stage Scan` if you want to know whether anything is wrong before
changing anything.

## Blast radius

`DISM /RestoreHealth` rewrites files inside the component store
(`%SystemRoot%\WinSxS`) and may download replacement payloads from Windows Update.
`sfc /scannow` replaces protected system files. Both are Microsoft's own repair tools
and both are designed to be safe to re-run, but neither is read-only.

Every tool invocation passes `$PSCmdlet.ShouldProcess` first, so `-WhatIf` prints the
exact command lines in order and runs none of them. That gate is necessary because
`-WhatIf` does not reach a native executable on its own: `dism.exe` and `sfc.exe`
know nothing about PowerShell.

A `-Stage Repair` run holds a machine-wide named mutex (`Global\lzc-repairsystemfiles`)
and a second run exits `75`, because two concurrent servicing operations fail on the
servicing stack's own lock with a far less obvious error. The read-only stages and any
`-WhatIf` preview take no lock and are never blocked.

## Deliberately not done

| Omitted step | Why |
| --- | --- |
| `/StartComponentCleanup /ResetBase` | Microsoft's own warning: "All existing update packages can't be uninstalled after this command is completed." That permanently removes your ability to roll back every installed update, including the one that just broke the machine. It has no place in a repair script. |
| Deleting anything from `WinSxS` directly | Microsoft: doing so "may severely damage your system so that your PC might not boot". |
| Running `sfc /scannow` two or three times "to be sure" | One pass after a successful `RestoreHealth` is the documented procedure. A second pass is only warranted when the first reported corruption it could not fix, and DISM has been re-run since. |
| `chkdsk /f /r` | A response to observed disk corruption or SMART warnings, not maintenance. `/r` can take hours and locks the system volume across a reboot. |

## Tool exit codes and verdicts, honestly

This section is about what DISM and SFC return. For what the *script* returns, see
[Exit codes](#exit-codes) below.

- **DISM** returns `0` for success and `3010` for "success, restart required". Both
  are treated as success, and `3010` sets `Status = RebootRequired` on the result
  object. Any other code is a failure and is reported verbatim, not flattened into a
  generic message.
- **A read-only stage that finds corruption is a failure, not a pass.** DISM returns
  `0` for any scan that *completed*, so `-Stage Check` or `-Stage Scan` reporting "the
  component store is repairable" means corruption was found and nothing was repaired.
  The script reports `Status = Failed` and exits `1` rather than passing that off as a
  clean bill of health.
- **SFC has no documented exit-code contract.** Microsoft documents its outcomes as
  console messages, not return codes. This script therefore never concludes "your
  system is clean" from an exit code. It parses the console text into an explicit
  verdict and reports `Unknown` when nothing matches, rather than guessing.

`sfc.exe` writes UTF-16 when its output is redirected; the script strips the NUL
bytes so the text parses correctly.

Verdict parsing matches the **English** console strings. On a non-English Windows the
tools still run correctly and the exit code is still reported accurately, but the two
tools degrade differently, and the difference matters:

- **SFC** has no exit-code fallback. Unmatched output becomes `Unknown`, which maps to
  exit `1`. An unreadable SFC outcome is never mistaken for a healthy one.
- **DISM** does have an exit-code contract, so unmatched output with exit code `0`
  falls back to `Completed`, not `Unknown`. A read-only `-Stage Check` or `-Stage Scan`
  on a localized Windows therefore **cannot** detect "the component store is
  repairable", and reports `Success` with exit `0` even when corruption was found.

**Do not read exit `0` from a localized read-only scan as a clean store.** Read
`dism.log`, or run `-Stage Repair`, which repairs regardless of console language.

| Verdict (SFC) | Meaning |
| --- | --- |
| `Clean` | No integrity violations found. |
| `Repaired` | Corrupt files found and repaired. |
| `RepairFailed` | Corruption found that SFC could not fix. Re-run DISM, then SFC. |
| `RebootRequired` | A system repair is already pending. Reboot and re-run. |
| `ScanFailed` | SFC could not complete the scan. |
| `NotElevated` | SFC refused for want of administrative privileges. |
| `Unknown` | Output matched no known phrase. Read the log; draw no conclusion. |

| Verdict (DISM) | Meaning |
| --- | --- |
| `NoCorruption` | No component store corruption detected. |
| `Repairable` | Corruption found and the store is repairable. |
| `Repaired` | The restore operation completed. |
| `SourceMissing` | DISM could not obtain replacement files (often `0x800f081f`). Supply `-Source`. |
| `TimedOut` | The tool exceeded `-TimeoutMinutes` and was terminated. |
| `Completed` / `Unknown` | Completed with no more specific phrase / unclassified. |

## Logs

These hold far more detail than the console:

```
%SystemRoot%\Logs\CBS\CBS.log      SFC and servicing detail
%SystemRoot%\Logs\DISM\dism.log    DISM detail
```

Extract just the SFC findings:

```
findstr /c:"[SR]" %windir%\Logs\CBS\CBS.log > "%userprofile%\Desktop\sfc.txt"
```

The script prints both paths in its summary and puts the relevant one on every result
object.

## Requirements

- Windows. Any other platform exits `3`.
- Windows PowerShell 5.1 or PowerShell 7.x. Older exits `3`.
- `Dism.exe` and `sfc.exe` present. Only the tools the requested stage will actually
  use are required, so `-SkipSfc` is not blocked by a missing `sfc.exe`. A missing
  tool exits `3`.
- Administrator; a non-elevated run exits `4`. Elevation is required even for the
  read-only stages and for `-WhatIf`, because `DISM /Online` refuses to run without
  it.

Elevation is checked at run time rather than with `#Requires -RunAsAdministrator`,
which fails the script before it starts and exits `1`. The runtime check is what
makes the documented exit `4` reachable.

Arguments and `LZC_REPAIRSYSTEMFILES_*` values are validated **before** the elevation
check, so a typo can be found from an ordinary shell.

Both tools are called by absolute path, never by bare name, because `PATH` is
influenceable. On 64-bit Windows that path goes through `Sysnative` rather than
`System32` whenever the script runs inside a 32-bit PowerShell (some RMM agents and
scheduled tasks still do): WOW64 redirects `System32` to `SysWOW64` for a 32-bit
process, and the 32-bit DISM refuses to service a running 64-bit operating system.

## Usage

```powershell
# Read-only assessment first.
.\RepairSystemFiles.ps1 -Stage Scan

# See exactly what the default repair would run, in order. Runs nothing.
.\RepairSystemFiles.ps1 -WhatIf

# Interactive repair: DISM RestoreHealth, then SFC.
.\RepairSystemFiles.ps1

# Unattended, with the tool output narrated.
.\RepairSystemFiles.ps1 -Force -Verbose

# Windows Update is itself broken: repair from a local image.
.\RepairSystemFiles.ps1 -Source 'WIM:D:\sources\install.wim:1' -Force
.\RepairSystemFiles.ps1 -Source 'D:\mount\Windows' -Force

Get-Help .\RepairSystemFiles.ps1 -Full
```

## Parameters

Every parameter has an environment variable, so the script can be driven entirely
from the environment in a scheduled task. Every variable is named
`LZC_REPAIRSYSTEMFILES_*`, so `Get-ChildItem env:LZC_*` lists everything configurable
in this repository.

| Parameter | Environment variable | Default | Meaning |
| --- | --- | --- | --- |
| `-Stage <Check\|Scan\|Repair>` | `LZC_REPAIRSYSTEMFILES_STAGE` | `Repair` | Which stage to run. Case does not matter. |
| `-Source <string>` | `LZC_REPAIRSYSTEMFILES_SOURCE` | none | Known-good source for DISM: a mounted image directory, or a `WIM:<path>:<index>` specifier. Implies `/LimitAccess`, so DISM will not contact Windows Update. |
| `-SkipDism` | `LZC_REPAIRSYSTEMFILES_SKIP_DISM` | off | Run SFC only. Rarely correct: it reintroduces the ordering problem. The script warns when you use it. |
| `-SkipSfc` | `LZC_REPAIRSYSTEMFILES_SKIP_SFC` | off | Run DISM only. |
| `-TimeoutMinutes <int>` | `LZC_REPAIRSYSTEMFILES_TIMEOUT_MINUTES` | `120` | Wall-clock limit for **each** tool invocation separately, so a `Repair` stage can take twice this long. Range 1-1440. |
| `-Force` | `LZC_REPAIRSYSTEMFILES_FORCE` | off | Suppress confirmation prompts. Required for unattended runs. |

An explicitly passed parameter always wins over its environment variable. `-WhatIf`
takes precedence over `-Force`.

Value rules, enforced with a clear message and exit `2` rather than a default or a
crash:

- **Booleans** (`LZC_REPAIRSYSTEMFILES_SKIP_DISM`, `..._SKIP_SFC`, `..._FORCE`) accept
  `1`, `true`, `yes`, `on`, `0`, `false`, `no`, `off`, in any case.
- **Numbers** (`LZC_REPAIRSYSTEMFILES_TIMEOUT_MINUTES`, `-TimeoutMinutes`) are digits
  only, within the documented range. A zero-padded value such as `08` is read as
  decimal `8`, never as octal.
- Passing both `-SkipDism` and `-SkipSfc` leaves nothing to run and is a usage error.

**About the timeout.** There is deliberately no "wait forever" value: an unbounded
DISM is exactly the hang the bound exists to prevent, so `0` is rejected rather than
treated as unlimited. Terminating DISM part way through a repair can leave a pending
servicing operation; the fix is to reboot and re-run, and the script says so when it
times out. The 120-minute default is generous for `/RestoreHealth` on a slow disk —
raise it rather than letting a slow-but-healthy repair get killed.

`NO_COLOR` (any non-empty value, per [no-color.org](https://no-color.org)) is
honoured. The script emits no colour of its own — progress, warnings and errors go to
PowerShell's streams and the host renders them — and on PowerShell 7 `NO_COLOR`
additionally forces `$PSStyle.OutputRendering` to `PlainText` for the run.

## Output

One result object per tool that ran:

| Property | Meaning |
| --- | --- |
| `Tool` / `Operation` | `DISM` + `RestoreHealth`, `SFC` + `scannow`, etc. |
| `CommandLine` | The exact command line that ran, with an absolute executable path. |
| `ExitCode` | The tool's real exit code. `$null` when the tool timed out or never started. |
| `Verdict` | The parsed verdict from the tables above. |
| `DurationSeconds` | Wall-clock time. |
| `LogPath` | The log with the detail for that tool. |
| `Status` | `Success`, `RebootRequired`, `Failed`, `Unknown` or `Skipped`. |

`-Verbose` additionally narrates every line the tool printed.

## Exit codes

The repository-wide table. Every script in this repository uses these numbers and no
others.

| Code | Meaning here |
| --- | --- |
| `0` | Every stage that ran reported success and no corruption remains. **A pending restart is still `0`** — see below. |
| `1` | A tool failed, timed out, or reported corruption it could not repair. Also returned when a result could not be classified, so an unreadable outcome is never mistaken for a healthy one. |
| `2` | Usage error: an unknown argument, an invalid parameter or `LZC_REPAIRSYSTEMFILES_*` value, a `-Source` that does not exist, or `-SkipDism` together with `-SkipSfc`. |
| `3` | Not Windows, PowerShell older than 5.1, or `Dism.exe`/`sfc.exe` missing. |
| `4` | Not running as Administrator. |
| `5` | Refused: the run needs confirmation, there is no terminal to confirm on, and neither `-Force` nor `-Confirm:$false` was given. |
| `75` | Another instance holds `Global\lzc-repairsystemfiles` (`EX_TEMPFAIL`: retry later, not a fault). |
| `130` | Interrupted (Ctrl-C or cancellation). |

**A pending restart is not signalled with a bespoke exit code.** DISM's own `3010` is
recorded on the result object (`ExitCode = 3010`, `Status = RebootRequired`) and the
script still exits `0`, because the work succeeded. A deployment tool that needs to
schedule a reboot should test the result objects:

```powershell
$r = .\RepairSystemFiles.ps1 -Force
if ($r | Where-Object Status -eq 'RebootRequired') { <# schedule the restart #> }
```

## Scheduled task

Use `-File`, never `-Command`. `-Command` collapses the exit code to 0 or 1.

```
Program:   C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe
Arguments: -NoProfile -NonInteractive -ExecutionPolicy Bypass
           -File "C:\Scripts\windows\RepairSystemFiles\RepairSystemFiles.ps1" -Force
```

`-Force` is not optional: without it the task has nothing to confirm on and the run is
refused with exit `5`. Set `LZC_REPAIRSYSTEMFILES_FORCE=1` if you prefer to carry it
in the environment.
