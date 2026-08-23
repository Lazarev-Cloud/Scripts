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
- never touches `/`, a system directory, or anything *inside* one, whatever
  `/etc/passwd` claims — and refuses the directories that merely hold homes
  (`/home`, `/srv`, `/var`), so a missing or mistyped user name cannot widen the
  target from one home to all of them. See [Which directories it
  refuses](#which-directories-it-refuses)
- never crosses a filesystem boundary unless asked
- never runs two applying instances at once: `--apply` takes an exclusive
  `flock` and exits 75 if another run holds it

## Requirements

GNU `find` (the `-printf` extension), `timeout`, and `xargs`. `flock`
(util-linux) as well, for `--apply` — a dry run takes no lock and does not need
it.

`getfacl`/`setfacl` from the `acl` package are **required for `--apply`**,
because they are what records the undo point. An applying run on a host without
them stops at exit 3 before it scans or prompts, rather than making thousands of
irreversible changes with nothing recorded. Pass `--no-backup` if you want that
trade anyway — it just has to be asked for. A dry run never needs `acl`.

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
| `--no-backup` | `LZC_FIX_PERMISSIONS_BACKUP=0` | Skip the `getfacl` snapshot and accept an irreversible run. Without it, a host with no `getfacl` refuses to apply (exit 3). |
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
| 3 | A required tool is missing: GNU `find`, `timeout`, `xargs`, `flock`, or `getfacl` when a snapshot was not waived with `--no-backup`. |
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

Code 2 covers an unknown user or group and a refused home directory, whether
that came from `--home` or from `/etc/passwd` — see [Which directories it
refuses](#which-directories-it-refuses). The fix is the invocation: pass a
different `--user`, or point `--home` somewhere real.

The `/etc/passwd` half of that matters more than it looks, because several stock
system accounts have a system directory as their home. `--user daemon`
(`/usr/sbin`), `--user backup` (`/var/backups`), `--user sys` (`/dev`) and
`--user nobody` (`/nonexistent`) all exit 2 without a `--home` flag anywhere in
the command. That is deliberate: those accounts have no home to repair, and a
mistyped user name must not turn into a recursive `chown` of the operating
system. `--user www-data` still works, because `/var/www` is a real home.

Code 4 is only reached when the run would change ownership. `--no-chown --apply`
works as an ordinary user on files that user already owns.

## Which directories it refuses

The target is checked *after* being resolved with `readlink -f`, so
`--home /home/x/../..` and a symlinked home are judged on where they actually
land, not on how they were spelled. Two lists, because "is the operating system"
and "contains home directories" need opposite rules.

**Refused, and so is everything beneath them** — these hold the OS, so nothing
inside one is a home:

```
/bin  /boot  /dev  /etc  /lib  /lib32  /lib64  /libx32  /proc  /sbin  /sys  /usr
/var/backups  /var/cache  /var/log  /var/spool  /var/tmp
```

**Refused themselves, but their children are fine** — each of these legitimately
holds home directories one level down:

```
/home  /media  /mnt  /opt  /run  /srv  /tmp  /var
/var/lib  /var/local  /var/mail  /var/opt
/nonexistent  /var/empty
```

So `--home /home` is refused while `--home /home/alice` works;
`--home /var/lib` is refused while `--home /var/lib/postgresql` works. `/var`
stays in the second list rather than the first so that `www-data`'s `/var/www`
keeps working, and `/var/lib` is in it because service accounts really do live
under it.

`/` is refused on its own. `/root` is deliberately on neither list: it is root's
real home, and refusing it would make the script useless for the account most
likely to need it.

On a usrmerge system `/bin`, `/sbin` and `/lib` resolve to `/usr/...` before the
check, so they are caught by the `/usr` entry.

This is an enumeration, not a proof. The self-only rules necessarily admit some
small runtime and spool directories that a few daemon accounts use as a home —
`/run/ircd` for `irc`, `/var/list` for `list`. Tightening those would start
eroding the legitimate service-home case that `/var/lib/postgresql` and
`/var/www` depend on, so the list stops where it does. Read the dry run.

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

Install the `acl` package before scheduling this. Without `getfacl` the run
stops at exit 3 instead of applying anything, which is the safe outcome but is
still a broken cron job — and cron reports it by mailing the error, so you will
hear about it on the first run rather than after a silent irreversible one.

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
- `--home` accepts any directory the deny list above does not refuse. It is the
  escape hatch for homes that are not in `/etc/passwd`, and it is also the
  sharpest edge in the script: the deny list stops it aiming at the operating
  system, but it cannot tell a real home from any other directory you own. Read
  the dry run before adding `--apply`.
- **Hardened against, but not proof against, an actively hostile target user.**
  Linux has no `lchmod`, and `chmod` follows a symlink named on its command
  line, so a user who can write in their own home can in principle swap a
  listed regular file for a link to `/etc/shadow` and have root `chmod` the
  target instead. Each `chmod` batch is therefore re-checked immediately before
  it is applied, and the check covers **every path component below the home**,
  not just the last one — swapping an ancestor redirects a `chmod` exactly as
  well as swapping the file, so a leaf-only check would be no defence at all.
  That cuts the window from the length of the report and the confirmation
  prompt — potentially minutes — down to the interval between the check and
  `chmod`'s own path resolution. Closing that last gap needs
  `openat(O_NOFOLLOW)` and `fchmod`, which a shell script cannot call, so for a
  genuinely hostile user the rule stands: run this when they have no processes
  running. Anything dropped by the re-check is reported, not skipped quietly.
  Ownership changes were never affected — those use `chown -h` throughout.

  The `getfacl` snapshot is taken before this re-check and does follow symlinks,
  so a path swapped during that step records the target's ownership and mode
  under the in-home name. The snapshot is a superset of what is actually
  changed, so it never misses an undo; but a `setfacl --restore` run against a
  home that was being tampered with is not trustworthy on its own.
- The snapshot records ownership and permission bits for the files and
  directories being changed. It does not record file contents, ACLs beyond the
  base entries, extended attributes, symlinks, or the other inode types
  (sockets, fifos, devices) — so `setfacl --restore` will not undo the
  `chown -h` applied to those. Symlinks are excluded deliberately: `getfacl`
  reports a link's target, so including them would let a restore write outside
  the home.
- Awkward file names are not a gap. `getfacl` escapes them rather than writing
  them raw -- a newline becomes `\012` and a literal backslash becomes `\\` --
  and `setfacl --restore` decodes both, so a name containing a newline, tab,
  quote or leading dash round trips through the undo unchanged.
- The snapshot is a full structural listing of the home, so it is written under
  `umask 0077` and ends up mode `0600` in `--backup-dir`. Set `--backup-dir` to
  somewhere only root can read if the default does not already satisfy that.
