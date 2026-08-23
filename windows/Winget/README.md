# WingetFix

Diagnoses winget, cleans stale App Installer directories out of the system `PATH`, resets package
sources, and — only when you ask — upgrades installed packages.

## Blast radius

| Action | Elevation | Effect |
| --- | --- | --- |
| `Report` | No | None. Read-only |
| `CleanPath` | Yes | Rewrites the machine `PATH` registry value. Backed up to a file first |
| `SourceReset` | No | Resets winget sources to defaults; custom and private sources are removed |
| `Upgrade` | No | Upgrades installed packages. Can close running applications and request reboots |

`Report` is the default.

## The PATH problem this fixes

winget is reached through the **per-user App Execution Alias** at
`%LOCALAPPDATA%\Microsoft\WindowsApps\winget.exe`, which is already on `PATH` by default.

A common "fix winget" snippet appends the versioned install directory instead:

```
%ProgramFiles%\WindowsApps\Microsoft.DesktopAppInstaller_<version>_x64__8wekyb3d8bbwe
```

That directory name changes with **every** App Installer update, so each run leaves another dead
entry behind and the machine `PATH` grows until it hits the registry value size limit. The
entries never did anything useful, because winget was always resolving via the alias.

`-Action Report` lists any such entries and whether the directory still exists.
`-Action CleanPath` removes them. By default it only removes entries whose directory is **gone**;
pass `-RemoveExistingAppInstallerPath` to also drop ones that still exist.

`CleanPath` reads the **raw, unexpanded** registry value and writes it back with its original type
(normally `REG_EXPAND_SZ`), so any `%VAR%` references elsewhere in `PATH` keep working. The
previous value is saved to `machine-path-<stamp>.txt` under `-BackupPath` before anything changes,
and the change is abandoned if that backup cannot be written.

Already-running processes keep the old `PATH`. Sign out and back in for the change to apply
everywhere.

## Usage

```powershell
# Read-only diagnosis: winget location, version, sources, stale PATH entries.
.\WingetFix.ps1

# Preview the PATH cleanup.
.\WingetFix.ps1 -Action CleanPath -WhatIf

# Do it (elevated).
.\WingetFix.ps1 -Action CleanPath -Force

# Re-point sources at the defaults.
.\WingetFix.ps1 -Action SourceReset

# Explicitly opt in to a mass upgrade.
.\WingetFix.ps1 -Action Upgrade -Force
```

## Parameters

| Parameter | Environment variable | Default | Meaning |
| --- | --- | --- | --- |
| `-Action` | `LZC_WINGET_ACTION` | `Report` | `Report`, `CleanPath`, `SourceReset`, `Upgrade` |
| `-BackupPath` | `LZC_WINGET_BACKUP_PATH` | `%ProgramData%\LazarevScripts\WingetFix` | Where the `PATH` backup is written |
| `-RemoveExistingAppInstallerPath` | `LZC_WINGET_REMOVE_EXISTING` | off | Also remove App Installer entries that still exist on disk |
| `-IncludeUnknown` | `LZC_WINGET_INCLUDE_UNKNOWN` | off | With `Upgrade`, also upgrade packages whose installed version is unknown |
| `-TimeoutSeconds` | `LZC_WINGET_TIMEOUT_SECONDS` | `1800` | Per-winget-command timeout, 30-7200. See below |
| `-Force` | `LZC_WINGET_FORCE` | off | Suppress confirmation prompts, for unattended use |
| `-WhatIf` | — | — | Dry run. Wins over `-Force` |
| `-Version` | — | — | Print the version and exit |

A parameter given on the command line always wins; the environment variable is only read when
the parameter was not passed.

**What `-TimeoutSeconds` bounds.** One winget invocation, not the whole run. Each `winget` call
the script makes gets the allowance separately, so a `Report` that asks for both version and
sources spends it twice. It does *not* bound an individual package install inside
`winget upgrade --all` — that entire command is a single invocation, which is why the default is
a generous 30 minutes.

