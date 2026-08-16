# Fix DNF Lock

`fix_dnf_lock.sh` diagnoses a dnf/yum run that will not start — `Waiting for
process with pid NNNN to finish` — and clears the lock **only when no process
holds it**.

## Read this before running it

dnf and rpm locks are advisory locks taken on a file. Deleting one while a
package manager holds it **does not stop that package manager** — it lets a
second one start alongside it, and two concurrent rpm transactions are what
corrupt the RPM database. The lock file is not the problem; it is the mechanism
that was protecting you.

The honest order of operations when dnf says the lock is busy:

1. **Wait.** Something is legitimately working — usually `dnf-automatic` or
   PackageKit — and it will finish. Unlike apt, **dnf already waits by default**
   rather than failing immediately.
2. If the default ceiling is too low for your automation, raise it:
   ```bash
   dnf --setopt=lock_timeout=600 upgrade
   ```
3. Only if the holder is genuinely dead does the lock need clearing.

This script automates step 3 and refuses to act during steps 1 and 2.

### You probably need this less often than you think

dnf already recovers from the usual "stale lock" on its own. `ProcessLock._try_lock`
in `dnf/lock.py` reads the PID recorded inside the lock file and, when
`/proc/<pid>/stat` no longer exists, **truncates the file and takes the lock
over**:

```python
if not os.access('/proc/%d/stat' % old_pid, os.F_OK):
    os.lseek(fd, 0, os.SEEK_SET)
    os.ftruncate(fd, 0)
    os.write(fd, str(pid).encode('utf-8'))
    return pid
```

It also unlinks its own lock file on a clean exit. So a `*_lock.pid` naming a
dead process is not a condition dnf needs help with, and deleting it changes
nothing dnf would not have done itself.

The state dnf genuinely cannot recover from is a lock file whose contents are
**not a PID at all** — it reports `Malformed lock file found: <path>` and tells
you to remove the file or run `systemd-tmpfiles --remove dnf.conf`. That is the
case this script exists for, and it clears it only after proving nothing holds
the file. Run `-n` first: "nothing to clean up" is a normal, common, correct
answer here.

**Deleting an unheld lock file is a no-op for root.** Root is not blocked by
file permissions, and an advisory lock with no holder blocks nothing. The
removal is included because this situation is almost universally misdiagnosed as
needing it, and because a script that refuses to do the thing people came for
gets replaced by a worse one. The value is in the refusal and the diagnosis.

## How it decides

`/proc/locks` is the authority. Per `proc_locks(5)` it lists every `POSIX`
(`fcntl`) byte-range lock, every `FLOCK` (BSD `flock(2)`) lock and every `OFDLCK`
open-file-description lock the kernel holds, so it answers the only question that
matters: *is this file locked right now, and by which PID?* That covers dnf,
which takes its `*_lock.pid` locks with `fcntl.flock(fd, LOCK_EX | LOCK_NB)` —
a `FLOCK` record.

Lock records are matched by **inode**, because the `st_dev` → `major:minor`
mapping is not reversible on btrfs, ZFS or overlayfs (anonymous devices can have
a minor number above 255). Matching the inode alone can only ever over-report,
and over-reporting refuses a removal — the safe direction. Under-reporting would
permit one. OFD locks are reported by the kernel with a PID of `-1`, which the
script renders as an unidentified owner and treats as held.

Reading the lock table is preferred over trying to take a lock (`flock -n`)
because it names the holding process, and because finding out whether a lock
*could* be taken by taking it is a side effect this script has no business
having.

Three further checks stack on top:

- **The recorded PID.** dnf's lock files are pid files too. If the PID written
  inside names a live process, the lock is treated as held even when the lock
  record is ambiguous — the same `/proc/<pid>/stat` test dnf itself applies, so
  the script is never more conservative than dnf is. If it names a process that
  no longer exists, that is reported, with the note that dnf reclaims such a lock
  by itself. Contents that are not a plain integer produce no recorded PID at
  all, which is exactly right: that is dnf's unrecoverable "malformed lock file"
  case, and it falls through to the normal lock checks.
