#!/usr/bin/env bash
#
# Debian/Ubuntu package-database repair.
#
# Diagnoses an interrupted or broken dpkg/APT state, runs the standard recovery
# sequence in the order dpkg and apt actually require, and then verifies the
# result instead of assuming it. Reports what is still broken and what to try
# next.
#
# License: MIT
# Origin:  https://github.com/Lazarev-Cloud/Scripts
#
# Error model: this script uses `set -uo pipefail` and deliberately NOT `set -e`.
# A repair step that fails is information, not a reason to stop: `dpkg --configure
# -a` can fail on one package and still leave `apt-get --fix-broken install` able
# to finish the job. Every step is checked explicitly, and the verdict at the end
# comes from re-inspecting the system, never from the exit status of the repair.
# Do not add `set -e`, and do not call this script as `fix_broken_packages.sh ||
# true`.
set -uo pipefail

readonly SCRIPT_NAME='Debian/Ubuntu Package Repair'
readonly SCRIPT_VERSION='2.0'

# --- Tunables (env overridable, then flag overridable) -----------------------
#
# Every user-facing variable is LZC_FIX_BROKEN_PACKAGES_*, so `env | grep LZC_`
# shows everything that can be configured here and in every other script in this
# repository. Internal names below are shell locals and are not an interface.
LOG_FILE="${LZC_FIX_BROKEN_PACKAGES_LOG:-/var/log/apt-repair.log}"
LOG_MAX_BYTES="${LZC_FIX_BROKEN_PACKAGES_LOG_MAX_BYTES:-5242880}"
LOCK_FILE="${LZC_FIX_BROKEN_PACKAGES_LOCK:-/run/lock/lzc-fix_broken_packages.lock}"
DPKG_LOCK_TIMEOUT="${LZC_FIX_BROKEN_PACKAGES_DPKG_LOCK_TIMEOUT:-600}"
ACQUIRE_RETRIES="${LZC_FIX_BROKEN_PACKAGES_ACQUIRE_RETRIES:-3}"
LISTCHANGES_FRONTEND="${LZC_FIX_BROKEN_PACKAGES_LISTCHANGES_FRONTEND:-none}"
CONFIGURE_TIMEOUT="${LZC_FIX_BROKEN_PACKAGES_CONFIGURE_TIMEOUT:-1800}"
UPDATE_TIMEOUT="${LZC_FIX_BROKEN_PACKAGES_UPDATE_TIMEOUT:-600}"
FIX_TIMEOUT="${LZC_FIX_BROKEN_PACKAGES_FIX_TIMEOUT:-1800}"
PROBE_TIMEOUT="${LZC_FIX_BROKEN_PACKAGES_PROBE_TIMEOUT:-120}"
PASSES="${LZC_FIX_BROKEN_PACKAGES_PASSES:-2}"
SKIP_UPDATE="${LZC_FIX_BROKEN_PACKAGES_SKIP_UPDATE:-0}"
CONFFILE="${LZC_FIX_BROKEN_PACKAGES_CONFFILE:-old}"
FORCE="${LZC_FIX_BROKEN_PACKAGES_FORCE:-0}"
ASSUME_YES="${LZC_FIX_BROKEN_PACKAGES_YES:-0}"
DPKG_ADMIN_DIR="${LZC_FIX_BROKEN_PACKAGES_DPKG_ADMINDIR:-/var/lib/dpkg}"
LOCK_PATHS="${LZC_FIX_BROKEN_PACKAGES_LOCK_PATHS:-/var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/cache/apt/archives/lock /var/lib/apt/lists/lock}"
SAFE_PATH="${LZC_FIX_BROKEN_PACKAGES_PATH:-/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin}"
RUN_LOCALE="${LZC_FIX_BROKEN_PACKAGES_LOCALE:-C}"
DRY_RUN=0
USE_COLOR=auto

# --- Exit codes ---------------------------------------------------------------
#
# The repository-wide table. These are the only statuses this script returns;
# see --help for the operator-facing version.
readonly EX_OK=0          # success
readonly EX_BROKEN=1      # the work ran but something in it failed
readonly EX_USAGE=2       # usage error
readonly EX_UNSUPPORTED=3 # unsupported platform, or a missing prerequisite tool
readonly EX_NEEDROOT=4    # must be run as root
readonly EX_REFUSED=5     # confirmation needed, but no TTY and no --yes
readonly EX_LOCKED=75     # another instance holds the lock (EX_TEMPFAIL)
readonly EX_INTERRUPT=130 # interrupted (SIGINT/SIGTERM)

# --- Runtime state -----------------------------------------------------------
declare -a BROKEN=()
declare -a HELD=()
declare -a FAILED_STEPS=()
declare -a APT_OPTS=()
declare -a APT_WRITE_OPTS=()
JOURNAL_PENDING=0
APT_CHECK_OK=1
# Whether the probe behind each count actually ran. A failed inspection must
# never be reported as a count of zero -- see count_label().
BROKEN_KNOWN=1
HELD_KNOWN=1
JOURNAL_KNOWN=1
PASSES_RUN=0
LOG_READY=0
LOG_SINK=/dev/null
LOCK_HELD=0
YW='' BL='' RD='' GN='' CL=''

# --- Output ------------------------------------------------------------------

setup_color() {
    # NO_COLOR wins over everything, including --color always: per no-color.org
    # the variable is honoured "when present and not an empty string, regardless
    # of its value".
    [[ -n ${NO_COLOR:-} ]] && return 0
    if [[ $USE_COLOR == never ]] || { [[ $USE_COLOR == auto ]] && [[ ! -t 1 ]]; }; then
        return 0
    fi
    YW=$'\033[33m' BL=$'\033[36m' RD=$'\033[01;31m' GN=$'\033[1;92m' CL=$'\033[m'
}

