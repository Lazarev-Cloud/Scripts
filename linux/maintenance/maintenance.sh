#!/usr/bin/env bash
#
# Linux system maintenance runner.
#
# Runs named maintenance tasks -- health reporting, package updates, cache/log/
# tmp cleanup and package-state repair -- on Debian/Ubuntu, RHEL, Arch, SUSE and Alpine
# hosts. Nothing runs unless you name it, every task that changes the system is
# previewable with --dry-run, and unattended runs need --yes.
#
# License: MIT
# Origin:  https://github.com/Lazarev-Cloud/Scripts
#
# Error model: this script deliberately does NOT use `set -e`. It is a batch
# runner -- when one task fails the remaining tasks must still run and the
# failure must be reported at the end. Every fallible command is therefore
# checked explicitly and routed into FAILED_TASKS[]. Do not add `set -e`, and do
# not invoke this script as `maintenance.sh || true`: both make the error
# handling non-local and hide exactly the failures this script exists to report.
set -uo pipefail

readonly SCRIPT_NAME='Linux Maintenance Runner'
readonly SCRIPT_VERSION='2.1'
readonly PROG='maintenance.sh'

# Exit codes, shared by every script in this repository. 75 is EX_TEMPFAIL from
# sysexits.h, which cron and systemd read as "retry later" rather than a fault.
readonly EX_FAIL=1 EX_USAGE=2 EX_PREREQ=3 EX_NOROOT=4
readonly EX_NOCONFIRM=5 EX_LOCKED=75 EX_INTERRUPT=130

# cron gives a script an almost empty environment and sources no profile, so the
# search path is set here rather than in the crontab -- the script stays
# self-contained and a missing PATH cannot turn into exit 127 halfway through.
PATH="${LZC_MAINTENANCE_PATH:-/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin}"
export PATH

# --- Tunables (env overridable, then flag overridable) -----------------------
LOG_FILE="${LZC_MAINTENANCE_LOG:-/var/log/maintenance.log}"
LOG_MAX_BYTES="${LZC_MAINTENANCE_LOG_MAX_BYTES:-5242880}"
LOCK_FILE="${LZC_MAINTENANCE_LOCK:-/run/lock/lzc-maintenance.lock}"
TASK_TIMEOUT="${LZC_MAINTENANCE_TIMEOUT:-3600}"
PROBE_TIMEOUT="${LZC_MAINTENANCE_PROBE_TIMEOUT:-30}"
PKG_LOCK_WAIT="${LZC_MAINTENANCE_PKG_LOCK_WAIT:-600}"
UPGRADE_MODE="${LZC_MAINTENANCE_UPGRADE_MODE:-upgrade}"
NEEDRESTART_CHOICE="${LZC_MAINTENANCE_NEEDRESTART_MODE:-l}"
DISK_WARN="${LZC_MAINTENANCE_DISK_WARN:-85}"
INODE_WARN="${LZC_MAINTENANCE_INODE_WARN:-85}"
FS_EXCLUDE="${LZC_MAINTENANCE_FS_EXCLUDE:-tmpfs devtmpfs squashfs overlay efivarfs}"
ETC_DIR="${LZC_MAINTENANCE_ETC_DIR:-/etc}"
LOG_DIR="${LZC_MAINTENANCE_LOG_DIR:-/var/log}"
LOG_AGE_DAYS="${LZC_MAINTENANCE_LOG_AGE_DAYS:-30}"
LOG_EXCLUDE="${LZC_MAINTENANCE_LOG_EXCLUDE:-audit wtmp btmp lastlog}"
JOURNAL_SIZE="${LZC_MAINTENANCE_JOURNAL_SIZE:-500M}"
JOURNAL_AGE="${LZC_MAINTENANCE_JOURNAL_AGE:-30d}"
TMP_DIRS="${LZC_MAINTENANCE_TMP_DIRS:-/tmp /var/tmp}"
TMP_AGE_DAYS="${LZC_MAINTENANCE_TMP_AGE_DAYS:-10}"
TMP_MODE="${LZC_MAINTENANCE_TMP_MODE:-auto}"
TMP_EXCLUDE="${LZC_MAINTENANCE_TMP_EXCLUDE:-.X11-unix .XIM-unix .ICE-unix .font-unix .Test-unix systemd-private snap-private-tmp}"
ASSUME_YES="${LZC_MAINTENANCE_YES:-0}"
DRY_RUN="${LZC_MAINTENANCE_DRY_RUN:-0}"
QUIET="${LZC_MAINTENANCE_QUIET:-0}"
USE_COLOR="${LZC_MAINTENANCE_COLOR:-auto}"

# --- Runtime state -----------------------------------------------------------
declare -a TASKS=()
declare -a FAILED_TASKS=()
declare -a OK_TASKS=()
declare -a SKIPPED_TASKS=()
FAMILY=''
PKG_TOOL=''
REBOOT_REQUIRED=0
HAVE_TIMEOUT=0
LOG_READY=0
LOG_SINK=/dev/null
LOCK_HELD=0
SUMMARY_DONE=0
TASK_SKIPPED=0
YW='' BL='' RD='' GN='' CL=''

# --- Output ------------------------------------------------------------------

setup_color() {
    # NO_COLOR is honoured per no-color.org: any non-empty value disables colour.
    # --color always still wins, because an explicit flag is a deliberate answer
    # to the question the environment variable answers by default.
    if [[ $USE_COLOR == never ]] ||
        { [[ $USE_COLOR == auto ]] && { [[ -n ${NO_COLOR:-} ]] || [[ ! -t 1 ]]; }; }; then
        return
    fi
    YW=$'\033[33m' BL=$'\033[36m' RD=$'\033[01;31m' GN=$'\033[1;92m' CL=$'\033[m'
}

# Normal output goes to stdout, warnings and errors to stderr, so `maintenance.sh
# report > report.txt` keeps the diagnostics visible on the terminal.
log() {
    local level=$1
    shift
    local msg=$*

    if ((LOG_READY)); then
        printf '[%s] [%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$level" "$msg" >>"$LOG_FILE"
    fi

    case $level in
        ERROR) printf '%s[Error]%s %s\n' "$RD" "$CL" "$msg" >&2 ;;
        WARN) printf '%s[Warning]%s %s\n' "$YW" "$CL" "$msg" >&2 ;;
        INFO) ((QUIET)) || printf '%s[Info]%s %s\n' "$BL" "$CL" "$msg" ;;
        RUN) ((QUIET)) || printf '%s[Run]%s %s\n' "$BL" "$CL" "$msg" ;;
        DRY) ((QUIET)) || printf '%s[Dry-run]%s %s\n' "$YW" "$CL" "$msg" ;;
        OK) ((QUIET)) || printf '%s[OK]%s %s\n' "$GN" "$CL" "$msg" ;;
        *) ((QUIET)) || printf '%s\n' "$msg" ;;
    esac
}

die() {
    local code=$1
    shift
    log ERROR "$*"
    exit "$code"
}

say() {
    ((QUIET)) && return 0
    printf '%s\n' "$*"
}

section() {
    ((QUIET)) && return 0
    printf '\n%s== %s ==%s\n' "$GN" "$*" "$CL"
}

