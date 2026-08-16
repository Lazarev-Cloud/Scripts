# Linux Maintenance Runner

`maintenance.sh` runs named housekeeping tasks on Debian/Ubuntu and RHEL-family
hosts: a health report, package updates, cache/log/tmp cleanup, and repair of an
interrupted package operation.

Nothing happens unless you name a task. With no task it prints a read-only
report. Every task that changes the system can be previewed with `--dry-run`,
prints its blast radius before acting, and refuses to run unattended without
`--yes`.

```bash
./maintenance.sh                              # health report, changes nothing
./maintenance.sh --dry-run clean-logs         # exactly which files would go
sudo ./maintenance.sh --yes routine           # unattended nightly run
```

## Requirements

Runs as root for anything except `report`. Needs `bash` 4.4 or newer, plus
`find` and `df` from coreutils/findutils. An older `bash` exits `3`.

`flock` (util-linux) is required for any run that changes the system: without
it there is no concurrency protection, and running a package transaction
alongside another one is the collision this script exists to avoid, so it exits
`3` rather than proceeding unlocked. `report` and `--dry-run` never take the
lock and run fine without it.

`timeout` (coreutils) is strongly recommended — without it the script warns and
runs commands unbounded. `apt-get`, `dnf`/`yum`, `journalctl`,
`systemd-tmpfiles`, `fuser`/`lsof` are used when present and skipped when not.

## Tasks

| Task | Changes the system | What it does | Blast radius |
| --- | --- | --- | --- |
| `report` | no | Health summary (see below). | None. The only task that runs without root. |
| `update` | yes | Refreshes the index, then upgrades. | Installs new package versions; packaging scripts may restart services. |
| `autoremove` | yes | Removes packages nothing needs any more. | **Purges packages and their config**, old kernels included. |
| `clean-cache` | yes | Deletes downloaded package archives. | Cache only; all of it is re-downloadable. |
| `clean-logs` | yes | Vacuums the journal, deletes aged rotated logs. | **Deletes log history permanently.** |
| `clean-tmp` | yes | Cleans temporary files. | **Deletes files.** In `age` mode, in `--tmp-dirs`. In `tmpfiles` mode — the default under systemd — everywhere the distribution's `tmpfiles.d` policy covers, which is wider. |
| `fix-packages` | yes | `dpkg --configure -a`, then `apt-get -f install`. | Completes half-finished package operations. Debian/Ubuntu only. |
| `fix-locks` | no* | Diagnoses package-manager locks. | Read-only on Debian/Ubuntu. On RHEL it may delete a dnf pid file whose process is provably gone, and asks first. |
| `routine` | yes | Group: `update`, `autoremove`, `clean-cache`, `report`. | The union of its members. |

\* `fix-locks` still requires root: an unprivileged `fuser` cannot see file
handles held by other users, so it would report "nothing holds the lock" while
root's `dpkg` holds it. Rather than guess, it refuses.

Tasks run in the order given and each name runs once, so `routine report` runs
the report a single time, at the end.

### `report`

Read-only. Covers the host and OS, uptime and load, memory and swap,
filesystems and inodes at or above the warning thresholds, `/boot` usage,
installed kernel packages versus the running one, pending updates and held
packages, whether a reboot is pending, failed systemd units, config files the
packaging left behind (`.dpkg-dist`, `.dpkg-new`, `.ucf-dist`, `.rpmnew`,
`.rpmsave`), journal size, and whether any package-manager lock is held.

A pending reboot is reported in the `Reboot` section and repeated as a warning
in the run summary. It is not an exit code: the repo-wide table reserves every
code it defines, and a reboot is not one of those situations. A monitoring
wrapper should read `/run/reboot-required` or the report output.

Under `--quiet` the report body goes to the log file instead of stdout — this is
what keeps `--yes --quiet routine` silent in cron even though `routine` ends
with a report. The report is still generated, so a pending reboot is still
recorded where an unattended run can be audited afterwards. If the log file is
not writable there is nowhere to put it and `--quiet report` produces nothing.

