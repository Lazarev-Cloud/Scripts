# ReRegisterWindowsApps

Repairs a **single named** Microsoft Store app for the **current user**, using the supported
`Reset-AppxPackage` path.

## Read this first

This script deliberately does not do what almost every "re-register Windows apps" snippet does.
The widely copied one-liner is:

```powershell
# HARMFUL - this script will not do this
Get-AppxPackage -AllUsers | Foreach {Add-AppxPackage -DisableDevelopmentMode -Register "$($_.InstallLocation)\AppXManifest.xml"}
```

Why it is harmful:

- `-AllUsers` iterates packages belonging to **every profile on the machine**. Deployment into
  another user's context usually fails with access-denied and can leave partial registrations.
- It re-registers packages that are staged but not installed for the current user, which
  **reinstalls apps the user deliberately removed**.
- Framework packages and packages with a null `InstallLocation` make it throw part-way through,
  so it half-completes silently.
- `Add-AppxPackage -Register <manifest>` is a **developer-mode sideload**. It bypasses the normal
  deployment path and can leave a package in a state the Store can no longer service, producing
  the well-known `0x80073CF6` / `0x80073D02` errors that often end in a machine reset.
- It cannot be made `-WhatIf`-safe: there is no gate per package.

## What this does instead

- Acts on **one** package that you name. Wildcards are rejected, so nothing fans out.
- Acts only on the **current user's** packages. Never `-AllUsers`.
- Prefers `Reset-AppxPackage`, the supported cmdlet for returning an app to its freshly-installed
  state.
- Falls back to the `-Register` sideload only via an explicit `-Action Reregister`, with a warning
  about what that costs.
- If the name matches more than one package, it lists them and stops rather than guessing.

## Run this as the affected user, not as administrator

AppX registration is **per user**. Run from an elevated session, it operates on the
administrator's profile and will not fix the app for the person who reported the problem. The
script refuses to run elevated unless `-AllowElevated` is passed.

## Blast radius

`-Action Reset` returns the named app to its freshly-installed state. **The app's local data and
settings are discarded** — sign-ins, preferences and cached content in the package's local store
are lost. Other apps and other users are not touched.

## Try these first

1. Settings → Apps → Installed apps → Advanced options → **Repair** (non-destructive)
2. The same screen's **Reset** (equivalent to `-Action Reset` here)
3. `wsreset.exe`, for Microsoft Store cache problems specifically

## Usage

```powershell
# List the Store apps installed for you, so you can find the exact name.
.\ReRegisterWindowsApps.ps1

# Narrow the list.
.\ReRegisterWindowsApps.ps1 -Name Calculator

# Preview a reset.
.\ReRegisterWindowsApps.ps1 -Name Microsoft.WindowsStore -Action Reset -WhatIf

# Do it.
.\ReRegisterWindowsApps.ps1 -Name Microsoft.WindowsCalculator -Action Reset -Force
```

## Parameters

| Parameter | Environment variable | Default | Meaning |
| --- | --- | --- | --- |
| `-Name` | `LZC_REREGISTERWINDOWSAPPS_NAME` | — | Package to act on. Exact `Name` match wins, otherwise a single substring match. Wildcards rejected. Required for `Reset`/`Reregister` |
| `-Action` | `LZC_REREGISTERWINDOWSAPPS_ACTION` | `Report` | `Report`, `Reset`, `Reregister` |
| `-AllowElevated` | `LZC_REREGISTERWINDOWSAPPS_ALLOW_ELEVATED` | off | Proceed in an elevated session, repairing the administrator profile |
| `-Force` | `LZC_REREGISTERWINDOWSAPPS_FORCE` | off | Suppress confirmation prompts, for unattended use |
| `-WhatIf` | — | — | Dry run. Wins over `-Force` |
| `-Version` | — | — | Print the version and exit |

A parameter given on the command line always wins; the environment variable is only read when
the parameter was not passed.

**Boolean values.** `LZC_REREGISTERWINDOWSAPPS_ALLOW_ELEVATED` and
`LZC_REREGISTERWINDOWSAPPS_FORCE` accept `1`, `true`, `yes`, `on`, `0`, `false`, `no` and `off`,
in any case. Any other value is a usage error and exits `2` — an unrecognised word is never read
as "off", so a typo surfaces immediately instead of silently disabling the flag.

**Colour.** This script emits no colour: all narration goes to the information, warning and error
streams, and it writes no escape sequences of its own. There is nothing for `NO_COLOR` to
suppress. Any colour you see is the host rendering the warning and error streams.

## Actions

| Action | Changes anything | Notes |
| --- | --- | --- |
| `Report` | No | Lists the current user's packages with name, full name, version, install location, status |
| `Reset` | Yes | `Reset-AppxPackage`. Supported. Discards the app's local data |
| `Reregister` | Yes | `Add-AppxPackage -Register`. Developer-mode sideload, last resort |

## Exit codes

These are the repo-wide codes. This script returns the subset below.

| Code | Meaning |
| --- | --- |
| `0` | Success, or a `-WhatIf` dry run |
| `1` | The work ran but something in it failed |
| `2` | Usage error: an invalid parameter or environment variable value, no package matched, the name matched several packages, or an elevated session without `-AllowElevated` |
| `3` | Unsupported platform: `Reset-AppxPackage` is unavailable on this Windows build |
| `5` | Refused: confirmation was needed, the session cannot prompt, and `-Force` was not given |

Code `4` (must be run as administrator) is never returned. This script is the opposite case: it
refuses an *elevated* session unless `-AllowElevated` says otherwise, and that refusal is `2`.

Guards run in a fixed order, so the code you get names the first thing that was wrong:
configuration (`2`), prerequisites (`3`), interactivity (`5`), then the work itself (`0` or `1`).

Exit `5` is what you get from a scheduled task or any other host that cannot answer a prompt.
Pass `-Force` (or set `LZC_REREGISTERWINDOWSAPPS_FORCE=1`) to confirm in advance.

One limit worth knowing: a malformed **command line** — an unknown parameter, or a value rejected
by `ValidateSet` — is caught by PowerShell's parameter binder before any script code runs, and
PowerShell exits `1`. Only validation the script performs itself, which is every environment
variable, can report `2`.

## Requirements

- Windows PowerShell 5.1 or PowerShell 7 on Windows.
- `Reset-AppxPackage` needs Windows 10 build 20175 or later, or Windows 11. The script checks for
  the cmdlet at runtime and tells you what to use instead if it is missing, rather than failing
  with a command-not-found error.
- **No elevation.** Run as the affected user.

On PowerShell 7 the `Appx` module does not load natively; the script imports it through the
Windows PowerShell compatibility layer automatically. Objects returned that way are deserialised,
so the script reads properties only and never calls methods on them.
