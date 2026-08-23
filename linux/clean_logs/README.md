# Clean System Logs

`clean_logs.sh` frees disk space by deleting **rotated log archives** older than
a cutoff, and by vacuuming the systemd journal with `journalctl`. It prints
every path it would remove, and how much space that releases, before touching
anything.

It changes nothing unless you pass `--yes`.

## Requirements

Linux with GNU findutils and GNU coreutils (`find -printf`, `du -sb`,
`timeout`, `mktemp`). A missing one of those is exit 3. `journalctl` is used
when present and skipped when it is not.

`--yes` additionally requires root (exit 4 otherwise) and `flock` from
util-linux (exit 3 otherwise) — a concurrency guard that silently degrades to
no guard is not a guard. A report needs neither: any user can produce one, over
the parts of the tree they can read.

## Running it

```bash
./clean_logs.sh                          # report on /var/log, change nothing
./clean_logs.sh --days 30                # report, 30-day cutoff
sudo ./clean_logs.sh --yes               # actually delete
sudo ./clean_logs.sh --yes --days 7 --path /var/log --path /srv/app/logs
```

There is no prompt in either direction. The default is a report, so a run
without `--yes` is always safe, and a run with `--yes` never blocks waiting for
a terminal that cron does not have.

### From the network

Fetch, verify, then run — pin to a **commit SHA** and check the hash first.

```bash
REV=<40-char-commit-sha>
SUM=<sha256-of-that-file>
URL=https://raw.githubusercontent.com/Lazarev-Cloud/Scripts/$REV/linux/clean_logs/clean_logs.sh

curl -fsSL --proto '=https' --tlsv1.2 -o /tmp/clean_logs.sh "$URL" \
  && echo "$SUM  /tmp/clean_logs.sh" | sha256sum -c - \
  && sudo bash /tmp/clean_logs.sh --yes
```

A branch name is not a pin — it means "whatever was pushed most recently",
executed as root. Environment variables are the easiest way to configure a
piped run, since they avoid the `$0` argument problem entirely:

```bash
LZC_CLEAN_LOGS_YES=1 LZC_CLEAN_LOGS_DAYS=30 bash -c "$s"
```

## What it deletes

A file is deleted only when **all** of these hold:

1. it is under one of the `--path` roots (default `/var/log`);
2. it is a regular file, reached without following a symlink;
3. its name matches one of the rotated-archive patterns;
4. its mtime is older than `--days` × 24h;
5. it does not match any `--exclude` glob;
6. it is not inside a `journal` directory.

Default patterns:

```
*.gz  *.bz2  *.xz  *.zst  *.lz4  *.old
*.[0-9]  *.[0-9][0-9]
*-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]
```

The digit classes are bounded to one and two digits **on purpose**. A greedy
`*.[0-9]*` would also match `/var/log/mysql/mysql-bin.000001`; deleting MySQL
binary logs silently breaks replication and point-in-time recovery.

Override the list with `--pattern` (repeatable) or `LZC_CLEAN_LOGS_PATTERNS`,
but add *specific* patterns rather than generalising these. Both forms
**replace** the built-in list rather than adding to it, which is the safe
direction: narrowing a sweep to `--pattern '*.gz'` must mean only `*.gz`, not
`*.gz` plus eight patterns you did not ask for. Patterns are matched against
the file name only, never the directory part — use `--exclude` for paths.

## Blast radius

- Deletes matching rotated archives under the roots you name. Nothing outside
  them is touched: the walk uses `find -P`, so a symlink is never followed out
  of a root, and a symlink is never itself a candidate.
- Roots that are too broad are refused outright: `/`, `/bin`, `/boot`, `/dev`,
  `/etc`, `/home`, `/lib*`, `/media`, `/mnt`, `/opt`, `/proc`, `/root`, `/run`,
  `/sbin`, `/srv`, `/sys`, `/usr`, `/var`. These are exact matches — `/var/log`
  and `/home/me/logs` are fine.
- Directories named `journal` are pruned. journald's store is a live indexed
  database; removing a `.journal` file with `rm` corrupts it. It is handled
  with `journalctl --vacuum-*` and nothing else.
- `--truncate-active` additionally empties live log files. This destroys data.
  It is off by default.