usage() {
    cat <<EOF
$SCRIPT_NAME v$SCRIPT_VERSION

Runs named system maintenance tasks on Debian/Ubuntu, RHEL-family, Arch
(including Manjaro), SUSE and Alpine hosts.

Usage:
  $PROG [options] [task ...]

With no task, '$PROG report' is assumed: a read-only summary that
changes nothing.

Tasks:
  report          Read-only health summary: OS, uptime, load, memory, swap,
                  filesystems and inodes above the warning threshold, /boot
                  usage, installed vs running kernel, pending updates, pending
                  reboot, failed systemd units, package-manager lock holders,
                  leftover .dpkg-dist/.rpmnew config drift, journal size.
                  Blast radius: none. Safe under any user; fuller as root.

  update          Refresh the package index and upgrade installed packages.
                  Blast radius: installs new package versions and restarts
                  whatever the packaging scripts restart. Defaults to
                  'upgrade', which never removes a package; --upgrade-mode
                  dist-upgrade allows removals.

  autoremove      Remove packages no longer required by anything installed.
                  Blast radius: PURGES packages, including old kernels and
                  their config files. Review a --dry-run first.

  clean-cache     Delete downloaded package archives.
                  Blast radius: cache only; everything is re-downloadable.

  clean-logs      Vacuum the systemd journal to --journal-size/--journal-age and
                  delete already-rotated files under --log-dir older than
                  --log-age days.
                  Blast radius: DELETES log history permanently. Live *.log
                  files are never touched, and --log-exclude (default:
                  $LOG_EXCLUDE) is skipped.

  clean-tmp       Clean temporary files. Two different behaviours, and they do
                  not have the same blast radius -- the plan printed before the
                  run names the one that will apply on this host:
                    tmpfiles mode (the default wherever systemd is running):
                      defers to 'systemd-tmpfiles --clean', which follows the
                      distribution's own tmpfiles.d policy.
                      Blast radius: DELETES aged files EVERYWHERE that policy
                      covers, which is more than --tmp-dirs; --tmp-dirs and
                      --tmp-age do not apply. 'systemd-tmpfiles --cat-config'
                      lists the rules that will be used.
                      --dry-run runs 'systemd-tmpfiles --clean --dry-run' to
                      show the real file list where systemd is new enough
                      (249+); on an older one it says so and previews nothing
                      rather than guessing. A preview is a query, so it reports
                      a non-zero status as a warning and never fails the run.
                    age mode (no systemd, or --tmp-mode age):
                      regular files whose atime and mtime are both older than
                      --tmp-age days are deleted and empty directories pruned.
                      Blast radius: DELETES files in $TMP_DIRS. Sockets,
                      symlinks and --tmp-exclude entries are left alone.

  fix-packages    Repair an interrupted package installation:
                  'dpkg --configure -a' then 'apt-get -f install'.
                  Blast radius: completes half-finished package operations,
                  which may install or configure packages. Debian/Ubuntu only.

  fix-locks       Diagnose package-manager locks. Reports which process holds
                  them and never kills it. dpkg/apt lock files are flock(2)
                  targets and cannot go stale, so they are never deleted. A
                  dnf pid file whose process is gone is removed with --yes.
                  Blast radius: read-only on Debian/Ubuntu; on RHEL may delete
                  a provably dead dnf pid file.

  routine         Group: update, autoremove, clean-cache, report.

Options:
  -n, --dry-run             Print what each task would do; change nothing.
  -y, --yes                 Run unattended; skip the confirmation. Required by
                            cron and systemd timers for any task that mutates.
  -q, --quiet               Suppress progress output; print only warnings,
                            errors and a summary when something failed. Command
                            output still goes to the log file.
      --list-tasks          Print the task names, one per line, and exit.
      --upgrade-mode MODE   upgrade | dist-upgrade (default: $UPGRADE_MODE).
      --timeout SECONDS     Bounds each system-changing command individually:
                            one package transaction, one journal vacuum, one
                            systemd-tmpfiles run. Not a budget for the whole
                            run (default: $TASK_TIMEOUT, minimum 1).
      --probe-timeout SEC   Bounds each read-only probe individually: df,
                            dpkg-query, rpm, systemctl, journalctl
                            --disk-usage, fuser/lsof and the simulated
                            upgrade the report counts (default: $PROBE_TIMEOUT,
                            minimum 1).
      --pkg-lock-wait SEC   How long apt waits for the dpkg lock to be released
                            before giving up (DPkg::Lock::Timeout). Not a
                            timeout(1) bound; 0 means do not wait at all
                            (default: $PKG_LOCK_WAIT).
      --disk-warn PCT       Filesystem usage to report (default: $DISK_WARN).
      --inode-warn PCT      Inode usage to report (default: $INODE_WARN).
      --log-dir PATH        Directory cleaned by clean-logs (default: $LOG_DIR).
      --log-age DAYS        Age of rotated logs to delete (default: $LOG_AGE_DAYS).
      --log-exclude LIST    Space-separated names clean-logs must not touch.
      --journal-size SIZE   journalctl --vacuum-size (default: $JOURNAL_SIZE).
      --journal-age TIME    journalctl --vacuum-time (default: $JOURNAL_AGE).
      --tmp-dirs LIST       Space-separated dirs for clean-tmp.
                            Default: $TMP_DIRS.
      --tmp-age DAYS        Age threshold for clean-tmp (default: $TMP_AGE_DAYS).
      --tmp-mode MODE       auto | tmpfiles | age (default: $TMP_MODE).
      --tmp-exclude LIST    Space-separated names clean-tmp must not touch.
      --needrestart-mode M  l | i | a. What to do about services still running
                            old libraries after an update: l lists them, a
                            RESTARTS them, i asks (default: $NEEDRESTART_CHOICE).
      --log-file PATH       This script's own log.
                            Default: $LOG_FILE.
      --lock-file PATH      Concurrency lock.
                            Default: $LOCK_FILE.
      --color WHEN          auto | always | never (default: $USE_COLOR).
  -V, --version             Print version and exit.
  -h, --help                Print this help and exit.

Every option has an environment variable, which is easier when piping this
script in from the network. Every one is named LZC_MAINTENANCE_*, so
'env | grep LZC_' shows a user everything that is configurable:
  LZC_MAINTENANCE_YES=1  LZC_MAINTENANCE_DRY_RUN=1  LZC_MAINTENANCE_QUIET=1
  LZC_MAINTENANCE_COLOR=never  LZC_MAINTENANCE_UPGRADE_MODE=upgrade
  LZC_MAINTENANCE_TIMEOUT=3600  LZC_MAINTENANCE_PROBE_TIMEOUT=30
  LZC_MAINTENANCE_PKG_LOCK_WAIT=600  LZC_MAINTENANCE_NEEDRESTART_MODE=l
  LZC_MAINTENANCE_DISK_WARN=85  LZC_MAINTENANCE_INODE_WARN=85
  LZC_MAINTENANCE_FS_EXCLUDE='tmpfs devtmpfs'
  LZC_MAINTENANCE_LOG_DIR=/var/log  LZC_MAINTENANCE_LOG_AGE_DAYS=30
  LZC_MAINTENANCE_LOG_EXCLUDE=audit  LZC_MAINTENANCE_JOURNAL_SIZE=500M
  LZC_MAINTENANCE_JOURNAL_AGE=30d  LZC_MAINTENANCE_TMP_DIRS='/tmp /var/tmp'
  LZC_MAINTENANCE_TMP_AGE_DAYS=10  LZC_MAINTENANCE_TMP_MODE=auto
  LZC_MAINTENANCE_TMP_EXCLUDE='.X11-unix systemd-private'
  LZC_MAINTENANCE_LOG=/var/log/maintenance.log
  LZC_MAINTENANCE_LOCK=/run/lock/lzc-maintenance.lock
  LZC_MAINTENANCE_LOG_MAX_BYTES=5242880  LZC_MAINTENANCE_ETC_DIR=/etc
  LZC_MAINTENANCE_PATH=/usr/sbin:/usr/bin:/sbin:/bin

The boolean variables (YES, DRY_RUN, QUIET) accept 1/true/yes/on and
0/false/no/off in any case. Anything else is a usage error rather than a
silently wrong default.

--log-dir and every --tmp-dirs entry is a sweep root: files under it are
deleted, as root. Each must therefore be an absolute path with no '.' or '..'
component, and must not be '/' or a top-level system directory such as /usr or
/var. Name the directory inside one that you meant instead.

Exit status:
  0    success: every task that applied to this host succeeded
  1    the work ran but something in it failed
  2    usage error: unknown flag, unknown task, missing or invalid value
  3    unsupported platform or a missing prerequisite tool
  4    must be run as root
  5    refused: confirmation needed, but no TTY and --yes was not given
  75   temporary failure: another instance holds the lock (EX_TEMPFAIL, so
       cron and systemd treat it as "retry later" rather than a real fault).
       The lock is $LOCK_FILE
  130  interrupted (SIGINT/SIGTERM)

A pending reboot is a warning in the summary, not an exit code. A task that
does not apply to this host is reported as skipped and does not fail the run.

Tell a scheduler that a held lock is not a fault:
  systemd:  SuccessExitStatus=0 75
  cron:     wrap in a quiet-on-success runner.

Examples:
  $PROG                                # health report, changes nothing
  $PROG --dry-run clean-logs clean-tmp # exactly what would be deleted
  sudo $PROG --yes routine             # unattended nightly run
  sudo $PROG --yes --upgrade-mode dist-upgrade update
EOF
}

# --- Task table ---------------------------------------------------------------

readonly -a ALL_TASKS=(report update autoremove clean-cache clean-logs
    clean-tmp fix-packages fix-locks routine)

task_is_known() {
    case $1 in
        report | update | autoremove | clean-cache | clean-logs | clean-tmp | fix-packages | fix-locks | routine) return 0 ;;
        *) return 1 ;;
    esac
}

# True when the task can change the system. Drives the confirmation gate and
# whether the run needs the concurrency lock at all -- a read-only report must
# not be blocked by a long-running update.
#
# fix-locks is excluded: on Debian/Ubuntu it only ever reports, and diagnosing a
# stuck apt is precisely when you do not want to be told to pass --yes first.
# The one destructive branch it has (a dead dnf pid file) asks for itself.
task_mutates() {
    case $1 in
        report | fix-locks) return 1 ;;
        *) return 0 ;;
    esac
}

# True when the task needs root to do its job correctly. fix-locks needs it even
# though it only reads: an unprivileged fuser cannot see file handles held by
# other users, so it would report "nothing holds the lock" while root's dpkg
# holds it.
task_needs_root() {
    case $1 in
        report) return 1 ;;
        *) return 0 ;;
    esac
}

task_blast_radius() {
    case $1 in
        report) printf '%s' 'reads only; changes nothing' ;;
        # Both of these read differently on Arch, and the difference is exactly
        # the kind a blast-radius line exists to convey. pacman has no
        # upgrade/dist-upgrade split, so naming UPGRADE_MODE there would report
        # a setting that has no effect; and it keeps one version per kernel
        # package, so "old kernels included" would be describing a risk the
        # host does not have while omitting the one it does -- orphan removal.
        update)
            if [[ $FAMILY == arch ]]; then
                printf '%s' 'installs new package versions (full -Syu; pacman has no partial mode)'
            else
                printf '%s' "installs new package versions ($UPGRADE_MODE)"
            fi
            ;;
        autoremove)
            if [[ $FAMILY == arch ]]; then
                printf '%s' 'PURGES orphans: packages installed as dependencies that nothing now requires'
            else
                printf '%s' 'PURGES packages no longer required, old kernels included'
            fi
            ;;
        clean-cache) printf '%s' 'deletes downloaded package archives (re-downloadable)' ;;
        clean-logs) printf '%s' "DELETES rotated logs in $LOG_DIR older than ${LOG_AGE_DAYS}d and vacuums the journal" ;;
        # TMP_MODE is resolved from 'auto' in preflight(), before the plan is
        # printed, so this reports the behaviour that will actually apply. The
        # two modes have genuinely different blast radii and saying "$TMP_DIRS"
        # for both understates the one that runs by default on a systemd host.
        clean-tmp)
            if [[ $TMP_MODE == tmpfiles ]]; then
                printf '%s' "DELETES aged files everywhere the distribution tmpfiles.d policy covers, which is more than $TMP_DIRS (systemd-tmpfiles --clean)"
            else
                printf '%s' "DELETES files in $TMP_DIRS untouched for more than ${TMP_AGE_DAYS}d"
            fi
            ;;
        fix-packages) printf '%s' 'completes interrupted dpkg/apt operations' ;;
        fix-locks) printf '%s' 'reports lock holders; may delete a dead dnf pid file' ;;
        *) printf '%s' 'unknown' ;;
    esac
}

expand_task() {
    case $1 in
        routine) printf '%s\n' update autoremove clean-cache report ;;
        *) printf '%s\n' "$1" ;;
    esac
}

# --- Argument parsing --------------------------------------------------------

need_value() {
    ((${1} >= 2)) || die "$EX_USAGE" "$2 requires a value"
}

# Maps an internal setting name to the flag and environment variable a user
# actually types, so a validation error points at something they can change.
setting_label() {
    case $1 in
        TASK_TIMEOUT) printf '%s' '--timeout / LZC_MAINTENANCE_TIMEOUT' ;;
        PROBE_TIMEOUT) printf '%s' '--probe-timeout / LZC_MAINTENANCE_PROBE_TIMEOUT' ;;
        PKG_LOCK_WAIT) printf '%s' '--pkg-lock-wait / LZC_MAINTENANCE_PKG_LOCK_WAIT' ;;
        DISK_WARN) printf '%s' '--disk-warn / LZC_MAINTENANCE_DISK_WARN' ;;
        INODE_WARN) printf '%s' '--inode-warn / LZC_MAINTENANCE_INODE_WARN' ;;
        LOG_AGE_DAYS) printf '%s' '--log-age / LZC_MAINTENANCE_LOG_AGE_DAYS' ;;
        TMP_AGE_DAYS) printf '%s' '--tmp-age / LZC_MAINTENANCE_TMP_AGE_DAYS' ;;
        LOG_MAX_BYTES) printf '%s' 'LZC_MAINTENANCE_LOG_MAX_BYTES' ;;
        LOG_DIR) printf '%s' '--log-dir / LZC_MAINTENANCE_LOG_DIR' ;;
        TMP_DIRS) printf '%s' '--tmp-dirs / LZC_MAINTENANCE_TMP_DIRS' ;;
        NEEDRESTART_CHOICE) printf '%s' '--needrestart-mode / LZC_MAINTENANCE_NEEDRESTART_MODE' ;;
        ETC_DIR) printf '%s' 'LZC_MAINTENANCE_ETC_DIR' ;;
        LOG_FILE) printf '%s' '--log-file / LZC_MAINTENANCE_LOG' ;;
        LOCK_FILE) printf '%s' '--lock-file / LZC_MAINTENANCE_LOCK' ;;
        ASSUME_YES) printf '%s' '--yes / LZC_MAINTENANCE_YES' ;;
        DRY_RUN) printf '%s' '--dry-run / LZC_MAINTENANCE_DRY_RUN' ;;
        QUIET) printf '%s' '--quiet / LZC_MAINTENANCE_QUIET' ;;
        *) printf '%s' "$1" ;;
    esac
}

# Accepts the spellings people actually write in cron files and unit files.
# Without this, LZC_MAINTENANCE_YES=true reaches (( )) as a bare word and the
# script dies with "true: unbound variable" under `set -u` -- a real crash a
# user hits by writing the obvious thing. Normalise to 1/0 before any
# arithmetic context reads the value.
_normalise_bool() {
    local name=$1 value
    case ${!name,,} in
        1 | true | yes | on) value=1 ;;
        0 | false | no | off | '') value=0 ;;
        *) die "$EX_USAGE" "$(setting_label "$name") must be one of 1/true/yes/on or 0/false/no/off, got '${!name}'" ;;
    esac
    printf -v "$name" '%s' "$value"
}

