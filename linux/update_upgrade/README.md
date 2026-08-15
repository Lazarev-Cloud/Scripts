# Debian/Ubuntu System Updater

`update_upgrade.sh` refreshes the APT indexes, upgrades installed packages
without ever asking a question, and then reports the part a script cannot do
for you: a pending reboot, configuration files that were kept back, packages
held at a fixed version.

It is built to run from cron or a systemd timer with no terminal attached, and
works the same by hand.

## Requirements

Debian, Ubuntu, or a derivative (Devuan, Raspberry Pi OS, Mint, Pop!\_OS,
elementary, Kali, Zorin). Needs `apt-get`, `timeout`, `flock`, `find` and `sed`.
`apt-mark` and `needrestart` are optional and only improve the report.

On anything that is not APT-based the script names the package manager that
system actually uses and exits `3` without touching anything. A required tool
that is missing exits `3` as well — from the caller's side both mean "this host
cannot run me". That check runs before the root check, so you get the right
diagnosis even without `sudo`.

Root is required for a real run. `--dry-run` works as an ordinary user.

## Running it

### From a checkout

```bash
./update_upgrade.sh -n                    # show the plan, change nothing
sudo ./update_upgrade.sh                  # interactive, asks before applying
sudo ./update_upgrade.sh -y               # unattended
sudo ./update_upgrade.sh -y --autoremove --autoclean
```

### From the network

Fetch, verify, then run. Two things matter: pin to a **commit SHA**, and check
the hash before executing.

```bash
REV=<40-char-commit-sha>
SUM=<sha256-of-that-file>
URL=https://raw.githubusercontent.com/Lazarev-Cloud/Scripts/$REV/linux/update_upgrade/update_upgrade.sh

curl -fsSL --proto '=https' --tlsv1.2 -o /tmp/update_upgrade.sh "$URL" \
  && echo "$SUM  /tmp/update_upgrade.sh" | sha256sum -c - \
  && sudo bash /tmp/update_upgrade.sh -y
```

Produce the two values from a checkout with:

```bash
git rev-parse HEAD
sha256sum linux/update_upgrade/update_upgrade.sh
```

A branch name such as `refs/heads/main` is not a pin — it means "whatever was
pushed most recently", executed as root. A tag is not a pin either, because a
tag can be moved. A commit SHA is content-addressed and cannot be changed.

Piping straight in works too, but note that `bash -c "$script" arg` assigns the
first argument to `$0`, so flags need a `--` placeholder. Environment variables
avoid the problem entirely:

```bash
LZC_UPDATE_UPGRADE_YES=1 LZC_UPDATE_UPGRADE_CLEAN=autoclean bash -c "$s"
```

## Options

| Flag | Environment variable | Meaning |
| --- | --- | --- |
| `-y, --yes` | `LZC_UPDATE_UPGRADE_YES` | Unattended; no prompts. Required with no TTY. |
| `-n, --dry-run` | — | Print the plan. Changes nothing, needs no root. |
| `--mode MODE` | `LZC_UPDATE_UPGRADE_MODE` | `upgrade` (default) or `dist-upgrade`. |
| `--with-new-pkgs` | `LZC_UPDATE_UPGRADE_WITH_NEW_PKGS` | Let `upgrade` pull in new dependencies. |
| `--conffile POLICY` | `LZC_UPDATE_UPGRADE_CONFFILE` | `old` (default) or `new`. |
| `--restart-services` | `LZC_UPDATE_UPGRADE_NEEDRESTART_MODE=a` | Let needrestart restart services. |
| `--autoremove` | `LZC_UPDATE_UPGRADE_AUTOREMOVE` | Remove packages nothing depends on. |
| `--autoremove-purge` | `LZC_UPDATE_UPGRADE_AUTOREMOVE_PURGE` | As above, and delete their config. Implies `--autoremove`. |
| `--autoclean` | `LZC_UPDATE_UPGRADE_CLEAN=autoclean` | Delete unfetchable cached `.deb`s. |
| `--clean` | `LZC_UPDATE_UPGRADE_CLEAN=clean` | Delete the whole `.deb` cache. |
| `--lock-timeout SEC` | `LZC_UPDATE_UPGRADE_DPKG_LOCK_TIMEOUT` | How long **apt** waits for the **dpkg** lock (600). Not this script's own lock, and not `timeout(1)` — see [Concurrency](#concurrency). `0` means "fail at once". |
| `--timeout SEC` | `LZC_UPDATE_UPGRADE_UPGRADE_TIMEOUT` | Wall-clock limit for the upgrade step itself — the single `apt-get upgrade`/`dist-upgrade` invocation (3600). Minimum 1. |
| `--log-file PATH` | `LZC_UPDATE_UPGRADE_LOG` | Log file (`/var/log/apt-upgrade.log`). |
| `--color WHEN` | — | `auto`, `always`, `never`. |
| `-V, --version` | — | Print version. |
| `-h, --help` | — | Print help. |

