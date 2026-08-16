# ManageService

Reports on or changes the state of a single named Windows service, with protection for services
the system depends on.

## Blast radius

Stopping or restarting a service interrupts everything that depends on it.

- With `-Force`, dependent services are stopped too, and **neither `Stop` nor `Restart` starts
  them again**. `Restart` brings back only the service you named; its dependents stay stopped.
  They are listed by name in the warning before the stop, so you can start them yourself.
- Stopping servicing services (`TrustedInstaller`, `msiserver`, `wuauserv`) while an update is
  applying can leave the component store in a pending state that makes later DISM runs fail.

`Status` is the default action, is read-only, and needs no elevation.

## Safety behaviour

**Exact names only.** Wildcards, quotes and path separators are rejected.
`Get-Service -Name 'w*'` would match dozens of services; a typo here cannot fan out. Quotes are
refused because the name is interpolated into a WQL `-Filter` when reading `Win32_Service`, and
an embedded quote would end the literal early. No real Windows service name contains one, so
nothing legitimate is excluded.

**Dependents are named before they are stopped.** Running dependent services are enumerated and
listed. If any exist, the stop requires `-Force`, because that is what actually cascades — and
without it the stop would fail anyway. The point is that you see which services go down with it.

**Protected services need a second, explicit opt-in.** Stopping these breaks servicing, logon,
networking or security, so they require `-AllowProtectedService` *in addition to* the normal
confirmation. `-Force` alone is deliberately not enough, so an unattended run cannot stop
`TrustedInstaller` by accident.

Default protected list:

```
TrustedInstaller  msiserver  wuauserv  CryptSvc  BFE  MpsSvc  WinDefend  RpcSs  DcomLaunch
EventLog  SamSs  LSM  gpsvc  ProfSvc  Schedule  PlugPlay  Power  nsi  Dhcp  Dnscache
LanmanServer  LanmanWorkstation  TermService  WinRM  NlaSvc  netprofm
```

Replace it entirely with `-ProtectedService` or `LZC_MANAGESERVICE_PROTECTED_SERVICES`.

## Usage

```powershell
# Read-only report: state, start mode, start account, path, dependencies, dependents.
.\ManageService.ps1 -Name Spooler

# Preview a restart, including which dependents would be affected.
.\ManageService.ps1 -Name Spooler -Action Restart -WhatIf

# Unattended restart, cascading to dependents.
.\ManageService.ps1 -Name Spooler -Action Restart -Force

# A protected service needs the extra opt-in.
.\ManageService.ps1 -Name wuauserv -Action Restart -AllowProtectedService -Force
```

Use the short service name (`Spooler`), not the display name (`Print Spooler`). Run `Get-Service`
to list them.

## Parameters

| Parameter | Environment variable | Default | Meaning |
| --- | --- | --- | --- |
| `-Name` | `LZC_MANAGESERVICE_NAME` | — | Exact service name. Wildcards, quotes and path separators rejected. Required |
| `-Action` | `LZC_MANAGESERVICE_ACTION` | `Status` | `Status`, `Start`, `Stop`, `Restart` |
| `-TimeoutSeconds` | `LZC_MANAGESERVICE_TIMEOUT_SECONDS` | `60` | Wait for the target state, 5-600. See below |
| `-ProtectedService` | `LZC_MANAGESERVICE_PROTECTED_SERVICES` | see list above | Replaces the protected list. Env var is comma separated |
| `-AllowProtectedService` | `LZC_MANAGESERVICE_ALLOW_PROTECTED` | off | Permit stopping/restarting a protected service |
| `-Force` | `LZC_MANAGESERVICE_FORCE` | off | Cascade to dependents and suppress confirmation prompts |
| `-WhatIf` | — | — | Dry run. Wins over `-Force` |
| `-Version` | — | — | Print the version and exit |

A parameter given on the command line always wins; the environment variable is only read when
the parameter was not passed.

**What `-TimeoutSeconds` bounds.** One thing only: how long to wait for the service to report the
requested state after the start or stop has been issued. It is not a budget for the whole script,
and for `Restart` the stop and the following start each get the full allowance.

**Boolean values.** `LZC_MANAGESERVICE_ALLOW_PROTECTED` and `LZC_MANAGESERVICE_FORCE` accept `1`,
`true`, `yes`, `on`, `0`, `false`, `no` and `off`, in any case. Any other value is a usage error
and exits `2` — an unrecognised word is never read as "off", so a typo in a scheduled task
surfaces immediately instead of silently disabling the flag.

**Numeric values.** `LZC_MANAGESERVICE_TIMEOUT_SECONDS` is parsed as decimal, so a zero-padded
value such as `08` means 8. Non-numeric and out-of-range values exit `2`. The floor of 5 is
enforced so the timeout can never be set to 0, which a caller would reasonably read as "no limit"
and which would remove the protection the option exists to provide.

**Colour.** This script emits no colour: all narration goes to the information, warning and error
streams, and it writes no escape sequences of its own. There is nothing for `NO_COLOR` to
suppress. Any colour you see is the host rendering the warning and error streams.

## Exit codes

These are the repo-wide codes. This script returns the subset below.

| Code | Meaning |
| --- | --- |
| `0` | Success, or a `-WhatIf` dry run |
| `1` | The work ran but something in it failed, including the service not reaching the requested state within the timeout |
| `2` | Usage error: an invalid parameter or environment variable value, no service with that name, a protected service without `-AllowProtectedService`, running dependents without `-Force`, or a service that cannot be stopped |
| `4` | Must be run as administrator |
| `5` | Refused: confirmation was needed, the session cannot prompt, and `-Force` was not given |

Guards run in a fixed order, so the code you get names the first thing that was wrong:
configuration (`2`), elevation (`4`), interactivity (`5`), then the work itself (`0` or `1`).

Exit `5` is what you get from a scheduled task or any other host that cannot answer a prompt.
Pass `-Force` (or set `LZC_MANAGESERVICE_FORCE=1`) to confirm in advance.

One limit worth knowing: a malformed **command line** — an unknown parameter, or a value rejected
by `ValidateSet`/`ValidateRange` — is caught by PowerShell's parameter binder before any script
code runs, and PowerShell exits `1`. Only validation the script performs itself, which is every
environment variable, can report `2`.

## Output

`-Action Status` returns an object with `Name`, `DisplayName`, `Status`, `StartMode`,
`StartAccount`, `ExecutablePath`, `CanStop`, `RunningDependents` and `DependsOn`. Start mode,
account and path come from the CIM `Win32_Service` class, which `Get-Service` does not expose.

## Requirements

- Windows PowerShell 5.1 or PowerShell 7 on Windows.
- Administrator rights for `Start`, `Stop` and `Restart`. `Status` and `-WhatIf` need none.
