# RestartGraphicsDriver

Reports graphics adapter and display-driver-recovery state, and can restart the Desktop Window
Manager for the current session.

## Read this first: stopping `dwm.exe` is not a graphics driver restart

`dwm.exe` is the Desktop Window Manager — the compositor that draws the desktop. Killing it makes
Windows restart it, which rebuilds the composition tree. That can clear some visual corruption,
but it **does not reload, reset or restart the display driver**, and it will not fix a
driver-level fault.

The real "restart the graphics driver" gesture is **Win+Ctrl+Shift+B**, which triggers a Timeout
Detection and Recovery (TDR) reset of the graphics stack. Windows exposes no supported public API
for it, so it cannot be scripted. There is no PowerShell equivalent.

Because of that, this script leads with a read-only report. Recent **Event ID 4101** entries in
the System log ("display driver stopped responding and has recovered") are the actual evidence of
a driver problem. Repeated 4101 events for the same adapter point at a driver or hardware fault —
a clean driver reinstall, temperature and power checks, and a memory test are the useful next
steps. Restarting the compositor will not help.

## Blast radius

`-Action RestartDwm`: the screen goes black for roughly a second and every window is redrawn.
Applications keep running and nothing is closed, but full-screen games and some capture,
remote-control or overlay software react badly to losing the compositor and can crash. On rare
configurations the session does not recover cleanly and needs a sign-out.

**Only the current session's compositor is stopped.** `Stop-Process -Name dwm` matches every
compositor on the machine, so on a multi-session box it blanks the desktop of every other
signed-in user as well. This script filters by session id.

`Report` is the default and changes nothing.

## Usage

```powershell
# Read-only. No elevation needed.
.\RestartGraphicsDriver.ps1

# Look 30 days back for driver recovery events.
.\RestartGraphicsDriver.ps1 -SinceDays 30

# Preview the compositor restart.
.\RestartGraphicsDriver.ps1 -Action RestartDwm -WhatIf

# Do it (elevated).
.\RestartGraphicsDriver.ps1 -Action RestartDwm -Force
```

## Parameters

| Parameter | Environment variable | Default | Meaning |
| --- | --- | --- | --- |
| `-Action` | `LZC_GRAPHICSDRIVER_ACTION` | `Report` | `Report`, `RestartDwm` |
| `-SinceDays` | `LZC_GRAPHICSDRIVER_SINCE_DAYS` | `7` | Lookback window for Event ID 4101, 1-365 |
| `-Force` | `LZC_GRAPHICSDRIVER_FORCE` | off | Suppress confirmation prompts, for unattended use |
| `-WhatIf` | — | — | Dry run. Wins over `-Force` |
| `-Version` | — | — | Print the version and exit |

A parameter given on the command line always wins; the environment variable is only read when
the parameter was not passed.

**Boolean values.** `LZC_GRAPHICSDRIVER_FORCE` accepts `1`, `true`, `yes`, `on`, `0`, `false`,
`no` and `off`, in any case. Any other value is a usage error and exits `2` — an unrecognised
word is never read as "off", so a typo in a scheduled task surfaces immediately instead of
silently disabling the flag.

**Numeric values.** `LZC_GRAPHICSDRIVER_SINCE_DAYS` is parsed as decimal, so a zero-padded value
such as `08` means 8. Out-of-range and non-numeric values exit `2`.

**Colour.** This script emits no colour: all narration goes to the information, warning and error
streams, and it writes no escape sequences of its own. There is nothing for `NO_COLOR` to
suppress. Any colour you see is the host rendering the warning and error streams.

## Output

`-Action Report` returns an object with:

- `Adapters` — name, driver version, driver date, video processor, current resolution, status and
  PnP device id for each display adapter, from CIM `Win32_VideoController`.
- `RecoveryEvents` — Event ID 4101 entries within the lookback window, with timestamp, provider
  and message.
- `LookbackDays` — the window actually used.

## Exit codes

These are the repo-wide codes. This script returns the subset below.

| Code | Meaning |
| --- | --- |
| `0` | Success, or a `-WhatIf` dry run |
| `1` | The work ran but something in it failed |
| `2` | Usage error: an unknown or invalid parameter or environment variable value |
| `3` | Unsupported platform or missing prerequisite: no Desktop Window Manager in this session |
| `4` | Must be run as administrator |
| `5` | Refused: confirmation was needed, the session cannot prompt, and `-Force` was not given |

Exit code `3` is expected under `SYSTEM`, on Windows Server Core, and in any session without a
desktop — there is simply nothing to restart there.

Guards run in a fixed order, so the code you get names the first thing that was wrong:
configuration (`2`), prerequisites (`3`), elevation (`4`), interactivity (`5`), then the work
itself (`0` or `1`).

Exit `5` is what you get from a scheduled task or any other host that cannot answer a prompt.
Pass `-Force` (or set `LZC_GRAPHICSDRIVER_FORCE=1`) to confirm in advance.

One limit worth knowing: a malformed **command line** — an unknown parameter, or a value
rejected by `ValidateSet`/`ValidateRange` — is caught by PowerShell's parameter binder before any
script code runs, and PowerShell exits `1`. Only validation the script performs itself, which is
every environment variable, can report `2`.

## Requirements

- Windows PowerShell 5.1 or PowerShell 7 on Windows.
- Administrator rights for `RestartDwm` only (`dwm.exe` runs as a virtual service account).
  `Report` and `-WhatIf` need none.
