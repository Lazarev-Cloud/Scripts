#!/usr/bin/env bash
#
# APT/dpkg lock doctor.
#
# Works out whether the dpkg and APT locks are genuinely held, refuses to touch
# anything while a package manager is alive, clears only locks that are provably
# orphaned, and then runs the repair that actually fixes an interrupted dpkg
# transaction.
#
# License: MIT
# Origin:  https://github.com/Lazarev-Cloud/Scripts
#
# Error model: this is a linear script -- detect, decide, act -- that must abort
# on the first unexpected failure rather than carry on towards an `rm`, so
# `set -Eeuo pipefail` is the right choice and is used deliberately. On top of
# that, every detection routine fails CLOSED: a lock whose state cannot be
# determined is reported as held, and nothing is ever removed on the strength of
# a check that did not actually run. Do not weaken either property.
set -Eeuo pipefail
# inherit_errexit is bash >= 4.4. Older shells simply miss the extra safety net;
# every fallible command is checked explicitly regardless.
shopt -s inherit_errexit 2>/dev/null || true

# cron and systemd start with a near-empty environment. Keep the script
# self-contained rather than depending on the caller's PATH.
PATH="${PATH:-}:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export PATH

readonly SCRIPT_NAME='APT lock doctor'
readonly SCRIPT_VERSION='2.0'

# --- Exit codes --------------------------------------------------------------
# Shared by every script in this repository. 75 is EX_TEMPFAIL from sysexits.h,
# which cron and systemd read as "retry later" rather than a real fault -- which
# is exactly what "a package manager is busy right now" means.
readonly EX_OK=0 EX_FAIL=1 EX_USAGE=2 EX_PREREQ=3 EX_NOROOT=4
readonly EX_NOCONFIRM=5 EX_LOCKED=75 EX_INTERRUPT=130

# --- Tunables (env overridable, then flag overridable) -----------------------
LOCK_PATHS_SPEC="${LZC_FIX_APT_LOCK_PATHS:-/var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/lib/apt/lists/lock /var/cache/apt/archives/lock}"
PROC_LOCKS="${LZC_FIX_APT_LOCK_PROC_LOCKS:-/proc/locks}"
SELF_LOCK="${LZC_FIX_APT_LOCK_SELF_LOCK:-/run/lock/lzc-fix-apt-lock.lock}"
DPKG_UPDATES_DIR="${LZC_FIX_APT_LOCK_DPKG_UPDATES:-/var/lib/dpkg/updates}"
WAIT_SECONDS="${LZC_FIX_APT_LOCK_WAIT:-0}"
POLL_SECONDS="${LZC_FIX_APT_LOCK_POLL:-5}"
PROBE_TIMEOUT="${LZC_FIX_APT_LOCK_PROBE_TIMEOUT:-10}"
REPAIR_TIMEOUT="${LZC_FIX_APT_LOCK_REPAIR_TIMEOUT:-900}"
CMDLINE_MAX="${LZC_FIX_APT_LOCK_CMDLINE_MAX:-160}"
ASSUME_YES="${LZC_FIX_APT_LOCK_YES:-0}"
DO_REPAIR="${LZC_FIX_APT_LOCK_REPAIR:-1}"
DRY_RUN="${LZC_FIX_APT_LOCK_DRY_RUN:-0}"
USE_COLOR="${LZC_FIX_APT_LOCK_COLOR:-auto}"

# --- Paths this script must never remove -------------------------------------
# Deliberately NOT configurable. LZC_FIX_APT_LOCK_PATHS lets an operator point
# the scanner at extra lock files; it must never become a way to aim `rm` at the
# package database. Every one of these is either the dpkg database itself or
# in-flight transaction state, and losing any of them is unrecoverable without a
# restore from /var/backups.
readonly -a NEVER_REMOVE=(
    /var/lib/dpkg/status
    /var/lib/dpkg/status-old
    /var/lib/dpkg/available
    /var/lib/dpkg/diversions
    /var/lib/dpkg/statoverride
)
readonly -a NEVER_REMOVE_PREFIX=(
    /var/lib/dpkg/info/
    /var/lib/dpkg/updates/
    /var/lib/dpkg/triggers/
    /var/backups/
)
# An allow-list of basenames is the stronger half of the guard: a deny-list has
# to anticipate every file worth protecting, whereas this refuses everything
# that is not shaped like a lock file in the first place.
readonly -a REMOVABLE_BASENAMES=(
    lock
    lock-frontend
    '*.lock'
)

# --- Runtime state -----------------------------------------------------------
declare -a PATHS=()
declare -a STALE=()
declare -A STATE=()
declare -A DETAIL=()
declare -a BUSY_REASONS=()
LOCK_FD=-1
CHANGED=0
YW='' BL='' RD='' GN='' CL=''

