# Fix Permissions

`fix_permissions.sh` gives one user back ownership of their home directory and
clears group/other-writable bits, without flattening executable bits or
breaking SSH and GnuPG. It reports first and changes nothing until you ask.

## Blast radius

Read this before running it as root.

Every file, directory, symlink and socket beneath **one** home directory is
chown'ed to that user and has its group- and other-write bits cleared. On a
normal home that is tens of thousands of inodes, and the filesystem has no undo.

That is why the script defaults to a dry run, and why it snapshots the
ownership and mode of every path it is about to change, with `getfacl`, before
changing any of them:

```bash
setfacl --restore=/var/backups/fix-permissions/<user>-<timestamp>.facl
```

The snapshot covers exactly the change set — not the whole home — so it honours
`--exclude` and the filesystem boundary, and stays proportional to the work
rather than to the size of the directory.

What it deliberately does **not** do:

- never `chmod 777`, and never grants a group, other, setuid or setgid bit that
  the path did not already have — the only bits it adds are the owner's
- never strips the executable bit from files, so `~/bin` and `~/.local/bin`
  keep working
- never follows a symlink. Links get `chown -h` and are never `chmod`'ed, so a
  link pointing at `/etc/shadow` cannot be used to drag the script outside the
  home directory
- never touches `/` or a system directory, whatever `/etc/passwd` claims
- never crosses a filesystem boundary unless asked
- never runs two applying instances at once: `--apply` takes an exclusive
  `flock` and exits 75 if another run holds it

## Requirements

GNU `find` (the `-printf` extension), `timeout`, and `xargs`. `flock`
(util-linux) as well, for `--apply` — a dry run takes no lock and does not need
it. `getfacl`/`setfacl` from the `acl` package are optional but strongly
recommended — without them there is no snapshot and the run cannot be undone.
Changing ownership needs root; a dry run works as any user, but only sees the
paths that user can read.

## Running it

```bash
./fix_permissions.sh                       # dry run for your own home
sudo ./fix_permissions.sh --user alice     # dry run for alice
sudo ./fix_permissions.sh --user alice --apply   # prompts, then applies
sudo ./fix_permissions.sh --user alice --yes     # unattended, for cron
```

Under `sudo` the default target is `$SUDO_USER`, not `root` — the invoking
human's home, which is almost always what you meant.

### From the network

Fetch, verify, then run. Pin to a **commit SHA** and check the hash first.

```bash
REV=<40-char-commit-sha>
SUM=<sha256-of-that-file>
URL=https://raw.githubusercontent.com/Lazarev-Cloud/Scripts/$REV/linux/fix_permissions/fix_permissions.sh

curl -fsSL --proto '=https' --tlsv1.2 -o /tmp/fix_permissions.sh "$URL" \
  && echo "$SUM  /tmp/fix_permissions.sh" | sha256sum -c - \
  && sudo bash /tmp/fix_permissions.sh --user alice
```

Produce the two values from a checkout with `git rev-parse HEAD` and
`sha256sum linux/fix_permissions/fix_permissions.sh`. A branch name is not a
pin — it means "whatever was pushed most recently", executed as root. A tag is
not a pin either, because a tag can be moved.

Because `bash -c "$script" arg` assigns the first argument to `$0`, flags need a
literal `--` in front of them. Environment variables avoid the problem:

```bash
LZC_FIX_PERMISSIONS_USER=alice LZC_FIX_PERMISSIONS_APPLY=1 \
  LZC_FIX_PERMISSIONS_YES=1 bash -c "$s"
```

`LZC_FIX_PERMISSIONS_APPLY=1` is what makes it write; `LZC_FIX_PERMISSIONS_YES=1`
only suppresses the prompt. Setting `LZC_FIX_PERMISSIONS_YES=1` on its own
produces a dry run and exits 0 — deliberately, so a stray value in an
environment file cannot turn an invocation destructive.

## Options