### `clean-logs`

Two independent steps:

- `journalctl --vacuum-size` and `--vacuum-time`, when journald is present.
- Deleting already-rotated files under `--log-dir` older than `--log-age` days:
  `*.gz`, `*.xz`, `*.bz2`, `*.zst`, `*.old`, and one- or two-digit numeric
  suffixes such as `syslog.1`.

Live `*.log` files are never touched. Truncating a file a daemon holds open is
how "free some space" becomes "the service stopped logging". Names matching
`--log-exclude` (default `audit wtmp btmp lastlog`) are skipped, so the audit
trail and the login records survive; on a host with a compliance obligation,
deleting those is an incident, not housekeeping.

`logrotate`'s own `rotate` and `maxage` settings are the better place to express
retention. This task is for a filesystem that is already full.

### `clean-tmp`

Two modes, and **they do not have the same blast radius.** `auto` picks
`tmpfiles` wherever systemd is running and `age` otherwise. Which one applies is
resolved before the plan is printed, so the plan line you confirm names the
behaviour you are actually getting. Force either with `--tmp-mode tmpfiles` or
`--tmp-mode age`.

**`tmpfiles` mode** defers to `systemd-tmpfiles --clean`, which follows the
distribution's own `tmpfiles.d` policy — that policy already encodes which paths
are safe to remove, after how long, and which sockets must survive. The cost of
delegating is that the policy is **wider than `--tmp-dirs`**: it can clean paths
you did not name, and neither `--tmp-dirs` nor `--tmp-age` applies. List the
rules that will be used with `systemd-tmpfiles --cat-config`.

`--dry-run` in this mode runs `systemd-tmpfiles --clean --dry-run` and shows you
the real file list. That option arrived in systemd 249, so support is probed
rather than assumed; on an older systemd (Debian 11 ships 247) the dry run says
it cannot preview and changes nothing, rather than guessing. Use `--tmp-mode age`
there if you need a previewable sweep.

A preview is a query, not work: if `systemd-tmpfiles --clean --dry-run` exits
non-zero — which an unprivileged preview will, since it cannot stat everything
the policy covers — the status is reported as a warning and the task still
counts as succeeded. Every task's `--dry-run` returns `0`.

**`age` mode** deletes regular files under `--tmp-dirs` whose **atime and mtime
are both** older than `--tmp-age` days, then removes directories left empty.
Directories are never deleted for being old, only for being empty, so an old
directory holding fresh files survives. Sockets and symlinks are left alone, as
are names matching `--tmp-exclude`.

### `fix-locks`

Reports which process holds each package-manager lock, and never kills it.

It does not delete `/var/lib/dpkg/lock`, `lock-frontend`, or the apt locks.
Those are `flock(2)` targets: the kernel releases the lock when the holding
process exits, including on `kill -9`, so they cannot go stale. A leftover
zero-byte file blocks nothing. Deleting one while a holder is alive is what lets
a second `dpkg` run concurrently against the same database — that is the actual
cause of the corruption people are usually trying to fix.

If the holder cannot be determined — no `fuser`, no `lsof`, or not root — it
refuses rather than assuming the lock is free.

The genuine fix for a busy lock is to wait, which `--pkg-lock-wait` does for you
on every apt transaction this script runs.

## Options

Every option has an environment variable, which is easier when piping the script
in from the network. Every variable is named `LZC_MAINTENANCE_*`, matching the
repo-wide namespace, so `env | grep LZC_` shows everything that is configurable.

