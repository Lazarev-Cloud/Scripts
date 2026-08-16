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
| `-Scope` | `LZC_RESETNETWORK_SCOPE` | `DnsCache` | `DnsCache`, `Winsock`, `IPv4`, `IPv6`, `All`. Accepts several; env var is comma separated |
| `-BackupPath` | `LZC_RESETNETWORK_BACKUP_PATH` | `%ProgramData%\LazarevScripts\ResetNetwork` | Where the rollback snapshot is written |
| `-SkipBackup` | `LZC_RESETNETWORK_SKIP_BACKUP` | off | Reset without a snapshot. Makes the reset unrecoverable |
| `-AllowRemoteSession` | `LZC_RESETNETWORK_ALLOW_REMOTE_SESSION` | off | Permit destructive scopes over RDP/SSH |
| `-TimeoutSeconds` | `LZC_RESETNETWORK_TIMEOUT_SECONDS` | `120` | Per-netsh-command timeout, 10-600. See below |
| `-Force` | `LZC_RESETNETWORK_FORCE` | off | Suppress confirmation prompts, for unattended use |
| `-WhatIf` | — | — | Dry run. Wins over `-Force` |
| `-Version` | — | — | Print the version and exit |

A parameter given on the command line always wins; the environment variable is only read when
the parameter was not passed.

**What `-TimeoutSeconds` bounds.** One `netsh` invocation, not the whole run. The snapshot dump
and each component reset are separate calls and each gets the allowance in full.

**Boolean values.** `LZC_RESETNETWORK_SKIP_BACKUP`, `LZC_RESETNETWORK_ALLOW_REMOTE_SESSION` and
`LZC_RESETNETWORK_FORCE` accept `1`, `true`, `yes`, `on`, `0`, `false`, `no` and `off`, in any
case. Any other value is a usage error and exits `2` — an unrecognised word is never read as
"off", so a typo in a scheduled task surfaces immediately instead of silently disabling the flag.

**Numeric values.** `LZC_RESETNETWORK_TIMEOUT_SECONDS` is parsed as decimal, so a zero-padded
value such as `08` means 8. Non-numeric and out-of-range values exit `2`. The floor of 10 is
enforced so the timeout can never be set to 0, which a caller would reasonably read as "no limit"
and which would remove the protection the option exists to provide.

**Colour.** This script emits no colour: all narration goes to the information, warning and error
streams, and it writes no escape sequences of its own. There is nothing for `NO_COLOR` to
suppress. Any colour you see is the host rendering the warning and error streams.

`-Verbose` shows each command as it runs. `-InformationAction SilentlyContinue` silences the
progress narration.

## Output

One object per operation, with `Operation`, `Target`, `ExitCode`, `Status` and `RebootRequired`.

`Status` is `Succeeded` or `Skipped`; `Skipped` means the confirmation gate declined it, which is
what every operation reports under `-WhatIf`. `RebootRequired` is `$true` only on an operation
that actually ran and needs a restart, so it is always `$false` on a skipped operation and on
`DnsCache`.

## Exit codes

These are the repo-wide codes, plus `3010`. This script returns the subset below.

| Code | Meaning |
| --- | --- |
| `0` | Success, or a `-WhatIf` dry run |
| `1` | The work ran but something in it failed, including the rollback snapshot a destructive scope depends on |
| `2` | Usage error: an invalid parameter or environment variable value, no component selected, or a remote session without `-AllowRemoteSession` |
| `4` | Must be run as administrator |
| `5` | Refused: confirmation was needed, the session cannot prompt, and `-Force` was not given |
| `3010` | Success, and a restart is required before the reset takes effect |

Guards run in a fixed order, so the code you get names the first thing that was wrong:
configuration (`2`), elevation (`4`), interactivity (`5`), then the work itself (`0`, `1` or
`3010`).

Exit `5` is what you get from a scheduled task or any other host that cannot answer a prompt.
Pass `-Force` (or set `LZC_RESETNETWORK_FORCE=1`) to confirm in advance.

**Why `3010`.** It is the one code outside the repo-wide table, and it is the Windows convention
for "success, soft reboot required" that Intune, SCCM and most RMM tools act on. A `Winsock`,
`IPv4` or `IPv6` reset does not take effect until the machine restarts, so exiting `0` would tell
a scheduler the job was finished while leaving the stack in a half-reset state that looks healthy
and is not. If your wrapper cannot handle `3010`, treat it as success and read the
`RebootRequired` property on the returned objects instead.

One limit worth knowing: a malformed **command line** — an unknown parameter, or a value rejected
by `ValidateSet`/`ValidateRange` — is caught by PowerShell's parameter binder before any script
code runs, and PowerShell exits `1`. Only validation the script performs itself, which is every
environment variable, can report `2`.

## Requirements

- Windows PowerShell 5.1 or PowerShell 7 on Windows.
- Administrator rights for `Winsock`, `IPv4` and `IPv6`. The default `DnsCache` scope and any
  `-WhatIf` preview need none.

Run it as a scheduled task with `-File`, not `-Command`; `-Command` collapses the exit code to
0 or 1 and you lose the 3010 signal:

```
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "C:\path\ResetNetwork.ps1" -Scope Winsock -Force
```

## What this script does not do

`ipconfig /flushdns` as a cure-all, and the "TCP tuning" folklore
(`netsh int tcp set global autotuninglevel=disabled` and friends) are not included. The latter
were workarounds for specific 2008-era router bugs and degrade throughput on current Windows.
