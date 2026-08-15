# ResetNetwork

Resets selected Windows networking components, after saving a rollback snapshot.

Each component is chosen explicitly, because they have very different consequences. There is no
single "reset the network" button here on purpose.

## Blast radius

| Scope | What it does | Cost | Reboot |
| --- | --- | --- | --- |
| `DnsCache` | Clears the DNS resolver cache | None. Nothing is lost | No |
| `Winsock` | `netsh winsock reset` | Removes every third-party Layered Service Provider. VPN clients, endpoint security/EDR filters and parental-control products stop working until reinstalled | Yes |
| `IPv4` | `netsh interface ipv4 reset` | Static IP addresses, custom routes and manually set DNS servers are lost; the adapter falls back to DHCP | Yes |
| `IPv6` | `netsh interface ipv6 reset` | As above, for IPv6 | Yes |
| `All` | All of the above | | Yes |

`DnsCache` is the default. The other scopes must be named explicitly.

**On a remote machine this can cut you off.** `IPv4`/`IPv6` discard a static address, and the
script may not be reachable afterwards. It refuses to run destructive scopes when it detects an
RDP or SSH session unless `-AllowRemoteSession` is passed.

## Rollback

Before any destructive scope runs, the current configuration is captured to `-BackupPath`:

- `network-snapshot-<stamp>.json` — adapters, IP addresses, DNS servers, routes, interface DHCP
  state. Written first and verified non-empty.
- `netsh-interface-dump-<stamp>.txt` — a re-applicable netsh script (best effort).

If the JSON snapshot cannot be written, **the run is aborted**. A reset with no rollback artefact
is not a reversible operation. `-SkipBackup` overrides this deliberately.

To restore:

```powershell
netsh -f C:\ProgramData\LazarevScripts\ResetNetwork\netsh-interface-dump-<stamp>.txt
```

Winsock LSPs are **not** restored by that dump. Reinstall the affected VPN or security product.

## Usage

```powershell
# Preview a full reset. Changes nothing, and works without elevation.
.\ResetNetwork.ps1 -Scope All -WhatIf

# Default: clear the DNS cache only.
.\ResetNetwork.ps1

# Unattended Winsock reset.
.\ResetNetwork.ps1 -Scope Winsock -Force
```

Always run with `-WhatIf` first. Every destructive step is gated individually, so the dry run
lists exactly what would happen.

## Parameters

| Parameter | Environment variable | Default | Meaning |
| --- | --- | --- | --- |
| `-Scope` | `RESETNETWORK_SCOPE` | `DnsCache` | `DnsCache`, `Winsock`, `IPv4`, `IPv6`, `All`. Accepts several; env var is comma separated |
| `-BackupPath` | `RESETNETWORK_BACKUP_PATH` | `%ProgramData%\LazarevScripts\ResetNetwork` | Where the rollback snapshot is written |
| `-SkipBackup` | `RESETNETWORK_SKIP_BACKUP=1` | off | Reset without a snapshot. Makes the reset unrecoverable |
| `-AllowRemoteSession` | `RESETNETWORK_ALLOW_REMOTE_SESSION=1` | off | Permit destructive scopes over RDP/SSH |
| `-TimeoutSeconds` | `RESETNETWORK_TIMEOUT_SECONDS` | `120` | Per-netsh-command timeout, 10-600 |
| `-Force` | `RESETNETWORK_FORCE=1` | off | Suppress confirmation prompts, for unattended use |
| `-WhatIf` | — | — | Dry run. Wins over `-Force` |
| `-Version` | — | — | Print the version and exit |

`-Verbose` shows each command as it runs. `-InformationAction SilentlyContinue` silences the
progress narration.

## Exit codes

| Code | Meaning |
| --- | --- |
| `0` | Success, or a `-WhatIf` dry run |
| `1` | An operation failed |
| `2` | Refused: not elevated, remote session without `-AllowRemoteSession`, or the snapshot could not be written |
| `3010` | Success, reboot required. Schedulers and RMM tools understand this code |

## Requirements

- Windows PowerShell 5.1 or PowerShell 7 on Windows.
- Administrator rights for every scope except a `-WhatIf` preview.

Run it as a scheduled task with `-File`, not `-Command`; `-Command` collapses the exit code to
0 or 1 and you lose the 3010 signal:

```
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "C:\path\ResetNetwork.ps1" -Scope Winsock -Force
```

## What this script does not do

`ipconfig /flushdns` as a cure-all, and the "TCP tuning" folklore
(`netsh int tcp set global autotuninglevel=disabled` and friends) are not included. The latter
were workarounds for specific 2008-era router bugs and degrade throughput on current Windows.