# Validates, range-checks and normalises a numeric setting.
#
# The 18-digit bound is what makes the 10# normalisation safe: bash arithmetic
# is signed 64-bit and wraps without complaint, so a 20-digit argument can
# normalise to a negative number and disable a timeout silently
# (12345678901234567890 -> -6101065172474983726). 18 digits cannot overflow.
_normalise_int() {
    local name=$1 min=$2 max=${3:-} value
    [[ ${!name} =~ ^[0-9]{1,18}$ ]] ||
        die "$EX_USAGE" "$(setting_label "$name") must be a non-negative integer of at most 18 digits, got '${!name}'"
    # 10# forces base ten: a zero-padded value such as 08 is otherwise read as
    # an invalid octal literal, and every later ((...)) on it raises "value too
    # great for base" and evaluates false -- silently dropping the very limit
    # the option was setting.
    value=$((10#${!name}))
    ((value >= min)) || die "$EX_USAGE" "$(setting_label "$name") must be at least $min, got '${!name}'"
    [[ -z $max ]] || ((value <= max)) ||
        die "$EX_USAGE" "$(setting_label "$name") must be at most $max, got '${!name}'"
    printf -v "$name" '%s' "$value"
}

# clean-logs and clean-tmp delete files under a directory the caller names, as
# root. That makes a sweep root the one setting where a typo is unrecoverable:
# '--log-dir /' deletes every '*.gz' and '*.[0-9]' on the root device -- the
# whole man page tree included -- and '--tmp-dirs /' deletes every regular file
# on it that is older than the age threshold.
#
# The guard is stated as a principle rather than a blacklist of bad values: a
# sweep root must be absolute, must not contain traversal, and must never be a
# directory that IS the operating system.
assert_sweep_root() {
    local label=$1 dir=$2 trimmed
    [[ $dir == /* ]] || die "$EX_USAGE" "$label must be an absolute path, got '$dir' (a relative path is resolved against the working directory, which cron does not set)"
    [[ $dir != *//* ]] || die "$EX_USAGE" "$label must not contain '//', got '$dir'"
    trimmed=${dir%/}
    # '.' and '..' walk straight through every check below: '/tmp/../' is
    # absolute, is not literally a system directory, and still resolves to '/'
    # by the time find(1) sees it. Reject traversal outright rather than trying
    # to enumerate the paths it can reach.
    case $trimmed/ in
        */../* | */./*)
            die "$EX_USAGE" "$label must not contain '.' or '..' components, got '$dir'"
            ;;
    esac
    # '/tmp' is deliberately absent from the list below: it is the one top-level
    # directory whose contents are disposable by definition, and it is a default
    # sweep root. Every other name here is the operating system itself.
    case $trimmed in
        '')
            die "$EX_USAGE" "$label must not be '/': sweeping the root filesystem would delete the operating system"
            ;;
        /bin | /boot | /dev | /etc | /home | /lib | /lib32 | /lib64 | /libx32 | \
            /proc | /root | /run | /sbin | /srv | /sys | /usr | /var)
            die "$EX_USAGE" "$label must not be '$trimmed': that is a system directory, not a sweep root. Name the directory inside it that you meant."
            ;;
    esac
}

parse_args() {
    local positional_only=0 arg
    while (($#)); do
        if ((positional_only)); then
            TASKS+=("$1")
            shift
            continue
        fi
        case $1 in
            -n | --dry-run) DRY_RUN=1 ;;
            -y | --yes) ASSUME_YES=1 ;;
            -q | --quiet) QUIET=1 ;;
            --list-tasks)
                printf '%s\n' "${ALL_TASKS[@]}"
                exit 0
                ;;
            --upgrade-mode)
                need_value "$#" "$1"
                UPGRADE_MODE=$2
                shift
                ;;
            --timeout)
                need_value "$#" "$1"
                TASK_TIMEOUT=$2
                shift
                ;;
            --probe-timeout)
                need_value "$#" "$1"
                PROBE_TIMEOUT=$2
                shift
                ;;
            --pkg-lock-wait)
                need_value "$#" "$1"
                PKG_LOCK_WAIT=$2
                shift
                ;;
            --disk-warn)
                need_value "$#" "$1"
                DISK_WARN=$2
                shift
                ;;
            --inode-warn)
                need_value "$#" "$1"
                INODE_WARN=$2
                shift
                ;;
            --log-dir)
                need_value "$#" "$1"
                LOG_DIR=$2
                shift
                ;;
            --log-age)
                need_value "$#" "$1"
                LOG_AGE_DAYS=$2
                shift
                ;;
            --log-exclude)
                need_value "$#" "$1"
                LOG_EXCLUDE=$2
                shift
                ;;
            --journal-size)
                need_value "$#" "$1"
                JOURNAL_SIZE=$2
                shift
                ;;
            --journal-age)
                need_value "$#" "$1"
                JOURNAL_AGE=$2
                shift
                ;;
            --tmp-dirs)
                need_value "$#" "$1"
                TMP_DIRS=$2
                shift
                ;;
            --tmp-age)
                need_value "$#" "$1"
                TMP_AGE_DAYS=$2
                shift
                ;;
            --tmp-mode)
                need_value "$#" "$1"
                TMP_MODE=$2
                shift
                ;;
            --needrestart-mode)
                need_value "$#" "$1"
                NEEDRESTART_CHOICE=$2
                shift
                ;;
            --tmp-exclude)
                need_value "$#" "$1"
                TMP_EXCLUDE=$2
                shift
                ;;
            --log-file)
                need_value "$#" "$1"
                LOG_FILE=$2
                shift
                ;;
            --lock-file)
                need_value "$#" "$1"
                LOCK_FILE=$2
                shift
                ;;
            --color)
                need_value "$#" "$1"
                USE_COLOR=$2
                shift
                ;;
            -V | --version)
                printf '%s v%s\n' "$SCRIPT_NAME" "$SCRIPT_VERSION"
                exit 0
                ;;
            -h | --help)
                usage
                exit 0
                ;;
            --)
                positional_only=1
                ;;
            -*)
                die "$EX_USAGE" "Unknown option: $1 (try --help)"
                ;;
            *)
                TASKS+=("$1")
                ;;
        esac
        shift
    done

    [[ $USE_COLOR =~ ^(auto|always|never)$ ]] || die "$EX_USAGE" "--color must be auto, always or never, got '$USE_COLOR'"
    [[ $UPGRADE_MODE =~ ^(upgrade|dist-upgrade)$ ]] || die "$EX_USAGE" "--upgrade-mode must be upgrade or dist-upgrade, got '$UPGRADE_MODE'"
    [[ $TMP_MODE =~ ^(auto|tmpfiles|age)$ ]] || die "$EX_USAGE" "--tmp-mode must be auto, tmpfiles or age, got '$TMP_MODE'"
    # Validated like every other setting rather than passed through: this value
    # is exported into the environment of the package transaction, and 'a' means
    # "restart running services", which is the most disruptive thing this script
    # can be asked to do. An unrecognised value must be a usage error, not an
    # undefined behaviour that surfaces mid-upgrade.
    [[ $NEEDRESTART_CHOICE =~ ^[lia]$ ]] ||
        die "$EX_USAGE" "$(setting_label NEEDRESTART_CHOICE) must be l (list), i (interactive) or a (auto-restart), got '$NEEDRESTART_CHOICE'"
    [[ $JOURNAL_SIZE =~ ^[0-9]+[KMGT]?$ ]] || die "$EX_USAGE" "--journal-size must look like 500M, got '$JOURNAL_SIZE'"
    [[ $JOURNAL_AGE =~ ^[0-9]+(s|m|h|d|w|month|y)?$ ]] || die "$EX_USAGE" "--journal-age must look like 30d, got '$JOURNAL_AGE'"

    # Booleans first: every one of these is read in an arithmetic context later,
    # and a bare word reaching (( )) under `set -u` is fatal.
    local name
    for name in ASSUME_YES DRY_RUN QUIET; do
        _normalise_bool "$name"
    done

    # Minimum 1, not 0, for anything handed to timeout(1): `timeout 0` means NO
    # limit, so accepting 0 would silently remove the protection the option
    # exists to provide.
    for name in TASK_TIMEOUT PROBE_TIMEOUT; do
        _normalise_int "$name" 1
    done
    # PKG_LOCK_WAIT is apt's DPkg::Lock::Timeout, not a timeout(1) bound: 0 is
    # the meaningful "do not wait for the lock at all".
    _normalise_int PKG_LOCK_WAIT 0
    _normalise_int LOG_MAX_BYTES 1
    _normalise_int DISK_WARN 0 100
    _normalise_int INODE_WARN 0 100
    # 0 days is legitimate here: it means "everything already rotated", which is
    # what an operator reclaiming a full disk actually asks for.
    _normalise_int LOG_AGE_DAYS 0
    _normalise_int TMP_AGE_DAYS 0

    for name in ETC_DIR LOG_FILE LOCK_FILE; do
        [[ ${!name} == /* ]] ||
            die "$EX_USAGE" "$(setting_label "$name") must be an absolute path, got '${!name}'"
    done

    # Both sweep roots get the floor guard. LOG_DIR is a single path; TMP_DIRS
    # is a list, and every entry is swept, so every entry is checked.
    assert_sweep_root "$(setting_label LOG_DIR)" "$LOG_DIR"
    local -a tmp_toks=()
    read -r -a tmp_toks <<<"$TMP_DIRS"
    ((${#tmp_toks[@]})) ||
        die "$EX_USAGE" "$(setting_label TMP_DIRS) must name at least one directory"
    local dir
    for dir in "${tmp_toks[@]}"; do
        assert_sweep_root "$(setting_label TMP_DIRS)" "$dir"
    done

    ((${#TASKS[@]})) || TASKS=(report)

    local -a expanded=()
    for arg in "${TASKS[@]}"; do
        task_is_known "$arg" || die "$EX_USAGE" "Unknown task: $arg (try --list-tasks)"
        local sub
        while read -r sub; do
            in_array "$sub" expanded || expanded+=("$sub")
        done < <(expand_task "$arg")
    done
    TASKS=("${expanded[@]}")
}

in_array() {
    local needle=$1 item
    local -n _haystack=$2
    ((${#_haystack[@]})) || return 1
    for item in "${_haystack[@]}"; do
        [[ $item == "$needle" ]] && return 0
    done
    return 1
}

# --- Environment probing -----------------------------------------------------

have() { command -v "$1" >/dev/null 2>&1; }

# Read-only probes get a short leash: a wedged `dnf check-update` against a dead
# mirror is the classic reason a cron health check never returns.
probe() {
    if ((HAVE_TIMEOUT && PROBE_TIMEOUT > 0)); then
        timeout --foreground "$PROBE_TIMEOUT" "$@"
    else
        "$@"
    fi
}

is_root() { [[ ${EUID:-$(id -u)} -eq 0 ]]; }

# A prompt is only possible with a terminal to write the question to and one to
# read the answer from. /dev/tty is checked as well because under `curl | bash`
# stdin is the script itself, not the user.
can_prompt() {
    [[ -t 1 ]] || return 1
    [[ -t 0 ]] && return 0
    [[ -r /dev/tty ]]
}

detect_family() {
    if have apt-get; then
        FAMILY=debian
        PKG_TOOL=apt-get
        return 0
    fi
    if have dnf; then
        FAMILY=rhel
        PKG_TOOL=dnf
        return 0
    fi
    if have yum; then
        FAMILY=rhel
        PKG_TOOL=yum
        return 0
    fi
    if have pacman; then
        FAMILY=arch
        PKG_TOOL=pacman
        return 0
    fi
    if have zypper; then
        FAMILY=suse
        PKG_TOOL=zypper
        return 0
    fi
    if have apk; then
        FAMILY=alpine
        PKG_TOOL=apk
        return 0
    fi
    return 1
}

preflight() {
    # bash 4.4 is the floor: `mapfile -d ''` reads the NUL-delimited file lists
    # that make the cleanup tasks safe against newlines in filenames.
    if ((BASH_VERSINFO[0] < 4)) || { ((BASH_VERSINFO[0] == 4)) && ((BASH_VERSINFO[1] < 4)); }; then
        die "$EX_PREREQ" "bash 4.4 or newer required, found ${BASH_VERSION}"
    fi

    have timeout && HAVE_TIMEOUT=1
    ((HAVE_TIMEOUT)) || log WARN "timeout (coreutils) not found; long-running commands will not be bounded"

    detect_family || log WARN "No apt-get, dnf, yum, pacman, zypper or apk found; package tasks will be skipped"

    # Resolved here, before print_plan runs, so that the blast radius shown to
    # the operator and the code that does the deleting read the same value.
    # Deciding it inside the task instead would leave the plan guessing.
    if [[ $TMP_MODE == auto ]]; then
        if have systemd-tmpfiles && [[ -d /run/systemd/system ]]; then
            TMP_MODE=tmpfiles
        else
            TMP_MODE=age
        fi
    fi

    # Rotate before opening, so an unattended host does not grow the log without
    # bound between logrotate runs.
    if [[ -f $LOG_FILE ]]; then
        local size
        # 2>/dev/null must precede the input redirection: bash applies
        # redirections left to right and reports a failing one on stderr as it
        # stands at that moment, so a trailing 2>/dev/null suppresses nothing.
        size=$(wc -c 2>/dev/null <"$LOG_FILE") || size=0
        if ((size > LOG_MAX_BYTES)); then
            mv -f "$LOG_FILE" "$LOG_FILE.1" 2>/dev/null || true
        fi
    fi

    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
    # Again: 2>/dev/null first, or an unwritable log path prints a raw
    # "No such file or directory" from bash before the tidy warning below.
    if : 2>/dev/null >>"$LOG_FILE"; then
        chmod 0640 "$LOG_FILE" 2>/dev/null || true
        LOG_READY=1
        LOG_SINK=$LOG_FILE
    else
        printf '%s[Warning]%s Cannot write %s; continuing without a log file.\n' \
            "$YW" "$CL" "$LOG_FILE" >&2
    fi
}

# Only ever called for a run that will actually change the system, so a
# read-only report is never blocked by an update already in flight -- and never
# refused on a host that has no flock.
acquire_lock() {
    # A mutating run without the lock is exactly the concurrent apt/dpkg
    # collision this script exists to avoid, so a missing flock is a missing
    # prerequisite rather than something to warn about and carry on through.
    have flock || die "$EX_PREREQ" "flock (util-linux) not found; refusing to change the system without concurrency protection. Preview with --dry-run instead."
    mkdir -p "$(dirname "$LOCK_FILE")" 2>/dev/null || true
    exec 9>"$LOCK_FILE" || die "$EX_PREREQ" "Cannot open lock file $LOCK_FILE"
    # The lock file is never deleted. Two processes can each hold a lock on a
    # different inode at the same path if one unlinks it and the next recreates
    # it, which defeats the point.
    flock -n 9 || die "$EX_LOCKED" "Another $PROG run holds $LOCK_FILE. Refusing to run concurrently."
    LOCK_HELD=1
}

# --- Command execution -------------------------------------------------------

# Runs a system-changing command. Honours --dry-run, echoes the exact argv, tees
# output to the log, and bounds the runtime when a timeout is configured.
run_cmd() {
    local secs=$1
    shift
    if ((DRY_RUN)); then
        log DRY "would run: $*"
        return 0
    fi

    log RUN "$*"
    exec_cmd "$secs" "$@"
}

# The execution half of run_cmd, without the --dry-run gate. Called directly
# only for a command that is itself a preview and therefore has to run during a
# dry run -- 'systemd-tmpfiles --clean --dry-run' is the one case.
exec_cmd() {
    local secs=$1
    shift
    local rc
    if ((QUIET)); then
        if ((HAVE_TIMEOUT && secs > 0)); then
            timeout --foreground "$secs" "$@" >>"$LOG_SINK" 2>&1
        else
            "$@" >>"$LOG_SINK" 2>&1
        fi
        rc=$?
    else
        if ((HAVE_TIMEOUT && secs > 0)); then
            timeout --foreground "$secs" "$@" 2>&1 | tee -a "$LOG_SINK"
        else
            "$@" 2>&1 | tee -a "$LOG_SINK"
        fi
        rc=${PIPESTATUS[0]}
    fi

    if ((rc == 124)); then
        log ERROR "timed out after ${secs}s: $*"
    fi
    return "$rc"
}

# apt options used for every transaction:
#   --force-confdef/--force-confold  take the maintainer default where one
#     exists, otherwise keep the local file; never stop to ask.
#   DPkg::Lock::Timeout  wait for unattended-upgrades instead of racing it.
#     This is what replaces the hand-rolled "wait for the lock" loops.
#   Dpkg::Use-Pty=0  no progress redraws in the log.
apt_opts() {
    printf '%s\n' \
        -y \
        -o "Dpkg::Options::=--force-confdef" \
        -o "Dpkg::Options::=--force-confold" \
        -o "DPkg::Lock::Timeout=$PKG_LOCK_WAIT" \
        -o "Dpkg::Use-Pty=0"
}

export_pkg_env() {
    # Debian-family only. pacman and dnf ignore these, but exporting them into
    # every transaction on every distribution is how a variable ends up being
    # blamed for behaviour it had nothing to do with.
    [[ $FAMILY == debian ]] || return 0
    # DEBIAN_FRONTEND only silences debconf; the conffile prompts come from dpkg
    # and are handled by apt_opts above.
    export DEBIAN_FRONTEND=noninteractive
    export DEBIAN_PRIORITY=critical
    export UCF_FORCE_CONFOLD=1
    # 'l' lists services needing a restart instead of restarting them. Restarting
    # services is a decision for whoever scheduled the run, so it is opt-in via
    # LZC_MAINTENANCE_NEEDRESTART_MODE=a.
    export NEEDRESTART_MODE="$NEEDRESTART_CHOICE"
}

# Distinct from unsupported_family, which means "wrong distribution". This one
# means "right distribution, and this package manager has no safe equivalent" --
# a different fact for whoever reads the summary, and one that should not read
# as though the host were unrecognised.
no_equivalent() {
    local task=$1 why=$2
    log WARN "Task '$task' has no safe equivalent on $FAMILY: $why Skipping."
    SKIPPED_TASKS+=("$task (no equivalent on $FAMILY)")
    TASK_SKIPPED=1
    return 0
}

unsupported_family() {
    local task=$1 want=$2
    log WARN "Task '$task' is $want only; this host is ${FAMILY:-unknown}. Skipping."
    SKIPPED_TASKS+=("$task (not applicable to ${FAMILY:-unknown})")
    TASK_SKIPPED=1
    return 0
}

# --- Task: report -------------------------------------------------------------

report_identity() {
    section 'Host'
    local pretty=''
    if [[ -r /etc/os-release ]]; then
        # shellcheck source=/dev/null  # distro-provided file, not in this repo
        pretty=$(. /etc/os-release 2>/dev/null && printf '%s' "${PRETTY_NAME:-${NAME:-}}")
    fi
    printf '  Hostname      : %s\n' "$(hostname 2>/dev/null || printf 'unknown')"
    printf '  OS            : %s\n' "${pretty:-unknown}"
    printf '  Kernel        : %s\n' "$(uname -r 2>/dev/null || printf 'unknown')"
    printf '  Package family: %s\n' "${FAMILY:-unknown}"
    if have uptime; then
        printf '  Uptime/load   : %s\n' "$(uptime 2>/dev/null | sed 's/^ *//')"
    fi
}

report_memory() {
    have free || return 0
    section 'Memory and swap'
    probe free -h 2>/dev/null | sed 's/^/  /'
}

# Emits "percent<TAB>available<TAB>mountpoint" for every filesystem, for
# kind=disk or kind=inode.
#
# df's first column routinely contains spaces -- '//nas/my share', a bind mount,
# 'C:/Program Files/...' under Cygwin -- so counting fields from the left is
# wrong and silently reports the wrong number against the wrong mount point.
# `--output` (coreutils 8.21+) drops the device column entirely and is used when
# available; the fallback locates the NN% capacity field by scanning from the
# right and treats everything after it as the mount point, which also survives a
# mount point containing spaces.
df_rows() {
    local kind=$1
    local pcent=pcent avail=avail
    if [[ $kind == inode ]]; then
        pcent=ipcent avail=iavail
    fi

    local -a excl=() toks=()
    read -r -a toks <<<"$FS_EXCLUDE"
    local t
    for t in "${toks[@]}"; do
        excl+=(-x "$t")
    done

    if probe df -h --output="$pcent","$avail",target >/dev/null 2>&1; then
        probe df -h --output="$pcent","$avail",target ${excl[@]+"${excl[@]}"} 2>/dev/null |
            awk 'NR > 1 {
                p = $1; sub(/%/, "", p); a = $2
                m = ""
                for (i = 3; i <= NF; i++) m = (m == "" ? $i : m " " $i)
                printf "%s\t%s\t%s\n", p, a, m
            }'
        return 0
    fi

    local -a dfargs=(-P -h)
    [[ $kind == inode ]] && dfargs+=(-i)
    probe df "${dfargs[@]}" ${excl[@]+"${excl[@]}"} 2>/dev/null |
        awk 'NR > 1 {
            c = 0
            for (i = NF; i >= 1; i--) if ($i ~ /^[0-9]+%$/) { c = i; break }
            if (c == 0 || c < 2) next
            p = $c; sub(/%/, "", p); a = $(c - 1)
            m = ""
            for (i = c + 1; i <= NF; i++) m = (m == "" ? $i : m " " $i)
            printf "%s\t%s\t%s\n", p, a, m
        }'
}

report_filesystems() {
    have df || return 0
    local out

    section "Filesystems at or above ${DISK_WARN}% used"
    out=$(df_rows disk |
        awk -F'\t' -v w="$DISK_WARN" '$1 + 0 >= w { printf "  %-28s %3s%% used, %s free\n", $3, $1, $2 }')
    if [[ -n $out ]]; then
        printf '%s\n' "$out"
    else
        printf '  none\n'
    fi

    section "Inodes at or above ${INODE_WARN}% used"
    out=$(df_rows inode |
        awk -F'\t' -v w="$INODE_WARN" '$1 + 0 >= w { printf "  %-28s %3s%% used, %s free\n", $3, $1, $2 }')
    if [[ -n $out ]]; then
        printf '%s\n' "$out"
    else
        printf '  none\n'
    fi
}

# /boot filling up is the single most common way a Debian host stops being able
# to install a kernel update, so it is reported whether or not it is over the
# threshold, alongside what is installed and what is actually running.
report_kernels() {
    section 'Kernel and /boot'
    printf '  Running       : %s\n' "$(uname -r 2>/dev/null || printf 'unknown')"
    if have df && [[ -d /boot ]]; then
        printf '  /boot         : %s\n' "$(fs_usage_line /boot)"
    fi
    case $FAMILY in
        debian)
            have dpkg-query || return 0
            local installed
            # shellcheck disable=SC2016 # ${db:Status-Abbrev} and ${Package} are dpkg-query format placeholders; the shell must not expand them
            installed=$(probe dpkg-query -W -f='${db:Status-Abbrev} ${Package}\n' 'linux-image-*' 2>/dev/null |
                awk '$1 ~ /^ii/ && $2 ~ /^linux-image-[0-9]/ { print $2 }')
            if [[ -n $installed ]]; then
                printf '  Installed     : %s\n' "$(printf '%s\n' "$installed" | wc -l | tr -d ' ') image package(s)"
                printf '%s\n' "$installed" | sed 's/^/    /'
                printf '  Removal path  : maintenance.sh --yes autoremove\n'
            fi
            ;;
        rhel)
            have rpm || return 0
            local kernels
            kernels=$(probe rpm -q kernel 2>/dev/null)
            [[ -n $kernels ]] && printf '%s\n' "$kernels" | sed 's/^/    /'
            printf '  Removal path  : installonly_limit in /etc/dnf/dnf.conf\n'
            ;;
        arch)
            have pacman || return 0
            # Walked from /usr/lib/modules, not /boot/vmlinuz-*. On Manjaro the
            # image in /boot is generated at install time and pacman answers
            # "No package owns" for it, so the obvious query returns nothing at
            # all; the modules tree is owned by the kernel package itself.
            # Asking about the vmlinuz *inside* that tree rather than the
            # directory keeps the answer to the kernel package alone -- the
            # directory is also owned by the matching -headers package.
            #
            # Arch carries one version per kernel package instead of
            # accumulating them, so unlike Debian and RHEL there is no backlog
            # to prune: upgrading `linux` replaces the image in place. This is
            # inventory, not a cleanup prompt, which is why there is no removal
            # path to offer.
            local d ver owner mark running
            running=$(uname -r 2>/dev/null) || running=''
            for d in /usr/lib/modules/*/; do
                [[ -d $d ]] || continue
                ver=${d%/}
                ver=${ver##*/}
                owner=$(probe pacman -Qoq "${d}vmlinuz" 2>/dev/null | head -n1)
                [[ -n $owner ]] || owner=$(probe pacman -Qoq "$d" 2>/dev/null | head -n1)
                mark=''
                [[ $ver == "$running" ]] && mark=' -- running'
                printf '    %s (%s)%s\n' "${owner:-unknown}" "$ver" "$mark"
            done
            printf '  Removal path  : none needed; Arch keeps one version per kernel package\n'
            ;;
        suse)
            have rpm || return 0
            # Matched on exact flavour names rather than a `kernel-*` glob:
            # kernel-firmware, kernel-macros and friends all match that glob and
            # none of them is a kernel.
            local ks
            ks=$(probe rpm -qa --qf '%{NAME} %{VERSION}-%{RELEASE}\n' 2>/dev/null |
                awk '$1 ~ /^kernel-(default|preempt|rt|kvmsmall|azure)$/ { print $1 "-" $2 }' | sort -u)
            [[ -n $ks ]] && printf '%s\n' "$ks" | sed 's/^/    /'
            printf '  Removal path  : multiversion.kernels in /etc/zypp/zypp.conf, then purge-kernels\n'
            ;;
        alpine)
            have apk || return 0
            # `apk info` prints installed package names one per line, so the
            # flavour packages (linux-lts, linux-virt) can be matched exactly.
            local ks
            ks=$(probe apk info 2>/dev/null | grep -E '^linux-(lts|virt|edge|rpi|rpi4)$' | sort -u)
            [[ -n $ks ]] && printf '%s\n' "$ks" | sed 's/^/    /'
            printf '  Removal path  : apk del <flavour>; Alpine keeps one version per flavour\n'
            ;;
    esac
}