- **`fuser` and `lsof`**, when installed — neither is required. They report
  processes with the file merely *open*, a superset of those that have it
  *locked*, so they add the one case `/proc/locks` cannot see. Their three
  outcomes are kept distinct, because collapsing them is how a wedged mount comes
  to look like a clean bill of health:

  | Outcome | Effect on the verdict |
  | --- | --- |
  | Probe ran | Any PID it names is treated as a holder. |
  | Tool not installed | The `/proc/locks` verdict stands; the report says the corroboration **did not happen** rather than implying it passed. |
  | Probe timed out | That file is reported `unknown`, nothing is removed, exit 75. |

  The middle row matters on minimal images — UBI minimal and similar ship neither
  `psmisc` nor `lsof`, and that is exactly where stuck locks turn up. Refusing to
  work there would make the script useless; the process scan below is the guard
  that does not depend on either tool.
- **Process and unit scan.** The script refuses when any `dnf`, `dnf-3`, `dnf5`,
  `yum`, `microdnf`, `tdnf`, `rpm` or PackageKit process exists anywhere on the
  system, and reports whether `dnf-automatic*.service`, `dnf-makecache.service`
  or `packagekit.service` is active. An rpm transaction releases and re-takes
  locks between stages, so "no lock at this instant" is not the same as "no
  transaction in flight".

Every check fails **closed**: a lock whose state cannot be determined is treated
as held. That includes the read of `/proc/locks` itself — if it cannot be read
at all the script exits 3 before scanning anything; if an individual lock's
records cannot be read, that lock is reported `unknown` and the run stops with
exit 75, rather than treating "no records returned" as "no holder".

Note that a brief `rpm -q` query is enough to make the script refuse. That is
deliberate — it is transient, and the alternative failure mode deletes a live
lock.

## Requirements

Runs as root on a RHEL/Fedora/Rocky/Alma system. Needs Linux procfs
(`/proc/locks`), `rpm`, `timeout`, `stat`, `awk` and `flock`; a missing one is
exit 3. `flock` is required rather than optional because it is the only thing
stopping two copies of this script from racing each other towards the same `rm`
— it ships in `util-linux`, which is essential on every system this script
supports. `fuser`, `lsof`, `ps`, `systemctl` and `dnf` itself are used when
present and skipped when not.

## Usage

```bash
sudo ./fix_dnf_lock.sh -n     # diagnose only; change nothing
sudo ./fix_dnf_lock.sh        # diagnose, then act after a confirmation
sudo ./fix_dnf_lock.sh -y     # unattended
sudo ./fix_dnf_lock.sh -w 600 # wait up to 10 min for the holder to finish
```

## Options

| Flag | Environment variable | Meaning |
| --- | --- | --- |
| `-n, --dry-run` | `LZC_FIX_DNF_LOCK_DRY_RUN` | Report state and plan, change nothing. |
| `-y, --yes` | `LZC_FIX_DNF_LOCK_YES` | Unattended; no prompt. |
| `-w, --wait SECONDS` | `LZC_FIX_DNF_LOCK_WAIT` | Wait for a held lock to be released (`0`). |
| `--no-check` | `LZC_FIX_DNF_LOCK_CHECK=0` | Skip the `dnf check` afterwards. |
| `--path PATH` | `LZC_FIX_DNF_LOCK_PATHS` | Extra lock file to inspect. Repeatable, globs OK. |
| `--timeout SECONDS` | `LZC_FIX_DNF_LOCK_CHECK_TIMEOUT` | Time limit for the post-clean `dnf check` run, and nothing else (`300`). |
| `--color WHEN` | `LZC_FIX_DNF_LOCK_COLOR` | `auto`, `always`, `never`. |
| `-V, --version` | — | Print version. |
| `-h, --help` | — | Print help. |

Everything you can configure is under one prefix, so `env | grep LZC_` shows it:

| Environment variable | Default | What it sets |
| --- | --- | --- |
| `LZC_FIX_DNF_LOCK_YES` | `0` | Bool. Skip the confirmation prompt. |
| `LZC_FIX_DNF_LOCK_DRY_RUN` | `0` | Bool. Report only, change nothing. |
| `LZC_FIX_DNF_LOCK_CHECK` | `1` | Bool. Run `dnf check` after clearing. |
| `LZC_FIX_DNF_LOCK_WAIT` | `0` | Seconds to wait for a held lock; `0` does not wait. |
| `LZC_FIX_DNF_LOCK_POLL` | `5` | Seconds between `--wait` polls. Min 1. |
| `LZC_FIX_DNF_LOCK_CHECK_TIMEOUT` | `300` | Bounds the `dnf check` run. Min 1. |
| `LZC_FIX_DNF_LOCK_PROBE_TIMEOUT` | `10` | Bounds each `fuser`, `lsof` and `systemctl` probe. Min 1. |
| `LZC_FIX_DNF_LOCK_CMDLINE_MAX` | `160` | Characters of a holder's command line printed. Min 1. |
| `LZC_FIX_DNF_LOCK_COLOR` | `auto` | `auto`, `always` or `never`. |
| `LZC_FIX_DNF_LOCK_PATHS` | the eight dnf/yum/rpm locks below | Whitespace-separated lock files to **inspect**; globs allowed. |
| `LZC_FIX_DNF_LOCK_SELF_LOCK` | `/run/lock/lzc-fix-dnf-lock.lock` | This script's own `flock` file. |
| `LZC_FIX_DNF_LOCK_PROC_LOCKS` | `/proc/locks` | Kernel lock table to read. |

