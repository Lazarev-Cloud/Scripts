# Windows Scripts

PowerShell utilities for common Windows maintenance and troubleshooting. Each
lives in its own subfolder with a README covering parameters, environment
variables, exit codes and blast radius.

Every script supports `SupportsShouldProcess`: `-WhatIf` previews the change and
`-Confirm`/`-Force` gates it. Read-only reporting is the default action almost
everywhere — you have to ask for a change. Run `Get-Help .\Script.ps1 -Full`
for the authoritative reference.

## Scripts

| Folder | What it does | Env prefix |
| --- | --- | --- |
| [`Clean-Disk/`](Clean-Disk/) | Deletes stale files from temporary directories and reports the space freed. Refuses drive roots and system directories; will not escape the cleaning root through a junction. | `LZC_CLEAN_DISK_` |
| [`Updates/`](Updates/) | `Clear-WindowsUpdateCache.ps1` — stops the services holding handles inside `SoftwareDistribution`, clears the download cache, restarts them, and reports the space freed. | `LZC_UPDATES_` |
| [`Winget/`](Winget/) | Reports on winget, removes stale App Installer directories from the system `PATH`, resets package sources, and optionally upgrades installed packages. The `PATH` edit is backed up and verified before it is written. | `LZC_WINGET_` |
| [`Features/`](Features/) | Lists Windows optional features; enables or disables a named feature with confirmation. Read-only with no arguments. | `LZC_WINDOWSFEATURES_` |
| [`GraphicsDriver/`](GraphicsDriver/) | Reports graphics adapter and display-driver-recovery (TDR) state, and can restart the Desktop Window Manager for the current session. | `LZC_GRAPHICSDRIVER_` |
| [`ResetNetwork/`](ResetNetwork/) | Resets selected networking components — DNS client cache, Winsock catalog, IPv4/IPv6 stacks — after saving a rollback snapshot. Defaults to `DnsCache`, the only non-disruptive scope. Winsock and stack resets need a reboot. | `LZC_RESETNETWORK_` |
| [`ResetFirewall/`](ResetFirewall/) | Exports, resets or restores the Windows Defender Firewall policy. It refuses to reset unless it has exported a backup you can import again, unless you explicitly pass `-SkipBackup`. | `LZC_RESETFIREWALL_` |
| [`ManageService/`](ManageService/) | Reports on or changes the state of a single named Windows service, with protection for services the system depends on. `Status` is the default action, is read-only, and needs no elevation. | `LZC_MANAGESERVICE_` |
| [`RepairSystemFiles/`](RepairSystemFiles/) | Repairs the component store with DISM, then repairs protected system files with SFC, and reports the real exit codes and log paths. DISM runs first, because SFC repairs from the component store. | `LZC_REPAIRSYSTEMFILES_` |
| [`ReRegisterWindowsApps/`](ReRegisterWindowsApps/) | Repairs a single named Microsoft Store app for the current user via the supported `Reset-AppxPackage` path. It refuses an ambiguous name rather than acting on several packages. | `LZC_REREGISTERWINDOWSAPPS_` |

## Notes

- **Elevation.** Most changes need an elevated session; the read-only actions
  generally do not. A script that needs elevation and does not have it refuses
  with a documented exit code instead of failing partway.
- **Compatibility.** Windows PowerShell 5.1, which is what CI analyses them
  against.
- **Backups.** `ResetFirewall` and `ResetNetwork` write a backup before the
  destructive step; `Winget` checks its `PATH` backup is non-empty before
  editing the registry, and `ResetFirewall` refuses to continue if the export
  failed.
- **Blast radius is documented per script.** `Clean-Disk -IncludeRecycleBin`
  and the `ResetNetwork` stack scopes destroy user-visible state; read the
  folder README before running either.
- **Exit codes** come from the [repo-wide table](../docs/exit-codes.md): `0`
  success, `1` partial failure, `2` usage, `3` unsupported platform or missing
  prerequisite, `4` not elevated, `5` confirmation needed but the session is
  not interactive, `75` another instance holds the lock, `130` interrupted. Not
  every script can return every code — the ones it can are in its README. The
  guard order is the same everywhere: configuration, then platform, then
  elevation, then interactivity, then the work.
  `ResetNetwork.ps1` additionally returns `3010` when a reset needs a reboot to
  finish — the only code in the repo outside that table.
- **Every parameter has an `LZC_<SCRIPT>_<SETTING>` environment variable**, for
  Intune, SCCM and Task Scheduler where passing arguments is awkward. A
  parameter given on the command line always wins over the variable.
