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
| [`update_upgrade/`](update_upgrade/) | Refreshes APT indexes, upgrades packages non-interactively, and reports follow-up work: pending reboot, conffile drift, held packages. Debian/Ubuntu — on any other family it refuses and points at `maintenance.sh update`. | `LZC_UPDATE_UPGRADE_` |
| [`fix_broken_packages/`](fix_broken_packages/) | Repairs a half-finished dpkg transaction or unsatisfied dependencies, then verifies the system is actually consistent again. Debian/Ubuntu. | `LZC_FIX_BROKEN_PACKAGES_` |
| [`fix_apt_lock/`](fix_apt_lock/) | Diagnoses a stuck `Could not get lock /var/lib/dpkg/lock-frontend` and clears the lock **only** when no process holds it. Can run `dpkg --configure -a` afterwards. | `LZC_FIX_APT_LOCK_` |
| [`fix_dnf_lock/`](fix_dnf_lock/) | The same doctor for dnf/yum: diagnoses `Waiting for process with pid NNNN`, clears a lock only when nothing holds it. | `LZC_FIX_DNF_LOCK_` |
| [`clean_logs/`](clean_logs/) | Deletes rotated log archives older than a cutoff and vacuums the systemd journal. Can also truncate oversized live logs (off by default). | `LZC_CLEAN_LOGS_` |
| [`fix_permissions/`](fix_permissions/) | Repairs ownership and permissions inside a single user's home directory, never following symlinks out of it. | `LZC_FIX_PERMISSIONS_` |
| [`network_restart/`](network_restart/) | Restarts one interface and verifies it came back, with an armed rollback so a failed bounce recovers without console access. Refuses to bounce the interface carrying your SSH session unless forced. | `LZC_NETWORK_RESTART_` |
| [`maintenance/`](maintenance/) | Runs named maintenance tasks on Debian/Ubuntu, RHEL-family, Arch (incl. Manjaro), SUSE and Alpine hosts. With no task it produces a read-only health report. | `LZC_MAINTENANCE_` |
| [`proxmox/ve/`](proxmox/ve/) | Updates the packages inside every LXC container on a Proxmox VE node, or across a whole cluster over SSH. | `LZC_UPDATE_LXCS_` |

`maintenance/` tasks: `report`, `update`, `autoremove`, `clean-cache`,
`clean-logs`, `clean-tmp`, `fix-packages`, `fix-locks`, `routine`.

Every flag has an `LZC_<SCRIPT>_<SETTING>` environment variable, which is the
practical route when piping a script in over `curl`. `--color` is settable that
way in every script. `--dry-run` is the one exception: it has a variable in
`fix_apt_lock`, `fix_dnf_lock` and `maintenance` only, and `fix_permissions`
inverts it as `LZC_FIX_PERMISSIONS_APPLY`. Everywhere else `--dry-run` is
flag-only, deliberately — a dry run is a decision you make per invocation, not
a mode you leave switched on in an environment file.

## Installing them

[`../install.sh`](../install.sh) copies these scripts to `PREFIX/sbin` (default
`/usr/local`) as `lzc-*` commands — `lzc-update-upgrade`, `lzc-clean-logs`,
`lzc-update-lxcs` and so on — along with the shared library and bash
completion. It only copies files already on the machine; it never downloads
anything. `--uninstall` removes what it created.

## Exit codes

The [repo-wide table](../docs/exit-codes.md) applies to all of them: `0`
success, `1` partial failure, `2` usage, `3` unsupported platform or missing
prerequisite, `4` not root, `5` refused for want of confirmation, `75` another
instance holds the lock, `130` interrupted.

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