| Flag | Environment variable | Default | Meaning |
| --- | --- | --- | --- |
| `-n, --dry-run` | `LZC_MAINTENANCE_DRY_RUN` | off | Print what would happen; change nothing. |
| `-y, --yes` | `LZC_MAINTENANCE_YES` | off | Skip the confirmation. Required by cron. |
| `-q, --quiet` | `LZC_MAINTENANCE_QUIET` | off | Silent on success; output only on failure. |
| `--list-tasks` | — | — | Print task names and exit. |
| `--upgrade-mode MODE` | `LZC_MAINTENANCE_UPGRADE_MODE` | `upgrade` | `upgrade` or `dist-upgrade`. |
| `--timeout SECONDS` | `LZC_MAINTENANCE_TIMEOUT` | `3600` | Bounds **each system-changing command** individually: one apt/dnf transaction, one journal vacuum, one `systemd-tmpfiles` run. Not a budget for the whole run. Minimum `1`. |
| `--probe-timeout SEC` | `LZC_MAINTENANCE_PROBE_TIMEOUT` | `30` | Bounds **each read-only probe** individually: `df`, `dpkg-query`, `rpm`, `systemctl`, `journalctl --disk-usage`, `fuser`/`lsof`, and the simulated upgrade the report counts. Minimum `1`. |
| `--pkg-lock-wait SEC` | `LZC_MAINTENANCE_PKG_LOCK_WAIT` | `600` | How long apt waits for the dpkg lock to be released before giving up (`DPkg::Lock::Timeout`). Not a `timeout(1)` bound; `0` means do not wait. |
| `--disk-warn PCT` | `LZC_MAINTENANCE_DISK_WARN` | `85` | Filesystem usage worth reporting (0–100). |
| `--inode-warn PCT` | `LZC_MAINTENANCE_INODE_WARN` | `85` | Inode usage worth reporting (0–100). |
| `--log-dir PATH` | `LZC_MAINTENANCE_LOG_DIR` | `/var/log` | Directory `clean-logs` sweeps. |
| `--log-age DAYS` | `LZC_MAINTENANCE_LOG_AGE_DAYS` | `30` | Age of rotated logs to delete. |
| `--log-exclude LIST` | `LZC_MAINTENANCE_LOG_EXCLUDE` | `audit wtmp btmp lastlog` | Names `clean-logs` must not touch. |
| `--journal-size SIZE` | `LZC_MAINTENANCE_JOURNAL_SIZE` | `500M` | `journalctl --vacuum-size`. |
| `--journal-age TIME` | `LZC_MAINTENANCE_JOURNAL_AGE` | `30d` | `journalctl --vacuum-time`. |
| `--tmp-dirs LIST` | `LZC_MAINTENANCE_TMP_DIRS` | `/tmp /var/tmp` | Directories `clean-tmp` cleans. |
| `--tmp-age DAYS` | `LZC_MAINTENANCE_TMP_AGE_DAYS` | `10` | Age threshold, `age` mode only. |
| `--tmp-mode MODE` | `LZC_MAINTENANCE_TMP_MODE` | `auto` | `auto`, `tmpfiles`, or `age`. |
| `--tmp-exclude LIST` | `LZC_MAINTENANCE_TMP_EXCLUDE` | X11/ICE sockets, `systemd-private*` | Names `clean-tmp` must not touch. |
| `--needrestart-mode M` | `LZC_MAINTENANCE_NEEDRESTART_MODE` | `l` | After an update, what to do about services still running old libraries: `l` lists them, `a` **restarts** them, `i` asks. |
| `--log-file PATH` | `LZC_MAINTENANCE_LOG` | `/var/log/maintenance.log` | This script's own log. |
| `--lock-file PATH` | `LZC_MAINTENANCE_LOCK` | `/run/lock/lzc-maintenance.lock` | Concurrency lock. |
| `--color WHEN` | `LZC_MAINTENANCE_COLOR` | `auto` | `auto`, `always`, `never`. |
| `-V, --version` | — | — | Print version and exit. |
| `-h, --help` | — | — | Print help and exit. |

