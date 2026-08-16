# Debian/Ubuntu Package Repair

`fix_broken_packages.sh` recovers a Debian or Ubuntu system whose dpkg
transaction was interrupted, or whose package dependencies no longer resolve —
the state that produces `dpkg was interrupted, you must manually run 'dpkg
--configure -a'`, `E: Unmet dependencies`, or a package stuck half-configured.

It diagnoses first, prints what the repair would do, runs the sequence in the
order dpkg and apt actually require, and then **verifies** the result by
re-inspecting the system rather than trusting the repair's exit status.

## Requirements

Debian, Ubuntu, or a derivative. Needs `apt-get`, `dpkg`, `dpkg-query`,
`timeout`, `awk`, `find` and `flock`. `apt-mark` and `fuser` (from `psmisc`)
are optional and only improve the report; where one is missing the value it
would have supplied is reported as `unknown` rather than guessed.

On anything that is not APT-based the script names the equivalent repair tool
for that system and exits `3` without touching anything. A required tool that
is missing exits `3` as well — from the caller's side both mean "this host
cannot run me". That check runs before the root check, so you get the right
diagnosis even without `sudo`.

Root is required for a real run. `--dry-run` works as an ordinary user.

## The repair sequence

| Step | Command | Why in this position |
| --- | --- | --- |
| 1 | `dpkg --force-confdef --force-confold --configure -a` | APT refuses to do almost anything while dpkg is mid-transaction, so dpkg has to be finished first. This also replays `/var/lib/dpkg/updates`. |
| 2 | `apt-get update` | Step 3 usually needs to download something; stale indexes make it fail for the wrong reason. Skip with `--no-update`. |
| 3 | `apt-get --fix-broken install` | Resolves unsatisfied dependencies. |
| 4 | `dpkg --configure -a` | Configures whatever step 3 unpacked. |

Steps 3 and 4 repeat up to `--passes` times (default 2), stopping the moment
the system verifies clean.

The force flags in step 1 are passed to `dpkg` directly, not through apt's
`-o Dpkg::Options::=`, because that option only reaches dpkg when apt is the
one invoking it. Without them a maintainer script's conffile prompt hangs the
repair — the exact failure being repaired.

## What "verified" means

Three independent checks, all re-run from scratch after every pass:

- `apt-get check` — the authoritative verdict on broken dependencies.
- `/var/lib/dpkg/updates/` — dpkg's journal of an in-flight transaction. Any
  file left there means dpkg was interrupted and `dpkg --configure -a` still
  has work to replay.
- The dpkg status of every installed package, via
  `dpkg-query -W -f='${binary:Package}\t${Status}\n'`. Anything whose error
  flag is not `ok`, or whose state is `half-installed`, `half-configured`,
  `unpacked`, `triggers-awaited` or `triggers-pending`, is still broken.
  Packages that are simply absent or left as config-files are not problems and
  are filtered out.

`dpkg --audit` output is shown as human-readable detail, but nothing branches
on it: it has no documented exit-status contract, so treating a zero exit as
"clean" would report success on a still-broken system.

**An inspection that cannot run is not a pass.** If `dpkg-query` itself fails —
entirely possible on the corrupt-database case this script exists for — an
empty result would otherwise be indistinguishable from a healthy system. Instead
the script warns, reports `Packages in a bad state : unknown (the check could
not run)`, and exits `1` with "could not be verified" rather than "repaired".

The same rule governs the journal check. `Interrupted transaction` has three
answers, not two: if `/var/lib/dpkg/updates/` cannot be listed — or is missing
entirely, which on an intact installation it never is, since the `dpkg` package
ships it — the line reads `unknown (the check could not run)` and the system is
not called consistent. A directory nobody could read is not proof that no
transaction was interrupted. A journal file that *was* seen still reads `yes`
even if the scan then failed: positive evidence is conclusive.

Same for the optional `apt-mark` hold list: absent or failing renders as
`unknown`, never as `0`.

## Running it

### From a checkout

```bash
./fix_broken_packages.sh -n          # diagnose and show the plan; no root needed
sudo ./fix_broken_packages.sh        # asks before repairing
sudo ./fix_broken_packages.sh -y     # unattended
sudo ./fix_broken_packages.sh -y --no-update   # offline
```

If the system is already consistent, the script says so and stops. Use
`--force` to run the sequence anyway.

The exit status describes the system, not whether the run finished, so
`fix_broken_packages.sh -n` works as an unprivileged read-only health check:
`0` when the package database is consistent, `1` when it is not.

### From the network

Fetch, verify, then run. Pin to a **commit SHA** and check the hash before
executing.

```bash
REV=<40-char-commit-sha>
SUM=<sha256-of-that-file>
URL=https://raw.githubusercontent.com/Lazarev-Cloud/Scripts/$REV/linux/fix_broken_packages/fix_broken_packages.sh

curl -fsSL --proto '=https' --tlsv1.2 -o /tmp/fix_broken_packages.sh "$URL" \
  && echo "$SUM  /tmp/fix_broken_packages.sh" | sha256sum -c - \
  && sudo bash /tmp/fix_broken_packages.sh -y
```