report_updates() {
    section 'Pending updates'
    case $FAMILY in
        debian)
            # Debug::NoLocking lets this run while another apt process holds the
            # lock, so a health check never blocks on an in-flight upgrade.
            #
            # The simulation is captured and its status checked before anything
            # is counted. Piping it straight into `grep -c` loses that status:
            # grep prints "0" for empty input whether apt found no upgrades or
            # failed outright, so a broken sources.list, an unreachable mirror
            # or a probe timeout would all be reported as "0 package(s)" -- a
            # health check answering "all clear" because it could not look. The
            # rhel branch below already reads its status; this now matches.
            local sim rc
            sim=$(probe apt-get -s -o Debug::NoLocking=1 upgrade 2>/dev/null)
            rc=$?
            if ((rc == 0)); then
                printf '  Upgradable    : %s package(s)\n' \
                    "$(printf '%s\n' "$sim" | grep -c '^Inst ' || true)"
            else
                printf '  Upgradable    : unknown (apt-get -s upgrade exited %s)\n' "$rc"
            fi
            if have apt-mark; then
                local held
                held=$(probe apt-mark showhold 2>/dev/null)
                [[ -n $held ]] && printf '  On hold       : %s\n' "$(printf '%s' "$held" | tr '\n' ' ')"
            fi
            ;;
        rhel)
            local out rc
            out=$(probe "$PKG_TOOL" -q check-update 2>/dev/null)
            rc=$?
            case $rc in
                0) printf '  Upgradable    : 0 package(s)\n' ;;
                100) printf '  Upgradable    : %s package(s) (approximate)\n' \
                    "$(printf '%s\n' "$out" | awk 'NF && $1 !~ /^(Last|Obsoleting|Security:)/ { n = n + 1 } END { print n + 0 }')" ;;
                *) printf '  Upgradable    : unknown (%s check-update exited %s)\n' "$PKG_TOOL" "$rc" ;;
            esac
            ;;
        arch)
            # checkupdates, not `pacman -Sy && pacman -Qu`. Syncing the database
            # without upgrading leaves the system in a partial-upgrade state,
            # which Arch upstream calls unsupported -- and a health report has
            # no business changing the machine at all. checkupdates copies the
            # database to a temporary location and queries that, so it is
            # read-only. It ships in pacman-contrib, which is not installed by
            # default; absent means unknown, never zero.
            if have checkupdates; then
                local out rc
                out=$(probe checkupdates 2>/dev/null)
                rc=$?
                case $rc in
                    0) printf '  Upgradable    : %s package(s)\n' \
                        "$(printf '%s\n' "$out" | grep -c . || true)" ;;
                    2) printf '  Upgradable    : 0 package(s)\n' ;;
                    *) printf '  Upgradable    : unknown (checkupdates exited %s)\n' "$rc" ;;
                esac
            else
                printf '  Upgradable    : unknown (install pacman-contrib for checkupdates)\n'
            fi
            # Arch's equivalent of a hold is IgnorePkg in pacman.conf.
            if [[ -r /etc/pacman.conf ]]; then
                local ignored
                ignored=$(sed -n 's/^[[:space:]]*IgnorePkg[[:space:]]*=[[:space:]]*//p' /etc/pacman.conf |
                    tr '\n' ' ' | tr -s ' ' | sed 's/ *$//')
                [[ -n $ignored ]] && printf '  On hold       : %s\n' "$ignored"
            fi
            ;;
        suse)
            # No refresh: a health report must not mutate repository metadata.
            # That makes the answer only as fresh as the last refresh, which is
            # said out loud rather than left for someone to infer.
            local out rc
            out=$(probe zypper --non-interactive --quiet list-updates 2>/dev/null)
            rc=$?
            if ((rc == 0)); then
                printf '  Upgradable    : %s package(s) (from cached metadata)\n' \
                    "$(printf '%s\n' "$out" | awk -F'|' '$1 ~ /^v[[:space:]]*$/ { n = n + 1 } END { print n + 0 }')"
            else
                printf '  Upgradable    : unknown (zypper list-updates exited %s)\n' "$rc"
            fi
            if [[ -r /etc/zypp/locks ]] && [[ -s /etc/zypp/locks ]]; then
                printf '  On hold       : see /etc/zypp/locks (zypper locks)\n'
            fi
            ;;
        alpine)
            # Same reasoning as suse: no `apk update` from a report, so this
            # reflects the index as it stands on disk.
            local out rc
            out=$(probe apk version -l '<' 2>/dev/null)
            rc=$?
            if ((rc == 0)); then
                printf '  Upgradable    : %s package(s) (from cached index)\n' \
                    "$(printf '%s\n' "$out" | awk 'NR > 1 && NF { n = n + 1 } END { print n + 0 }')"
            else
                printf '  Upgradable    : unknown (apk version exited %s)\n' "$rc"
            fi
            ;;
        *) printf '  Upgradable    : unknown (no supported package manager)\n' ;;
    esac
}