Environment-only settings:
`LZC_MAINTENANCE_FS_EXCLUDE` (default `tmpfs devtmpfs squashfs overlay efivarfs`),
`LZC_MAINTENANCE_ETC_DIR` (default `/etc`), `LZC_MAINTENANCE_LOG_MAX_BYTES`
(default `5242880`), `LZC_MAINTENANCE_PATH`
(default `/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin`).

### Values

The three boolean variables — `LZC_MAINTENANCE_DRY_RUN`, `LZC_MAINTENANCE_YES`,
`LZC_MAINTENANCE_QUIET` — accept `1`/`true`/`yes`/`on` and `0`/`false`/`no`/`off`
in any case. Anything else is a usage error (exit `2`) with a message naming the
setting, rather than a silently wrong default.

Numeric values are validated and read as decimal, so a zero-padded `08` means
eight, not an invalid octal literal. `--timeout` and `--probe-timeout` have a
minimum of `1`: `timeout 0` means *no* limit, so accepting `0` would silently
remove the protection the option exists to provide.

`--log-dir` and every entry in `--tmp-dirs` is a **sweep root**: files beneath it
are deleted, as root. A typo there is not recoverable, so each is required to be
an absolute path, with no `.` or `..` component, that is not `/` and not a
top-level system directory such as `/usr` or `/var`. `/tmp` is allowed — it is
the one top-level directory whose contents are disposable by definition, and it
is a default. Anything rejected exits `2` naming the value; name the directory
inside it that you meant.

### Colour

