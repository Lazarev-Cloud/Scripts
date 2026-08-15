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
| [`Clean-Disk/`](Clean-Disk/) | Deletes stale files from temporary directories and reports the space freed. Refuses drive roots and system directories; will not escape the cleaning root through a junction. | `CLEAN_DISK_` |
| [`Updates/`](Updates/) | `Clear-WindowsUpdateCache.ps1` — stops the services holding handles inside `SoftwareDistribution`, clears the download cache, restarts them, and reports the space freed. | `WU_CACHE_` |
| [`Winget/`](Winget/) | Reports on winget, removes stale App Installer directories from the system `PATH`, resets package sources, and optionally upgrades installed packages. The `PATH` edit is backed up and verified before it is written. | `WINGETFIX_` |
| [`Features/`](Features/) | Lists Windows optional features; enables or disables a named feature with confirmation. Read-only with no arguments. | `WINFEATURE_` |
| [`GraphicsDriver/`](GraphicsDriver/) | Reports graphics adapter and display-driver-recovery (TDR) state, and can restart the Desktop Window Manager for the current session. | `GRAPHICSDRIVER_` |
| [`ResetNetwork/`](ResetNetwork/) | Resets selected networking components — DNS client cache, Winsock catalog, IPv4/IPv6 stacks — after saving a rollback snapshot. Defaults to `DnsCache`, the only non-disruptive scope. Winsock and stack resets need a reboot. | `RESETNETWORK_` |
| [`ResetFirewall/`](ResetFirewall/) | Exports, resets or restores the Windows Defender Firewall policy. It refuses to reset unless it has exported a backup you can import again, unless you explicitly pass `-SkipBackup`. | `RESETFIREWALL_` |
| [`ManageService/`](ManageService/) | Reports on or changes the state of a single named Windows service, with protection for services the system depends on. `Status` is the default action, is read-only, and needs no elevation. | `MANAGESERVICE_` |
| [`RepairSystemFiles/`](RepairSystemFiles/) | Repairs the component store with DISM, then repairs protected system files with SFC, and reports the real exit codes and log paths. DISM runs first, because SFC repairs from the component store. | `REPAIR_` |
| [`ReRegisterWindowsApps/`](ReRegisterWindowsApps/) | Repairs a single named Microsoft Store app for the current user via the supported `Reset-AppxPackage` path. It refuses an ambiguous name rather than acting on several packages. | `REREGISTERAPPS_` |

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
