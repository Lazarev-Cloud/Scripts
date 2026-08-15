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
| `-Action` | `RESETFIREWALL_ACTION` | `Report` | `Report`, `Export`, `Reset`, `Import` |
| `-BackupPath` | `RESETFIREWALL_BACKUP_PATH` | `%ProgramData%\LazarevScripts\ResetFirewall` | Where `.wfw` exports are written |
| `-ImportFile` | `RESETFIREWALL_IMPORT_FILE` | — | The `.wfw` file to restore. Required by `-Action Import` |
| `-SkipBackup` | `RESETFIREWALL_SKIP_BACKUP=1` | off | Reset without exporting. Makes the reset irreversible |
| `-AllowRemoteSession` | `RESETFIREWALL_ALLOW_REMOTE_SESSION=1` | off | Permit destructive actions over RDP/SSH |
| `-TimeoutSeconds` | `RESETFIREWALL_TIMEOUT_SECONDS` | `120` | Per-netsh-command timeout, 10-600 |
| `-Force` | `RESETFIREWALL_FORCE=1` | off | Suppress confirmation prompts, for unattended use |
| `-WhatIf` | — | — | Dry run. Wins over `-Force` |
| `-Version` | — | — | Print the version and exit |

## Actions

| Action | Elevation | Changes anything |
| --- | --- | --- |
| `Report` | No | No |
| `Export` | Yes | Writes a `.wfw` file only |
| `Reset` | Yes | Yes — exports, verifies, resets, then re-reports the resulting state |
| `Import` | Yes | Yes — replaces the entire current policy |

## Exit codes

| Code | Meaning |
| --- | --- |
| `0` | Success, or a `-WhatIf` dry run |
| `1` | An operation failed |
| `2` | Refused: not elevated, remote session without `-AllowRemoteSession`, or the export could not be written and verified |

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