- Concurrent `--yes` runs are refused via `flock` on
  `/run/lock/lzc-clean_logs.lock` (exit 75). A run without `--yes` mutates
  nothing and takes no lock, so a report never has to wait for a cron sweep.

## Options

| Flag | Environment variable | Meaning |
| --- | --- | --- |
| `-y, --yes` | `LZC_CLEAN_LOGS_YES` | Actually delete. Without it, this is a report. |
| `-n, --dry-run` | — | Report only (the default). Wins over `--yes`. |
| `-p, --path DIR` | `LZC_CLEAN_LOGS_PATHS` | Root to clean; repeatable. Env form is `:`-separated. Default `/var/log`. |
| `-d, --days N` | `LZC_CLEAN_LOGS_DAYS` | Cutoff in 24h units (14). `0` means "older than 24 hours". |
| `-x, --exclude GLOB` | `LZC_CLEAN_LOGS_EXCLUDE` | Skip matching paths; repeatable. |
| `--pattern GLOB` | `LZC_CLEAN_LOGS_PATTERNS` | Filename glob marking a rotated archive; repeatable. **Replaces** the built-in list. Env form is whitespace-separated. |
| `--active-pattern GLOB` | `LZC_CLEAN_LOGS_ACTIVE_PATTERNS` | Same, for the live-log list `--truncate-active` works from (`*.log syslog messages`). |
| `--no-journal` | `LZC_CLEAN_LOGS_JOURNAL=0` | Leave the systemd journal alone. |
| `--journal-size SIZE` | `LZC_CLEAN_LOGS_JOURNAL_KEEP_SIZE` | Journal size to keep (`200M`). |
| `--journal-time TIME` | `LZC_CLEAN_LOGS_JOURNAL_KEEP_TIME` | Journal age to keep. Defaults to `--days` as `Nd`, floored at `1d`. |
| `--truncate-active` | `LZC_CLEAN_LOGS_TRUNCATE` | Also empty live logs. Destroys their contents. |
| `--truncate-larger-than N` | `LZC_CLEAN_LOGS_TRUNCATE_MIN` | Byte threshold for the above (104857600). |
| `--list-limit N` | `LZC_CLEAN_LOGS_LIST_LIMIT` | Paths printed per section, `0` = all (50). |
| `--timeout SECONDS` | `LZC_CLEAN_LOGS_TIMEOUT` | Wall-clock limit for **each** `du` call that measures the journal and for the `journalctl` vacuum call (60). It does not bound the file scan or the run as a whole. Minimum 1 — `timeout 0` means *no* limit. |
| `--color WHEN` | — | `auto`, `always`, `never`. |
| — | `LZC_CLEAN_LOGS_LOCK` | Lock file (`/run/lock/lzc-clean_logs.lock`). |
| `-V, --version` | — | Print version and exit. |
| `-h, --help` | — | Print help and exit. |

Every variable a user can set is namespaced `LZC_CLEAN_LOGS_*`, so
`env | grep LZC_` shows the whole configurable surface of this script.

### Precedence

A flag beats the environment variable it shadows. For the three list-valued
options this means **replace, not merge**: passing any `--path` discards
`LZC_CLEAN_LOGS_PATHS` entirely, and the same holds for `--pattern` against
`LZC_CLEAN_LOGS_PATTERNS` and `--active-pattern` against
`LZC_CLEAN_LOGS_ACTIVE_PATTERNS`. So if a cron file sets
`LZC_CLEAN_LOGS_PATTERNS` and someone later adds `--pattern` to the command
line, the environment value is gone rather than combined — which is the safe
direction for a delete filter, but worth knowing before you edit that crontab.

`--exclude` is the one exception and deliberately **adds** to
`LZC_CLEAN_LOGS_EXCLUDE`: exclusions only ever remove files from the sweep, so
accumulating them can never widen the blast radius.

### Value formats

**Booleans** (`LZC_CLEAN_LOGS_YES`, `_JOURNAL`, `_TRUNCATE`) accept
`1`/`true`/`yes`/`on` and `0`/`false`/`no`/`off`, in any case. Anything else is
rejected with exit 2 rather than reaching an arithmetic context, where a bare
word under `set -u` would abort the run with `true: unbound variable` — which is
what you would otherwise get for writing the obvious thing in a cron file.

