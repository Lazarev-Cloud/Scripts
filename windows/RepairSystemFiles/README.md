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

## Deliberately not done

| Omitted step | Why |
| --- | --- |
| `/StartComponentCleanup /ResetBase` | Microsoft's own warning: "All existing update packages can't be uninstalled after this command is completed." That permanently removes your ability to roll back every installed update, including the one that just broke the machine. It has no place in a repair script. |
| Deleting anything from `WinSxS` directly | Microsoft: doing so "may severely damage your system so that your PC might not boot". |
| Running `sfc /scannow` two or three times "to be sure" | One pass after a successful `RestoreHealth` is the documented procedure. A second pass is only warranted when the first reported corruption it could not fix, and DISM has been re-run since. |
| `chkdsk /f /r` | A response to observed disk corruption or SMART warnings, not maintenance. `/r` can take hours and locks the system volume across a reboot. |

## Exit codes and verdicts, honestly

- **DISM** returns `0` for success and `3010` for "success, restart required". Both
  are treated as success; `3010` becomes the script's exit code. Any other code is a
  failure and is reported verbatim, not flattened into a generic message.
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
| `Unknown` | Output matched no known phrase. Read the log; draw no conclusion. |

| Verdict (DISM) | Meaning |
| --- | --- |
| `NoCorruption` | No component store corruption detected. |
| `Repairable` | Corruption found and the store is repairable. |
| `Repaired` | The restore operation completed. |
| `SourceMissing` | DISM could not obtain replacement files (often `0x800f081f`). Supply `-Source`. |
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

- Windows PowerShell 5.1 or PowerShell 7.x.
- Administrator. Enforced by `#Requires -RunAsAdministrator`.

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

| Parameter | Environment variable | Default | Meaning |
| --- | --- | --- | --- |
| `-Stage <Check\|Scan\|Repair>` | `REPAIR_STAGE` | `Repair` | Which stage to run. |
| `-Source <string>` | `REPAIR_DISM_SOURCE` | none | Known-good source for DISM: a mounted image directory, or a `WIM:<path>:<index>` specifier. Implies `/LimitAccess`, so DISM will not contact Windows Update. |
| `-SkipDism` | `REPAIR_SKIP_DISM` | off | Run SFC only. Rarely correct: it reintroduces the ordering problem. The script warns when you use it. |
| `-SkipSfc` | `REPAIR_SKIP_SFC` | off | Run DISM only. |
| `-TimeoutMinutes <int>` | `REPAIR_TIMEOUT_MINUTES` | `120` | Per-tool wall-clock limit. `0` waits indefinitely. Range 0-1440. |
| `-Force` | `REPAIR_FORCE` | off | Suppress confirmation prompts. Required for unattended runs. |

An explicitly passed switch always wins over its environment variable. `-WhatIf`
takes precedence over `-Force`.

**About the timeout.** Terminating DISM part way through a repair can leave a pending
servicing operation. The fix is to reboot and re-run, and the script says so when it
times out. The 120-minute default is generous for `/RestoreHealth` on a slow disk;
raise it or set `0` rather than letting a slow-but-healthy repair get killed.

## Output

One result object per tool that ran:

| Property | Meaning |
| --- | --- |
| `Tool` / `Operation` | `DISM` + `RestoreHealth`, `SFC` + `scannow`, etc. |
| `CommandLine` | The exact command line that ran, with an absolute executable path. |
| `ExitCode` | The tool's real exit code. |
| `Verdict` | The parsed verdict from the tables above. |
| `DurationSeconds` | Wall-clock time. |
| `LogPath` | The log with the detail for that tool. |
| `Status` | `Success`, `RebootRequired`, `Failed`, `Unknown` or `Skipped`. |

## Exit codes

| Code | Meaning |
| --- | --- |
| `0` | Every stage that ran reported success and no corruption remains. |
| `1` | A tool failed, timed out, or reported corruption it could not repair. Also returned when a result could not be classified, so an unreadable outcome is never mistaken for a healthy one. |
| `2` | Usage or precondition failure: a tool was missing, `-Source` does not exist, or both stages were skipped. |
| `3010` | Success, and a restart is required to finish. |

## Scheduled task

Use `-File`, never `-Command`.

```
Program:   C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe
Arguments: -NoProfile -NonInteractive -ExecutionPolicy Bypass
           -File "C:\Scripts\windows\RepairSystemFiles\RepairSystemFiles.ps1" -Force
```

Management systems such as Intune, SCCM and most RMM tools understand `3010` and will
handle the reboot for you.