`NO_COLOR` is honoured per [no-color.org](https://no-color.org): any non-empty
value disables colour. An explicit `--color always` still wins, because a flag
is a deliberate answer to the question the variable answers by default.
Otherwise colour is emitted only when stdout is a terminal.

Normal output goes to stdout and diagnostics to stderr, so
`maintenance.sh report > report.txt` still shows you the warnings.

## Exit status

| Code | Meaning |
| --- | --- |
| 0 | Success. Every task that applied to this host succeeded. |
| 1 | The work ran but something in it failed. |
| 2 | Usage error: unknown flag, unknown task, missing or invalid argument value. |
| 3 | Unsupported platform or a missing prerequisite tool: `bash` older than 4.4, no `flock` for a run that changes the system, or an unusable lock file. |
| 4 | Must be run as root. |
| 5 | Refused: confirmation needed, but no TTY and `--yes` was not given. |
| 75 | Temporary failure: another instance holds the lock (`EX_TEMPFAIL`, so cron and systemd treat it as "retry later" rather than a real fault). |
| 130 | Interrupted (`SIGINT`/`SIGTERM`). |

A failing task never stops the ones after it — the run finishes, then reports.

A pending reboot is a warning in the summary, not an exit code. A task that does
not apply to this host (`fix-packages` on RHEL, any package task with no package
manager present) is reported as skipped and does not fail the run.

Code 75 is not a fault as far as a scheduler is concerned. Say so, or you will
train people to ignore the mail.

## Scheduling

### systemd timer

```ini
# /etc/systemd/system/maintenance.service
[Unit]
Description=Nightly system maintenance
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/maintenance.sh --yes --quiet routine
TimeoutStartSec=2h
SuccessExitStatus=0 75
Nice=10
IOSchedulingClass=idle
```

```ini
# /etc/systemd/system/maintenance.timer
[Unit]
Description=Nightly system maintenance

[Timer]
OnCalendar=*-*-* 03:20:00
Persistent=true
RandomizedDelaySec=30m

[Install]
WantedBy=timers.target
```

`Persistent=true` catches up a run missed while the machine was off.
`RandomizedDelaySec=` stops a fleet hitting the mirror in lockstep.

`SuccessExitStatus=` lists `75` and nothing else. `75` means another instance
already holds the lock, which is genuinely not a fault. Do **not** add `3` to
that list: `3` means a prerequisite is missing — no `flock`, for instance — and a
host in that state runs no maintenance at all while its unit stays green.

### cron

```
# /etc/cron.d/maintenance — 03:20 daily
20 3 * * * root /usr/local/sbin/maintenance.sh --yes --quiet routine
```

`--quiet` is what makes this cron-friendly: output only appears when something
failed, so mail means something. The script sets its own `PATH` and never
prompts, so it needs nothing from the crontab environment.

Concurrent runs are refused via `flock` on `/run/lock/lzc-maintenance.lock`
(exit 75). The lock is only taken when a task will actually change something, so
a `report` is never blocked by an update already in progress. The script's own
log rotates once past `LZC_MAINTENANCE_LOG_MAX_BYTES`.

## Running from the network

Fetch, verify, then run. Pin to a **commit SHA** and check the hash before
executing.

```bash
REV=<40-char-commit-sha>
SUM=<sha256-of-that-file>
URL=https://raw.githubusercontent.com/Lazarev-Cloud/Scripts/$REV/linux/maintenance/maintenance.sh

curl -fsSL --proto '=https' --tlsv1.2 -o /tmp/maintenance.sh "$URL" \
  && echo "$SUM  /tmp/maintenance.sh" | sha256sum -c - \
  && sudo bash /tmp/maintenance.sh --yes routine
```

Produce the two values from a checkout with `git rev-parse HEAD` and
`sha256sum linux/maintenance/maintenance.sh`.

A branch name is not a pin — it means "whatever was pushed most recently",
executed as root. A tag is not a pin either, because a tag can be moved. A
commit SHA is content-addressed.

`main "$@"` is the last line of the script and everything above it is a
definition, so a truncated download fails to parse and runs nothing rather than
executing half a cleanup. Environment variables are the easier way to pass
settings through a pipe, since `bash -c "$script" arg` assigns the first
argument to `$0`:

```bash
LZC_MAINTENANCE_YES=1 LZC_MAINTENANCE_QUIET=1 bash -c "$s" -- routine
```

## Notes and limits

- Package transactions are given a generous timeout rather than a short one,
  because killing `dpkg` mid-transaction is itself a way to break a system. If
  the timeout does fire, run `fix-packages` to replay the dpkg journal. The bound
  cannot be switched off — `--timeout 0` is rejected, because `timeout 0` means
  *no* limit and accepting it would silently remove the protection. Raise it
  instead (`--timeout 86400`).
- `update` defaults to `upgrade`, which never removes a package. `dist-upgrade`
  can remove packages to satisfy dependencies; ask for it deliberately.
- Service restarts are listed, not performed. Pass `--needrestart-mode a` (or
  `LZC_MAINTENANCE_NEEDRESTART_MODE=a`) if a maintenance window means restarting
  services still running old libraries is fine.
- Config changes shipped by packages are not applied: apt runs with
  `--force-confdef --force-confold`, so your edited files stay. `report` lists
  the `.dpkg-dist`/`.rpmnew` files this leaves behind — reconcile them yourself.
- Old kernels are removed by `autoremove`, which is the packaging system's own
  mechanism for it. There is no bespoke kernel purge here: getting it wrong
  makes a host unbootable, and on Proxmox `/boot` is additionally governed by
  `proxmox-boot-tool`. On RHEL, kernel retention is `installonly_limit` in
  `/etc/dnf/dnf.conf`.
- SIGHUP is ignored, so losing an SSH connection mid-run does not kill `dpkg`.
  For a long run, prefer `systemd-run --unit=maint --collect
  /usr/local/sbin/maintenance.sh --yes routine` and follow it with `journalctl`.
- This is a maintenance tool. It does not create users, install Docker, add
  repositories, configure firewalls, set locales, create swap, take backups, or
  execute arbitrary commands. Those are provisioning decisions and belong to
  configuration management.
- If two patching mechanisms run unmanaged on the same host they will fight over
  the lock. Pick one: this script, or `unattended-upgrades`/`dnf-automatic`.