| Flag | Environment variable | Meaning |
| --- | --- | --- |
| `--apply` | `LZC_FIX_PERMISSIONS_APPLY` | Make the changes. Prompts when interactive. |
| `-y, --yes` | `LZC_FIX_PERMISSIONS_YES` | Skip the confirmation prompt. Required for cron. The flag implies `--apply`; the environment variable does **not**, so pair it with `LZC_FIX_PERMISSIONS_APPLY=1`. |
| `-n, --dry-run` | — | Report only. The default, and it wins over `--apply`/`--yes`. |
| `-u, --user NAME` | `LZC_FIX_PERMISSIONS_USER` | Whose home to repair (default: `$SUDO_USER`, else you). |
| `-g, --group NAME` | `LZC_FIX_PERMISSIONS_GROUP` | Group to set (default: the user's primary group). |
| `--home PATH` | `LZC_FIX_PERMISSIONS_HOME` | Repair this directory instead of the passwd home. |
| `--strict` | `LZC_FIX_PERMISSIONS_STRICT` | Remove all group/other access, not just write. |
| `--private DIRS` | `LZC_FIX_PERMISSIONS_PRIVATE_DIRS` | Dirs locked to 0700/0600 (`.ssh,.gnupg`). |
| `--exclude GLOB` | `LZC_FIX_PERMISSIONS_EXCLUDE` | Prune a subtree. Matched against the full path below the home; `*` crosses `/`. Repeatable. |
| `--cross-filesystems` | `LZC_FIX_PERMISSIONS_CROSS_FILESYSTEMS` | Descend into mounted filesystems. |
| `--no-chown` | `LZC_FIX_PERMISSIONS_CHOWN=0` | Fix modes only. |
| `--no-chmod` | `LZC_FIX_PERMISSIONS_CHMOD=0` | Fix ownership only. |
| `--no-backup` | `LZC_FIX_PERMISSIONS_BACKUP=0` | Skip the `getfacl` snapshot. |
| `--backup-dir PATH` | `LZC_FIX_PERMISSIONS_BACKUP_DIR` | Snapshot location (`/var/backups/fix-permissions`). |
| `--timeout SECONDS` | `LZC_FIX_PERMISSIONS_SCAN_TIMEOUT` | Bounds the scan of the home directory: the single `find` walk that builds the plan (600). |
| `--apply-timeout SEC` | `LZC_FIX_PERMISSIONS_APPLY_TIMEOUT` | Bounds each `chown`/`chmod` batch on its own, not the apply phase as a whole (1800). |
| `--backup-timeout SEC` | `LZC_FIX_PERMISSIONS_BACKUP_TIMEOUT` | Bounds the `getfacl` snapshot of the change set (600). |
| `--max-list N` | `LZC_FIX_PERMISSIONS_MAX_LIST` | Example paths printed per category (20). `0` prints counts only. |
| `--lock-file PATH` | `LZC_FIX_PERMISSIONS_LOCK` | Concurrency lock (`/run/lock/lzc-fix_permissions.lock`). |
| `--color WHEN` | `LZC_FIX_PERMISSIONS_COLOR` | `auto`, `always`, `never`. |
| `-V, --version` | — | Print version. |
| `-h, --help` | — | Print help, including the blast radius. |

Every variable a user may set is named `LZC_FIX_PERMISSIONS_*`, so
`env | grep LZC_` shows the whole configurable surface.

Boolean variables (`_APPLY`, `_YES`, `_STRICT`, `_CHOWN`, `_CHMOD`, `_BACKUP`,
`_CROSS_FILESYSTEMS`) accept `1/true/yes/on` and `0/false/no/off` in any case;
anything else is rejected with exit 2 rather than crashing in an arithmetic
context. The three timeouts are in seconds and must be at least 1: `timeout 0`
means *no* limit, which would remove the protection the option exists to
provide. Zero-padded values such as `08` are read as decimal.

Colour is emitted only when stdout is a terminal, and
[`NO_COLOR`](https://no-color.org) (any non-empty value) turns it off.
`--color always` overrides both; `--color never` overrides everything.

## What it sets

| Kind | Result |
| --- | --- |
| Home and normal directories | owner `rwx`, group/other write cleared; setgid and sticky preserved |
| Normal files | owner `rw`, group/other write cleared, setuid/setgid cleared; execute bits untouched |
| `.ssh`, `.gnupg` directories | `0700` |
| Files inside them | `0600`, including `*.pub` |
| Symlinks | ownership only, via `chown -h` |
| Sockets, fifos, devices | ownership only |

With `--strict`, "group/other write cleared" becomes "group/other access removed
entirely" — `0700` directories and `0600` files, with the owner's execute bit
still preserved.

SSH's `StrictModes` also requires that the home directory itself is not group-
or other-writable. The default rule already guarantees that, so a run with no
other effect can still be what fixes public-key login.

Ownership is applied before permissions, because the kernel clears setuid and
setgid on `chown`; doing it the other way round would leave modes that no longer
match what the dry run reported.

## Exit status

| Code | Meaning |
| --- | --- |
| 0 | Nothing to change, dry run finished, or every change applied. |
| 1 | The work ran but something in it failed. |
| 2 | Usage error: unknown flag, missing or invalid argument value. |
| 3 | A required tool is missing: GNU `find`, `timeout`, `xargs`, or `flock`. |
| 4 | Must be run as root. |
| 5 | Changes pending, but no terminal to confirm at and no `--yes`. |
| 75 | Another instance holds the lock. |
| 130 | Interrupted (SIGINT/SIGTERM). |

Code 1 is everything that fails after the run has started: a `chown`/`chmod`
batch that could not be applied, a scan that timed out, a snapshot that could
not be written, an unusable working directory. If `getfacl` exists but the
snapshot fails, the run stops before touching anything rather than proceed
irreversibly — raise `--backup-timeout` if it ran out of time, or pass
`--no-backup` to accept that trade deliberately.

Code 2 covers an unknown user or group and a home directory that is `/` or a
system directory, whether that came from `--home` or from `/etc/passwd`. In both
cases the fix is the invocation: pass a different `--user`, or point `--home`
somewhere real. System accounts whose passwd home is `/nonexistent` land here by
design.

Code 4 is only reached when the run would change ownership. `--no-chown --apply`
works as an ordinary user on files that user already owns.

## Concurrency

An `--apply` run takes an exclusive `flock` on
`/run/lock/lzc-fix_permissions.lock` (`--lock-file`,
`LZC_FIX_PERMISSIONS_LOCK`) and exits 75 if another run holds it — a code cron
and systemd read as "temporarily unavailable, retry later" rather than a fault.

The lock is held across the scan as well as the apply, because the apply
executes a plan the scan produced; a second run mutating the same tree in
between would make that plan describe a filesystem that no longer exists.

A dry run takes no lock. It changes nothing, and `/run/lock` is root-owned, so
locking it would stop an unprivileged user from running the report at all. For
the same reason a non-root `--no-chown --apply` that cannot open the lock file
warns and continues instead of failing: it can only touch modes on files it
already owns, and the operation is idempotent. Point
`LZC_FIX_PERMISSIONS_LOCK` at a writable path to get a real lock in that case.

## Scheduling

```
# /etc/cron.d/fix-permissions — Sunday 04:00, alice's home, unattended
0 4 * * 0 root /usr/local/sbin/fix_permissions.sh --user alice --yes --exclude .cache
```

`--yes` is mandatory under cron: with no terminal to confirm at, the script
exits 5 rather than guess. Excluding large caches keeps the scan short. If the
previous week's run is somehow still going, this one exits 75 and cron treats it
as a retryable condition rather than a failure.

## Excluding subtrees

`--exclude` patterns are matched against the whole path below the home, and `*`
crosses `/`. That makes the behaviour worth stating precisely:

| Pattern | Prunes |
| --- | --- |
| `.cache` | `~/.cache` and everything under it |
| `.cache/*` | the contents of `~/.cache`, but not `~/.cache` itself |
| `node_modules` | only `~/node_modules` — **not** `~/proj/node_modules` |
| `*/node_modules` | every `node_modules` **below a subdirectory** — `~/proj/node_modules`, but **not** `~/node_modules` |

A bare directory name matches only a direct child of the home; the `*/` form
matches only things that are *not* direct children, because `*` still has to
match at least one character. Neither covers both, so when you mean "wherever
this appears" pass the pattern twice:

```bash
--exclude node_modules --exclude '*/node_modules'
```

## Notes and limits

- Very large homes take a while: the scan stats every inode. The snapshot only
  covers the paths being changed, so it does not add a second full walk.
  `--exclude .cache` and `--exclude '*/node_modules'` cut the scan a lot.
- Mounted filesystems under the home are not descended into by default. The
  mount point directory itself is still adjusted. Use `--cross-filesystems` to
  include them, and think about what else lives on that mount first.
- A dry run as a non-root user only reports the paths that user can read; the
  count of unreadable paths is printed so a partial view is not mistaken for a
  clean one.
- `--home` accepts any directory that is not `/` and not on the system deny
  list. It is the escape hatch for homes that are not in `/etc/passwd`, and it
  is also the sharpest edge in the script.
- **Not safe against an actively hostile target user.** Linux has no `lchmod`,
  so between the scan and the apply the user could replace a regular file with
  a symlink and redirect one `chmod` outside the home. Run this when the target
  user has no processes running. Ownership changes are not affected — those use
  `chown -h` throughout.
- The snapshot records ownership and permission bits for the files and
  directories being changed. It does not record file contents, ACLs beyond the
  base entries, extended attributes, symlinks, or the other inode types
  (sockets, fifos, devices) — so `setfacl --restore` will not undo the
  `chown -h` applied to those. Symlinks are excluded deliberately: `getfacl`
  reports a link's target, so including them would let a restore write outside
  the home.
- Without `getfacl` on the host the snapshot is skipped with a warning and the
  run proceeds anyway, so a host lacking the `acl` package is the one case where
  `--yes` applies changes with nothing recorded. Install `acl` before scheduling
  this, or pass `--no-backup` so that choice is at least explicit.