**Booleans** accept `1`/`true`/`yes`/`on` and `0`/`false`/`no`/`off`, in any
case. Anything else is rejected with exit 2 and a message naming the variable.
Validation runs before the value reaches an arithmetic context, where a bare
word under `set -u` is a fatal `unbound variable` error rather than a usable
complaint — `LZC_FIX_DNF_LOCK_YES=true` in a cron file is the obvious thing to
write, so it has to work.

**Numbers** must be whole. A zero-padded value such as `08` is read as decimal,
not as an invalid octal literal. `--timeout`, `LZC_FIX_DNF_LOCK_PROBE_TIMEOUT`
and `LZC_FIX_DNF_LOCK_POLL` must be **at least 1**: GNU `timeout` reads a
duration of `0` as "no timeout at all", so a `0` there would silently remove the
guard rather than tighten it. `--wait 0` is still valid and means "do not wait".

**Colour** is emitted only when stdout is a terminal. `NO_COLOR` with any
non-empty value disables it, as does `--color never`; `--color always` overrides
both.

## Concurrency

The script takes an `flock` on `/run/lock/lzc-fix-dnf-lock.lock` and exits 75 if
another copy already holds it. The lock file is never deleted — the kernel
releases it when the descriptor closes, and unlinking it would let a second run
lock a different inode.

## Blast radius

**On a healthy system a default run acts every time.** Whichever of these lock
files exist and are unheld will be offered for removal — an unheld lock is by
definition a stale one, and the script does not try to guess which stale locks
you "meant". Run `-n` first to see exactly what it will do.

With `--yes`, or an answered prompt, the script deletes lock files that nothing
holds or has open, from this list:

| Path | What it is |
| --- | --- |
| `/var/cache/dnf/metadata_lock.pid` | dnf metadata cache lock |
| `/var/cache/dnf/*/metadata_lock.pid` | same, per-repo-config layout |
| `/var/cache/dnf/download_lock.pid` | dnf download lock |
| `/var/cache/dnf/*/download_lock.pid` | same, per-repo-config layout |
| `/var/lib/dnf/rpmdb_lock.pid` | dnf's RPM database lock |
| `/var/lib/rpm/.rpm.lock` | rpm's own lock |
| `/run/dnf.pid`, `/run/yum.pid` | legacy pid files |

Globs are expanded and non-matching entries are dropped, so a path that does not
exist on your release costs nothing. All of these are recreated automatically.

Two caveats on that list, both handled with `--path` rather than by guessing:

- `/var/lib/rpm/.rpm.lock` assumes the default RPM database location. Confirm
  yours with `rpm -E '%{_dbpath}'` and point `--path` at `<dbpath>/.rpm.lock` if
  it differs.
- **dnf5** (Fedora 41+, RHEL 10) has *not* been confirmed to use these paths —
  it uses a different cache root (`/var/cache/libdnf5`) and its lock layout was
  not verified while writing this, so nothing is asserted about it. If `dnf5` is
  your package manager, find the lock it is actually holding
  (`grep -i dnf /proc/locks`, or `lsof -p <pid>`) and pass it with `--path`.

It then runs `dnf check`, which is read-only, to confirm the package manager can
take its locks again. Skip with `--no-check`.

It never removes a held lock, never installs, updates or removes a package,
never runs `rpm --rebuilddb`, and never touches `/var/lib/rpm/rpmdb.sqlite*`
(including `-wal` and `-shm`), `/var/lib/rpm/Packages`, `/var/lib/rpm/__db.*` or
`/var/lib/dnf/history.sqlite`.

Two independent guards enforce that, checked immediately before every unlink:
a **basename allow-list** — anything not named like a lock (`.rpm.lock`,
`*_lock.pid`, `*.lock`, `dnf.pid`, `yum.pid`) is refused outright — and a
never-remove list of database paths. Both are deliberately **not** configurable.
`LZC_FIX_DNF_LOCK_PATHS` can widen what gets *inspected*, never what gets
deleted.