check_reboot_required() {
    case $FAMILY in
        debian)
            if [[ -f /run/reboot-required || -f /var/run/reboot-required ]]; then
                REBOOT_REQUIRED=1
                return 0
            fi
            ;;
        rhel)
            # needs-restarting uses an inverted convention: exit 1 means "reboot
            # required". That makes availability checking mandatory -- dnf also
            # exits non-zero when the subcommand does not exist, and
            # dnf-plugins-core is not installed by default. Reading that as
            # "reboot required" would make every such host permanently report a
            # pending reboot. An absent tool means unknown, never yes.
            local -a nr=()
            if have needs-restarting; then
                nr=(needs-restarting)
            elif [[ -n $PKG_TOOL ]] && probe "$PKG_TOOL" needs-restarting --help >/dev/null 2>&1; then
                nr=("$PKG_TOOL" needs-restarting)
            fi
            if ((${#nr[@]})); then
                # Exactly 1 means "reboot required". Every other non-zero
                # status is the tool failing, not answering -- 124 from the
                # probe timeout, or dnf's own error codes -- and a bare
                # `|| REBOOT_REQUIRED=1` read all of them as yes, so a slow or
                # unhappy dnf produced a permanent phantom pending reboot.
                local nrc=0
                probe "${nr[@]}" -r >/dev/null 2>&1 || nrc=$?
                if ((nrc == 1)); then
                    REBOOT_REQUIRED=1
                    return 0
                fi
                ((nrc > 1)) && log WARN "needs-restarting exited $nrc; reboot state unknown"
            fi
            ;;
        arch)
            # Arch has no reboot-required marker. What it does have is a very
            # reliable side effect: upgrading the kernel package replaces
            # /usr/lib/modules/<version>, so once the running kernel's module
            # directory has gone, the running kernel no longer matches the
            # installed one and nothing further can be modprobe'd. That is the
            # symptom people actually hit, and it is exactly the condition worth
            # reporting.
            #
            # Both paths are checked because /lib is a symlink to /usr/lib on a
            # merged-/usr Arch install but not necessarily on a derivative.
            local kver dir=''
            kver=$(uname -r 2>/dev/null) || kver=''
            [[ -n $kver ]] || return 1
            # Both paths, because /lib is a symlink to /usr/lib on a merged-/usr
            # Arch install but not necessarily on a derivative.
            [[ -d /usr/lib/modules/$kver ]] && dir=/usr/lib/modules/$kver
            [[ -z $dir && -d /lib/modules/$kver ]] && dir=/lib/modules/$kver

            # Gone is the easy case. Present-but-unowned is the one that matters
            # and the one a plain -d test misses: Manjaro's kernel tooling keeps
            # the running kernel's module tree alive across an upgrade so the
            # live kernel can still load modules, so the directory still exists
            # while the package that owned it has moved to a new version. It is
            # left orphaned, and `pacman -Qoq` on it fails -- which is the
            # signal. A -d test alone reports "no reboot needed" on exactly the
            # host that needs one most.
            if [[ -z $dir ]]; then
                REBOOT_REQUIRED=1
                return 0
            fi
            if have pacman && ! probe pacman -Qoq "$dir" >/dev/null 2>&1; then
                REBOOT_REQUIRED=1
                return 0
            fi
            ;;
        suse)
            # Same inverted convention as dnf's needs-restarting, and the same
            # trap: `zypper needs-restarting -r` documents "returns 1 if a full
            # reboot is required, 0 if not", and zypper also exits non-zero for
            # an unknown subcommand. Reading that as "reboot required" would
            # make every host without the subcommand report one forever, so
            # availability is probed first and an absent tool means unknown.
            if [[ -n $PKG_TOOL ]] && probe "$PKG_TOOL" needs-restarting --help >/dev/null 2>&1; then
                # Only 1 means "reboot required"; see the rhel branch. zypper
                # additionally exits 7 when another zypper holds the ZYPP lock,
                # which is a state this report is meant to tolerate, not to
                # translate into a pending reboot.
                local zrc=0
                probe "$PKG_TOOL" needs-restarting -r >/dev/null 2>&1 || zrc=$?
                if ((zrc == 1)); then
                    REBOOT_REQUIRED=1
                    return 0
                fi
                ((zrc > 1)) && log WARN "zypper needs-restarting exited $zrc; reboot state unknown"
            fi
            ;;
        alpine)
            # Alpine ships no reboot marker and no needs-restarting equivalent.
            # Reported as unknown rather than guessed at from kernel versions,
            # which on a container host -- Alpine's usual role -- would be
            # answering a question the host cannot be asked.
            :
            ;;
    esac
    return 1
}

