#!/usr/bin/env bash
#
# Debian/Ubuntu system updater.
#
# Refreshes the APT indexes and upgrades installed packages without ever asking
# a question, then reports what the operator still has to act on: a pending
# reboot, conffiles that were kept back, held packages. Built for cron and
# systemd timers; equally usable by hand.
#
# License: MIT
# Origin:  https://github.com/Lazarev-Cloud/Scripts
#
# Error model: this script uses `set -uo pipefail` and deliberately NOT `set -e`.
# The reporting at the end -- pending reboot, conffile drift, held packages -- is
# most valuable precisely when an earlier step failed, so every step is checked
# explicitly and routed into FAILED_STEPS[]. Do not add `set -e`, and do not call
# this script as `update_upgrade.sh || true`: both move the error handling
# somewhere this script cannot see it.
set -uo pipefail

readonly SCRIPT_NAME='Debian/Ubuntu System Updater'
readonly SCRIPT_VERSION='2.0'

# --- Tunables (env overridable, then flag overridable) -----------------------
#
# Every user-facing variable is LZC_UPDATE_UPGRADE_*, so `env | grep LZC_` shows
# everything that can be configured here and in every other script in this
# repository. Internal names below are shell locals and are not an interface.
LOG_FILE="${LZC_UPDATE_UPGRADE_LOG:-/var/log/apt-upgrade.log}"
LOG_MAX_BYTES="${LZC_UPDATE_UPGRADE_LOG_MAX_BYTES:-5242880}"
LOCK_FILE="${LZC_UPDATE_UPGRADE_LOCK:-/run/lock/lzc-update_upgrade.lock}"
DPKG_LOCK_TIMEOUT="${LZC_UPDATE_UPGRADE_DPKG_LOCK_TIMEOUT:-600}"
ACQUIRE_RETRIES="${LZC_UPDATE_UPGRADE_ACQUIRE_RETRIES:-3}"
LISTCHANGES_FRONTEND="${LZC_UPDATE_UPGRADE_LISTCHANGES_FRONTEND:-none}"
UPDATE_TIMEOUT="${LZC_UPDATE_UPGRADE_UPDATE_TIMEOUT:-600}"
UPGRADE_TIMEOUT="${LZC_UPDATE_UPGRADE_UPGRADE_TIMEOUT:-3600}"
CLEANUP_TIMEOUT="${LZC_UPDATE_UPGRADE_CLEANUP_TIMEOUT:-600}"
PROBE_TIMEOUT="${LZC_UPDATE_UPGRADE_PROBE_TIMEOUT:-120}"
MODE="${LZC_UPDATE_UPGRADE_MODE:-upgrade}"
WITH_NEW_PKGS="${LZC_UPDATE_UPGRADE_WITH_NEW_PKGS:-0}"
CONFFILE="${LZC_UPDATE_UPGRADE_CONFFILE:-old}"
AUTOREMOVE="${LZC_UPDATE_UPGRADE_AUTOREMOVE:-0}"
AUTOREMOVE_PURGE="${LZC_UPDATE_UPGRADE_AUTOREMOVE_PURGE:-0}"
CLEAN_MODE="${LZC_UPDATE_UPGRADE_CLEAN:-none}"
NEEDRESTART_RUN_MODE="${LZC_UPDATE_UPGRADE_NEEDRESTART_MODE:-l}"
ETC_DIR="${LZC_UPDATE_UPGRADE_ETC_DIR:-/etc}"
REBOOT_MARKERS="${LZC_UPDATE_UPGRADE_REBOOT_MARKERS:-/run/reboot-required /var/run/reboot-required}"
REBOOT_PKGS_FILE="${LZC_UPDATE_UPGRADE_REBOOT_PKGS:-/run/reboot-required.pkgs}"
ASSUME_YES="${LZC_UPDATE_UPGRADE_YES:-0}"
SAFE_PATH="${LZC_UPDATE_UPGRADE_PATH:-/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin}"
RUN_LOCALE="${LZC_UPDATE_UPGRADE_LOCALE:-C}"
DRY_RUN=0
USE_COLOR=auto

# --- Exit codes ---------------------------------------------------------------
#
# The repository-wide table. These are the only statuses this script returns;
# see --help for the operator-facing version. A pending reboot is reported in
# the summary and in the log, and exits 0 -- it is not a failure, and there is
# no code outside this table to signal it with. Callers that want to act on it
# should test /run/reboot-required, which is the actual source of truth and
# outlives the run.
readonly EX_OK=0          # success
readonly EX_FAILED=1      # the work ran but something in it failed
readonly EX_USAGE=2       # usage error
readonly EX_UNSUPPORTED=3 # unsupported platform, or a missing prerequisite tool
readonly EX_NEEDROOT=4    # must be run as root
readonly EX_REFUSED=5     # confirmation needed, but no TTY and no --yes
readonly EX_LOCKED=75     # another instance holds the lock (EX_TEMPFAIL)
readonly EX_INTERRUPT=130 # interrupted (SIGINT/SIGTERM)