**Numbers** (`_DAYS`, `_TRUNCATE_MIN`, `_LIST_LIMIT`, `_TIMEOUT`) must be whole
numbers and are read as base ten, so a zero-padded `08` is 8 and not an invalid
octal literal. `_TIMEOUT` has a minimum of 1; the rest allow 0, which is
meaningful for `--days` and `--list-limit`.

### Colour

Colour is written only when stdout is a terminal, and never when `NO_COLOR` is
set to any non-empty value ([no-color.org](https://no-color.org)). `--color
always` overrides both; `--color never` disables it unconditionally.

## The systemd journal

`journalctl --vacuum-size=` and `--vacuum-time=` are the only correct way to
shrink the journal, and they are what this script uses.

Vacuuming removes **archived** journal files only. The active file is never
removed, so the space reclaimed is normally less than the journal's total size.
If the journal is much larger than you want permanently, set a cap in
`/etc/systemd/journald.conf` (`SystemMaxUse=`) so it never grows back — this
script trims, it does not configure.

The vacuum time defaults to `--days` expressed as `Nd`, **floored at `1d`**.
`--days 0` means "files older than 24 hours", and `0d` is not the journal
equivalent of that: depending on the systemd release a zero retention reads
either as "no time limit at all" or as "discard every archived file", and those
are opposite outcomes. An explicit `--journal-time` is never rewritten.

## Exit status

The table is the same across every script in this repository.

| Code | Meaning |
| --- | --- |
| 0 | Report produced, or every requested change succeeded. |
| 1 | The sweep ran, but at least one delete, truncate or vacuum failed. |
| 2 | Usage error: unknown flag, missing or invalid argument value, or a refused scan root. |
| 3 | Missing prerequisite: `find`, `du`, `timeout` or `mktemp` absent, a `find` without `-printf`, or `flock` absent on a `--yes` run. |
| 4 | `--yes` was given but the script is not running as root. |
| 5 | Not used here. This script never prompts, so there is no confirmation to refuse — a run without `--yes` is already a report. |
| 75 | Another run holds the lock. `EX_TEMPFAIL`, so cron and systemd read it as "retry later" rather than a fault. |
| 130 | Interrupted (SIGINT/SIGTERM). |

The split matters for alerting: "I could not delete a file", "you pointed me at
`/etc`" and "the weekly sweep is still running" are three different problems,
and only the last one should resolve itself.

## Scheduling

```
# /etc/cron.d/clean-logs — Sunday 04:00
0 4 * * 0 root /usr/local/sbin/clean_logs.sh --yes --days 30
```

Better still, use logrotate for routine rotation and schedule this only as a
backstop. logrotate compresses, keeps a bounded number of generations, and
signals the writing daemon; this script only removes what rotation left behind.

## Notes and limits

- **Reported space is "will be released", not "df will drop by this".** A file
  that a running process still holds open frees nothing until that process
  closes it. `lsof +L1` finds those. Sizes are the on-disk allocation
  (`st_blocks` × 512), not the apparent size.
- **`--truncate-active` is opt-in for a reason.** Truncating a file whose writer
  opened it with `O_APPEND` works as expected. A writer *without* `O_APPEND`
  keeps writing at its old offset, producing a sparse file that immediately
  reports the old size again — with everything in between lost. The real fix
  for a log that grows without bound is logrotate plus a service reload, not
  truncation.
- Deleting a rotated archive does not signal any daemon; nothing needs it to.
- The script does not compress anything, does not edit logrotate configuration,
  and does not touch package-manager caches.
- Running as a non-root user produces a partial report and says so.
- **The scan does not stop at filesystem boundaries.** A separate mount or a
  bind mount underneath a root is walked like any other directory. That is
  deliberate — `/var/log/audit` being its own filesystem is common and should
  still be swept — but it means a bind mount of unrelated data under `/var/log`
  is in scope. Check the dry-run listing, or exclude it with `--exclude`.
- Patterns match the **file name**, not the path. `--pattern '*/nginx/*.gz'`
  matches nothing; use `--path` or `--exclude` to select by directory.