log() {
    local level=$1
    shift
    local msg=$*

    if ((LOG_READY)); then
        printf '[%s] [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$msg" >>"$LOG_FILE"
    fi

    case $level in
        ERROR) printf '%s[Error]%s %s\n' "$RD" "$CL" "$msg" >&2 ;;
        WARN) printf '%s[Warning]%s %s\n' "$YW" "$CL" "$msg" >&2 ;;
        INFO) printf '%s[Info]%s %s\n' "$BL" "$CL" "$msg" ;;
        SUCCESS) printf '%s[OK]%s %s\n' "$GN" "$CL" "$msg" ;;
        *) printf '%s\n' "$msg" ;;
    esac
}

die() {
    local code=$1
    shift
    log ERROR "$*"
    exit "$code"
}

banner() {
    [[ -t 1 ]] || return 0
    printf '%s%s v%s%s\n\n' "$GN" "$SCRIPT_NAME" "$SCRIPT_VERSION" "$CL"
}

# Renders a count only when the probe behind it actually ran. A bare "0" from a
# failed inspection is indistinguishable from a "0" that means the system is
# clean, and this summary is the entire product of the run -- so an unverified
# count says so instead of quietly reading as good news.
count_label() {
    local known=$1 n=$2
    if ((known)); then
        printf '%d' "$n"
    elif ((n)); then
        printf '%d (incomplete: the check could not finish)' "$n"
    else
        printf 'unknown (the check could not run)'
    fi
}

# The yes/no counterpart of count_label(), and it exists for the same reason:
# "no" and "I could not look" are different facts, and printing the second as
# the first is how an unverified system reads as a healthy one.
yes_no_label() {
    local known=$1 yes=$2
    if ((!known)); then
        printf 'unknown (the check could not run)'
    elif ((yes)); then
        printf 'yes'
    else
        printf 'no'
    fi
}