Produce the two values from a checkout with:

```bash
git rev-parse HEAD
sha256sum linux/fix_broken_packages/fix_broken_packages.sh
```

A branch name is not a pin — it means "whatever was pushed most recently",
executed as root. A tag can be moved. A commit SHA cannot.

## Options

| Flag | Environment variable | Meaning |
| --- | --- | --- |
| `-y, --yes` | `LZC_FIX_BROKEN_PACKAGES_YES` | Unattended; no prompts. Required with no TTY. |
| `-n, --dry-run` | — | Diagnose and print the plan. Needs no root. |
| `--force` | `LZC_FIX_BROKEN_PACKAGES_FORCE` | Repair even when the system verifies clean. |
| `--passes N` | `LZC_FIX_BROKEN_PACKAGES_PASSES` | Repair passes (2). Minimum 1. |
| `--no-update` | `LZC_FIX_BROKEN_PACKAGES_SKIP_UPDATE` | Skip `apt-get update`. |
| `--conffile POLICY` | `LZC_FIX_BROKEN_PACKAGES_CONFFILE` | `old` (default) or `new`. |
| `--lock-timeout SEC` | `LZC_FIX_BROKEN_PACKAGES_DPKG_LOCK_TIMEOUT` | How long **apt** waits for the **dpkg** lock (600). Not this script's own lock, and not `timeout(1)` — see [It never deletes lock files](#it-never-deletes-lock-files). `0` means "fail at once". |
| `--timeout SEC` | `LZC_FIX_BROKEN_PACKAGES_FIX_TIMEOUT` | Wall-clock limit for one `apt-get --fix-broken install`, applied per repair pass (1800). Minimum 1. |
| `--log-file PATH` | `LZC_FIX_BROKEN_PACKAGES_LOG` | Log file (`/var/log/apt-repair.log`). |
| `--color WHEN` | — | `auto`, `always`, `never`. |
| `-V, --version` | — | Print version. |
| `-h, --help` | — | Print help. |

Also settable, with no matching flag — each is the wall-clock limit for the
step it names, and each has a minimum of 1 because `timeout 0` means *no*
limit: `LZC_FIX_BROKEN_PACKAGES_CONFIGURE_TIMEOUT` (1800, `dpkg --configure -a`),
`LZC_FIX_BROKEN_PACKAGES_UPDATE_TIMEOUT` (600, `apt-get update`),
`LZC_FIX_BROKEN_PACKAGES_PROBE_TIMEOUT` (120, each read-only inspection).

Two more shape how apt behaves unattended:

- `LZC_FIX_BROKEN_PACKAGES_ACQUIRE_RETRIES` (3) becomes `-o Acquire::Retries`,
  so a transient mirror or DNS blip does not abandon a repair that is already
  half done. `0` disables retrying. Unlike the timeouts, `0` is legal here.
- `LZC_FIX_BROKEN_PACKAGES_LISTCHANGES_FRONTEND` (`none`) becomes
  `APT_LISTCHANGES_FRONTEND`. `apt-listchanges` runs as an APT
  `Pre-Install-Pkgs` hook, outside everything `DEBIAN_FRONTEND` governs, and
  with `confirm=true` in its own configuration it asks a question on stdin —
  which would hang the very repair you are running. `none` is its documented
  off switch.

And the rest: `LZC_FIX_BROKEN_PACKAGES_LOG_MAX_BYTES` (5242880),
`LZC_FIX_BROKEN_PACKAGES_LOCK` (`/run/lock/lzc-fix_broken_packages.lock`),
`LZC_FIX_BROKEN_PACKAGES_DPKG_ADMINDIR` (`/var/lib/dpkg`),
`LZC_FIX_BROKEN_PACKAGES_LOCK_PATHS`, `LZC_FIX_BROKEN_PACKAGES_PATH`,
`LZC_FIX_BROKEN_PACKAGES_LOCALE` (`C`).

Every variable a user can set is named `LZC_FIX_BROKEN_PACKAGES_*`, the
repository-wide convention, so `env | grep LZC_` shows everything you have
configured for this script and for every other script here.

### Values

Booleans — `YES`, `FORCE`, `SKIP_UPDATE` — accept `1`/`true`/`yes`/`on` and
`0`/`false`/`no`/`off`, in any case. Anything else is rejected with exit `2`
before the run starts, rather than crashing partway through it.

Numbers must be whole. A leading zero is read as decimal, so `08` is eight, not
an invalid octal literal.

### Colour

`--color auto` (the default) emits colour only when stdout is a terminal;
`always` and `never` force the choice. `NO_COLOR` is honoured: any non-empty
value disables colour, overriding `--color always`.

## Blast radius