Also settable, with no matching flag — each is the wall-clock limit for the
step it names, and each has a minimum of 1 because `timeout 0` means *no*
limit: `LZC_UPDATE_UPGRADE_UPDATE_TIMEOUT` (600, `apt-get update`),
`LZC_UPDATE_UPGRADE_CLEANUP_TIMEOUT` (600, autoremove and clean),
`LZC_UPDATE_UPGRADE_PROBE_TIMEOUT` (120, each read-only inspection).

And the rest: `LZC_UPDATE_UPGRADE_LOG_MAX_BYTES` (5242880),
`LZC_UPDATE_UPGRADE_LOCK` (`/run/lock/lzc-update_upgrade.lock`),
`LZC_UPDATE_UPGRADE_ETC_DIR` (`/etc`), `LZC_UPDATE_UPGRADE_REBOOT_MARKERS`,
`LZC_UPDATE_UPGRADE_REBOOT_PKGS`, `LZC_UPDATE_UPGRADE_PATH`,
`LZC_UPDATE_UPGRADE_LOCALE` (`C`).

Every variable a user can set is named `LZC_UPDATE_UPGRADE_*`, the
repository-wide convention, so `env | grep LZC_` shows everything you have
configured for this script and for every other script here.

### Values

Booleans — `YES`, `WITH_NEW_PKGS`, `AUTOREMOVE`, `AUTOREMOVE_PURGE` — accept
`1`/`true`/`yes`/`on` and `0`/`false`/`no`/`off`, in any case. Anything else is
rejected with exit `2` before the run starts, rather than crashing partway
through it. Setting `LZC_UPDATE_UPGRADE_AUTOREMOVE_PURGE` on its own implies
`AUTOREMOVE`, exactly as the flag does.

Numbers must be whole. A leading zero is read as decimal, so `08` is eight, not
an invalid octal literal.

### Colour

`--color auto` (the default) emits colour only when stdout is a terminal;
`always` and `never` force the choice. `NO_COLOR` is honoured: any non-empty
value disables colour, overriding `--color always`.

### `upgrade` versus `dist-upgrade`

`upgrade` never removes a package, which is why it is the default. It also
never installs a new one, so on Ubuntu a kernel upgrade that arrives as a new
`linux-image-*` package is held back — add `--with-new-pkgs` (what `apt upgrade`
does) or use `--mode dist-upgrade` if you want those.

`dist-upgrade` will remove packages when that is the only way to resolve new
dependencies. Deliberate choice, not a default.

## Blast radius

A default run upgrades installed packages. Nothing is removed, no cache is
deleted, no service is restarted, no file of yours under `/etc` is overwritten,
and the machine is never rebooted.

| Option | What it can destroy |
| --- | --- |
| `--mode dist-upgrade` | Removes packages to resolve dependencies. |
| `--autoremove` | Removes packages nothing depends on any more. |
| `--autoremove-purge` | The above, plus their configuration files. |
| `--conffile new` | Overwrites your edited files under `/etc`. |
| `--clean` | Deletes the cached `.deb`s. Recoverable; apt re-fetches. |
| `--restart-services` | Restarts running services. Brief interruptions. |

Run `-n` first for anything in that table. With `--autoremove` or
`--autoremove-purge` the removal list is simulated and printed alongside the
upgrade plan, before the confirmation prompt. Treat it as a lower bound: it is
computed *before* the upgrade, and the upgrade can orphan further packages,
which are then removed too.

## Conffiles

The default `--conffile old` passes `--force-confdef --force-confold` to dpkg:
take the maintainer's default where there is one, otherwise keep your edited
file, never prompt. That is what makes the run safe unattended — but it also
means new upstream configuration is silently skipped.

So the script scans `/etc` after every run and lists `*.dpkg-dist`,
`*.dpkg-new` and `*.ucf-dist`. Those are the files a package wanted to install
and dpkg kept back. Diff each against the live file and delete it once you have
reconciled it; otherwise they accumulate for years.

`--conffile new` does the opposite and discards your edits. Only use it where
configuration management re-applies state right afterwards.

Files managed by `ucf` rather than by dpkg directly are a separate mechanism
that dpkg's `--force-conf*` options do not reach, so the policy is applied to
them too, via `UCF_FORCE_CONFFOLD` / `UCF_FORCE_CONFFNEW`.

## Reboot reporting

The script never reboots. It reports that one is needed and lets you schedule
it.

Detection is `/run/reboot-required` or `/var/run/reboot-required`, which Ubuntu
writes via `update-notifier-common`; the packages responsible are listed from
`/run/reboot-required.pkgs`. Plain Debian does not ship that by default, so if
`needrestart` is installed the script asks it instead (`needrestart -b -r l`,
which is list-only and restarts nothing) and treats a kernel state of 2 or 3 as
"reboot pending".

If neither is present, reboot detection is simply unavailable. Install
`update-notifier-common` or `needrestart` to get it.