usage() {
    cat <<EOF
$SCRIPT_NAME v$SCRIPT_VERSION

Repairs a half-finished dpkg transaction or unsatisfied dependencies on
Debian/Ubuntu, then verifies that the system is actually consistent again.

Usage:
  fix_broken_packages.sh [options]

The repair sequence, in the order it has to happen:
  1. dpkg --configure -a       finish packages that were unpacked but never
                               configured. APT refuses to do almost anything
                               while dpkg is mid-transaction, so this is first.
  2. apt-get update            refresh the indexes, so step 3 can find the
                               packages it needs to download. Skip with --no-update.
  3. apt-get --fix-broken install
                               resolve unsatisfied dependencies.
  4. dpkg --configure -a       again, for anything step 3 unpacked.
  Steps 3 and 4 repeat up to --passes times, stopping as soon as the system
  verifies clean.

Verification is a fresh inspection: 'apt-get check' plus the dpkg status of
every installed package. The exit status of the repair commands is never
treated as proof that the repair worked. If an inspection cannot run, the
result is reported as unknown and the run does NOT exit $EX_OK -- an
unverifiable system is not a repaired one.

Options:
  -y, --yes                 Run unattended; no prompts. Required with no TTY.
  -n, --dry-run             Diagnose and print the plan. Changes nothing and
                            needs no root. Exits $EX_BROKEN if the system is
                            inconsistent, so it doubles as a health check.
      --force               Run the repair even when the system verifies clean.
      --passes N            Repair passes (default: $PASSES). Minimum 1.
      --no-update           Do not run apt-get update. Use offline, or when the
                            fix needs no downloads.
      --conffile POLICY     old | new (default: $CONFFILE). 'old' keeps your
                            edited files; 'new' OVERWRITES them with the
                            package's copy.
      --lock-timeout SEC    How long APT waits for the *dpkg* lock when another
                            package tool holds it (default: $DPKG_LOCK_TIMEOUT). This is
                            apt's own DPkg::Lock::Timeout, a different mechanism
                            from the flock this script takes on its own lock
                            file. 0 means "fail at once if the lock is held".
      --timeout SEC         Wall-clock limit for a single
                            'apt-get --fix-broken install' invocation, applied
                            per repair pass (default: $FIX_TIMEOUT). Minimum 1;
                            'timeout 0' would mean no limit at all. The other
                            steps have their own timeouts, listed below.
      --log-file PATH       Log file (default: $LOG_FILE).
      --color WHEN          auto | always | never (default: auto).
  -V, --version             Print version and exit.
  -h, --help                Print this help and exit.

Blast radius:
  apt-get --fix-broken install CAN REMOVE PACKAGES. That is how it resolves a
  dependency it cannot otherwise satisfy, and on a badly broken system the set
  it removes can be large. The plan is printed before anything runs, and with a
  terminal you are asked to confirm it. Run with -n first.

  One caveat, because it matters on the case this script exists for: while dpkg
  is mid-transaction, apt refuses to simulate at all -- it answers "dpkg was
  interrupted, you must manually run 'dpkg --configure -a'". The plan is then
  empty and you are confirming step 1 unseen. Simulating after step 1 instead
  would mean running every half-configured package's maintainer scripts before
  you had agreed to anything, which is the worse trade.

  dpkg --configure -a runs the maintainer scripts of every half-configured
  package. Those scripts can restart services.

  --conffile new OVERWRITES your edited configuration files.

  This script does NOT upgrade the system (use update_upgrade.sh), does NOT
  reboot, and NEVER deletes an apt or dpkg lock file. Deleting a lock while a
  live process holds it is what lets two dpkg runs overlap and corrupt
  /var/lib/dpkg. If a lock is held, this script tells you who holds it and
  stops.

Every option also has an environment variable, which is the easier route when
piping this script in from the network. They all begin LZC_FIX_BROKEN_PACKAGES_,
so \`env | grep LZC_\` lists everything you have configured:
  LZC_FIX_BROKEN_PACKAGES_YES=1        LZC_FIX_BROKEN_PACKAGES_FORCE=1
  LZC_FIX_BROKEN_PACKAGES_PASSES=2     LZC_FIX_BROKEN_PACKAGES_SKIP_UPDATE=1
  LZC_FIX_BROKEN_PACKAGES_CONFFILE=old
  LZC_FIX_BROKEN_PACKAGES_DPKG_LOCK_TIMEOUT=600
  LZC_FIX_BROKEN_PACKAGES_ACQUIRE_RETRIES=3
  LZC_FIX_BROKEN_PACKAGES_LISTCHANGES_FRONTEND=none
  LZC_FIX_BROKEN_PACKAGES_CONFIGURE_TIMEOUT=1800
  LZC_FIX_BROKEN_PACKAGES_UPDATE_TIMEOUT=600
  LZC_FIX_BROKEN_PACKAGES_FIX_TIMEOUT=1800
  LZC_FIX_BROKEN_PACKAGES_PROBE_TIMEOUT=120
  LZC_FIX_BROKEN_PACKAGES_LOG=/var/log/apt-repair.log
  LZC_FIX_BROKEN_PACKAGES_LOG_MAX_BYTES=5242880
  LZC_FIX_BROKEN_PACKAGES_LOCK=/run/lock/lzc-fix_broken_packages.lock
  LZC_FIX_BROKEN_PACKAGES_DPKG_ADMINDIR=/var/lib/dpkg
  LZC_FIX_BROKEN_PACKAGES_LOCK_PATHS='...'
  LZC_FIX_BROKEN_PACKAGES_PATH=/usr/sbin:/usr/bin:/sbin:/bin
  LZC_FIX_BROKEN_PACKAGES_LOCALE=C

Boolean variables (YES, FORCE, SKIP_UPDATE) accept 1/true/yes/on and
0/false/no/off in any case. Anything else is a usage error, rather than a
crash halfway through the run. Numbers must be whole; a leading zero is read
as decimal, not octal.

NO_COLOR is honoured: any non-empty value disables colour, overriding
--color always.

Exit status:
  $EX_OK   the system verifies consistent (it already was, or it was repaired)
  $EX_BROKEN   the repair ran but the system is still inconsistent -- or the
      repair was declined, or only simulated with -n; details printed
  $EX_USAGE   usage error (unknown flag, missing or invalid argument value)
  $EX_UNSUPPORTED   not an APT-based system, or a required tool is missing;
      nothing was changed
  $EX_NEEDROOT   must be run as root
  $EX_REFUSED   refused: confirmation needed, but no TTY and --yes was not given
  $EX_LOCKED  temporary failure: another process holds an apt/dpkg lock, or
      another copy of this script holds its own lock file
      ($LOCK_FILE).
      Chosen so cron and systemd read it as "retry later", not a real fault.
  $EX_INTERRUPT interrupted (SIGINT/SIGTERM)
EOF
}

# --- Argument parsing --------------------------------------------------------

need_arg() {
    (($1 >= 2)) || die "$EX_USAGE" "$2 requires a value"
}

parse_args() {
    while (($#)); do
        case $1 in
            -y | --yes) ASSUME_YES=1 ;;
            -n | --dry-run) DRY_RUN=1 ;;
            --force) FORCE=1 ;;
            --no-update) SKIP_UPDATE=1 ;;
            --passes)
                need_arg $# --passes
                PASSES=$2
                shift
                ;;
            --conffile)
                need_arg $# --conffile
                CONFFILE=$2
                shift
                ;;
            --lock-timeout)
                need_arg $# --lock-timeout
                DPKG_LOCK_TIMEOUT=$2
                shift
                ;;
            --timeout)
                need_arg $# --timeout
                FIX_TIMEOUT=$2
                shift
                ;;
            --log-file)
                need_arg $# --log-file
                LOG_FILE=$2
                shift
                ;;
            --color)
                need_arg $# --color
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

    validate_args
}

# Normalises a boolean to 1 or 0 in place, accepting the spellings people
# actually type in a cron file. Without this, LZC_FIX_BROKEN_PACKAGES_YES=true
# reaches `((ASSUME_YES))`, where bash treats a bare word as a variable name and
# `set -u` aborts the script with "true: unbound variable" -- a crash, some way
# into the run, instead of a sentence saying what is wrong. $2 is the name the
# user actually typed, which is not the internal one.
normalise_flag() {
    local name=$1 label=$2 value=${!1}
    case ${value,,} in
        1 | true | yes | on) printf -v "$name" '%s' 1 ;;
        0 | false | no | off | '') printf -v "$name" '%s' 0 ;;
        *) die "$EX_USAGE" \
            "$label must be one of 1/true/yes/on or 0/false/no/off, got '$value'" ;;
    esac
}

# Validates a number and normalises it to base ten in place. The 10# matters:
# a zero-padded value such as 08 is otherwise read as an invalid octal literal
# and every later (( )) on it fails with "value too great for base".
normalise_int() {
    local name=$1 min=$2 label=$3 value=${!1}
    [[ $value =~ ^[0-9]+$ ]] ||
        die "$EX_USAGE" "$label must be a whole number, got '$value'"
    value=$((10#$value))
    ((value >= min)) ||
        die "$EX_USAGE" "$label must be at least $min, got '${!1}'"
    printf -v "$name" '%s' "$value"
}

validate_args() {
    normalise_flag ASSUME_YES '--yes (LZC_FIX_BROKEN_PACKAGES_YES)'
    normalise_flag FORCE '--force (LZC_FIX_BROKEN_PACKAGES_FORCE)'
    normalise_flag SKIP_UPDATE '--no-update (LZC_FIX_BROKEN_PACKAGES_SKIP_UPDATE)'

    [[ $USE_COLOR =~ ^(auto|always|never)$ ]] ||
        die "$EX_USAGE" "--color must be auto, always or never, got '$USE_COLOR'"
    [[ $CONFFILE =~ ^(old|new)$ ]] ||
        die "$EX_USAGE" "--conffile must be old or new, got '$CONFFILE'"

    [[ $LISTCHANGES_FRONTEND =~ ^[a-z][a-z-]*$ ]] ||
        die "$EX_USAGE" \
            "LZC_FIX_BROKEN_PACKAGES_LISTCHANGES_FRONTEND must be an apt-listchanges frontend name (none, pager, text, mail, ...), got '$LISTCHANGES_FRONTEND'"

    normalise_int PASSES 1 '--passes (LZC_FIX_BROKEN_PACKAGES_PASSES)'

    # 0 is meaningful here and is not a timeout: it means "do not retry a failed
    # download at all", which is the right choice on a metered or air-gapped host.
    normalise_int ACQUIRE_RETRIES 0 'LZC_FIX_BROKEN_PACKAGES_ACQUIRE_RETRIES'

    # Minimum 1, never 0: every one of these is handed to timeout(1), where 0
    # means "no limit" and would silently remove the protection the setting
    # exists to provide.
    normalise_int FIX_TIMEOUT 1 '--timeout (LZC_FIX_BROKEN_PACKAGES_FIX_TIMEOUT)'
    normalise_int CONFIGURE_TIMEOUT 1 'LZC_FIX_BROKEN_PACKAGES_CONFIGURE_TIMEOUT'
    normalise_int UPDATE_TIMEOUT 1 'LZC_FIX_BROKEN_PACKAGES_UPDATE_TIMEOUT'
    normalise_int PROBE_TIMEOUT 1 'LZC_FIX_BROKEN_PACKAGES_PROBE_TIMEOUT'
    normalise_int LOG_MAX_BYTES 1 'LZC_FIX_BROKEN_PACKAGES_LOG_MAX_BYTES'

    # The exception, and it is a real one: this is apt's own
    # DPkg::Lock::Timeout, not timeout(1). There 0 means "fail immediately if
    # the dpkg lock is held", which is a legitimate thing to ask for.
    normalise_int DPKG_LOCK_TIMEOUT 0 \
        '--lock-timeout (LZC_FIX_BROKEN_PACKAGES_DPKG_LOCK_TIMEOUT)'
}

# --- Preflight ---------------------------------------------------------------

# Runs before anything looks a tool up. cron hands a script PATH=/usr/bin:/bin
# and sources no profile, so /usr/sbin tools are invisible unless PATH is set
# here first. LC_ALL is fixed for the same reason: this script reads dpkg and
# apt output, and a translated message parses differently.
setup_runtime_env() {
    export PATH="$SAFE_PATH"
    export LC_ALL="$RUN_LOCALE"
}

# ID and ID_LIKE from /etc/os-release, space separated. Sourced in a subshell
# with `set +u` because os-release is a third-party file that this script's
# strictness has no business applying to.
os_release_ids() {
    [[ -r /etc/os-release ]] || return 1
    (
        set +u
        # shellcheck disable=SC1091 # runtime file on the target host; not in this repo
        . /etc/os-release 2>/dev/null || exit 1
        printf '%s %s\n' "${ID:-}" "${ID_LIKE:-}"
    )
}

# Refuses, with a useful pointer, on anything that is not Debian-family. Checked
# before the root check so that e.g. a Fedora user without sudo is told the real
# problem instead of "run me as root".
require_apt_system() {
    local ids='' token pretty=''
    local -a tokens=()
    ids=$(os_release_ids) || ids=''
    read -r -a tokens <<<"$ids"

    for token in ${tokens[@]+"${tokens[@]}"}; do
        case ${token,,} in
            debian | ubuntu | devuan | raspbian | linuxmint | pop | elementary | kali | zorin)
                if command -v apt-get >/dev/null 2>&1 && command -v dpkg >/dev/null 2>&1; then
                    return 0
                fi
                die "$EX_UNSUPPORTED" \
                    "This looks like a Debian-family system ($token) but apt-get or dpkg is not on PATH. Nothing was changed."
                ;;
        esac
    done

    for token in ${tokens[@]+"${tokens[@]}"}; do
        case ${token,,} in
            fedora | rhel | centos | rocky | almalinux | ol | amzn)
                pretty='dnf or yum; the equivalent repair there is "dnf check"'
                ;;
            suse | opensuse* | sles) pretty='zypper; the equivalent repair there is "zypper verify"' ;;
            arch | manjaro | endeavouros) pretty='pacman' ;;
            alpine) pretty='apk; the equivalent repair there is "apk fix"' ;;
        esac
        [[ -n $pretty ]] && break
    done

    local what=${tokens[0]:-}
    [[ -n $what ]] || what='this system'
    if [[ -n $pretty ]]; then
        die "$EX_UNSUPPORTED" \
            "$what uses $pretty. This script only repairs dpkg/APT on Debian/Ubuntu and derivatives. Nothing was changed."
    fi
    die "$EX_UNSUPPORTED" \
        "No dpkg/APT package manager found on $what. This script only repairs Debian/Ubuntu and derivatives. Nothing was changed."
}

require_root() {
    ((DRY_RUN)) && return 0
    [[ ${EUID:-$(id -u)} -eq 0 ]] && return 0
    die "$EX_NEEDROOT" \
        "Root privileges required. Re-run under sudo, or use --dry-run to see the diagnosis as an ordinary user."
}

preflight() {
    # A missing tool is a missing prerequisite, not a failed repair: it exits
    # $EX_UNSUPPORTED, the same status as "this is not an APT system", because
    # from the caller's point of view both mean "this host cannot run me".
    local tool
    for tool in apt-get dpkg dpkg-query timeout awk find; do
        command -v "$tool" >/dev/null 2>&1 ||
            die "$EX_UNSUPPORTED" "$tool not found; it is required."
    done

    # flock is only needed for the real run; a dry run takes no lock, so it must
    # not demand a tool it will never use.
    ((DRY_RUN)) && return 0
    command -v flock >/dev/null 2>&1 ||
        die "$EX_UNSUPPORTED" "flock (util-linux) not found; it is required."

    # Rotate before opening, so an unattended host does not grow an endless log.
    local size
    if [[ -f $LOG_FILE ]]; then
        size=$(wc -c <"$LOG_FILE" 2>/dev/null) || size=0
        if ((size > LOG_MAX_BYTES)); then
            mv -f "$LOG_FILE" "$LOG_FILE.1" 2>/dev/null || true
        fi
    fi

    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
    if : >>"$LOG_FILE" 2>/dev/null; then
        LOG_READY=1
        LOG_SINK=$LOG_FILE
    else
        log WARN "Cannot write $LOG_FILE; continuing without a log file."
    fi
    return 0
}

acquire_lock() {
    mkdir -p "$(dirname "$LOCK_FILE")" 2>/dev/null || true
    exec 9>"$LOCK_FILE" || die "$EX_BROKEN" "Cannot open lock file $LOCK_FILE"
    flock -n 9 ||
        die "$EX_LOCKED" "Another run holds $LOCK_FILE. Refusing to run concurrently."
    LOCK_HELD=1
}

setup_apt_env() {
    export DEBIAN_FRONTEND=noninteractive
    export DEBIAN_PRIORITY=critical
    # A repair must not also restart every service on the box; list only.
    export NEEDRESTART_MODE=l

    # apt-listchanges runs as an APT Pre-Install-Pkgs hook, outside everything
    # DEBIAN_FRONTEND governs, and with `confirm=true` in its own configuration
    # it asks a question on stdin. 'none' is its documented off switch.
    export APT_LISTCHANGES_FRONTEND="$LISTCHANGES_FRONTEND"

    # ucf-managed conffiles are a separate mechanism from dpkg's, and neither
    # the Dpkg::Options below nor dpkg's own --force-conf* reach them. ucf's
    # variables are spelled with two Fs (ucf(1)): UCF_FORCE_CONFFOLD keeps the
    # installed file, UCF_FORCE_CONFFNEW lets the package copy overwrite it.
    # UCF_FORCE_CONFOLD is not a name ucf reads, so setting it does nothing.
    case $CONFFILE in
        old) export UCF_FORCE_CONFFOLD=1 ;;
        new) export UCF_FORCE_CONFFNEW=1 ;;
    esac

    APT_OPTS=(
        -o "Dpkg::Use-Pty=0"
        -o "DPkg::Lock::Timeout=$DPKG_LOCK_TIMEOUT"
        # A transient mirror or DNS blip should not abandon a repair that is
        # already half done.
        -o "Acquire::Retries=$ACQUIRE_RETRIES"
    )
    [[ -t 1 ]] || APT_OPTS+=(-q)

    APT_WRITE_OPTS=("${APT_OPTS[@]}" -y -o "Dpkg::Options::=--force-confdef")
    case $CONFFILE in
        old) APT_WRITE_OPTS+=(-o "Dpkg::Options::=--force-confold") ;;
        new) APT_WRITE_OPTS+=(-o "Dpkg::Options::=--force-confnew") ;;
    esac
    return 0
}

# `-o Dpkg::Options::=` only reaches dpkg when APT is the one invoking it, so a
# standalone `dpkg --configure -a` needs the force flags passed to dpkg itself.
# Without them a maintainer script's conffile prompt hangs the repair -- which
# is the exact failure mode being repaired.
dpkg_configure_argv() {
    local -a argv=(dpkg --force-confdef)
    case $CONFFILE in
        old) argv+=(--force-confold) ;;
        new) argv+=(--force-confnew) ;;
    esac
    argv+=(--configure -a)
    printf '%s\n' "${argv[@]}"
}

# Runs one step under a hard timeout, tees its output to stdout and the log, and
# records a failure instead of aborting. Returns the command's own status.
run_step() {
    local label=$1 secs=$2
    shift 2

    log INFO "$label"
    local rc
    timeout --foreground "$secs" "$@" 2>&1 | tee -a "$LOG_SINK"
    rc=${PIPESTATUS[0]}

    if ((rc == 0)); then
        return 0
    fi
    if ((rc == 124)); then
        log ERROR "$label timed out after ${secs}s"
        FAILED_STEPS+=("$label (timed out after ${secs}s)")
    else
        log ERROR "$label failed with status $rc"
        FAILED_STEPS+=("$label (status $rc)")
    fi
    return "$rc"
}

# --- Inspection --------------------------------------------------------------

# Every installed package whose dpkg status is not "install ok installed".
# ${Status} is three words: want, error flag, current state. Anything other than
# flag "ok", and any state that is mid-transaction, is a package dpkg still has
# work to do on. Packages that are simply absent or left as config-files are not
# problems and are filtered out.
list_broken_packages() {
    dpkg-query -W -f='${binary:Package}\t${Status}\n' 2>/dev/null |
        awk -F'\t' '
            {
                split($2, s, " ")
                flag = s[2]; state = s[3]
                if (state == "not-installed" || state == "config-files") next
                if (flag != "ok" || state != "installed") printf "%s\t%s\n", $1, $2
            }
        '
}

# Fills HELD, and records in HELD_KNOWN whether the answer is real. apt-mark is
# optional, so "not installed" and "installed but it failed" both have to render
# as unknown rather than as a confident zero.
collect_holds() {
    local out rc=0
    HELD=()
    HELD_KNOWN=1

    if ! command -v apt-mark >/dev/null 2>&1; then
        HELD_KNOWN=0
        return 0
    fi
    out=$(timeout --foreground "$PROBE_TIMEOUT" apt-mark showhold 2>/dev/null) || rc=$?
    if ((rc != 0)); then
        HELD_KNOWN=0
        return 0
    fi
    # Guarded: `mapfile <<<""` yields one empty element, not zero, which would
    # turn "no holds" into "one hold, named nothing".
    [[ -n $out ]] && mapfile -t HELD <<<"$out"
    return 0
}

# dpkg keeps a journal of an in-flight transaction here. Files left behind mean
# dpkg was interrupted; `dpkg --configure -a` replays them. Never delete them.
#
# Sets JOURNAL_PENDING and JOURNAL_KNOWN. This directory is part of the very
# database this script repairs, so "I could not look in it" is a real outcome
# and must not render as "there is no interrupted transaction": that reading is
# what lets a damaged /var/lib/dpkg report itself consistent and exit 0. The
# dpkg package ships updates/ as a directory, so on an intact installation it is
# always present -- its absence is a symptom, not an all-clear.
check_journal() {
    local dir="$DPKG_ADMIN_DIR/updates" out rc=0
    JOURNAL_PENDING=0
    JOURNAL_KNOWN=1

    if [[ ! -d $dir ]]; then
        JOURNAL_KNOWN=0
        return 0
    fi
    # Command substitution, not `mapfile < <(find ...)`: that form discards
    # find's exit status, and an unreadable directory then yields "no journal
    # entries" -- indistinguishable from a finished transaction.
    out=$(find "$dir" -mindepth 1 -maxdepth 1 -type f -print 2>/dev/null) || rc=$?
    if [[ -n $out ]]; then
        # Positive evidence is conclusive even from a scan that then failed: a
        # journal file exists, so a transaction was interrupted. Only an empty
        # result from a failed scan is genuinely unknown.
        JOURNAL_PENDING=1
    elif ((rc != 0)); then
        JOURNAL_KNOWN=0
    fi
    return 0
}

# The authoritative verdict on dependencies. dpkg --audit is used only for
# human-readable detail: it has no documented exit-status contract, so branching
# on it would risk reporting "repaired" on a system that is still broken.
apt_dependencies_ok() {
    timeout --foreground "$PROBE_TIMEOUT" \
        apt-get "${APT_OPTS[@]}" check >/dev/null 2>&1
}

# The verdict from the most recent verify_state. Reads the cached state only;
# it re-inspects nothing, so it is safe to call wherever the exit status has to
# describe the system rather than the step that just ran.
#
# BROKEN_KNOWN is part of the verdict, not decoration: "I could not look" is not
# the same answer as "I looked and it was fine", and only one of them may be
# reported as a successful repair.
state_is_clean() {
    ((BROKEN_KNOWN == 1)) && ((${#BROKEN[@]} == 0)) &&
        ((JOURNAL_KNOWN == 1)) && ((JOURNAL_PENDING == 0)) &&
        ((APT_CHECK_OK == 1))
}

# Re-inspects the system from scratch. 0 = consistent.
verify_state() {
    local out rc=0
    BROKEN=()
    BROKEN_KNOWN=1

    # The status of the probe matters here more than anywhere else in this
    # script. `mapfile < <(cmd)` discards it, and a dpkg-query that failed then
    # yields an empty BROKEN -- indistinguishable from a healthy system, on the
    # exact corrupt-database case this script exists to repair. Command
    # substitution keeps the status reachable.
    out=$(list_broken_packages) || rc=$?
    if ((rc != 0)); then
        BROKEN_KNOWN=0
        log WARN "Could not read the dpkg status database (dpkg-query exited $rc);" \
            "the package state is unknown, not clean."
    elif [[ -n $out ]]; then
        # Guarded: `mapfile <<<""` yields one empty element, not zero.
        mapfile -t BROKEN <<<"$out"
    fi

    check_journal
    ((JOURNAL_KNOWN)) ||
        log WARN "Could not inspect $DPKG_ADMIN_DIR/updates;" \
            "whether a dpkg transaction was interrupted is unknown, not settled."

    APT_CHECK_OK=1
    apt_dependencies_ok || APT_CHECK_OK=0

    state_is_clean
}

diagnose() {
    local item

    log INFO "Inspecting the package database..."
    verify_state
    collect_holds

    printf '\n'
    log INFO "Diagnosis:"
    printf '  Packages in a bad state : %s\n' "$(count_label "$BROKEN_KNOWN" "${#BROKEN[@]}")"
    printf '  Interrupted transaction : %s\n' "$(yes_no_label "$JOURNAL_KNOWN" "$JOURNAL_PENDING")"
    printf '  Dependencies satisfied  : %s\n' "$( ((APT_CHECK_OK)) && printf yes || printf no)"
    printf '  Packages on hold        : %s\n' "$(count_label "$HELD_KNOWN" "${#HELD[@]}")"
    printf '\n'

    if ((${#BROKEN[@]})); then
        log WARN "Packages dpkg has unfinished work on:"
        for item in "${BROKEN[@]}"; do printf '  %s\n' "$item" >&2; done
        printf '\n'
    fi

    if ((${#HELD[@]})); then
        log WARN "On hold. A hold can make a dependency unsolvable, so if the"
        log WARN "repair below cannot find a solution, look here first:"
        for item in "${HELD[@]}"; do printf '  %s\n' "$item" >&2; done
        printf '\n'
    fi

    log INFO "dpkg --audit says:"
    timeout --foreground "$PROBE_TIMEOUT" dpkg --audit 2>&1 | tee -a "$LOG_SINK"
    printf '\n'
    return 0
}

show_fix_plan() {
    log INFO "What 'apt-get --fix-broken install' would do (simulated):"
    local rc
    timeout --foreground "$PROBE_TIMEOUT" \
        apt-get "${APT_OPTS[@]}" -s --fix-broken install 2>&1 | tee -a "$LOG_SINK"
    rc=${PIPESTATUS[0]}
    printf '\n'
    if ((rc == 0)); then
        log WARN "Read the plan above. --fix-broken install removes packages when that"
        log WARN "is the only way to satisfy a dependency."
    else
        # Expected on the primary use case: apt refuses install-type operations,
        # simulated ones included, while dpkg is mid-transaction.
        log WARN "apt could not compute a plan (apt-get -s exited $rc). That is normal"
        log WARN "when dpkg was interrupted: apt will not simulate until step 1 has run."
        log WARN "Continuing means accepting a repair whose removals are not listed yet."
    fi
    return 0
}

# --- Lock holders ------------------------------------------------------------

# Reports, and refuses, when a live process holds an apt or dpkg lock. Deleting
# those files is what actually corrupts /var/lib/dpkg, because it lets a second
# dpkg run start alongside the first. `fuser` (psmisc) is optional: without it
# the answer is unknown, so the run proceeds and dpkg's own error message
# becomes the report.
report_lock_holders() {
    if ! command -v fuser >/dev/null 2>&1; then
        log INFO "fuser not installed (psmisc); cannot check for a live lock holder."
        return 1
    fi

    local -a paths=()
    read -r -a paths <<<"$LOCK_PATHS"
    local path held=1
    for path in ${paths[@]+"${paths[@]}"}; do
        [[ -e $path ]] || continue
        if timeout --foreground "$PROBE_TIMEOUT" fuser "$path" >/dev/null 2>&1; then
            held=0
            log ERROR "Locked: $path"
            timeout --foreground "$PROBE_TIMEOUT" fuser -v "$path" 2>&1 |
                tee -a "$LOG_SINK" >&2
        fi
    done
    return "$held"
}

refuse_if_locked() {
    report_lock_holders || return 0
    log ERROR "Another process is using the package system right now."
    log ERROR "This is usually unattended-upgrades or apt-daily. Wait for it:"
    log ERROR "  systemctl list-units --all 'apt-daily*' 'unattended-upgrades*'"
    log ERROR "Do NOT delete the lock files. Deleting a lock a live process holds"
    log ERROR "lets a second dpkg run start alongside it, and that is what breaks"
    log ERROR "$DPKG_ADMIN_DIR/status for real."
    exit "$EX_LOCKED"
}

# --- Repair ------------------------------------------------------------------

confirm() {
    ((ASSUME_YES)) && return 0
    local reply
    read -r -p "Run the repair sequence? [y/N] " reply
    [[ ${reply,,} == y* ]]
}

repair() {
    local -a configure_argv=()
    mapfile -t configure_argv < <(dpkg_configure_argv)

    # Step 1. APT refuses to work while dpkg is mid-transaction, so this comes
    # before anything that involves apt.
    run_step "Configuring packages dpkg left unfinished" \
        "$CONFIGURE_TIMEOUT" "${configure_argv[@]}"

    # Step 2. Fresh indexes, so step 3 can actually fetch what it needs.
    if ((SKIP_UPDATE)); then
        log INFO "Skipping apt-get update (--no-update)"
    elif ! run_step "Refreshing package indexes" "$UPDATE_TIMEOUT" \
        apt-get "${APT_OPTS[@]}" update; then
        log WARN "Continuing with the indexes already on disk. If the repair needs"
        log WARN "to download a package, it may not find it."
    fi

    # Steps 3 and 4, repeated. Each pass ends with a fresh inspection, so the
    # loop stops as soon as the system is genuinely consistent.
    local pass
    for ((pass = 1; pass <= PASSES; pass++)); do
        PASSES_RUN=$pass
        log INFO "Repair pass $pass of $PASSES"

        run_step "Resolving broken dependencies" "$FIX_TIMEOUT" \
            apt-get "${APT_WRITE_OPTS[@]}" --fix-broken install

        run_step "Configuring anything left unfinished" \
            "$CONFIGURE_TIMEOUT" "${configure_argv[@]}"

        if verify_state; then
            log SUCCESS "System verifies consistent after pass $pass"
            return 0
        fi
        log WARN "Still inconsistent after pass $pass"
    done
    return 1
}

# --- Reporting ---------------------------------------------------------------

report() {
    local item

    printf '\n'
    log INFO "Result:"
    printf '  Repair passes run       : %d\n' "$PASSES_RUN"
    printf '  Steps that failed       : %d\n' "${#FAILED_STEPS[@]}"
    printf '  Packages in a bad state : %s\n' "$(count_label "$BROKEN_KNOWN" "${#BROKEN[@]}")"
    printf '  Interrupted transaction : %s\n' "$(yes_no_label "$JOURNAL_KNOWN" "$JOURNAL_PENDING")"
    printf '  Dependencies satisfied  : %s\n' "$( ((APT_CHECK_OK)) && printf yes || printf no)"
    printf '\n'

    if ((${#FAILED_STEPS[@]})); then
        log WARN "Repair steps that reported an error:"
        for item in "${FAILED_STEPS[@]}"; do printf '  %s\n' "$item" >&2; done
        printf '\n'
    fi

    if ((${#BROKEN[@]})); then
        log ERROR "Still in a bad state:"
        for item in "${BROKEN[@]}"; do printf '  %s\n' "$item" >&2; done
        printf '\n'
    fi

    ((LOG_READY)) && log INFO "Full log: $LOG_FILE"
    return 0
}

next_steps() {
    log WARN "What to try next, in order:"
    log WARN "  1. Read the errors above. A failing maintainer script names the"
    log WARN "     package; reproduce it alone with: dpkg --configure <package>"
    log WARN "  2. Ask apt to explain its dependency reasoning:"
    log WARN "       apt-get -o Debug::pkgProblemResolver=true --fix-broken install"
    log WARN "  3. Check whether a hold is blocking the solution: apt-mark showhold"
    log WARN "  4. Read the transaction logs: /var/log/dpkg.log, /var/log/apt/term.log"
    log WARN "  5. A package whose files clash with another needs a decision from"
    log WARN "     you, not a --force flag. This script will not guess for you."
    return 0
}

# --- Traps -------------------------------------------------------------------

on_exit() {
    local rc=$?
    trap - EXIT INT TERM
    ((LOCK_HELD)) && exec 9>&-
    exit "$rc"
}

# dpkg runs in the foreground, and bash defers a trap until the running command
# returns, so this fires between steps rather than during one. That is
# deliberate: interrupting dpkg mid-transaction is how systems get into the
# state this script repairs.
on_signal() {
    log WARN "Interrupted between repair steps; the package database was left as it is."
    exit "$EX_INTERRUPT"
}

# --- Main --------------------------------------------------------------------

main() {
    setup_runtime_env
    parse_args "$@"
    setup_color
    banner

    require_apt_system
    require_root
    preflight
    setup_apt_env

    # SIGHUP is ignored rather than handled: an ignored disposition survives
    # execve(), so dpkg inherits it too. That is what stops a dropped SSH session
    # from killing dpkg in the middle of the repair.
    trap '' HUP
    trap on_exit EXIT
    trap on_signal INT TERM

    if ((!DRY_RUN)); then
        if ((!ASSUME_YES)) && { [[ ! -t 0 ]] || [[ ! -t 1 ]]; }; then
            die "$EX_REFUSED" \
                "No terminal and no --yes. Refusing to change packages unattended without explicit consent (--yes, or LZC_FIX_BROKEN_PACKAGES_YES=1)."
        fi
        acquire_lock
        log INFO "Starting $SCRIPT_NAME v$SCRIPT_VERSION on $(hostname 2>/dev/null || printf 'this host')"
    fi

    diagnose

    # diagnose() has just run verify_state(); state_is_clean reads that result
    # instead of paying for a second dpkg-query over every installed package and
    # a second apt-get check.
    if state_is_clean && ((!FORCE)); then
        log SUCCESS "Nothing to repair: the package database is consistent."
        log INFO "Run with --force to perform the repair sequence anyway."
        return "$EX_OK"
    fi

    show_fix_plan

    # The exit status describes the system, not whether the run finished. A
    # system that was broken when we looked is still broken now, so -n is a
    # read-only health check rather than something that always succeeds.
    if ((DRY_RUN)); then
        log INFO "Dry run: nothing was changed."
        state_is_clean && return "$EX_OK"
        if ((BROKEN_KNOWN)) && ((JOURNAL_KNOWN)); then
            log ERROR "The package database is inconsistent. Re-run without -n to repair it."
        else
            log ERROR "The package database could not be fully inspected, so it cannot be called consistent."
        fi
        return "$EX_BROKEN"
    fi

    refuse_if_locked

    if ! confirm; then
        log INFO "Cancelled; nothing was changed."
        state_is_clean && return "$EX_OK"
        log ERROR "The package database is still inconsistent; nothing was repaired."
        return "$EX_BROKEN"
    fi

    repair

    report

    if state_is_clean; then
        log SUCCESS "Repaired. The package database verifies consistent."
        return "$EX_OK"
    fi

    # "Could not verify" and "verified broken" are different facts, and the
    # operator's next move differs between them.
    if ((BROKEN_KNOWN)) && ((JOURNAL_KNOWN)); then
        log ERROR "The package database is still inconsistent."
    else
        log ERROR "The package database could not be verified, so the repair is not confirmed."
    fi
    next_steps
    return "$EX_BROKEN"
}

main "$@"