# --- Output ------------------------------------------------------------------

setup_color() {
    # NO_COLOR is honoured per no-color.org: any non-empty value disables
    # colour. It is consulted only under 'auto', so an explicit --color always
    # still wins -- an operator asking for colour outright gets it.
    if [[ $USE_COLOR == never ]] ||
        { [[ $USE_COLOR == auto ]] && { [[ -n ${NO_COLOR:-} ]] || [[ ! -t 1 ]]; }; }; then
        return 0
    fi
    YW=$'\033[33m' BL=$'\033[36m' RD=$'\033[01;31m' GN=$'\033[1;92m' CL=$'\033[m'
    return 0
}

# Human-facing narration goes to stderr so that stdout stays parseable; the
# state report is the script's actual output and goes to stdout.
log() {
    local level=$1
    shift
    case $level in
        ERROR) printf '%s[Error]%s %s\n' "$RD" "$CL" "$*" >&2 ;;
        WARN) printf '%s[Warning]%s %s\n' "$YW" "$CL" "$*" >&2 ;;
        INFO) printf '%s[Info]%s %s\n' "$BL" "$CL" "$*" >&2 ;;
        SUCCESS) printf '%s[OK]%s %s\n' "$GN" "$CL" "$*" >&2 ;;
        *) printf '%s\n' "$*" >&2 ;;
    esac
    return 0
}

die() {
    local code=$1
    shift
    log ERROR "$*"
    exit "$code"
}

usage() {
    cat <<EOF
$SCRIPT_NAME v$SCRIPT_VERSION

Diagnoses a stuck "Could not get lock /var/lib/dpkg/lock-frontend" and clears
the lock only when no process holds it.

WHY THIS IS NOT A ONE-LINE 'rm': the dpkg and APT lock files are zero-byte
advisory lock targets. Deleting one while a package manager holds it does not
stop that package manager -- it lets a second one start alongside it, and two
concurrent dpkg processes are what corrupt /var/lib/dpkg. This script therefore
identifies the process holding each lock and refuses to remove anything while
one is alive.

Usage:
  fix_apt_lock.sh [options]

Options:
  -n, --dry-run           Report the state and the plan; change nothing.
  -y, --yes               Run unattended; skip the confirmation prompt.
  -w, --wait SECONDS      If a lock is held, wait up to this long for it to be
                          released instead of giving up (default: $WAIT_SECONDS).
                          0 means do not wait.
      --no-repair         Do not run 'dpkg --configure -a' after clearing.
      --path PATH         Additional lock file to inspect. Repeatable.
      --timeout SECONDS   Time limit for the 'dpkg --configure -a' repair step,
                          and nothing else (default: $REPAIR_TIMEOUT). Minimum 1:
                          'timeout 0' means no limit at all.
      --color WHEN        auto | always | never (default: auto).
  -V, --version           Print version and exit.
  -h, --help              Print this help and exit.

Every option also has an environment variable, which is the easier route when
piping this script in from the network. Booleans accept 1/true/yes/on and
0/false/no/off, case-insensitively; anything else is a usage error. Numbers must
be whole; the value in brackets is what this run would use.

  LZC_FIX_APT_LOCK_YES             bool: skip the confirmation prompt [$ASSUME_YES]
  LZC_FIX_APT_LOCK_DRY_RUN         bool: report only, change nothing [$DRY_RUN]
  LZC_FIX_APT_LOCK_REPAIR          bool: run 'dpkg --configure -a' after
                                   clearing [$DO_REPAIR]
  LZC_FIX_APT_LOCK_WAIT            seconds to wait for a held lock, 0 to not
                                   wait at all [$WAIT_SECONDS]
  LZC_FIX_APT_LOCK_POLL            seconds between --wait polls, min 1 [$POLL_SECONDS]
  LZC_FIX_APT_LOCK_REPAIR_TIMEOUT  bounds 'dpkg --configure -a', min 1 [$REPAIR_TIMEOUT]
  LZC_FIX_APT_LOCK_PROBE_TIMEOUT   bounds each fuser, lsof and systemctl
                                   probe, min 1 [$PROBE_TIMEOUT]
  LZC_FIX_APT_LOCK_CMDLINE_MAX     characters of a holder's command line to
                                   print, min 1 [$CMDLINE_MAX]
  LZC_FIX_APT_LOCK_COLOR           auto | always | never [$USE_COLOR]
  LZC_FIX_APT_LOCK_PATHS           whitespace-separated lock files to inspect
  LZC_FIX_APT_LOCK_SELF_LOCK       this script's own lock file [$SELF_LOCK]
  LZC_FIX_APT_LOCK_DPKG_UPDATES    dpkg journal directory to report on [$DPKG_UPDATES_DIR]
  LZC_FIX_APT_LOCK_PROC_LOCKS      kernel lock table to read [$PROC_LOCKS]

Colour: NO_COLOR (any non-empty value) disables it, as does --color never.
Colour is emitted only when stdout is a terminal unless --color always is given.

Blast radius:
  With --yes (or an answered prompt) this script can do exactly two things:
    1. delete lock files that no process holds or has open, from this list --
       ${LOCK_PATHS_SPEC}
       Recreated automatically by apt/dpkg. Deleting an unheld lock is a no-op
       for root; it is included because the situation this script diagnoses is
       usually misdiagnosed as needing it.
    2. run 'dpkg --configure -a', which finishes any package installation that
       was interrupted. That runs maintainer scripts and can restart services.
       Skip it with --no-repair.
  It never removes a held lock, never installs or removes a package, never runs
  'apt-get update', and never touches /var/lib/dpkg/status, /var/lib/dpkg/info/
  or /var/lib/dpkg/updates/.

Exit status:
  0    success -- nothing needed changing, or every change succeeded
  1    the work ran but something in it failed: a removal was refused or the
       repair step failed
  2    usage error (unknown flag, missing or invalid argument value)
  3    unsupported platform or a missing prerequisite tool
  4    must be run as root
  5    refused: confirmation was needed, but there is no TTY and --yes was not
       given -- nothing was changed
  75   temporary failure, retry later (EX_TEMPFAIL): a package manager is
       running, another copy of this script holds $SELF_LOCK,
       or a lock's state could not be determined -- nothing was changed
  130  interrupted (SIGINT/SIGTERM)

75 is the interesting one for monitoring: the machine is busy, not broken, and
cron and systemd both read it as "retry later". The exception is a lock path
that is a symlink or not a regular file -- that is also 75 and will not clear on
a retry, so look at the report before wiring a retry loop around it.

For unattended automation, do not schedule this script. Tell apt to wait
instead:  apt-get -o DPkg::Lock::Timeout=600 upgrade
EOF
    return 0
}