## Exit status

| Code | Meaning |
| --- | --- |
| 0 | Success — nothing needed changing, or every change succeeded. |
| 1 | The work ran but something in it failed: a removal was refused or failed. |
| 2 | Usage error — unknown flag, missing or invalid argument value. |
| 3 | Unsupported platform or a missing prerequisite tool. |
| 4 | Must be run as root. |
| 5 | Refused: confirmation was needed, but there is no TTY and `--yes` was not given. Nothing changed. |
| 75 | Temporary failure, retry later (`EX_TEMPFAIL`): a package manager is running, another copy of this script holds the lock, or a lock's state could not be determined. Nothing changed. |
| 130 | Interrupted (SIGINT/SIGTERM). |

75 is the interesting one for monitoring: the machine is busy, not broken, and
cron and systemd both read `EX_TEMPFAIL` as "retry later" rather than a fault.
Four cases also return 75 but will **not** clear on a retry, so read the report
before wiring a retry loop around this:

- a lock path that is a symlink,
- a lock path that is not a regular file,
- a lock path whose `fuser`/`lsof` probe timed out — usually a wedged NFS or
  FUSE mount, which needs fixing before any of this is meaningful,
- a lock file whose recorded PID has been **reused** by an unrelated process.
  The report prints that process's command line, so you can see it is not a
  package manager.

A non-zero `dnf check` does **not** fail the run. It reports RPM database
problems that predate this script, and the fact that it ran at all proves the
locks are usable — which is what the script set out to fix. It is logged as a
warning.

## Limits and residual risk

- **There is a race between the final check and the `rm`.** Two re-checks narrow
  it. The full assessment — lock records *and* the system-wide package-manager
  process scan — is re-run after the confirmation prompt is answered, because
  that prompt can sit unanswered for minutes and an rpm transaction releases and
  re-takes its locks between stages, so a run that started while you were reading
  may hold no lock at that instant. Then each individual lock's records are
  re-checked immediately before it is unlinked. What remains is the gap between
  that last check and the `rm` itself, and a shell cannot make it zero — taking
  the lock properly would need an `fcntl` lock, which bash has no way to acquire.
- **Inode-only matching can over-report.** If an unrelated file on another
  filesystem happens to share an inode number with a lock file and is locked,
  the script reports the lock as held and refuses. It prints the PID and command
  line so you can see that the holder is unrelated. This is deliberate: the
  alternative failure mode deletes a live lock.
- **A recycled PID reads as a live holder.** If the PID recorded in a lock file
  has since been reused by an unrelated process, the lock is reported held and
  will stay that way across retries. dnf's own recovery path has the same
  blind spot, so this is not extra caution — but it does mean a permanent 75 is
  worth reading rather than retrying. The command line in the report tells you
  which it is.
- **`/proc/locks` cannot see an open-but-unlocked descriptor.** A process that
  has a lock file open without holding a lock on it is not in a critical section
  and does not block dnf, but it will re-lock that inode later. `fuser`/`lsof`
  are what catch it, and on a host with neither installed that check simply does
  not happen — the report says so. The system-wide scan for `dnf`, `yum`, `rpm`
  and PackageKit is the backstop that always runs, so the uncovered case is a
  *non-package-manager* process holding a dnf or rpm lock file open. That is
  rare, and it is stated here rather than papered over.
- **`/var/lib/rpm/.rpm.lock` is included on the strength of its name, not a
  verified locking mechanism.** rpm's own lock implementation was not read while
  writing this, so no claim is made about which API it uses. It does not matter
  for detection: `/proc/locks` records `POSIX`, `FLOCK` and `OFDLCK` alike.
- **There is no dnf equivalent of `dpkg --configure -a`.** RPM has no
  half-configured state to replay. If the RPM database is genuinely damaged, the
  recovery is `rpm --rebuilddb` after backing up `/var/lib/rpm` — a human-run
  step this script deliberately does not automate.
- RPM applies configuration changes silently as `.rpmnew`/`.rpmsave` files
  rather than prompting. Interrupted transactions can leave drift this script
  does not look for: `find /etc -name '*.rpmnew' -o -name '*.rpmsave'`.
- Killing a running rpm transaction is what breaks systems. If you must end a
  dead session's hold, `fuser -k -TERM /var/lib/rpm/.rpm.lock` sends a signal it
  can act on. Never `SIGKILL` a live rpm transaction.
