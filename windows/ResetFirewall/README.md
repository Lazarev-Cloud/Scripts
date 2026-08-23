# ResetFirewall

Exports, resets or restores the Windows Defender Firewall policy. It never resets without a
verified backup.

## Blast radius

`netsh advfirewall reset` restores every firewall setting to its out-of-the-box defaults and
**deletes every locally created rule**, including rules written by application installers.
Line-of-business software, game servers, database listeners, remote administration tools and
inbound Remote Desktop exceptions can all stop working until each product is reinstalled or
reconfigured.

What survives a reset and what does not:

- **Group Policy / Intune (MDM) rules** live in a separate policy store and come back at the next
  policy refresh.
- **Locally authored rules and rules added by application installers** are gone permanently,
  unless you restore the export this script takes.

Run `-Action Report` first: it prints how many rules are in the local store, which is how much
you stand to lose.

A reset can also remove the inbound rule keeping your Remote Desktop session open, so the
destructive actions refuse to run over RDP or SSH unless `-AllowRemoteSession` is passed.

## Rollback

`-Action Reset` always exports first, to `-BackupPath`, then **verifies the file exists and is
non-empty**. If that verification fails the reset is aborted — an export nobody checked is not a
backup. `-SkipBackup` overrides this deliberately.

```powershell
.\ResetFirewall.ps1 -Action Import -ImportFile C:\ProgramData\LazarevScripts\ResetFirewall\firewall-<stamp>.wfw
```

## Usage

```powershell
# Read-only. No elevation needed. Shows profile state and how many local rules exist.
.\ResetFirewall.ps1

# Preview a reset, including where the export would go.
.\ResetFirewall.ps1 -Action Reset -WhatIf

# Take a backup and stop.
.\ResetFirewall.ps1 -Action Export -BackupPath D:\Backups

# Restore a previous export.
.\ResetFirewall.ps1 -Action Import -ImportFile D:\Backups\firewall-20260815-101500.wfw -Force
```

## Parameters

| Parameter | Environment variable | Default | Meaning |
| --- | --- | --- | --- |
| `-Action` | `LZC_RESETFIREWALL_ACTION` | `Report` | `Report`, `Export`, `Reset`, `Import` |
| `-BackupPath` | `LZC_RESETFIREWALL_BACKUP_PATH` | `%ProgramData%\LazarevScripts\ResetFirewall` | Where `.wfw` exports are written |
| `-ImportFile` | `LZC_RESETFIREWALL_IMPORT_FILE` | — | The `.wfw` file to restore. Required by `-Action Import` |
| `-SkipBackup` | `LZC_RESETFIREWALL_SKIP_BACKUP` | off | Reset without exporting. Makes the reset irreversible |
| `-AllowRemoteSession` | `LZC_RESETFIREWALL_ALLOW_REMOTE_SESSION` | off | Permit destructive actions over RDP/SSH |
| `-TimeoutSeconds` | `LZC_RESETFIREWALL_TIMEOUT_SECONDS` | `120` | Per-netsh-command timeout, 10-600. See below |
| `-Force` | `LZC_RESETFIREWALL_FORCE` | off | Suppress confirmation prompts, for unattended use |
| `-WhatIf` | — | — | Dry run. Wins over `-Force` |
| `-Version` | — | — | Print the version and exit |

A parameter given on the command line always wins; the environment variable is only read when
the parameter was not passed.

**What `-TimeoutSeconds` bounds.** One `netsh` invocation, not the whole run. The export, the
reset and the import are separate calls and each gets the allowance in full.

**Boolean values.** `LZC_RESETFIREWALL_SKIP_BACKUP`, `LZC_RESETFIREWALL_ALLOW_REMOTE_SESSION` and
`LZC_RESETFIREWALL_FORCE` accept `1`, `true`, `yes`, `on`, `0`, `false`, `no` and `off`, in any
case. Any other value is a usage error and exits `2` — an unrecognised word is never read as
"off", so a typo in a scheduled task surfaces immediately instead of silently disabling the flag.

**Numeric values.** `LZC_RESETFIREWALL_TIMEOUT_SECONDS` is parsed as decimal, so a zero-padded
value such as `08` means 8. Non-numeric and out-of-range values exit `2`. The floor of 10 is
enforced so the timeout can never be set to 0, which a caller would reasonably read as "no limit"
and which would remove the protection the option exists to provide.

**Colour.** This script emits no colour: all narration goes to the information, warning and error
streams, and it writes no escape sequences of its own. There is nothing for `NO_COLOR` to
suppress. Any colour you see is the host rendering the warning and error streams.

## Actions

| Action | Elevation | Changes anything |
| --- | --- | --- |
| `Report` | No | No |
| `Export` | Yes | Writes a `.wfw` file only |
| `Reset` | Yes | Yes — exports, verifies, resets, then re-reports the resulting state |
| `Import` | Yes | Yes — replaces the entire current policy |

## Exit codes

These are the repo-wide codes. This script returns the subset below.

| Code | Meaning |
| --- | --- |
| `0` | Success, or a `-WhatIf` dry run |
| `1` | The work ran but something in it failed, including the export that `Reset` depends on |
| `2` | Usage error: an invalid parameter or environment variable value, `-Action Import` with no `-ImportFile`, or a remote session without `-AllowRemoteSession` |
| `4` | Must be run as administrator |
| `5` | Refused: confirmation was needed, the session cannot prompt, and `-Force` was not given |

Guards run in a fixed order, so the code you get names the first thing that was wrong:
configuration (`2`), elevation (`4`), interactivity (`5`), then the work itself (`0` or `1`).

A failed or unverified export is `1`, not `2`: the script was called correctly and the work it
performed is what failed. `Reset` stops there rather than continuing without a backup.

Exit `5` is what you get from a scheduled task or any other host that cannot answer a prompt.
Pass `-Force` (or set `LZC_RESETFIREWALL_FORCE=1`) to confirm in advance.

One limit worth knowing: a malformed **command line** — an unknown parameter, or a value rejected
by `ValidateSet`/`ValidateRange` — is caught by PowerShell's parameter binder before any script
code runs, and PowerShell exits `1`. Only validation the script performs itself, which is every
environment variable, can report `2`.

## Requirements

- Windows PowerShell 5.1 or PowerShell 7 on Windows.
- Administrator rights for everything except `-Action Report` and `-WhatIf`.

## What this script does not do

It will never disable the firewall. `netsh advfirewall set allprofiles state off` is not
implemented and will not be added: a script that restores connectivity by turning off the
firewall is a vulnerability, not a repair tool.

It also does not re-enable profiles after a reset. `netsh advfirewall reset` already restores the
default enabled state, so the old `set allprofiles state on` step was redundant. The script
re-reports the profile state afterwards so you can see the result rather than trust a message.

For targeted changes, use the `NetSecurity` module (`Get-NetFirewallRule`,
`Set-NetFirewallProfile`) instead of resetting everything.