# --- Argument parsing --------------------------------------------------------

parse_args() {
    while (($#)); do
        case $1 in
            -n | --dry-run) DRY_RUN=1 ;;
            -y | --yes) ASSUME_YES=1 ;;
            -w | --wait)
                [[ $# -ge 2 ]] || die "$EX_USAGE" "--wait requires a value in seconds"
                WAIT_SECONDS=$2
                shift
                ;;
            --no-repair) DO_REPAIR=0 ;;
            --path)
                [[ $# -ge 2 ]] || die "$EX_USAGE" "--path requires a file path"
                LOCK_PATHS_SPEC="$LOCK_PATHS_SPEC $2"
                shift
                ;;
            --timeout)
                [[ $# -ge 2 ]] || die "$EX_USAGE" "--timeout requires a value in seconds"
                REPAIR_TIMEOUT=$2
                shift
                ;;
            --color)
                [[ $# -ge 2 ]] || die "$EX_USAGE" "--color requires auto, always or never"
                USE_COLOR=$2
                shift
                ;;
            -V | --version)
                printf '%s v%s\n' "$SCRIPT_NAME" "$SCRIPT_VERSION"
                exit "$EX_OK"
                ;;
            -h | --help)
                usage
                exit "$EX_OK"
                ;;
            --)
                shift
                continue
                ;;
            *) die "$EX_USAGE" "Unknown option: $1 (try --help)" ;;
        esac
        shift
    done

    [[ $USE_COLOR =~ ^(auto|always|never)$ ]] ||
        die "$EX_USAGE" "--color must be auto, always or never"

    # Booleans first: every one of these reaches an arithmetic context below, and
    # a bare word there is fatal under 'set -u'. The label is the name the
    # operator actually typed, not the internal variable.
    _normalise_bool ASSUME_YES LZC_FIX_APT_LOCK_YES
    _normalise_bool DO_REPAIR LZC_FIX_APT_LOCK_REPAIR
    _normalise_bool DRY_RUN LZC_FIX_APT_LOCK_DRY_RUN

    # GNU timeout treats a duration of 0 as "no timeout at all". Accepting 0 for
    # a timeout would silently remove the guard instead of tightening it, and a
    # hung 'fuser' on a stale NFS mount or a wedged 'dpkg --configure -a' would
    # then block forever. WAIT_SECONDS is the exception: 0 there legitimately
    # means "do not wait".
    _normalise_int REPAIR_TIMEOUT 1 '--timeout / LZC_FIX_APT_LOCK_REPAIR_TIMEOUT'
    _normalise_int PROBE_TIMEOUT 1 LZC_FIX_APT_LOCK_PROBE_TIMEOUT
    _normalise_int POLL_SECONDS 1 LZC_FIX_APT_LOCK_POLL
    _normalise_int CMDLINE_MAX 1 LZC_FIX_APT_LOCK_CMDLINE_MAX
    _normalise_int WAIT_SECONDS 0 '--wait / LZC_FIX_APT_LOCK_WAIT'
    return 0
}