report_reboot() {
    section 'Reboot'
    if check_reboot_required; then
        printf '  Required      : yes\n'
        if [[ -r /run/reboot-required.pkgs ]]; then
            printf '  Triggered by  : %s\n' "$(sort -u /run/reboot-required.pkgs 2>/dev/null | tr '\n' ' ')"
        fi
    else
        printf '  Required      : no (or undetectable on this distribution)\n'
    fi
}

report_units() {
    have systemctl || return 0
    [[ -d /run/systemd/system ]] || return 0
    section 'Failed systemd units'
    local out
    out=$(probe systemctl --failed --no-legend --plain 2>/dev/null | awk 'NF { print "  " $1 }')
    if [[ -n $out ]]; then
        printf '%s\n' "$out"
    else
        printf '  none\n'
    fi
}

# Packages that ship a changed config file leave the new version beside the old
# one instead of prompting (dpkg with --force-confold, rpm always). Nothing
# reports these, so drift accumulates silently until something misbehaves.
report_config_drift() {
    have find || return 0
    section "Config drift under $ETC_DIR"
    local out
    out=$(probe find "$ETC_DIR" -xdev -type f \
        \( -name '*.dpkg-dist' -o -name '*.dpkg-new' -o -name '*.dpkg-old' \
        -o -name '*.ucf-dist' -o -name '*.rpmnew' -o -name '*.rpmsave' \) \
        2>/dev/null | sed 's/^/  /')
    if [[ -n $out ]]; then
        printf '%s\n' "$out"
        printf '  Review each: the packaged version is not the active one.\n'
    else
        printf '  none\n'
    fi
}

report_journal() {
    have journalctl || return 0
    section 'Journal'
    printf '  %s\n' "$(probe journalctl --disk-usage 2>/dev/null || printf 'unreadable')"
}

report_locks() {
    section 'Package-manager locks'
    local -a locks=()
    lock_paths locks
    if ((${#locks[@]} == 0)); then
        printf '  none applicable\n'
        return 0
    fi
    # Same false negative as fix-locks guards against: an unprivileged fuser sees
    # only this user's handles, so "no holder" would really mean "could not
    # look". report is the one task that routinely runs unprivileged, so it has
    # to say so rather than print a reassuring 'none held'.
    if ! is_root; then
        printf '  unknown (needs root to see other users file handles)\n'
        return 0
    fi

    local path holders any=0
    for path in "${locks[@]}"; do
        [[ -e $path ]] || continue
        holders=$(lock_holders "$path")
        if [[ $holders == unknown ]]; then
            printf '  %-40s holder unknown (no fuser/lsof)\n' "$path"
            any=1
        elif [[ -n $holders ]]; then
            printf '  %-40s held by PID %s\n' "$path" "$holders"
            any=1
        fi
    done
    ((any)) || printf '  none held\n'
}

report_body() {
    report_identity
    report_memory
    report_filesystems
    report_kernels
    report_updates
    report_reboot
    report_units
    report_config_drift
    report_journal
    report_locks
    printf '\n'
}

# The report body is written with plain printf rather than through log(), so
# under --quiet it would otherwise flood stdout -- and it is part of 'routine',
# which the README schedules as `--yes --quiet routine`. That would mail the
# whole report every night and destroy the "mail means something failed"
# contract that --quiet exists to provide.
#
# Under --quiet the body is redirected into the log file instead of being
# skipped, so that check_reboot_required still runs and a pending reboot is
# still recorded where an unattended run can be audited afterwards. QUIET is
# shadowed to 0 for the duration so section() keeps emitting its headers --
# without that the log copy is a run of bare "none" lines with nothing to
# attach them to.
#
# When the log file is not writable LOG_SINK is /dev/null, so `--quiet report`
# on such a host prints nothing and stores nothing. That is the documented
# meaning of --quiet, not a lost report.
task_report() {
    if ((QUIET)); then
        local QUIET=0
        report_body >>"$LOG_SINK"
    else
        report_body
    fi
    return 0
}

# --- Task: update / autoremove / clean-cache ----------------------------------

task_update() {
    [[ -n $FAMILY ]] || {
        unsupported_family update 'apt/dnf/pacman/zypper/apk'
        return 0
    }
    export_pkg_env
    local rc=0
    case $FAMILY in
        debian)
            local -a opts=()
            mapfile -t opts < <(apt_opts)
            run_cmd "$TASK_TIMEOUT" apt-get "${opts[@]}" update || rc=$?
            ((rc == 0)) || {
                log ERROR "apt-get update failed (status $rc); not upgrading against a stale index"
                return "$rc"
            }
            run_cmd "$TASK_TIMEOUT" apt-get "${opts[@]}" "$UPGRADE_MODE" || rc=$?
            ;;
        rhel)
            local mode=upgrade
            [[ $UPGRADE_MODE == dist-upgrade ]] && mode=distro-sync
            # strict=0 lets a multi-package transaction proceed when one package
            # is unresolvable instead of failing the whole run.
            # --refresh and --setopt=strict are dnf-only. Classic yum (the
            # only way PKG_TOOL is `yum`, since dnf is detected first) rejects
            # both and the task fails before it starts, so it gets an explicit
            # cache expiry instead.
            if [[ $PKG_TOOL == yum ]]; then
                run_cmd "$TASK_TIMEOUT" yum -y clean expire-cache || rc=$?
                ((rc == 0)) || {
                    log ERROR "yum clean expire-cache failed (status $rc); not upgrading against a stale cache"
                    return "$rc"
                }
                run_cmd "$TASK_TIMEOUT" yum -y "$mode" || rc=$?
            else
                run_cmd "$TASK_TIMEOUT" "$PKG_TOOL" -y --setopt=strict=0 --refresh "$mode" || rc=$?
            fi
            ;;
        arch)
            # One -Syu, never a separate -Sy followed by an upgrade. Refreshing
            # the database without upgrading in the same transaction produces a
            # partial upgrade, which on a rolling release can leave a library
            # and its dependants at incompatible versions; upstream Arch treats
            # it as unsupported and it is the classic way to break a Manjaro
            # box. The two-step the debian branch uses -- refresh, check, then
            # upgrade -- is therefore deliberately not mirrored here.
            #
            # UPGRADE_MODE is not consulted: pacman has no upgrade/dist-upgrade
            # distinction, -Syu is always a full-system upgrade.
            run_cmd "$TASK_TIMEOUT" pacman -Syu --noconfirm || rc=$?
            ;;
        suse)
            # Refresh, verify, then upgrade -- the same two-step as the debian
            # branch and for the same reason: upgrading against a stale or
            # half-fetched index is worse than not upgrading.
            run_cmd "$TASK_TIMEOUT" zypper --non-interactive refresh || rc=$?
            ((rc == 0)) || {
                log ERROR "zypper refresh failed (status $rc); not upgrading against a stale index"
                return "$rc"
            }
            # dup is a genuine counterpart to dist-upgrade: it allows vendor
            # changes and package removal, which `update` will not do. Mapping
            # UPGRADE_MODE onto it keeps one flag meaning one thing everywhere.
            local zmode=update
            [[ $UPGRADE_MODE == dist-upgrade ]] && zmode=dist-upgrade
            run_cmd "$TASK_TIMEOUT" zypper --non-interactive "$zmode" || rc=$?
            ;;
        alpine)
            # -U is `apk update` folded into the same invocation, so the index
            # refresh and the upgrade cannot be separated by an interruption.
            run_cmd "$TASK_TIMEOUT" apk -U upgrade || rc=$?
            ;;
    esac
    check_reboot_required
    return "$rc"
}

task_autoremove() {
    [[ -n $FAMILY ]] || {
        unsupported_family autoremove 'apt/dnf/pacman/zypper/apk'
        return 0
    }
    export_pkg_env
    local rc=0
    case $FAMILY in
        debian)
            local -a opts=()
            mapfile -t opts < <(apt_opts)
            run_cmd "$TASK_TIMEOUT" apt-get "${opts[@]}" --purge autoremove || rc=$?
            ;;
        rhel)
            run_cmd "$TASK_TIMEOUT" "$PKG_TOOL" -y autoremove || rc=$?
            ;;
        arch)
            # pacman has no autoremove. The equivalent is the orphan list:
            # packages installed as dependencies that nothing depends on any
            # more. `pacman -Qtdq` exits 1 when there are none, which is not an
            # error and must not be reported as one.
            local orphans
            orphans=$(probe pacman -Qtdq 2>/dev/null) || orphans=''
            if [[ -z $orphans ]]; then
                log INFO 'No orphaned packages'
                return 0
            fi
            log INFO "Orphaned packages: $(printf '%s' "$orphans" | tr '\n' ' ')"
            # Read into an array and expand it quoted. Unquoted $orphans would
            # word-split (wanted) but also glob-expand (not wanted): a local-db
            # entry named `[a-z]*` would turn into every matching name in the
            # current directory, handed to a root `pacman -Rns`. Pacman's own
            # name grammar excludes those characters, so this needs a corrupt
            # db to bite -- but a root deletion argv should not depend on the
            # db being well-formed, and the array costs nothing.
            local -a orphan_list=()
            mapfile -t orphan_list <<<"$orphans"
            # -Rns: remove the packages, their now-unneeded dependencies, and
            # their configuration. Matches --purge autoremove on the debian side.
            run_cmd "$TASK_TIMEOUT" pacman -Rns --noconfirm "${orphan_list[@]}" || rc=$?
            ;;
        suse)
            # zypper can list unneeded packages but has no autoremove that
            # consumes that list, and the list itself only comes out of a
            # human-readable table. Parsing a table to build a purge argv is
            # how an unattended maintenance run removes something it should not
            # have. Reported rather than approximated.
            no_equivalent autoremove \
                'zypper has no autoremove; review "zypper packages --unneeded" and remove by name.'
            return 0
            ;;
        alpine)
            # apk tracks explicitly-installed packages in /etc/apk/world and
            # prunes unneeded dependencies as part of ordinary transactions, so
            # there is no separate orphan set to collect.
            no_equivalent autoremove \
                'apk prunes unused dependencies during normal transactions; there is no orphan list to purge.'
            return 0
            ;;
    esac
    return "$rc"
}

task_clean_cache() {
    [[ -n $FAMILY ]] || {
        unsupported_family clean-cache 'apt/dnf/pacman/zypper/apk'
        return 0
    }
    local rc=0
    case $FAMILY in
        debian)
            run_cmd "$TASK_TIMEOUT" apt-get clean || rc=$?
            ;;
        rhel)
            # 'clean packages' keeps the repo metadata, so the next transaction
            # does not have to re-download every repomd.xml.
            run_cmd "$TASK_TIMEOUT" "$PKG_TOOL" clean packages || rc=$?
            ;;
        arch)
            # paccache keeps the most recent version of each package, which
            # leaves a downgrade path if an upgrade goes wrong. `pacman -Sc`
            # keeps nothing but the currently-installed versions, so it is the
            # fallback rather than the first choice. Neither drops the sync
            # database, matching the rhel branch's 'clean packages' -- though
            # `pacman -Sc --noconfirm` does also answer yes to its second
            # question and drop caches for repositories no longer configured.
            if have paccache; then
                run_cmd "$TASK_TIMEOUT" paccache -rk1 || rc=$?
            else
                run_cmd "$TASK_TIMEOUT" pacman -Sc --noconfirm || rc=$?
            fi
            ;;
        suse)
            # Bare `clean` drops cached packages and keeps repository metadata,
            # matching the rhel branch. `--all` would also drop the metadata and
            # make the next transaction re-download every repo index.
            run_cmd "$TASK_TIMEOUT" zypper --non-interactive clean || rc=$?
            ;;
        alpine)
            # Only meaningful when a cache is configured; apk errors out when
            # /etc/apk/cache is absent, which is the default on many installs
            # and is not a failure of this task.
            if [[ -e /etc/apk/cache ]]; then
                run_cmd "$TASK_TIMEOUT" apk cache clean || rc=$?
            else
                log INFO 'No apk cache configured (/etc/apk/cache absent); nothing to clean'
            fi
            ;;
    esac
    return "$rc"
}