**Boolean values.** `LZC_WINGET_REMOVE_EXISTING`, `LZC_WINGET_INCLUDE_UNKNOWN` and
`LZC_WINGET_FORCE` accept `1`, `true`, `yes`, `on`, `0`, `false`, `no` and `off`, in any case.
Any other value is a usage error and exits `2` — an unrecognised word is never read as "off", so
a typo in a scheduled task surfaces immediately instead of silently disabling the flag.

**Numeric values.** `LZC_WINGET_TIMEOUT_SECONDS` is parsed as decimal, so a zero-padded value
such as `08` means 8. Non-numeric and out-of-range values exit `2`. The floor of 30 is enforced
so the timeout can never be set to 0, which a caller would reasonably read as "no limit" and
which would remove the protection the option exists to provide.

**Colour.** This script emits no colour: all narration goes to the information, warning and error
streams, and it writes no escape sequences of its own. There is nothing for `NO_COLOR` to
suppress. Any colour you see is the host rendering the warning and error streams.

## Exit codes

These are the repo-wide codes. This script returns the subset below.

| Code | Meaning |
| --- | --- |
| `0` | Success, or a `-WhatIf` dry run |
| `1` | The work ran but something in it failed |
| `2` | Usage error: an unknown or invalid parameter or environment variable value |
| `3` | Missing prerequisite or unsupported context: winget was not found, or the session is `SYSTEM` |
| `4` | Must be run as administrator (`CleanPath` writes the machine `PATH`) |
| `5` | Refused: confirmation was needed, the session cannot prompt, and `-Force` was not given |

Guards run in a fixed order, so the code you get names the first thing that was wrong:
configuration (`2`), prerequisites (`3`), elevation (`4`), interactivity (`5`), then the work
itself (`0` or `1`).

Exit `5` is what you get from a scheduled task or any other host that cannot answer a prompt.
Pass `-Force` (or set `LZC_WINGET_FORCE=1`) to confirm in advance. `Report` is read-only and is
never gated this way.

One limit worth knowing: a malformed **command line** — an unknown parameter, or a value rejected
by `ValidateSet`/`ValidateRange` — is caught by PowerShell's parameter binder before any script
code runs, and PowerShell exits `1`. Only validation the script performs itself, which is every
environment variable, can report `2`.

`Upgrade` treats winget's "no applicable update found" result (`0x8A150014`) as success, because
finding nothing to upgrade is a normal outcome rather than a failure.

## Requirements

- Windows PowerShell 5.1 or PowerShell 7 on Windows.
- App Installer (winget) for every action except `CleanPath`, which only touches the registry.
- Administrator rights for `CleanPath` only.

**Under a `SYSTEM` scheduled task winget generally does not resolve at all**, because it is a
per-user MSIX alias. The script detects this and fails with a clear message instead of a mystery
error. Run the task as an interactive user account.

## What this script does not do

- **It never writes a versioned App Installer directory into `PATH`.** That is the bug, not the
  fix; see above.
- **It never upgrades packages unless you ask.** `winget upgrade --all` is an unattended mass
  software upgrade, not maintenance: it can restart browsers, replace developer toolchains, and
  reboot or sign out for some installers. It is a named action, never the default.
- **It does not repair winget itself.** The documented route is the `Microsoft.WinGet.Client`
  module, which is known to be unreliable across releases, so it is left as a deliberate manual
  step:

  ```powershell
  Install-Module Microsoft.WinGet.Client -Scope CurrentUser
  Repair-WinGetPackageManager -Latest
  ```

  Note that `winget install Microsoft.AppInstaller` cannot fix a broken winget — you would need a
  working winget to run it.

## Useful winget commands

| Command | Description |
| --- | --- |
| `winget list` | List installed packages |
| `winget source reset --force` | Reset sources to defaults |
| `winget export -o apps.json` | Export installed apps |
| `winget import -i apps.json` | Reinstall from an export |