# --- Runtime state -----------------------------------------------------------
declare -a FAILED_STEPS=()
declare -a APT_OPTS=()
declare -a APT_WRITE_OPTS=()
declare -a HELD=()
declare -a DRIFT=()
REBOOT_REQUIRED=0
REBOOT_REASON=''
# Whether the probe behind each reported value actually ran. A check that could
# not run must never be reported as a count of zero or as "no" -- see
# count_label() and check_reboot().
HELD_KNOWN=1
DRIFT_KNOWN=1
REBOOT_KNOWN=1
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
# failed inspection is indistinguishable from a "0" that means there is nothing
# to report, and this summary is the whole reason the script prints anything --
# so an unverified count says so rather than quietly reading as good news.
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

usage() {
    cat <<EOF
$SCRIPT_NAME v$SCRIPT_VERSION

Refreshes the APT indexes, upgrades installed packages non-interactively, and
reports the follow-up work: pending reboot, conffile drift, held packages.

Usage:
  update_upgrade.sh [options]

Options:
  -y, --yes                 Run unattended; no prompts. Required with no TTY.
  -n, --dry-run             Simulate. Refreshes nothing, changes nothing, and
                            needs no root.
      --mode MODE           upgrade | dist-upgrade (default: $MODE).
                            'upgrade' never removes a package. 'dist-upgrade'
                            may remove packages to resolve new dependencies.
      --with-new-pkgs       Let 'upgrade' pull in new dependencies, matching
                            what \`apt upgrade\` does. Needed on Ubuntu for
                            kernel meta-packages. Ignored for dist-upgrade.
      --conffile POLICY     old | new (default: $CONFFILE).
                            'old' keeps your edited files and writes the package
                            version alongside as *.dpkg-dist.
                            'new' OVERWRITES your edits with the package copy.
      --restart-services    Let needrestart restart affected services
                            (NEEDRESTART_MODE=a). Default is list-only.
      --autoremove          Remove packages nothing depends on any more.
      --autoremove-purge    As --autoremove, and delete their config files too.
      --autoclean           Delete cached .debs that can no longer be fetched.
      --clean               Delete the whole downloaded .deb cache.
      --lock-timeout SEC    How long APT waits for the *dpkg* lock when another
                            package tool holds it (default: $DPKG_LOCK_TIMEOUT). This is
                            apt's own DPkg::Lock::Timeout, a different mechanism
                            from the flock this script takes on its own lock
                            file. 0 means "fail at once if the lock is held".
      --timeout SEC         Wall-clock limit for the upgrade step itself -- the
                            single 'apt-get $MODE' invocation (default:
                            $UPGRADE_TIMEOUT). Minimum 1; 'timeout 0' would mean no
                            limit at all. The index refresh, autoremove and
                            clean steps have their own timeouts, listed below.
      --log-file PATH       Log file (default: $LOG_FILE).
      --color WHEN          auto | always | never (default: auto).
  -V, --version             Print version and exit.
  -h, --help                Print this help and exit.

Blast radius:
  Default run   upgrades installed packages only. No package is removed, no
                cache is deleted, no service is restarted, and no file of yours
                under $ETC_DIR is overwritten.
  --mode dist-upgrade, --autoremove, --autoremove-purge
                REMOVE packages. --autoremove-purge also deletes their config
                files. Run with -n first and read the plan. The autoremove list
                is simulated before the upgrade, so treat it as a lower bound:
                the upgrade can orphan further packages, which are removed too.
                If the upgrade itself fails, autoremove and the cache cleanup
                are SKIPPED: what is orphaned is read from the package state,
                and a half-applied upgrade is not a state to remove from.
  --conffile new
                OVERWRITES local edits under $ETC_DIR. Only sensible where
                configuration management re-applies state afterwards.
  --clean       deletes the downloaded .deb cache. Recoverable (apt re-fetches),
                but the next install then needs the network.
  --restart-services
                restarts running services whose libraries were replaced. Brief
                interruptions. It never restarts the machine.

This script never reboots and never deletes an apt or dpkg lock file. A pending
reboot is reported, and exits $EX_OK: it is not a failure.

To act on it from a wrapper, use the same test this script does -- which one
that is depends on the host, so do not assume the marker file:
  * with update-notifier-common installed:  [ -e /run/reboot-required ]
  * otherwise, with needrestart installed:
      needrestart -b -r l | grep -q '^NEEDRESTART-KSTA: [23]\$'
  * with neither, there is nothing to test; the summary says "unknown".

Reboot detection has three answers, not two. The markers come from
update-notifier-common, which Debian does not install by default; where nothing
writes them and needrestart is absent, the summary says "unknown" rather than
claiming "no". The same applies to every count in the summary: a check that
could not run is reported as unknown, never as a zero.

Every option also has an environment variable, which is the easier route when
piping this script in from the network. They all begin LZC_UPDATE_UPGRADE_, so
\`env | grep LZC_\` lists everything you have configured:
  LZC_UPDATE_UPGRADE_YES=1              LZC_UPDATE_UPGRADE_MODE=dist-upgrade
  LZC_UPDATE_UPGRADE_WITH_NEW_PKGS=1    LZC_UPDATE_UPGRADE_CONFFILE=old
  LZC_UPDATE_UPGRADE_AUTOREMOVE=1       LZC_UPDATE_UPGRADE_AUTOREMOVE_PURGE=1
  LZC_UPDATE_UPGRADE_CLEAN=autoclean    LZC_UPDATE_UPGRADE_NEEDRESTART_MODE=l
  LZC_UPDATE_UPGRADE_DPKG_LOCK_TIMEOUT=600
  LZC_UPDATE_UPGRADE_ACQUIRE_RETRIES=3
  LZC_UPDATE_UPGRADE_LISTCHANGES_FRONTEND=none
  LZC_UPDATE_UPGRADE_UPDATE_TIMEOUT=600 LZC_UPDATE_UPGRADE_UPGRADE_TIMEOUT=3600
  LZC_UPDATE_UPGRADE_CLEANUP_TIMEOUT=600
  LZC_UPDATE_UPGRADE_PROBE_TIMEOUT=120
  LZC_UPDATE_UPGRADE_LOG=/var/log/apt-upgrade.log
  LZC_UPDATE_UPGRADE_LOG_MAX_BYTES=5242880
  LZC_UPDATE_UPGRADE_LOCK=/run/lock/lzc-update_upgrade.lock
  LZC_UPDATE_UPGRADE_ETC_DIR=/etc
  LZC_UPDATE_UPGRADE_REBOOT_MARKERS='/run/reboot-required
                                     /var/run/reboot-required'
  LZC_UPDATE_UPGRADE_REBOOT_PKGS=/run/reboot-required.pkgs
  LZC_UPDATE_UPGRADE_PATH=/usr/sbin:/usr/bin:/sbin:/bin
  LZC_UPDATE_UPGRADE_LOCALE=C

Boolean variables (YES, WITH_NEW_PKGS, AUTOREMOVE, AUTOREMOVE_PURGE) accept
1/true/yes/on and 0/false/no/off in any case. Anything else is a usage error,
rather than a crash halfway through the run. Numbers must be whole; a leading
zero is read as decimal, not octal.

NO_COLOR is honoured: any non-empty value disables colour, overriding
--color always.

Exit status:
  $EX_OK   everything asked for succeeded (a pending reboot included)
  $EX_FAILED   the run happened but at least one step failed (details on stderr
      and in the log)
  $EX_USAGE   usage error (unknown flag, missing or invalid argument value)
  $EX_UNSUPPORTED   not an APT-based system, or a required tool is missing;
      nothing was changed
  $EX_NEEDROOT   must be run as root
  $EX_REFUSED   refused: confirmation needed, but no TTY and --yes was not given
  $EX_LOCKED  temporary failure: another copy of this script holds its own lock
      file ($LOCK_FILE).
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
            --mode)
                need_arg $# --mode
                MODE=$2
                shift
                ;;
            --with-new-pkgs) WITH_NEW_PKGS=1 ;;
            --conffile)
                need_arg $# --conffile
                CONFFILE=$2
                shift
                ;;
            --restart-services) NEEDRESTART_RUN_MODE=a ;;
            --autoremove) AUTOREMOVE=1 ;;
            --autoremove-purge)
                AUTOREMOVE=1
                AUTOREMOVE_PURGE=1
                ;;
            --autoclean) CLEAN_MODE=autoclean ;;
            --clean) CLEAN_MODE=clean ;;
            --lock-timeout)
                need_arg $# --lock-timeout
                DPKG_LOCK_TIMEOUT=$2
                shift
                ;;
            --timeout)
                need_arg $# --timeout
                UPGRADE_TIMEOUT=$2
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
# actually type in a cron file. Without this, LZC_UPDATE_UPGRADE_YES=true
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
    normalise_flag ASSUME_YES '--yes (LZC_UPDATE_UPGRADE_YES)'
    normalise_flag WITH_NEW_PKGS '--with-new-pkgs (LZC_UPDATE_UPGRADE_WITH_NEW_PKGS)'
    normalise_flag AUTOREMOVE '--autoremove (LZC_UPDATE_UPGRADE_AUTOREMOVE)'
    normalise_flag AUTOREMOVE_PURGE \
        '--autoremove-purge (LZC_UPDATE_UPGRADE_AUTOREMOVE_PURGE)'

    # The flag sets both; the environment variable has to imply the other half
    # too, or LZC_UPDATE_UPGRADE_AUTOREMOVE_PURGE=1 on its own is a silent
    # no-op.
    if ((AUTOREMOVE_PURGE)); then
        AUTOREMOVE=1
    fi

    [[ $USE_COLOR =~ ^(auto|always|never)$ ]] ||
        die "$EX_USAGE" "--color must be auto, always or never, got '$USE_COLOR'"
    [[ $MODE =~ ^(upgrade|dist-upgrade)$ ]] ||
        die "$EX_USAGE" "--mode must be upgrade or dist-upgrade, got '$MODE'"
    [[ $CONFFILE =~ ^(old|new)$ ]] ||
        die "$EX_USAGE" "--conffile must be old or new, got '$CONFFILE'"
    [[ $CLEAN_MODE =~ ^(none|autoclean|clean)$ ]] ||
        die "$EX_USAGE" "LZC_UPDATE_UPGRADE_CLEAN must be none, autoclean or clean, got '$CLEAN_MODE'"
    [[ $NEEDRESTART_RUN_MODE =~ ^[ali]$ ]] ||
        die "$EX_USAGE" "LZC_UPDATE_UPGRADE_NEEDRESTART_MODE must be a, l or i, got '$NEEDRESTART_RUN_MODE'"
    [[ $LISTCHANGES_FRONTEND =~ ^[a-z][a-z-]*$ ]] ||
        die "$EX_USAGE" \
            "LZC_UPDATE_UPGRADE_LISTCHANGES_FRONTEND must be an apt-listchanges frontend name (none, pager, text, mail, ...), got '$LISTCHANGES_FRONTEND'"

    # Minimum 1, never 0: every one of these is handed to timeout(1), where 0
    # means "no limit" and would silently remove the protection the setting
    # exists to provide.
    normalise_int UPGRADE_TIMEOUT 1 '--timeout (LZC_UPDATE_UPGRADE_UPGRADE_TIMEOUT)'
    normalise_int UPDATE_TIMEOUT 1 'LZC_UPDATE_UPGRADE_UPDATE_TIMEOUT'
    normalise_int CLEANUP_TIMEOUT 1 'LZC_UPDATE_UPGRADE_CLEANUP_TIMEOUT'
    normalise_int PROBE_TIMEOUT 1 'LZC_UPDATE_UPGRADE_PROBE_TIMEOUT'
    normalise_int LOG_MAX_BYTES 1 'LZC_UPDATE_UPGRADE_LOG_MAX_BYTES'

    # 0 is meaningful here and is not a timeout: it means "do not retry a failed
    # download at all", which is the right choice on a metered connection.
    normalise_int ACQUIRE_RETRIES 0 'LZC_UPDATE_UPGRADE_ACQUIRE_RETRIES'

    # The exception, and it is a real one: this is apt's own
    # DPkg::Lock::Timeout, not timeout(1). There 0 means "fail immediately if
    # the dpkg lock is held", which is a legitimate thing to ask for.
    normalise_int DPKG_LOCK_TIMEOUT 0 \
        '--lock-timeout (LZC_UPDATE_UPGRADE_DPKG_LOCK_TIMEOUT)'
}

# --- Preflight ---------------------------------------------------------------

# Runs before anything looks a tool up. cron hands a script PATH=/usr/bin:/bin
# and sources no profile, so /usr/sbin tools -- needrestart among them -- are
# invisible unless PATH is set here first. LC_ALL is fixed for the same reason:
# this script reads apt and needrestart output, and a translated message parses
# differently.
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
                command -v apt-get >/dev/null 2>&1 && return 0
                die "$EX_UNSUPPORTED" \
                    "This looks like a Debian-family system ($token) but apt-get is not on PATH. Nothing was changed."
                ;;
        esac
    done

    for token in ${tokens[@]+"${tokens[@]}"}; do
        case ${token,,} in
            fedora | rhel | centos | rocky | almalinux | ol | amzn) pretty='dnf or yum' ;;
            suse | opensuse* | sles) pretty='zypper' ;;
            arch | manjaro | endeavouros) pretty='pacman' ;;
            alpine) pretty='apk' ;;
        esac
        [[ -n $pretty ]] && break
    done

    local what=${tokens[0]:-}
    [[ -n $what ]] || what='this system'

    # The pointer matters as much as the refusal. This script is APT all the way
    # down -- dpkg conffile handling, apt-mark holds, apt-get's own argv -- so
    # there is nothing to generalise here, but maintenance.sh dispatches on the
    # package family and covers apt, dnf/yum and pacman. Sending people there
    # is the difference between "no" and "not here, use that".
    local -a alt=()
    if [[ $pretty == 'pacman' || $pretty == 'dnf or yum' ]]; then
        alt=("Use 'maintenance.sh --yes update' instead, which handles $pretty.")
    fi

    if [[ -n $pretty ]]; then
        die "$EX_UNSUPPORTED" \
            "$what uses $pretty, not APT. This script only handles Debian/Ubuntu and derivatives.${alt[0]:+ ${alt[0]}} Nothing was changed."
    fi
    die "$EX_UNSUPPORTED" \
        "No APT package manager found on $what. This script only handles Debian/Ubuntu and derivatives. Nothing was changed."
}

require_root() {
    ((DRY_RUN)) && return 0
    [[ ${EUID:-$(id -u)} -eq 0 ]] && return 0
    die "$EX_NEEDROOT" \
        "Root privileges required. Re-run under sudo, or use --dry-run to see the plan as an ordinary user."
}

preflight() {
    # A missing tool is a missing prerequisite, not a failed upgrade: it exits
    # $EX_UNSUPPORTED, the same status as "this is not an APT system", because
    # from the caller's point of view both mean "this host cannot run me".
    local tool
    for tool in apt-get timeout find sed; do
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
    exec 9>"$LOCK_FILE" || die "$EX_FAILED" "Cannot open lock file $LOCK_FILE"
    flock -n 9 ||
        die "$EX_LOCKED" "Another run holds $LOCK_FILE. Refusing to run concurrently."
    LOCK_HELD=1
}

# --- APT plumbing ------------------------------------------------------------

# The environment that makes an upgrade answer its own questions.
# DEBIAN_FRONTEND only silences debconf; conffile prompts come from dpkg and
# need the Dpkg::Options below. NEEDRESTART_MODE stops needrestart, which is
# installed by default on Ubuntu 22.04+, from opening a full-screen dialog in
# the middle of the run.
setup_apt_env() {
    export DEBIAN_FRONTEND=noninteractive
    export DEBIAN_PRIORITY=critical
    export NEEDRESTART_MODE="$NEEDRESTART_RUN_MODE"

    # apt-listchanges runs as an APT Pre-Install-Pkgs hook, outside everything
    # DEBIAN_FRONTEND governs, and with `confirm=true` in its own configuration
    # it asks a question on stdin. 'none' is its documented off switch.
    export APT_LISTCHANGES_FRONTEND="$LISTCHANGES_FRONTEND"

    # ucf-managed conffiles are a separate mechanism from dpkg's, and the
    # Dpkg::Options below do not reach them. ucf's own variables are spelled
    # with two Fs (ucf(1)): UCF_FORCE_CONFFOLD keeps the installed file,
    # UCF_FORCE_CONFFNEW lets the package copy overwrite it. UCF_FORCE_CONFOLD
    # is not a name ucf reads, so setting it does nothing at all.
    case $CONFFILE in
        old) export UCF_FORCE_CONFFOLD=1 ;;
        new) export UCF_FORCE_CONFFNEW=1 ;;
    esac

    APT_OPTS=(
        -o "Dpkg::Use-Pty=0"
        -o "DPkg::Lock::Timeout=$DPKG_LOCK_TIMEOUT"
        # A transient mirror or DNS blip should not fail an unattended run that
        # will not be looked at until morning.
        -o "Acquire::Retries=$ACQUIRE_RETRIES"
    )
    # Without a terminal, apt's progress redraws are just noise in a log file.
    [[ -t 1 ]] || APT_OPTS+=(-q)

    APT_WRITE_OPTS=("${APT_OPTS[@]}" -y -o "Dpkg::Options::=--force-confdef")
    case $CONFFILE in
        old) APT_WRITE_OPTS+=(-o "Dpkg::Options::=--force-confold") ;;
        new) APT_WRITE_OPTS+=(-o "Dpkg::Options::=--force-confnew") ;;
    esac
    return 0
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

# The apt-get argv for the configured upgrade, one word per line so the caller
# can read it back into an array without quoting games.
upgrade_argv() {
    local simulate=$1
    local -a argv=(apt-get)
    if ((simulate)); then
        argv+=("${APT_OPTS[@]}" -s)
    else
        argv+=("${APT_WRITE_OPTS[@]}")
    fi
    if ((WITH_NEW_PKGS)) && [[ $MODE == upgrade ]]; then
        argv+=(--with-new-pkgs)
    fi
    argv+=("$MODE")
    printf '%s\n' "${argv[@]}"
}

# --- Steps -------------------------------------------------------------------

do_update() {
    # A single broken third-party repository makes apt-get update exit non-zero.
    # Aborting the whole patch run for that is the wrong behaviour, so this warns
    # loudly, keeps going against the indexes already on disk, and leaves the
    # final exit status non-zero so monitoring still sees it.
    if run_step "Refreshing package indexes" "$UPDATE_TIMEOUT" \
        apt-get "${APT_OPTS[@]}" update; then
        return 0
    fi
    log WARN "Continuing with the package indexes already on disk; they may be stale."
    log WARN "If the errors above mention a changed release suite, review it by hand:"
    log WARN "  apt-get update --allow-releaseinfo-change"
    return 1
}

show_plan() {
    local -a argv=()
    mapfile -t argv < <(upgrade_argv 1)

    log INFO "Planned changes ($MODE):"
    local rc
    timeout --foreground "$PROBE_TIMEOUT" "${argv[@]}" 2>&1 | tee -a "$LOG_SINK"
    rc=${PIPESTATUS[0]}
    ((rc == 0)) || log WARN "Could not compute the plan (apt-get -s exited $rc)."

    # autoremove deletes packages, and --autoremove-purge deletes their
    # configuration too, so the removal list has to be visible before the
    # prompt rather than scroll past afterwards.
    ((AUTOREMOVE)) || return 0

    local -a rm_argv=(apt-get "${APT_OPTS[@]}" -s)
    ((AUTOREMOVE_PURGE)) && rm_argv+=(--purge)
    rm_argv+=(autoremove)

    printf '\n'
    log INFO "Planned autoremove, computed before the upgrade:"
    timeout --foreground "$PROBE_TIMEOUT" "${rm_argv[@]}" 2>&1 | tee -a "$LOG_SINK"
    rc=${PIPESTATUS[0]}
    ((rc == 0)) || log WARN "Could not compute the autoremove plan (apt-get -s exited $rc)."
    log WARN "That list is a lower bound, not the final one: the upgrade itself"
    log WARN "can orphan further packages, and those are removed too."
    return 0
}

confirm() {
    ((ASSUME_YES)) && return 0
    local reply
    read -r -p "Apply the changes above? [y/N] " reply
    [[ ${reply,,} == y* ]]
}

do_upgrade() {
    local -a argv=()
    mapfile -t argv < <(upgrade_argv 0)
    run_step "Upgrading packages ($MODE)" "$UPGRADE_TIMEOUT" "${argv[@]}"
}

do_autoremove() {
    ((AUTOREMOVE)) || return 0
    local -a argv=(apt-get "${APT_WRITE_OPTS[@]}")
    ((AUTOREMOVE_PURGE)) && argv+=(--purge)
    argv+=(autoremove)
    run_step "Removing packages nothing depends on" "$CLEANUP_TIMEOUT" "${argv[@]}"
}

do_clean() {
    case $CLEAN_MODE in
        autoclean)
            run_step "Deleting unfetchable cached .debs" "$CLEANUP_TIMEOUT" \
                apt-get "${APT_OPTS[@]}" autoclean
            ;;
        clean)
            run_step "Deleting the cached .deb archive" "$CLEANUP_TIMEOUT" \
                apt-get "${APT_OPTS[@]}" clean
            ;;
        *) return 0 ;;
    esac
}

# --- Reporting ---------------------------------------------------------------

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

# Conffiles the package shipped but dpkg kept back because the local copy was
# edited. The 'old' policy creates these on purpose, and nobody ever goes
# looking for them, so they are surfaced on every run.
#
# find exits non-zero when any directory could not be read, having still printed
# everything it did find -- which is the normal case for an unprivileged
# --dry-run over /etc. So the results are kept and the scan is marked
# incomplete, rather than thrown away or passed off as exhaustive.
collect_drift() {
    local out rc=0
    DRIFT=()
    DRIFT_KNOWN=1

    if [[ ! -d $ETC_DIR ]]; then
        DRIFT_KNOWN=0
        return 0
    fi
    out=$(timeout --foreground "$PROBE_TIMEOUT" \
        find "$ETC_DIR" -xdev -type f \
        \( -name '*.dpkg-dist' -o -name '*.dpkg-new' -o -name '*.ucf-dist' \) \
        -print 2>/dev/null) || rc=$?
    [[ -n $out ]] && mapfile -t DRIFT <<<"$out"
    ((rc == 0)) || DRIFT_KNOWN=0
    return 0
}

# Whether the ABSENCE of a reboot marker actually means anything. The markers
# are written by update-notifier-common, which Ubuntu installs by default and
# plain Debian does not. Where nothing writes them, "no marker" is silence, not
# a negative answer, and reporting it as "no" is simply false.
markers_are_authoritative() {
    command -v dpkg-query >/dev/null 2>&1 || return 1
    local status
    # shellcheck disable=SC2016 # ${db:Status-Status} is a dpkg-query(1) format
    # specifier, not a shell expansion; single quotes are required so dpkg-query
    # receives it verbatim.
    status=$(timeout --foreground "$PROBE_TIMEOUT" \
        dpkg-query -W -f='${db:Status-Status}' update-notifier-common 2>/dev/null) || return 1
    [[ $status == installed ]]
}

# Sets REBOOT_REQUIRED and REBOOT_KNOWN. Three outcomes, not two: yes, no, and
# "this host has no way to tell you". Returns 0 only when a reboot is pending.
check_reboot() {
    REBOOT_REQUIRED=0
    REBOOT_KNOWN=0
    REBOOT_REASON=''

    local marker
    local -a markers=()
    read -r -a markers <<<"$REBOOT_MARKERS"
    for marker in ${markers[@]+"${markers[@]}"}; do
        if [[ -e $marker ]]; then
            REBOOT_REQUIRED=1
            REBOOT_KNOWN=1
            REBOOT_REASON="$marker exists"
            return 0
        fi
    done

    # No marker. That is only a negative answer where something writes markers.
    markers_are_authoritative && REBOOT_KNOWN=1

    # needrestart settles the kernel question either way, and on a minimal
    # Debian it is the only detection there is. `-r l` is list-only and restarts
    # nothing. KSTA 2 means a kernel ABI upgrade is pending, 3 a version upgrade.
    local out ksta
    if command -v needrestart >/dev/null 2>&1 &&
        out=$(timeout --foreground "$PROBE_TIMEOUT" needrestart -b -r l 2>/dev/null); then
        ksta=$(printf '%s\n' "$out" | sed -n 's/^NEEDRESTART-KSTA: *//p' | head -n1)
        if [[ $ksta =~ ^[0-9]+$ ]]; then
            REBOOT_KNOWN=1
            if ((ksta >= 2)); then
                REBOOT_REQUIRED=1
                REBOOT_REASON="needrestart reports the running kernel is outdated (KSTA $ksta)"
                return 0
            fi
        fi
    fi
    return 1
}

report() {
    local item mode_note='' reboot_word=no

    collect_holds
    collect_drift
    check_reboot

    ((WITH_NEW_PKGS)) && [[ $MODE == upgrade ]] && mode_note=' (--with-new-pkgs)'
    if ((!REBOOT_KNOWN)); then
        reboot_word='unknown (install update-notifier-common or needrestart to detect it)'
    elif ((REBOOT_REQUIRED)); then
        reboot_word=yes
    fi

    printf '\n'
    log INFO "Summary:"
    printf '  Mode                : %s%s\n' "$MODE" "$mode_note"
    printf '  Conffile policy     : keep %s\n' "$CONFFILE"
    printf '  Steps failed        : %d\n' "${#FAILED_STEPS[@]}"
    printf '  Held packages       : %s\n' "$(count_label "$HELD_KNOWN" "${#HELD[@]}")"
    printf '  Conffiles kept back : %s\n' "$(count_label "$DRIFT_KNOWN" "${#DRIFT[@]}")"
    printf '  Reboot pending      : %s\n' "$reboot_word"
    printf '\n'

    if ((${#FAILED_STEPS[@]})); then
        log ERROR "Failed steps:"
        for item in "${FAILED_STEPS[@]}"; do printf '  %s\n' "$item" >&2; done
        printf '\n'
    fi

    if ((${#HELD[@]})); then
        log WARN "Held by apt-mark, so never upgraded:"
        for item in "${HELD[@]}"; do printf '  %s\n' "$item" >&2; done
        log WARN "Release a hold with: apt-mark unhold <package>"
        printf '\n'
    fi

    if ((${#DRIFT[@]})); then
        log WARN "New package configuration left unmerged (your edits were kept):"
        for item in "${DRIFT[@]}"; do printf '  %s\n' "$item" >&2; done
        log WARN "Compare each against the live file, then delete it once reconciled."
        printf '\n'
    fi

    if ((REBOOT_REQUIRED)); then
        log WARN "Reboot required: $REBOOT_REASON"
        if [[ -r $REBOOT_PKGS_FILE ]]; then
            log WARN "Triggered by:"
            while IFS= read -r item; do printf '  %s\n' "$item" >&2; done <"$REBOOT_PKGS_FILE"
        fi
        log WARN "This script never reboots. Schedule that yourself."
        printf '\n'
    fi

    ((LOG_READY)) && log INFO "Full log: $LOG_FILE"
    return 0
}

# --- Traps -------------------------------------------------------------------

on_exit() {
    local rc=$?
    trap - EXIT INT TERM
    ((LOCK_HELD)) && exec 9>&-
    exit "$rc"
}

# apt and dpkg run in the foreground, and bash defers a trap until the running
# command returns. So this fires after the current apt-get finishes, not during
# it -- which is what you want: a dpkg killed mid-transaction is exactly the
# mess this repo's fix_broken_packages.sh exists to clean up.
on_signal() {
    log WARN "Interrupted"
    exit "$EX_INTERRUPT"
}

# --- Main --------------------------------------------------------------------

run_dry() {
    log INFO "Dry run: no index refresh, no package change."
    log INFO "The plan below is computed from the package indexes already on disk,"
    log INFO "which may be older than what the mirrors currently offer."
    show_plan
    report
    return "$EX_OK"
}

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
    # execve(), so apt and dpkg inherit it too. That is what stops a dropped SSH
    # session from killing dpkg in the middle of a transaction.
    trap '' HUP
    trap on_exit EXIT
    trap on_signal INT TERM

    if ((DRY_RUN)); then
        run_dry
        return $?
    fi

    # Fail before touching anything, rather than after the index refresh.
    if ((!ASSUME_YES)) && { [[ ! -t 0 ]] || [[ ! -t 1 ]]; }; then
        die "$EX_REFUSED" \
            "No terminal and no --yes. Refusing to change packages unattended without explicit consent (--yes, or LZC_UPDATE_UPGRADE_YES=1)."
    fi

    acquire_lock
    log INFO "Starting $SCRIPT_NAME v$SCRIPT_VERSION on $(hostname 2>/dev/null || printf 'this host')"

    do_update
    show_plan

    if ! confirm; then
        log INFO "Cancelled; nothing was upgraded."
        report
        # A failed index refresh is still a failure, even if the user then
        # declined the upgrade -- the documented contract says so.
        ((${#FAILED_STEPS[@]} == 0)) || return "$EX_FAILED"
        return "$EX_OK"
    fi

    # Cleanup only runs if the upgrade actually finished. apt computes "no
    # longer needed" from the package state in front of it, so after a
    # part-applied transaction that set is derived from a dependency graph this
    # run failed to bring to completion. The case that strands a host: a kernel
    # meta-package moves to a new ABI and orphans the running kernel's image,
    # the upgrade then fails (a failed initramfs build is the usual way), and
    # autoremove deletes the last kernel that still boots. --autoremove-purge
    # additionally deletes the packages' configuration.
    #
    # This is not the do_update case above, where continuing is deliberate:
    # there the failure is a stale index and the work still makes sense. Here
    # the work is package removal decided from a state the run has just
    # reported as broken.
    if do_upgrade; then
        do_autoremove
        do_clean
    else
        if ((AUTOREMOVE)); then
            log WARN "Skipping autoremove: the upgrade failed, so the set of"
            log WARN "packages 'nothing depends on' would be computed from a"
            log WARN "half-applied transaction. Re-run once the upgrade succeeds."
        fi
        log WARN "Skipping the archive cleanup so a retry can reuse the downloaded packages."
    fi

    report

    if ((${#FAILED_STEPS[@]})); then
        return "$EX_FAILED"
    fi
    # A pending reboot has already been reported by report(). It is not a
    # failure and it does not get an exit code of its own: a wrapper that needs
    # to act on it should test /run/reboot-required, which outlives this run.
    log SUCCESS "Done."
    return "$EX_OK"
}

main "$@"