# --- Task: clean-logs ---------------------------------------------------------

# Turns a space-separated exclusion list into `find` prune arguments. The
# trailing '*' makes a single token cover both a directory (audit/) and the
# rotated files beneath a prefix (wtmp.1, btmp.1).
build_prune_args() {
    local list=$1
    local -a toks=()
    read -r -a toks <<<"$list"
    ((${#toks[@]})) || return 0
    local i
    printf '%s\n' '('
    for i in "${!toks[@]}"; do
        ((i > 0)) && printf '%s\n' '-o'
        printf '%s\n%s\n' '-name' "${toks[i]}*"
    done
    printf '%s\n%s\n%s\n' ')' '-prune' '-o'
}

# Usage summary for a single path. Asking for used/avail/pcent without the
# target column means there is no variable-width field to miscount, whatever the
# device is called.
fs_usage_line() {
    have df || return 0
    local out
    out=$(probe df -h --output=used,avail,pcent -- "$1" 2>/dev/null |
        awk 'NR == 2 { print $1 " used, " $2 " free (" $3 ")" }')
    if [[ -z $out ]]; then
        out=$(probe df -P -h -- "$1" 2>/dev/null |
            awk 'NR > 1 { for (i = NF; i >= 1; i--) if ($i ~ /^[0-9]+%$/) { print $(i - 2) " used, " $(i - 1) " free (" $i ")"; exit } }')
    fi
    printf '%s' "$out"
}

# Deletes the given NUL-delimited file list, honouring --dry-run. Returns
# non-zero if any removal failed.
delete_files() {
    local label=$1
    shift
    local -a victims=("$@")
    local rc=0 f

    if ((${#victims[@]} == 0)); then
        log INFO "$label: nothing older than the threshold"
        return 0
    fi

    log INFO "$label: ${#victims[@]} file(s) selected"
    for f in "${victims[@]}"; do
        if ((DRY_RUN)); then
            log DRY "would delete $f"
        else
            # Not gated on QUIET: log() already suppresses the terminal copy and
            # always writes the file, and which files were deleted is the one
            # record an unattended run must leave behind.
            if rm -f -- "$f"; then
                log RUN "deleted $f"
            else
                log WARN "could not delete $f"
                rc=1
            fi
        fi
    done
    return "$rc"
}

task_clean_logs() {
    local rc=0

    if have journalctl && [[ -d /run/systemd/system ]]; then
        run_cmd "$TASK_TIMEOUT" journalctl --vacuum-size="$JOURNAL_SIZE" || rc=1
        run_cmd "$TASK_TIMEOUT" journalctl --vacuum-time="$JOURNAL_AGE" || rc=1
    else
        log INFO "journald not present; skipping the journal vacuum"
    fi

    if ! have find; then
        log ERROR "find not found; cannot sweep rotated logs"
        return 1
    fi
    if [[ ! -d $LOG_DIR ]]; then
        log WARN "$LOG_DIR is not a directory; skipping the rotated-log sweep"
        return "$rc"
    fi

    local before after
    before=$(fs_usage_line "$LOG_DIR")

    local -a prune=()
    mapfile -t prune < <(build_prune_args "$LOG_EXCLUDE")

    # Only already-rotated files are eligible. A live *.log is never touched:
    # truncating one that a daemon holds open is what turns "free some space"
    # into "the service stopped logging".
    #
    # The numeric suffixes are matched with globs rather than -regex on purpose:
    # GNU find defaults to the Emacs regex dialect, in which '\+' is a literal
    # plus sign, so the obvious '.*\.[0-9]\+$' silently matches nothing.
    local -a victims=()
    mapfile -d '' -t victims < <(
        find "$LOG_DIR" -xdev -mindepth 1 \
            ${prune[@]+"${prune[@]}"} \
            -type f \
            \( -name '*.gz' -o -name '*.xz' -o -name '*.bz2' -o -name '*.zst' \
            -o -name '*.old' -o -name '*.[0-9]' -o -name '*.[0-9][0-9]' \) \
            -mtime +"$LOG_AGE_DAYS" -print0 2>/dev/null
    )

    delete_files "Rotated logs older than ${LOG_AGE_DAYS}d in $LOG_DIR" ${victims[@]+"${victims[@]}"} || rc=1

    after=$(fs_usage_line "$LOG_DIR")
    [[ -n $before ]] && log INFO "$LOG_DIR before: $before"
    [[ -n $after ]] && log INFO "$LOG_DIR after : $after"
    return "$rc"
}

# --- Task: clean-tmp ----------------------------------------------------------

# Removes directories left empty by the file sweep, deepest first. `find -delete`
# is deliberately not used here: it implies -depth, and -depth makes -prune a
# no-op, which would let the sweep remove the very directories the exclusion
# list exists to protect (/tmp/.X11-unix and friends). Each pass can only expose
# one more level of empty parent, so a small fixed number of passes is enough.
prune_empty_dirs() {
    local dir=$1
    shift
    local -a prune=("$@")
    local -a empties=()
    local d i

    for ((i = 0; i < 3; i++)); do
        empties=()
        mapfile -d '' -t empties < <(
            find "$dir" -xdev -mindepth 1 ${prune[@]+"${prune[@]}"} \
                -type d -empty -print0 2>/dev/null
        )
        ((${#empties[@]})) || return 0
        if ((DRY_RUN)); then
            for d in "${empties[@]}"; do log DRY "would remove empty directory $d"; done
            return 0
        fi
        for d in "${empties[@]}"; do
            rmdir -- "$d" 2>/dev/null && log RUN "removed empty directory $d"
        done
    done
    return 0
}

# systemd-tmpfiles grew --dry-run in systemd 249. Older releases are still in
# service (Debian 11 ships 247), so support is probed rather than assumed, and
# the absence of it is reported instead of being papered over.
# The help text is captured and matched in the shell rather than piped into
# `grep -q`. Under `pipefail`, `producer | grep -q` reports the pipeline as
# failed whenever grep exits on the first match before the producer has finished
# writing: the producer gets SIGPIPE and dies with 141, which pipefail promotes.
# That would make a systemd that DOES support --dry-run look as though it does
# not, and silently drop the preview -- and it only bites once the help text
# outgrows the pipe buffer, so it is the kind of bug that appears on someone
# else's distribution and never in a test.
tmpfiles_has_dry_run() {
    local help_text
    help_text=$(probe systemd-tmpfiles --help 2>/dev/null) || return 1
    [[ $help_text == *--dry-run* ]]
}

task_clean_tmp() {
    # TMP_MODE has already been resolved from 'auto' by preflight, so this is
    # the same value the plan showed the operator.
    local rc=0

    if [[ $TMP_MODE == tmpfiles ]]; then
        have systemd-tmpfiles || {
            log ERROR "systemd-tmpfiles not found; use --tmp-mode age"
            return 1
        }
        # The distribution's own tmpfiles.d policy already encodes which paths
        # are safe to remove and after how long, including the sockets that must
        # survive. Deferring to it beats re-deriving the rules here -- but it
        # also means the set of files at risk is the whole policy, not --tmp-dirs.
        log INFO "Using the distribution tmpfiles.d policy: --tmp-dirs and --tmp-age do not apply, and paths outside them may be cleaned. 'systemd-tmpfiles --cat-config' lists the rules."
        if ((DRY_RUN)); then
            if tmpfiles_has_dry_run; then
                log DRY 'systemd-tmpfiles --clean --dry-run (lists what it would remove; removes nothing)'
                # Deliberately not run_cmd: this argv is the preview itself, so
                # printing "would run" instead of running it would make
                # --dry-run useless for the default clean-tmp path.
                #
                # Its status is reported but does not fail the task. A preview is
                # a query: --dry-run deliberately skips the root check so an
                # unprivileged operator can decide whether to run this at all,
                # and such a run cannot stat everything the policy covers.
                # Marking the maintenance run failed because a preview was
                # incomplete would be wrong, and every other task's --dry-run
                # returns 0 as well.
                local prc=0
                exec_cmd "$TASK_TIMEOUT" systemd-tmpfiles --clean --dry-run || prc=$?
                ((prc == 0)) ||
                    log WARN "systemd-tmpfiles --clean --dry-run exited $prc; the list above may be incomplete (a full preview needs root)."
                return 0
            else
                # No preview available. Say so and change nothing -- never fall
                # through to the real --clean to produce some output.
                log DRY 'would run: systemd-tmpfiles --clean'
                log WARN "This systemd-tmpfiles predates --dry-run (systemd 249), so the file list cannot be previewed. Inspect the policy with 'systemd-tmpfiles --cat-config', or use --tmp-mode age for a previewable sweep."
            fi
            return "$rc"
        fi
        run_cmd "$TASK_TIMEOUT" systemd-tmpfiles --clean || rc=1
        return "$rc"
    fi

    have find || {
        log ERROR "find not found; cannot clean temporary directories"
        return 1
    }

    local -a dirs=()
    read -r -a dirs <<<"$TMP_DIRS"
    local -a prune=()
    mapfile -t prune < <(build_prune_args "$TMP_EXCLUDE")

    local dir before after
    for dir in "${dirs[@]}"; do
        if [[ ! -d $dir ]]; then
            log WARN "$dir is not a directory; skipping"
            continue
        fi
        before=$(fs_usage_line "$dir")

        # Regular files only, and both atime and mtime must be past the
        # threshold. A directory is never removed for being old -- only once it
        # is empty -- so a stale-looking directory holding fresh files survives.
        local -a victims=()
        mapfile -d '' -t victims < <(
            find "$dir" -xdev -mindepth 1 \
                ${prune[@]+"${prune[@]}"} \
                -type f -atime +"$TMP_AGE_DAYS" -mtime +"$TMP_AGE_DAYS" \
                -print0 2>/dev/null
        )
        delete_files "Files older than ${TMP_AGE_DAYS}d in $dir" ${victims[@]+"${victims[@]}"} || rc=1
        prune_empty_dirs "$dir" ${prune[@]+"${prune[@]}"}

        after=$(fs_usage_line "$dir")
        [[ -n $before ]] && log INFO "$dir before: $before"
        [[ -n $after ]] && log INFO "$dir after : $after"
    done
    return "$rc"
}

# --- Task: fix-packages -------------------------------------------------------

task_fix_packages() {
    [[ $FAMILY == debian ]] || {
        unsupported_family fix-packages 'Debian/Ubuntu'
        return 0
    }
    export_pkg_env
    local rc=0
    local -a opts=()
    mapfile -t opts < <(apt_opts)

    # The documented repair order: replay the dpkg journal first, then let apt
    # resolve whatever dependencies the interrupted transaction left unmet.
    run_cmd "$TASK_TIMEOUT" dpkg --configure -a || rc=$?
    run_cmd "$TASK_TIMEOUT" apt-get "${opts[@]}" -f install || rc=$?
    return "$rc"
}

# --- Task: fix-locks ----------------------------------------------------------

lock_paths() {
    local -n _out=$1
    _out=()
    case $FAMILY in
        debian)
            _out=(/var/lib/dpkg/lock-frontend /var/lib/dpkg/lock
                /var/lib/apt/lists/lock /var/cache/apt/archives/lock)
            ;;
        rhel)
            _out=(/var/lib/rpm/.rpm.lock)
            ;;
        arch)
            _out=(/var/lib/pacman/db.lck)
            ;;
        suse)
            _out=(/var/run/zypp.pid /var/lib/rpm/.rpm.lock)
            ;;
        alpine)
            _out=(/lib/apk/db/lock)
            ;;
    esac
}

# Prints the PIDs holding a path, an empty string when nothing holds it, or the
# literal 'unknown' when neither fuser nor lsof is available. "No tool to check"
# must never be reported as "nothing holds it".
lock_holders() {
    local path=$1
    if have fuser; then
        probe fuser "$path" 2>/dev/null | tr -s ' ' ' ' | sed 's/^ *//; s/ *$//'
        return 0
    fi
    if have lsof; then
        probe lsof -t -- "$path" 2>/dev/null | tr '\n' ' ' | sed 's/ *$//'
        return 0
    fi
    printf 'unknown'
}

pid_alive() {
    [[ $1 =~ ^[0-9]+$ ]] || return 1
    kill -0 "$1" 2>/dev/null
}

task_fix_locks() {
    [[ -n $FAMILY ]] || {
        unsupported_family fix-locks 'apt/dnf/pacman/zypper/apk'
        return 0
    }

    local -a locks=()
    lock_paths locks
    local path holders busy=0 unknown=0

    # An unprivileged fuser/lsof only sees this user's own file handles, so an
    # empty result would mean "I could not look", not "nothing holds it".
    if ! is_root; then
        log WARN 'Not running as root: file handles held by other users are invisible, so lock state cannot be established.'
        unknown=1
    fi

    for path in "${locks[@]}"; do
        [[ -e $path ]] || continue
        holders=$(lock_holders "$path")
        if [[ $holders == unknown ]]; then
            log WARN "$path: cannot determine the holder (install psmisc for fuser, or lsof)"
            unknown=1
            continue
        fi
        if [[ -n $holders ]]; then
            busy=1
            log WARN "$path is held by PID(s): $holders"
            local -a pids=()
            read -r -a pids <<<"$holders"
            local pid
            for pid in "${pids[@]}"; do
                # The holder can exit between pid_alive and this read, so the
                # 2>/dev/null has to come before the input redirection or bash
                # prints its own error over the diagnosis being produced.
                pid_alive "$pid" && log WARN "  PID $pid: $(tr '\0' ' ' 2>/dev/null <"/proc/$pid/cmdline" || printf 'unreadable')"
            done
        fi
    done

    if ((busy)); then
        log ERROR "A package manager is running. Wait for it, or let apt wait: apt-get -o DPkg::Lock::Timeout=$PKG_LOCK_WAIT ..."
        log ERROR "This task never kills the holder and never deletes a dpkg lock file: those are flock(2) targets that the kernel releases when the process dies, so they cannot go stale. Deleting one while a holder is alive is what corrupts /var/lib/dpkg."
        return 1
    fi

    if ((unknown)); then
        log ERROR "Refusing to act on locks whose holder could not be determined."
        return 1
    fi

    log OK "No package-manager lock is held."

    # dnf, unlike dpkg, uses a pid file rather than flock, so that one really can
    # outlive its process.
    if [[ $FAMILY == rhel ]]; then
        local pidfile
        for pidfile in /run/dnf.pid /var/run/dnf.pid; do
            [[ -f $pidfile ]] || continue
            local pid
            pid=$(head -n1 "$pidfile" 2>/dev/null | tr -dc '0-9')
            if [[ -n $pid ]] && pid_alive "$pid"; then
                log ERROR "$pidfile belongs to live PID $pid; leaving it alone"
                return 1
            fi
            log WARN "$pidfile refers to PID '${pid:-none}', which is not running"
            if ((DRY_RUN)); then
                log DRY "would delete $pidfile"
            elif confirm_step "delete the stale pid file $pidfile"; then
                rm -f -- "$pidfile" && log OK "removed stale $pidfile"
            fi
        done
    fi

    # An interrupted dpkg run leaves entries in its journal. Replaying them is
    # the actual repair; that is what fix-packages does.
    if [[ $FAMILY == debian ]] && [[ -d /var/lib/dpkg/updates ]]; then
        local pending
        pending=$(find /var/lib/dpkg/updates -mindepth 1 -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' ')
        if [[ ${pending:-0} != 0 ]]; then
            log WARN "dpkg has $pending unreplayed journal entries; run: $PROG --yes fix-packages"
        fi
    fi
    return 0
}

# --- Dispatch -----------------------------------------------------------------

run_task() {
    case $1 in
        report) task_report ;;
        update) task_update ;;
        autoremove) task_autoremove ;;
        clean-cache) task_clean_cache ;;
        clean-logs) task_clean_logs ;;
        clean-tmp) task_clean_tmp ;;
        fix-packages) task_fix_packages ;;
        fix-locks) task_fix_locks ;;
        *) return 2 ;;
    esac
}