**`apt-get --fix-broken install` can remove packages.** That is how it resolves
a dependency it cannot otherwise satisfy, and on a badly broken system the set
it removes can be large. The simulated plan is printed before anything runs,
and with a terminal you are asked to confirm it. Run `-n` first.

One caveat, and it applies to exactly the case this script exists for: while
dpkg is mid-transaction, apt refuses install-type operations — simulations
included — and answers `E: dpkg was interrupted, you must manually run 'dpkg
--configure -a'`. There is then no plan to show, the script says so, and
confirming means accepting step 1 without a removal list. Simulating after
step 1 instead would mean running every half-configured package's maintainer
scripts before you had agreed to anything, which is the worse trade.

`dpkg --configure -a` executes the maintainer scripts of every half-configured
package. Those scripts can restart services.

`--conffile new` overwrites your edited configuration files. The default,
`old`, keeps them. The policy is applied to `ucf`-managed files as well, via
`UCF_FORCE_CONFFOLD` / `UCF_FORCE_CONFFNEW` — dpkg's `--force-conf*` options do
not reach those.

The script does **not** upgrade the system — a repair that quietly upgrades
everything is no longer a repair. Use `../update_upgrade/` for that. It does
not reboot, and it never modifies anything outside the package system.

## It never deletes lock files

If a live process holds `/var/lib/dpkg/lock-frontend`, `/var/lib/dpkg/lock`,
`/var/cache/apt/archives/lock` or `/var/lib/apt/lists/lock`, this script names
the holder (via `fuser`, when `psmisc` is installed) and exits `75`.

Deleting those files is the advice you will find everywhere and it is how
package databases actually get corrupted: the lock is what stops a second dpkg
from starting alongside the first, and two concurrent dpkg runs are what leave
`/var/lib/dpkg/status` inconsistent. The holder is almost always
`unattended-upgrades` or `apt-daily`, and it finishes on its own:

```bash
systemctl list-units --all 'apt-daily*' 'unattended-upgrades*'
```

Once nothing holds the lock, run the repair. The script's own apt calls also
pass `-o DPkg::Lock::Timeout=600`, so they wait rather than fail if the lock is
taken while they run.

Never delete `/var/lib/dpkg/status`, `/var/lib/dpkg/info/*`,
`/var/lib/dpkg/updates/*` or `/var/lib/dpkg/triggers/*`. Those are the package
database itself; `dpkg --configure -a` is what replays the journal safely. A
backup of the status file lives in `/var/backups/dpkg.status.*`.

## Exit status

The repository-wide table. These are the only statuses this script returns.

| Code | Meaning |
| --- | --- |
| 0 | Success — the system verifies consistent, whether it already was or was repaired. |
| 1 | The work ran but the system is not confirmed consistent: still inconsistent after the repair, the state could not be verified, the repair was declined at the prompt, or it was only simulated with `-n`. Details and next steps printed. |
| 2 | Usage error — unknown flag, missing or invalid argument value. |
| 3 | Unsupported platform or a missing prerequisite tool: not an APT-based system, or a required binary is absent. Nothing was changed. |
| 4 | Must be run as root. |
| 5 | Refused: confirmation was needed, but there is no TTY and `--yes` was not given. |
| 75 | Temporary failure — an apt/dpkg lock is held by another process, or another copy of this script is running. `EX_TEMPFAIL`, so cron and systemd read it as "retry later" rather than a real fault. |
| 130 | Interrupted (SIGINT/SIGTERM). |

## When it exits 1

The script prints the packages that are still broken and an ordered list of
what to try. In short:

1. Read the errors. A failing maintainer script names its package — reproduce
   it alone with `dpkg --configure <package>`.
2. `apt-get -o Debug::pkgProblemResolver=true --fix-broken install` explains
   apt's dependency reasoning.
3. `apt-mark showhold` — a hold can make a dependency unsolvable.
4. `/var/log/dpkg.log` and `/var/log/apt/term.log` hold the transaction detail.

There is deliberately no `--force-overwrite`, `--force-depends` or equivalent.
A file conflict between two packages needs a decision from you; a flag that
makes it go away just moves the damage somewhere less visible.

## Notes and limits

- Concurrent runs are refused via `flock` on
  `/run/lock/lzc-fix_broken_packages.lock`, exit `75`. That lock only guards
  against a second copy of this script; the dpkg lock is a separate mechanism,
  handled as described above. The lock file is never deleted — the kernel
  releases it when the file descriptor closes, including on `kill -9`.
- Output is teed to `/var/log/apt-repair.log`, which rotates itself once past
  5 MB. If the log is not writable the run continues without one.
- SIGHUP is ignored, and because an ignored disposition survives `execve()`,
  dpkg inherits it. A dropped SSH session will not kill dpkg mid-repair.
- Ctrl-C is handled between steps, not during one. Interrupting dpkg
  mid-transaction is how systems get into this state in the first place.
- This repairs the package database. It cannot recover a full disk, a corrupt
  filesystem, or a package removed from its repository — those show up as
  errors in the output and need fixing first.