A pending reboot exits `0`. It is not a failure, and there is no exit code
outside the table below to signal it with. A wrapper that needs to act on it
should test `/run/reboot-required` itself — that is the actual source of truth,
and unlike an exit status it survives the run:

```bash
update_upgrade.sh --yes --autoclean || exit $?
[ -e /run/reboot-required ] && echo "reboot pending on $(hostname)"
```

## Exit status

The repository-wide table. These are the only statuses this script returns.

| Code | Meaning |
| --- | --- |
| 0 | Success — everything asked for succeeded. A pending reboot is included here. |
| 1 | The work ran but something in it failed. Details on stderr and in the log. |
| 2 | Usage error — unknown flag, missing or invalid argument value. |
| 3 | Unsupported platform or a missing prerequisite tool: not an APT-based system, or a required binary is absent. Nothing was changed. |
| 4 | Must be run as root. |
| 5 | Refused: confirmation was needed, but there is no TTY and `--yes` was not given. |
| 75 | Temporary failure — another copy of this script holds the lock. `EX_TEMPFAIL`, so cron and systemd read it as "retry later" rather than a real fault. |
| 130 | Interrupted (SIGINT/SIGTERM). |

A failing `apt-get update` is deliberately *not* fatal — one broken third-party
repository should not cancel the whole patch run. The script warns, upgrades
against the indexes already on disk, and still exits `1` so monitoring sees it.

A pending reboot exits `0`, because a nightly job that returns non-zero every
night until someone reboots trains people to ignore it. See
[Reboot reporting](#reboot-reporting) for how to act on it instead.

## Scheduling

### systemd timer (preferred)

```ini
# /etc/systemd/system/apt-upgrade.service
[Unit]
Description=Nightly APT upgrade
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/update_upgrade.sh --yes --autoclean
TimeoutStartSec=2h
SuccessExitStatus=0 75
```

```ini
# /etc/systemd/system/apt-upgrade.timer
[Unit]
Description=Nightly APT upgrade

[Timer]
OnCalendar=*-*-* 03:20:00
Persistent=true
RandomizedDelaySec=30m
FixedRandomDelay=true

[Install]
WantedBy=timers.target
```

`SuccessExitStatus=0 75` declares "another instance already holds the lock" as
a non-failure, so `OnFailure=` only fires for a real problem.

### cron

Quiet on success, loud on failure — with `moreutils` installed this is one
word:

```
# /etc/cron.d/apt-upgrade
20 3 * * * root chronic /usr/local/sbin/update_upgrade.sh --yes --autoclean
```

Without `moreutils`, capture the output and print it only when the run fails,
so cron mails you nothing on a good night:

```bash
#!/bin/sh
# /usr/local/sbin/apt-upgrade-cron
out=$(mktemp) || exit 1
trap 'rm -f "$out"' EXIT
if ! /usr/local/sbin/update_upgrade.sh --yes --autoclean --color never >"$out" 2>&1; then
  rc=$?
  echo "update_upgrade.sh failed rc=$rc" >&2
  cat "$out" >&2
  exit "$rc"
fi
```

Cron mails any output at all, so a chatty successful job trains people to
ignore cron mail.

## Concurrency

Two different locks are involved, and they solve different problems.

- `flock` on `/run/lock/lzc-update_upgrade.lock` stops a *second copy of this
  script* from running, exit `75`. That is all it does. The lock file is never
  deleted — the kernel releases it when the file descriptor closes, including
  on `kill -9`.
- `-o DPkg::Lock::Timeout=600` is what survives `apt-daily.timer` and
  `unattended-upgrades` holding the *dpkg* lock. Instead of failing with "Could
  not get lock", apt waits up to ten minutes. Raise it with `--lock-timeout` on
  busy machines.

If you let this script own patching, turn `unattended-upgrades` off rather than
running both: `APT::Periodic::Unattended-Upgrade "0";` in
`/etc/apt/apt.conf.d/20auto-upgrades`.

## Notes and limits

- Held packages are listed but never released. `apt-mark unhold <package>` is
  a decision for you, not for a script.
- `apt-get update` fails by design when a repository changes its release suite
  (for example `stable` becoming `oldstable`). The script points at
  `apt-get update --allow-releaseinfo-change` rather than accepting the change
  silently, because accepting it can pull in a different distribution release.
- `needrestart` is set to list-only unless you pass `--restart-services`, so an
  unattended run does not bounce your services at 03:20.
- Output is teed to `/var/log/apt-upgrade.log`, which rotates itself once past
  5 MB. If the log is not writable the run continues without one.
- SIGHUP is ignored, and because an ignored disposition survives `execve()`,
  dpkg inherits it. A dropped SSH session will not kill dpkg mid-transaction.
- If a run is killed anyway, `../fix_broken_packages/` repairs the result.
- The script does not touch snapshots or backups. Take one first if you want a
  way back.