# force=1 prints the plan even under --quiet. A confirmation prompt exists to
# show the operator the blast radius before they answer it, so suppressing the
# plan and then asking "Proceed? [y/N]" would leave nothing to consent to.
# --quiet still silences the plan for the runs it was meant for: --yes and
# --dry-run, neither of which asks a question.
print_plan() {
    local force=${1:-0} task
    ((QUIET)) && ((!force)) && return 0
    printf '\n'
    printf 'Plan for %s:\n' "$(hostname 2>/dev/null || printf 'this host')"
    for task in "${TASKS[@]}"; do
        printf '  %-13s %s\n' "$task" "$(task_blast_radius "$task")"
    done
    printf '\n'
}

confirm_plan() {
    local reply
    if [[ -t 0 ]]; then
        read -r -p 'Proceed? [y/N] ' reply || return 1
    else
        # Under `curl | bash` stdin is the script text, so the answer has to come
        # from the terminal directly.
        read -r -p 'Proceed? [y/N] ' reply </dev/tty || return 1
    fi
    [[ ${reply,,} == y* ]]
}

# Gate for a destructive step inside an otherwise read-only task. Same rules as
# the whole-run gate: --dry-run never asks, --yes never asks, no terminal means
# refuse rather than silently proceed.
confirm_step() {
    local what=$1
    ((DRY_RUN)) && return 0
    ((ASSUME_YES)) && return 0
    if can_prompt; then
        # printf, not say(): say() is silenced by --quiet, and a confirmation
        # prompt with nothing above it gives the operator nothing to consent to.
        # Same reasoning as print_plan's force flag. This is the only gate
        # fix-locks has -- it is not a mutating task, so the whole-run gate in
        # main() never fires for it.
        printf 'About to %s.\n' "$what"
        confirm_plan && return 0
        log INFO "Skipped: $what"
        return 1
    fi
    log ERROR "Refusing to $what unattended. Re-run with --yes."
    return 1
}

summary() {
    ((SUMMARY_DONE)) && return 0
    SUMMARY_DONE=1

    local item
    local failed=${#FAILED_TASKS[@]}

    # Quiet means quiet on success only: a failure must always reach the
    # operator, which under cron means it must reach stderr.
    if ((QUIET)) && ((failed == 0)); then
        return 0
    fi

    ((QUIET)) || printf '\n'
    if ((failed)); then
        log ERROR "Summary: ${#OK_TASKS[@]} ok, ${#SKIPPED_TASKS[@]} skipped, $failed failed"
        for item in "${FAILED_TASKS[@]}"; do printf '  FAILED  %s\n' "$item" >&2; done
    else
        log INFO "Summary: ${#OK_TASKS[@]} ok, ${#SKIPPED_TASKS[@]} skipped, 0 failed"
    fi
    if ((!QUIET)); then
        ((${#OK_TASKS[@]})) && for item in "${OK_TASKS[@]}"; do printf '  ok      %s\n' "$item"; done
        ((${#SKIPPED_TASKS[@]})) && for item in "${SKIPPED_TASKS[@]}"; do printf '  skipped %s\n' "$item"; done
    fi
    ((REBOOT_REQUIRED)) && log WARN "This host needs a reboot."
    ((LOG_READY)) && log INFO "Full log: $LOG_FILE"
    return 0
}

on_exit() {
    local rc=$?
    trap - EXIT INT TERM
    summary
    ((LOCK_HELD)) && exec 9>&-
    exit "$rc"
}

on_signal() {
    log WARN 'Interrupted'
    exit "$EX_INTERRUPT"
}

# --- Main ---------------------------------------------------------------------

main() {
    parse_args "$@"
    setup_color

    ((QUIET)) || [[ ! -t 1 ]] || printf '%s%s v%s%s\n' "$GN" "$SCRIPT_NAME" "$SCRIPT_VERSION" "$CL"

    preflight

    local task mutating=0 needs_root=0
    for task in "${TASKS[@]}"; do
        task_mutates "$task" && mutating=1
        task_needs_root "$task" && needs_root=1
    done

    # Root is needed to change anything, but not to preview it: --dry-run stays
    # usable for an unprivileged operator deciding whether to run this at all.
    if ((needs_root)) && ((!DRY_RUN)) && ! is_root; then
        die "$EX_NOROOT" "These tasks must run as root. Try: sudo $PROG ${TASKS[*]}"
    fi

    # Decided before the plan is printed, because the answer is what decides
    # whether --quiet is allowed to suppress it.
    local will_prompt=0
    ((!DRY_RUN)) && ((mutating)) && ((!ASSUME_YES)) && can_prompt && will_prompt=1
    print_plan "$will_prompt"

    if ((DRY_RUN)); then
        log INFO 'Dry run: nothing will be changed.'
    elif ((mutating)) && ((!ASSUME_YES)); then
        if ((will_prompt)); then
            confirm_plan || {
                log INFO 'Cancelled.'
                return 0
            }
        else
            die "$EX_NOCONFIRM" "Refusing to change this system unattended. Re-run with --yes (or LZC_MAINTENANCE_YES=1), or preview with --dry-run."
        fi
    fi

    # The lock is only taken when something will actually change, so a read-only
    # report is never blocked by an update that is already running.
    ((mutating)) && ((!DRY_RUN)) && acquire_lock

    trap on_exit EXIT
    trap on_signal INT TERM
    # An SSH disconnect sends HUP to the foreground process group. Ignoring it
    # here means dpkg -- which inherits the ignored disposition across exec --
    # is not killed mid-transaction, which is the usual cause of a package
    # database that then needs `dpkg --configure -a` to recover.
    trap '' HUP

    log INFO "Starting $SCRIPT_NAME v$SCRIPT_VERSION on $(hostname 2>/dev/null || printf 'this host')"

    local rc
    for task in "${TASKS[@]}"; do
        section "task: $task"
        rc=0
        TASK_SKIPPED=0
        run_task "$task" || rc=$?
        if ((TASK_SKIPPED)); then
            continue # the task already recorded why it did nothing
        fi
        if ((rc == 0)); then
            OK_TASKS+=("$task")
            log OK "$task completed"
        else
            FAILED_TASKS+=("$task (status $rc)")
            log ERROR "$task failed with status $rc"
        fi
    done

    # A pending reboot does not get an exit code of its own: the repo-wide table
    # reserves every code it defines, and "needs a reboot" is not one of those
    # situations. summary() reports it as a warning, which is what reaches the
    # operator through cron mail anyway.
    ((${#FAILED_TASKS[@]})) && return "$EX_FAIL"
    return 0
}

main "$@"