# Accepts the spellings people actually write in cron files and unit files.
# Without this, LZC_FIX_APT_LOCK_YES=true reaches (( )) as a bare word and the
# script dies with "true: unbound variable" before doing anything.
_normalise_bool() {
    local name=$1 label=$2 value
    case ${!name,,} in
        1 | true | yes | on) value=1 ;;
        0 | false | no | off | '') value=0 ;;
        *) die "$EX_USAGE" "$label must be one of 1/true/yes/on or 0/false/no/off, got '${!name}'" ;;
    esac
    printf -v "$name" '%s' "$value"
}

_normalise_int() {
    local name=$1 min=$2 label=$3 value
    [[ ${!name} =~ ^[0-9]+$ ]] ||
        die "$EX_USAGE" "$label must be a whole number, got '${!name}'"
    # 10# forces base ten: a zero-padded value such as 08 is otherwise read as
    # an invalid octal literal and aborts the arithmetic.
    value=$((10#${!name}))
    ((value >= min)) ||
        die "$EX_USAGE" "$label must be at least $min, got '${!name}'"
    printf -v "$name" '%s' "$value"
}

# --- Preflight ---------------------------------------------------------------

# Resolves the configured lock paths, dropping duplicates. /var/run is a symlink
# to /run on any current system, so the same file can easily be named twice.
#
# Only the DIRECTORY is canonicalised. Resolving the final component too (plain
# `readlink -f` on the whole path) would silently follow a symlinked lock file
# to wherever it points and aim the later `rm` at the target instead -- and it
# would defeat the symlink check in scan_path, because by then the path would no
# longer look like a symlink.
resolve_paths() {
    local raw token dir base canonical seen=''
    # Deliberate word splitting: the spec is a whitespace-separated path list.
    # shellcheck disable=SC2206 # splitting on whitespace is the documented format
    raw=($LOCK_PATHS_SPEC)
    for token in ${raw[@]+"${raw[@]}"}; do
        [[ -n $token ]] || continue
        [[ $token == /* ]] || die "$EX_USAGE" "Lock paths must be absolute: '$token'"
        dir=$(dirname -- "$token")
        base=$(basename -- "$token")
        canonical=$(readlink -f -- "$dir" 2>/dev/null) || canonical=$dir
        [[ -n $canonical ]] || canonical=$dir
        canonical="${canonical%/}/$base"
        case $seen in
            *"|$canonical|"*) continue ;;
        esac
        seen="$seen|$canonical|"
        PATHS+=("$canonical")
    done
    ((${#PATHS[@]})) || die "$EX_USAGE" "No lock paths to inspect"
    return 0
}

preflight() {
    [[ $EUID -eq 0 ]] || die "$EX_NOROOT" "This script must be run as root (try: sudo $0)"
    [[ -r $PROC_LOCKS ]] ||
        die "$EX_PREREQ" "Cannot read $PROC_LOCKS. This script needs Linux procfs to tell a held lock from a stale one; it will not guess."
    command -v dpkg >/dev/null 2>&1 ||
        die "$EX_PREREQ" "dpkg not found. This script is for Debian/Ubuntu systems."
    command -v timeout >/dev/null 2>&1 || die "$EX_PREREQ" "timeout (coreutils) not found."
    command -v stat >/dev/null 2>&1 || die "$EX_PREREQ" "stat (coreutils) not found."
    command -v awk >/dev/null 2>&1 || die "$EX_PREREQ" "awk not found."
    # Required, not optional: without it two copies of this script can race each
    # other towards the same `rm`, and there is no safe way to continue without
    # the guard. flock ships in util-linux, which is essential on every system
    # this script supports.
    command -v flock >/dev/null 2>&1 || die "$EX_PREREQ" "flock (util-linux) not found."
    return 0
}

# Guards against two copies of this script racing each other towards the same
# `rm`. The lock file is never deleted: the kernel releases it when the fd
# closes, and unlinking it would let a second run lock a different inode.
acquire_self_lock() {
    mkdir -p -- "$(dirname -- "$SELF_LOCK")" 2>/dev/null || true
    exec {LOCK_FD}>"$SELF_LOCK" || die "$EX_LOCKED" "Cannot open lock file $SELF_LOCK"
    flock -n "$LOCK_FD" ||
        die "$EX_LOCKED" "Another $SCRIPT_NAME run holds $SELF_LOCK. Refusing to run concurrently."
    return 0
}

release_self_lock() {
    ((LOCK_FD >= 0)) || return 0
    exec {LOCK_FD}>&- || true
    LOCK_FD=-1
    return 0
}

# --- Holder detection --------------------------------------------------------

# Describes a PID from procfs. Returns 1 if the process has already gone.
describe_pid() {
    local pid=$1 comm='' cmdline='' etime=''
    [[ $pid =~ ^[0-9]+$ ]] || {
        printf 'unidentified owner (open file description lock)'
        return 0
    }
    [[ -d /proc/$pid ]] || return 1
    if [[ -r /proc/$pid/comm ]]; then
        read -r comm </proc/"$pid"/comm || comm=''
    fi
    if [[ -r /proc/$pid/cmdline ]]; then
        # A command line is NUL-separated and may legitimately contain newlines
        # and tabs (a maintainer script invoked with an embedded here-doc, for
        # one). Flatten every one of them: this string goes into an indented
        # report, and a stray newline there would misalign the whole table and
        # could be used to fake a second entry.
        cmdline=$(tr '\0\n\r\t' '    ' </proc/"$pid"/cmdline) || cmdline=''
    fi
    if command -v ps >/dev/null 2>&1; then
        etime=$(ps -o etime= -p "$pid" 2>/dev/null) || etime=''
    fi
    # Trim the surrounding whitespace ps and cmdline leave behind.
    etime=${etime## } etime=${etime%% }
    cmdline=${cmdline%% }
    if ((${#cmdline} > CMDLINE_MAX)); then
        cmdline="${cmdline:0:CMDLINE_MAX}..."
    fi

    printf 'pid %s' "$pid"
    [[ -n $comm ]] && printf ' (%s)' "$comm"
    [[ -n $etime ]] && printf ' running %s' "$etime"
    [[ -n $cmdline ]] && printf ' -- %s' "$cmdline"
    return 0
}

# PIDs with a lock record over the given inode, one "pid holding|waiting" per
# line.
#
# /proc/locks lines look like:
#   1: POSIX  ADVISORY  WRITE 3376 08:02:1442316 0 EOF
#   1: -> POSIX  ADVISORY  WRITE 3402 08:02:1442316 0 EOF   (a blocked waiter)
#
# The kernel prints the device as %02x:%02x and the inode in decimal. The inode
# is matched on its own because the st_dev -> major:minor mapping is not
# reversible for every filesystem: btrfs, ZFS and overlayfs use anonymous
# devices whose minor number can exceed 255, where the encoding stops being a
# plain major*256+minor. Matching the inode alone can only ever over-report, and
# over-reporting refuses a removal -- the safe direction. Under-reporting would
# permit one, which is the direction that corrupts a package database.
#
# Exits non-zero if the lock table could not be read. The caller MUST treat that
# as "state unknown" rather than "no records found": returning 0 unconditionally
# here would turn a failed check into a clean bill of health and let the removal
# proceed, which is the one direction this script must never fail in.
locks_for_inode() {
    local inode=$1
    awk -v want="$inode" '
        {
            if ($2 == "->") { pid = $6; dev = $7; kind = "waiting" }
            else            { pid = $5; dev = $6; kind = "holding" }
            n = split(dev, part, ":")
            if (n >= 3 && part[n] == want) printf "%s %s\n", pid, kind
        }
    ' "$PROC_LOCKS"
}

# Corroboration only. fuser and lsof report processes with the file OPEN, which
# is a superset of the processes that have it LOCKED -- an open descriptor
# without a lock does not block apt. They are consulted because they are the
# tools an operator will reach for, and because a second opinion that disagrees
# with /proc/locks is worth printing. Neither is required to be installed.
openers_via_fuser() {
    local path=$1 out rc=0
    command -v fuser >/dev/null 2>&1 || return 1
    out=$(timeout "$PROBE_TIMEOUT" fuser -- "$path" 2>/dev/null) || rc=$?
    # fuser exits 1 when nothing has the file open, and >=124 when the timeout
    # fired. Only the latter means "we do not know".
    ((rc >= 124)) && return 1
    printf '%s\n' "$out"
    return 0
}

openers_via_lsof() {
    local path=$1 out rc=0
    command -v lsof >/dev/null 2>&1 || return 1
    out=$(timeout "$PROBE_TIMEOUT" lsof -t -- "$path" 2>/dev/null) || rc=$?
    ((rc >= 124)) && return 1
    printf '%s\n' "$out"
    return 0
}

# Inspects one lock file and records its state in STATE[]/DETAIL[].
#
# States: absent | free | locked | open | unsafe | unknown
# Everything except "absent" and "free" blocks removal.
scan_path() {
    local path=$1
    local inode='' dev='' line pid kind desc records='' found=0
    local -a notes=()

    # -L is tested before -e on purpose: -e follows the link, so a lock path that
    # is a symlink to something that does not exist would otherwise be reported
    # as "absent" while the symlink itself is sitting there blocking apt.
    if [[ -L $path ]]; then
        STATE["$path"]=unsafe
        DETAIL["$path"]='a symlink, not a lock file -- refusing to touch it'
        return 0
    fi

    if [[ ! -e $path ]]; then
        STATE["$path"]=absent
        DETAIL["$path"]=''
        return 0
    fi

    if [[ ! -f $path ]]; then
        STATE["$path"]=unsafe
        DETAIL["$path"]='not a regular file (directory, device or socket) -- refusing to touch it'
        return 0
    fi

    inode=$(stat -c '%i' -- "$path" 2>/dev/null) || inode=''
    dev=$(stat -c '%D' -- "$path" 2>/dev/null) || dev=''
    if [[ -z $inode ]]; then
        STATE["$path"]=unknown
        DETAIL["$path"]='cannot stat the file, so its lock state is unknown'
        return 0
    fi

    # Read the lock table through a variable rather than a process substitution:
    # a process substitution discards the producer's exit status, so a failed
    # read would be indistinguishable from "this file has no lock records".
    if ! records=$(locks_for_inode "$inode"); then
        STATE["$path"]=unknown
        DETAIL["$path"]="could not read lock records from $PROC_LOCKS, so the lock state is unknown"
        return 0
    fi

    while IFS= read -r line; do
        [[ -n $line ]] || continue
        pid=${line%% *}
        kind=${line##* }
        if desc=$(describe_pid "$pid"); then
            notes+=("$kind: $desc")
        else
            notes+=("$kind: pid $pid (process has since exited)")
        fi
        found=1
    done <<<"$records"

    local opener out
    for opener in openers_via_fuser openers_via_lsof; do
        if out=$("$opener" "$path"); then
            for pid in $out; do
                [[ $pid =~ ^[0-9]+$ ]] || continue
                if desc=$(describe_pid "$pid"); then
                    notes+=("has it open: $desc")
                    found=1
                fi
            done
        fi
    done

    if ((found)); then
        STATE["$path"]=locked
        DETAIL["$path"]=$(printf '%s\n' "${notes[@]}")
    else
        STATE["$path"]=free
        DETAIL["$path"]="no lock record in $PROC_LOCKS (device $dev, inode $inode)"
    fi
    return 0
}

# Package-manager processes anywhere on the system, whether or not they are
# currently holding one of the files above. dpkg releases and re-takes locks
# between stages of a transaction, so "no lock right now" is not the same as
# "no transaction in flight". comm is truncated to 15 characters by the kernel,
# hence the abbreviated patterns.
package_manager_processes() {
    local dir pid comm
    for dir in /proc/[0-9]*; do
        [[ -d $dir ]] || continue
        pid=${dir#/proc/}
        [[ $pid == "$$" ]] && continue
        [[ -r $dir/comm ]] || continue
        read -r comm <"$dir/comm" || continue
        case $comm in
            apt | apt-get | apt-config | aptitude | dpkg | dpkg-deb | dpkg-split | \
                unattended-upgr | synaptic | apt.systemd.dai | apt-key | debconf)
                printf '%s %s\n' "$pid" "$comm"
                ;;
        esac
    done
    return 0
}

# Advisory only: these units are the usual reason a lock is held on a machine
# nobody is logged into.
active_apt_units() {
    local unit
    command -v systemctl >/dev/null 2>&1 || return 0
    for unit in apt-daily.service apt-daily-upgrade.service unattended-upgrades.service packagekit.service; do
        if timeout "$PROBE_TIMEOUT" systemctl is-active --quiet "$unit" 2>/dev/null; then
            printf '%s\n' "$unit"
        fi
    done
    return 0
}

# --- Assessment --------------------------------------------------------------

# Fills STATE/DETAIL for every path and BUSY_REASONS for the system as a whole.
assess() {
    local path line
    BUSY_REASONS=()
    STALE=()

    for path in "${PATHS[@]}"; do
        scan_path "$path"
    done

    for path in "${PATHS[@]}"; do
        case ${STATE["$path"]} in
            free) STALE+=("$path") ;;
            absent) ;;
            *) BUSY_REASONS+=("${STATE["$path"]} lock: $path") ;;
        esac
    done

    while IFS= read -r line; do
        [[ -n $line ]] || continue
        BUSY_REASONS+=("package manager running: $line")
    done < <(package_manager_processes)

    while IFS= read -r line; do
        [[ -n $line ]] || continue
        BUSY_REASONS+=("systemd unit active: $line")
    done < <(active_apt_units)
    return 0
}

report() {
    local path state detail line

    printf 'Lock state:\n'
    for path in "${PATHS[@]}"; do
        state=${STATE["$path"]}
        detail=${DETAIL["$path"]}
        printf '  %-38s %s\n' "$path" "$state"
        if [[ -n $detail ]]; then
            # Fixed indent rather than a second padded column: lock paths are
            # long enough to overflow the column and misalign every detail line.
            while IFS= read -r line; do
                [[ -n $line ]] || continue
                printf '      %s\n' "$line"
            done <<<"$detail"
        fi
    done

    if [[ -d $DPKG_UPDATES_DIR ]]; then
        local pending
        pending=$(find "$DPKG_UPDATES_DIR" -maxdepth 1 -type f -printf '.' 2>/dev/null) || pending=''
        if [[ -n $pending ]]; then
            printf '\n  %s holds %d journal file(s): a dpkg transaction was interrupted.\n' \
                "$DPKG_UPDATES_DIR" "${#pending}"
            printf "  'dpkg --configure -a' replays it. Do not delete those files.\n"
        fi
    fi
    printf '\n'
    return 0
}

# Waits for every busy lock to be released. Returns 0 when the system went
# quiet, 1 when the deadline passed.
wait_for_release() {
    local deadline=$((SECONDS + WAIT_SECONDS))
    log INFO "Waiting up to ${WAIT_SECONDS}s for the package manager to finish"
    while ((SECONDS < deadline)); do
        sleep "$POLL_SECONDS"
        assess
        if ((${#BUSY_REASONS[@]} == 0)); then
            log SUCCESS "Locks released after ${SECONDS}s"
            return 0
        fi
    done
    return 1
}

# --- Actions -----------------------------------------------------------------

confirm() {
    local prompt=$1 reply src
    ((ASSUME_YES)) && return 0

    src=''
    if [[ -t 0 ]]; then
        src=/dev/stdin
    elif [[ -t 1 && -e /dev/tty ]]; then
        # Piped in from the network: stdin is the script text, so a prompt has
        # to come from the terminal directly or it would eat the script.
        src=/dev/tty
    fi
    if [[ -z $src ]]; then
        log ERROR "No terminal available and --yes was not given. Nothing was changed."
        return 1
    fi

    read -r -p "$prompt [y/N] " reply <"$src" || return 1
    [[ ${reply,,} == y* ]]
}

# The last gate before an unlink. Re-runs detection on this one path so the
# window between the report and the removal is as small as it can be made from
# a shell, and refuses outright for anything on the never-remove list.
safe_to_remove() {
    local path=$1 protected prefix pattern base allowed=0

    base=${path##*/}
    for pattern in "${REMOVABLE_BASENAMES[@]}"; do
        # shellcheck disable=SC2053 # the right-hand side is a glob on purpose
        if [[ $base == $pattern ]]; then
            allowed=1
            break
        fi
    done
    if ((!allowed)); then
        log ERROR "Refusing to remove $path: '$base' is not the name of a dpkg or APT lock file."
        return 1
    fi

    for protected in "${NEVER_REMOVE[@]}"; do
        if [[ $path == "$protected" ]]; then
            log ERROR "Refusing to remove $path: that is the dpkg database, not a lock."
            return 1
        fi
    done
    for prefix in "${NEVER_REMOVE_PREFIX[@]}"; do
        if [[ $path == "$prefix"* ]]; then
            log ERROR "Refusing to remove $path: everything under $prefix is dpkg state, not a lock."
            return 1
        fi
    done

    scan_path "$path"
    if [[ ${STATE["$path"]} != free ]]; then
        log ERROR "$path changed state to '${STATE["$path"]}' while this script was running. Nothing removed."
        return 1
    fi
    return 0
}

remove_stale_locks() {
    local path rc=0
    # Guard the expansion below: on bash < 4.4, "${STALE[@]}" on an empty array
    # is an unbound-variable error under `set -u`. STALE is legitimately empty
    # whenever there is nothing to clear but the repair step still has to run.
    ((${#STALE[@]})) || return 0
    for path in "${STALE[@]}"; do
        if ((DRY_RUN)); then
            log INFO "[dry-run] Would remove stale lock $path"
            continue
        fi
        if ! safe_to_remove "$path"; then
            rc=1
            continue
        fi
        if rm -f -- "$path"; then
            log SUCCESS "Removed stale lock $path"
            CHANGED=1
        else
            log ERROR "Could not remove $path"
            rc=1
        fi
    done
    return "$rc"
}

# 'dpkg --configure -a' is the documented repair for the state that usually
# produces a stuck lock: a transaction that was interrupted part way through.
# It is the step that actually fixes the machine; removing the lock file only
# clears the symptom.
run_repair() {
    local -a cmd=(dpkg --configure -a)
    local rc=0

    if ((DRY_RUN)); then
        log INFO "[dry-run] Would run: ${cmd[*]}"
        return 0
    fi

    # Unattended runs must not stop on a conffile prompt they cannot answer.
    # Interactive runs keep dpkg's normal prompting, because silently choosing
    # for the operator is not this script's job.
    if ((ASSUME_YES)) || [[ ! -t 0 ]]; then
        export DEBIAN_FRONTEND=noninteractive
        cmd+=(--force-confdef --force-confold)
    fi

    log INFO "Running: ${cmd[*]}"
    # An ignored signal disposition survives execve, so dpkg and every
    # maintainer script it runs inherit it. Without this, losing an SSH session
    # sends SIGHUP to the whole foreground process group and kills dpkg
    # mid-transaction -- exactly the damage this script exists to avoid.
    trap '' HUP
    timeout --foreground "$REPAIR_TIMEOUT" "${cmd[@]}" || rc=$?
    trap - HUP

    if ((rc == 0)); then
        CHANGED=1
        log SUCCESS "dpkg --configure -a completed"
        return 0
    fi
    if ((rc == 124)); then
        log ERROR "dpkg --configure -a timed out after ${REPAIR_TIMEOUT}s. It may still be mid-transaction; check with 'dpkg --audit' before doing anything else."
    else
        log ERROR "dpkg --configure -a exited $rc. Read the output above; do not re-run this script in a loop."
    fi
    return 1
}

# --- Lifecycle ---------------------------------------------------------------

on_exit() {
    local rc=$?
    trap - EXIT INT TERM
    release_self_lock
    exit "$rc"
}

on_signal() {
    log WARN "Interrupted -- nothing further will be changed"
    exit "$EX_INTERRUPT"
}

on_err() {
    log ERROR "Unexpected failure at line $1: '$2' (status $3)"
    return 0
}

# --- Main --------------------------------------------------------------------

main() {
    parse_args "$@"
    setup_color
    preflight
    resolve_paths
    acquire_self_lock

    trap on_exit EXIT
    trap on_signal INT TERM
    trap 'on_err "$LINENO" "$BASH_COMMAND" "$?"' ERR

    assess
    report

    if ((${#BUSY_REASONS[@]})); then
        local reason
        log WARN "A package manager is active. Removing a lock now would let a second one start alongside it, which is what corrupts /var/lib/dpkg."
        for reason in "${BUSY_REASONS[@]}"; do
            printf '  %s\n' "$reason" >&2
        done

        if ((WAIT_SECONDS > 0)) && wait_for_release; then
            report
        else
            printf '\n' >&2
            log ERROR "Nothing was changed. Wait for the run above to finish."
            log INFO "To make apt wait for the lock instead of failing:  apt-get -o DPkg::Lock::Timeout=600 upgrade"
            log INFO "If the holder is a dead session rather than live work, end it deliberately: 'fuser -k -TERM /var/lib/dpkg/lock-frontend', then re-run this script. Never SIGKILL a running dpkg."
            return "$EX_LOCKED"
        fi
    fi

    local -a plan=()
    ((${#STALE[@]})) && plan+=("remove ${#STALE[@]} stale lock file(s)")
    ((DO_REPAIR)) && plan+=("run 'dpkg --configure -a'")

    if ((${#plan[@]} == 0)); then
        log SUCCESS "No lock is held and there is nothing to clean up."
        return "$EX_OK"
    fi

    # One item per line: "${plan[*]}" joins on IFS and runs the steps together.
    local step
    log INFO "Plan:"
    for step in "${plan[@]}"; do
        log '' "  - $step"
    done
    if ((DRY_RUN)); then
        log INFO "Dry run: nothing will be changed."
    else
        if ! confirm "Proceed?"; then
            log INFO "Declined. Nothing was changed."
            return "$EX_NOCONFIRM"
        fi
        # The prompt above can sit unanswered for minutes, and the per-file
        # re-check in safe_to_remove only looks at that file's lock records.
        # dpkg releases and re-takes its locks between transaction stages, so a
        # package manager that started while the operator was deciding can hold
        # no lock at this instant and would otherwise slip straight through to
        # the unlink. Re-run the whole assessment, process check included.
        assess
        if ((${#BUSY_REASONS[@]})); then
            local late
            log ERROR "A package manager started while this script was waiting. Nothing was changed."
            for late in "${BUSY_REASONS[@]}"; do
                printf '  %s\n' "$late" >&2
            done
            return "$EX_LOCKED"
        fi
    fi

    local rc="$EX_OK"
    remove_stale_locks || rc="$EX_FAIL"
    if ((DO_REPAIR)); then
        run_repair || rc="$EX_FAIL"
    fi

    if ((DRY_RUN)); then
        log INFO "Dry run finished; nothing was changed."
    elif ((CHANGED)); then
        log SUCCESS "Done. Verify with: apt-get check"
    fi
    return "$rc"
}

main "$@"
