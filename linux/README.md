# Linux Scripts

Bash utilities for common Linux maintenance and troubleshooting. Each lives in
its own subdirectory with a README covering flags, environment variables, exit
codes and blast radius. Run any of them with `--help` for the authoritative
reference.

All of them are safe by default: they print a plan and change nothing until you
pass `--yes`. `-n`/`--dry-run` forces report-only.

## Scripts

| Folder | What it does | Env prefix |
| --- | --- | --- |
| [`update_upgrade/`](update_upgrade/) | Refreshes APT indexes, upgrades packages non-interactively, and reports follow-up work: pending reboot, conffile drift, held packages. Debian/Ubuntu. | `APT_UPGRADE_` |
| [`fix_broken_packages/`](fix_broken_packages/) | Repairs a half-finished dpkg transaction or unsatisfied dependencies, then verifies the system is actually consistent again. Debian/Ubuntu. | `APT_REPAIR_` |
| [`fix_apt_lock/`](fix_apt_lock/) | Diagnoses a stuck `Could not get lock /var/lib/dpkg/lock-frontend` and clears the lock **only** when no process holds it. Can run `dpkg --configure -a` afterwards. | `FIX_APT_LOCK_` |
| [`fix_dnf_lock/`](fix_dnf_lock/) | The same doctor for dnf/yum: diagnoses `Waiting for process with pid NNNN`, clears a lock only when nothing holds it. | `FIX_DNF_LOCK_` |
| [`clean_logs/`](clean_logs/) | Deletes rotated log archives older than a cutoff and vacuums the systemd journal. Can also truncate oversized live logs (off by default). | `CLEAN_LOGS_` |
| [`fix_permissions/`](fix_permissions/) | Repairs ownership and permissions inside a single user's home directory, never following symlinks out of it. | `FIXPERMS_` |
| [`network_restart/`](network_restart/) | Restarts one interface and verifies it came back, with an armed rollback so a failed bounce recovers without console access. Refuses to bounce the interface carrying your SSH session unless forced. | `NET_RESTART_` |
| [`maintenance/`](maintenance/) | Runs named maintenance tasks on Debian/Ubuntu and RHEL-family hosts. With no task it produces a read-only health report. | `MAINT_` |
| [`proxmox/ve/`](proxmox/ve/) | Updates the packages inside every LXC container on a Proxmox VE node, or across a whole cluster over SSH. | `LXC_UPDATER_` |

`maintenance/` tasks: `report`, `update`, `autoremove`, `clean-cache`,
`clean-logs`, `clean-tmp`, `fix-packages`, `fix-locks`, `routine`.

## Why the lock scripts are not `rm`

`fix_apt_lock` and `fix_dnf_lock` exist because deleting a package-manager lock
file is not a fix. Those files are zero-byte advisory lock targets: removing
one while a package manager holds it does not stop that package manager, it
lets a second one start alongside the first. Both scripts refuse to remove a
lock that any process still holds, and both fail closed when they cannot
determine a lock's state.

## Shared library

[`../lib/lzc-obs.sh`](../lib/) is optional. When present it lets a script ship
structured logs and run metrics to VictoriaLogs, Loki, VictoriaMetrics or a
Pushgateway. Nothing is sent unless an endpoint is configured. Currently only
`proxmox/ve/update-lxcs.sh` uses it; see that README for the variables.
