#!/usr/bin/env bash
#
# Proxmox VE LXC container updater.
#
# Updates every LXC container on this node one at a time, records per-container
# failures, and reports a summary. Runs interactively or fully unattended.
#
# License: MIT
# Origin:  https://github.com/Lazarev-Cloud/Scripts
#
# Error model: this script deliberately does NOT use `set -e`. Its whole job is
# to keep going when an individual container fails, so every fallible operation
# is checked explicitly and routed into FAILED[]. Do not add `set -e` and do not
# call this script as `update-lxcs.sh || true` -- both make the error handling
# non-local and reintroduce the bugs this rewrite removed.
set -uo pipefail

readonly SCRIPT_NAME='Proxmox VE LXC Updater'
readonly SCRIPT_VERSION='3.0'

# Exit codes, shared by every script in this repository. 75 is EX_TEMPFAIL from
# sysexits.h, which cron and systemd read as "retry later" rather than a fault.
readonly EX_FAIL=1 EX_USAGE=2 EX_PREREQ=3 EX_NOROOT=4
readonly EX_NOCONFIRM=5 EX_LOCKED=75 EX_INTERRUPT=130

# --- Tunables (env overridable, then flag overridable) -----------------------
LOG_FILE="${LZC_UPDATE_LXCS_LOG:-/var/log/lxc-updater.log}"
LOG_MAX_BYTES="${LZC_UPDATE_LXCS_LOG_MAX_BYTES:-5242880}"
LOCK_FILE="${LZC_UPDATE_LXCS_LOCK:-/run/lock/lxc-updater.lock}"
START_TIMEOUT="${LZC_UPDATE_LXCS_START_TIMEOUT:-60}"
READY_PROBE_TIMEOUT="${LZC_UPDATE_LXCS_READY_PROBE_TIMEOUT:-5}"
READY_POLL_INTERVAL="${LZC_UPDATE_LXCS_READY_POLL_INTERVAL:-2}"
SHUTDOWN_TIMEOUT="${LZC_UPDATE_LXCS_SHUTDOWN_TIMEOUT:-60}"
UPDATE_TIMEOUT="${LZC_UPDATE_LXCS_UPDATE_TIMEOUT:-1800}"
PROBE_TIMEOUT="${LZC_UPDATE_LXCS_PROBE_TIMEOUT:-20}"
RETRIES="${LZC_UPDATE_LXCS_RETRIES:-2}"
RETRY_DELAY="${LZC_UPDATE_LXCS_RETRY_DELAY:-10}"
EXCLUDE_SPEC="${LZC_UPDATE_LXCS_EXCLUDE:-}"
INCLUDE_SPEC="${LZC_UPDATE_LXCS_INCLUDE:-}"
ASSUME_YES="${LZC_UPDATE_LXCS_YES:-0}"
SKIP_STOPPED="${LZC_UPDATE_LXCS_SKIP_STOPPED:-0}"
CLUSTER_MODE="${LZC_UPDATE_LXCS_CLUSTER:-0}"
NODES_SPEC="${LZC_UPDATE_LXCS_NODES:-}"
SSH_USER="${LZC_UPDATE_LXCS_SSH_USER:-root}"
SSH_TIMEOUT="${LZC_UPDATE_LXCS_SSH_TIMEOUT:-15}"
SSH_EXTRA_OPTS="${LZC_UPDATE_LXCS_SSH_OPTS:-}"
DRY_RUN=0
USE_COLOR=auto

# Consumed by lib/lzc-obs.sh when it is available. Declared here so --logs-url
# and --metrics-url have something to assign to even when the library is not.
LZC_LOGS_URL="${LZC_LOGS_URL:-}"
LZC_METRICS_URL="${LZC_METRICS_URL:-}"

# --- Runtime state -----------------------------------------------------------
declare -a EXCLUDED=()
declare -a INCLUDED=()
declare -a STARTED_BY_US=()
declare -a FAILED=()
declare -a NEEDS_REBOOT=()
declare -a NODES_OK=()
declare -a NODES_FAILED=()
declare -a NODES_SKIPPED=()
SELF_PATH=''
OBS_LIB_PATH=''
COUNT_TOTAL=0
COUNT_UPDATED=0
COUNT_TEMPLATE=0
COUNT_EXCLUDED=0
LOG_READY=0
LOG_SINK=/dev/null
LOCK_HELD=0
YW='' BL='' RD='' GN='' CL=''

# --- Observability -----------------------------------------------------------
#
# Remote log and metric shipping lives in lib/lzc-obs.sh and is entirely
# optional. These no-op stubs are what runs when that library is not present, so
# every obs_* call below is safe unconditionally. _load_obs replaces them with
# the real implementations when it finds the library.

# Guarded: a cluster run prepends the real library to the payload it sends to
# each node, and these definitions come later in that stream. Without the guard
# they would silently replace the real implementations on every remote node.
if [[ -z ${_LZC_OBS_LOADED:-} ]]; then
    obs_init() { :; }
    obs_log() { :; }
    obs_metric() { :; }
    obs_finish() { :; }
    obs_cleanup() { :; }
    obs_enabled() { return 1; }
fi

_load_obs() {
    # Already present when a cluster run shipped the functions over SSH.
    if [[ -z ${_LZC_OBS_LOADED:-} ]]; then
        local candidate lib=''
        local -a search=()

        [[ -n ${LZC_LIB:-} ]] && search+=("$LZC_LIB")
        if [[ -n $SELF_PATH ]]; then
            local self_dir
            self_dir=$(dirname "$SELF_PATH")
            # A checkout, then an install of any prefix: installed as
            # <prefix>/sbin/<name>, the library sits at <prefix>/lib/lzc/.
            search+=("$self_dir/../../../lib/lzc-obs.sh"
                "$self_dir/../lib/lzc/lzc-obs.sh")
        fi
        search+=(/usr/local/lib/lzc/lzc-obs.sh /usr/lib/lzc/lzc-obs.sh)

        for candidate in "${search[@]}"; do
            if [[ -r $candidate ]]; then
                lib=$candidate
                break
            fi
        done

        if [[ -n $lib ]]; then
            # shellcheck source=/dev/null
            . "$lib" || return 0
            OBS_LIB_PATH=$lib
        fi
    fi

    # A no-op when nothing was loaded, so this is safe unconditionally.
    obs_init "$(basename "${SELF_PATH:-update-lxcs}" .sh)"
}

# --- Output ------------------------------------------------------------------

setup_color() {
    # NO_COLOR is honoured per no-color.org: any non-empty value disables colour.
    if [[ $USE_COLOR == never ]] ||
        { [[ $USE_COLOR == auto ]] && { [[ -n ${NO_COLOR:-} ]] || [[ ! -t 1 ]]; }; }; then
        return
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

    obs_log "$level" "$msg"
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

usage() {
    cat <<EOF
$SCRIPT_NAME v$SCRIPT_VERSION

Updates the packages of every LXC container on this Proxmox VE node.

Usage:
  update-lxcs.sh [options]

Options:
  -y, --yes                 Run unattended; skip prompts (needed for cron).
  -n, --dry-run             Report what would be done; change nothing.
  -e, --exclude IDS         Comma-separated CT IDs to skip. Repeatable.
  -i, --include IDS         Comma-separated CT IDs to update only.
                            Repeatable.
      --skip-stopped        Leave stopped containers alone (default: start,
                            update, then return them to stopped).
      --timeout SECONDS     Per-container update timeout (default: $UPDATE_TIMEOUT).
      --retries N           Update attempts per container (default: $RETRIES).
      --log-file PATH       Log file (default: $LOG_FILE).
      --color WHEN          auto | always | never (default: auto).
      --logs-url URL        Ship logs here. See docs/observability.md.
      --metrics-url URL     Ship run metrics here. Same.
  -V, --version             Print version and exit.
  -h, --help                Print this help and exit.

Cluster options:
  -c, --cluster             Update containers on every node in the cluster, not
                            just this one. Implies --yes.
      --nodes LIST          Comma-separated node names instead of autodiscovery.
      --local-only          Force single-node operation (overrides --cluster).
      --ssh-user USER       SSH user for remote nodes (default: $SSH_USER).

Cluster mode runs this same script on each remote node over SSH, which relies on
the passwordless root SSH trust that \`pvecm\` establishes between cluster
members. VMIDs are cluster-unique, so --exclude / --include work cluster-wide.
Each node keeps its own log and its own lock, so nodes are updated in sequence
and a node that is already running the updater is reported, not disturbed.

Most options also have an environment variable, which is the easier route when
piping this script in from the network. --dry-run, --color and --local-only are
flag-only. Boolean variables accept 1/true/yes/on and 0/false/no/off:
  LZC_UPDATE_LXCS_YES=1  LZC_UPDATE_LXCS_EXCLUDE=100,101
  LZC_UPDATE_LXCS_INCLUDE=
  LZC_UPDATE_LXCS_SKIP_STOPPED=1  LZC_UPDATE_LXCS_UPDATE_TIMEOUT=1800
  LZC_UPDATE_LXCS_RETRIES=2  LZC_UPDATE_LXCS_LOG=/var/log/lxc-updater.log
  LZC_UPDATE_LXCS_CLUSTER=1  LZC_UPDATE_LXCS_NODES=pve1,pve2
  LZC_UPDATE_LXCS_SSH_USER=root

Timeouts and paths, all seconds unless noted, all minimum 1:
  LZC_UPDATE_LXCS_LOCK=$LOCK_FILE
  LZC_UPDATE_LXCS_LOG_MAX_BYTES=$LOG_MAX_BYTES   rotate the log past this size
  LZC_UPDATE_LXCS_START_TIMEOUT=$START_TIMEOUT        wait for a container to boot
  LZC_UPDATE_LXCS_READY_PROBE_TIMEOUT=$READY_PROBE_TIMEOUT    each readiness probe
  LZC_UPDATE_LXCS_READY_POLL_INTERVAL=$READY_POLL_INTERVAL    between readiness probes
  LZC_UPDATE_LXCS_SHUTDOWN_TIMEOUT=$SHUTDOWN_TIMEOUT     graceful shutdown before stop
  LZC_UPDATE_LXCS_PROBE_TIMEOUT=$PROBE_TIMEOUT         in-guest probes (distro, df)
  LZC_UPDATE_LXCS_RETRY_DELAY=$RETRY_DELAY           between update attempts (min 0)
  LZC_UPDATE_LXCS_SSH_TIMEOUT=$SSH_TIMEOUT           SSH connect timeout
  LZC_UPDATE_LXCS_SSH_OPTS=''         extra ssh options, whitespace separated

Exit status:
  0    every selected container updated, or was skipped by choice
  1    a container failed, or a cluster node could not be reached
  2    usage error
  3    not a Proxmox VE node, or a required tool is missing
  4    not running as root
  5    confirmation needed but there is no terminal and --yes was not given
  75   another instance holds the lock; try again later
  130  interrupted

Remote invocation: because \`bash -c "\$(curl ...)"\` consumes \$0, flags must be
passed after a literal \`--\`. See the README for the pinned, checksum-verified
form -- fetching an unpinned branch and running it as root is not recommended.
EOF
}

# --- Argument parsing --------------------------------------------------------

append_spec() {
    local -n target=$1
    target="${target:+$target,}$2"
}

parse_args() {
    while (($#)); do
        case $1 in
            -y | --yes) ASSUME_YES=1 ;;
            -n | --dry-run) DRY_RUN=1 ;;
            -e | --exclude)
                [[ $# -ge 2 ]] || die "$EX_USAGE" "--exclude requires a comma-separated list of CT IDs"
                append_spec EXCLUDE_SPEC "$2"
                shift
                ;;
            -i | --include)
                [[ $# -ge 2 ]] || die "$EX_USAGE" "--include requires a comma-separated list of CT IDs"
                append_spec INCLUDE_SPEC "$2"
                shift
                ;;
            --skip-stopped) SKIP_STOPPED=1 ;;
            -c | --cluster)
                CLUSTER_MODE=1
                ASSUME_YES=1
                ;;
            --local-only) CLUSTER_MODE=0 ;;
            --nodes)
                [[ $# -ge 2 ]] || die "$EX_USAGE" "--nodes requires a comma-separated list of node names"
                NODES_SPEC=$2
                CLUSTER_MODE=1
                ASSUME_YES=1
                shift
                ;;
            --ssh-user)
                [[ $# -ge 2 ]] || die "$EX_USAGE" "--ssh-user requires a user name"
                SSH_USER=$2
                shift
                ;;
            --logs-url)
                [[ $# -ge 2 ]] || die "$EX_USAGE" "--logs-url requires an ingestion URL"
                LZC_LOGS_URL=$2
                shift
                ;;
            --metrics-url)
                [[ $# -ge 2 ]] || die "$EX_USAGE" "--metrics-url requires an ingestion URL"
                LZC_METRICS_URL=$2
                shift
                ;;
            --timeout)
                [[ $# -ge 2 ]] || die "$EX_USAGE" "--timeout requires a value in seconds"
                UPDATE_TIMEOUT=$2
                shift
                ;;
            --retries)
                [[ $# -ge 2 ]] || die "$EX_USAGE" "--retries requires a value"
                RETRIES=$2
                shift
                ;;
            --log-file)
                [[ $# -ge 2 ]] || die "$EX_USAGE" "--log-file requires a path"
                LOG_FILE=$2
                shift
                ;;
            --color)
                [[ $# -ge 2 ]] || die "$EX_USAGE" "--color requires auto, always or never"
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
                shift
                continue
                ;;
            *) die "$EX_USAGE" "Unknown option: $1 (try --help)" ;;
        esac
        shift
    done

    [[ $USE_COLOR =~ ^(auto|always|never)$ ]] || die "$EX_USAGE" "--color must be auto, always or never"

    local name
    for name in ASSUME_YES SKIP_STOPPED CLUSTER_MODE; do
        _normalise_bool "$name"
    done

    # Minimum 1, not 0: `timeout 0` means "no limit", so accepting 0 here would
    # silently remove the very protection the option exists to provide.
    for name in UPDATE_TIMEOUT START_TIMEOUT SHUTDOWN_TIMEOUT PROBE_TIMEOUT \
        SSH_TIMEOUT READY_PROBE_TIMEOUT READY_POLL_INTERVAL LOG_MAX_BYTES RETRIES; do
        _normalise_int "$name" 1
    done
    _normalise_int RETRY_DELAY 0
}

# Accepts the spellings people actually write in cron files and unit files.
# Without this, LZC_UPDATE_LXCS_YES=true reaches (( )) as a bare word and the script
# dies with "true: unbound variable" before doing anything.
_normalise_bool() {
    local name=$1 value
    case ${!name,,} in
        1 | true | yes | on) value=1 ;;
        0 | false | no | off | '') value=0 ;;
        *) die "$EX_USAGE" "$name must be true or false, got '${!name}'" ;;
    esac
    printf -v "$name" '%s' "$value"
}

_normalise_int() {
    local name=$1 min=$2 value
    [[ ${!name} =~ ^[0-9]+$ ]] || die "$EX_USAGE" "$name must be a whole number, got '${!name}'"
    # 10# forces base ten: a zero-padded value such as 08 is otherwise read as
    # an invalid octal literal and aborts the arithmetic.
    value=$((10#${!name}))
    ((value >= min)) || die "$EX_USAGE" "$name must be at least $min, got '${!name}'"
    printf -v "$name" '%s' "$value"
}

# Expands a comma/space separated ID list into the named array, rejecting
# anything that is not a plain integer.
parse_id_spec() {
    local -n out=$1
    local spec=$2 label=$3 token
    [[ -n $spec ]] || return 0
    local raw
    IFS=', ' read -r -a raw <<<"$spec"
    for token in "${raw[@]}"; do
        [[ -n $token ]] || continue
        [[ $token =~ ^[0-9]+$ ]] || die "$EX_USAGE" "Invalid container ID in $label list: '$token'"
        out+=("$token")
    done
}

in_list() {
    local needle=$1 name=$2
    local -n haystack=$name
    ((${#haystack[@]})) || return 1
    local item
    for item in "${haystack[@]}"; do
        [[ $item == "$needle" ]] && return 0
    done
    return 1
}

# --- Preflight ---------------------------------------------------------------

preflight() {
    [[ $EUID -eq 0 ]] || die "$EX_NOROOT" "This script must be run as root."
    command -v pct >/dev/null 2>&1 || die "$EX_PREREQ" "pct not found. This script must run on a Proxmox VE node."
    command -v timeout >/dev/null 2>&1 || die "$EX_PREREQ" "timeout (coreutils) not found."
    command -v flock >/dev/null 2>&1 || die "$EX_PREREQ" "flock (util-linux) not found."

    # Rotate before opening so a long-lived node does not grow an unbounded log.
    local size
    if [[ -f $LOG_FILE ]]; then
        size=$(wc -c 2>/dev/null <"$LOG_FILE") || size=0
        if ((size > LOG_MAX_BYTES)); then
            mv -f "$LOG_FILE" "$LOG_FILE.1" 2>/dev/null || true
        fi
    fi

    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
    if : >>"$LOG_FILE" 2>/dev/null; then
        LOG_READY=1
        LOG_SINK=$LOG_FILE
    else
        printf '%s[Warning]%s Cannot write %s; continuing without a log file.\n' \
            "$YW" "$CL" "$LOG_FILE" >&2
    fi
}

acquire_lock() {
    mkdir -p "$(dirname "$LOCK_FILE")" 2>/dev/null || true
    # EX_PREREQ, not EX_LOCKED: "cannot open" is a permanent misconfiguration
    # (unwritable /run/lock, missing directory), and 75 tells cron "transient,
    # retry later", so a broken host would retry forever instead of being
    # reported once. 75 is for a lock genuinely held by another run.
    exec 9>"$LOCK_FILE" || die "$EX_PREREQ" "Cannot open lock file $LOCK_FILE"
    flock -n 9 || die "$EX_LOCKED" "Another $SCRIPT_NAME run holds $LOCK_FILE. Refusing to run concurrently."
    LOCK_HELD=1
}

# --- Container inspection ----------------------------------------------------

# IDs only. Names and everything else come from `pct config`, whose key: value
# format is stable, rather than from the positional columns of `pct list`.
list_container_ids() {
    pct list 2>/dev/null | awk 'NR > 1 && $1 ~ /^[0-9]+$/ { print $1 }'
}

config_value() {
    local id=$1 key=$2
    pct config "$id" 2>/dev/null | sed -n "s/^${key}: //p" | head -n1
}

container_status() {
    pct status "$1" 2>/dev/null | awk '{ print $2 }'
}

is_template() {
    [[ $(config_value "$1" template) == 1 ]]
}

is_locked() {
    [[ -n $(config_value "$1" lock) ]]
}

# Runs a command inside the container under a hard timeout, so one wedged
# package manager cannot stall the entire node's update run.
ct_exec() {
    local id=$1 secs=$2
    shift 2
    timeout --foreground "$secs" pct exec "$id" -- "$@"
}

# Resolves the package-manager family. `pct config` ostype is authoritative when
# set, but containers created outside PVE tooling report `unmanaged`, so fall
# back to reading /etc/os-release from inside the running guest.
detect_family() {
    local id=$1 ostype family
    ostype=$(config_value "$id" ostype)

    family=$(family_from_id "$ostype")
    if [[ -n $family ]]; then
        printf '%s' "$family"
        return 0
    fi

    local os_release
    # Single quotes are deliberate: ID and ID_LIKE must expand in the guest's
    # shell, not this one.
    # shellcheck disable=SC2016
    os_release=$(ct_exec "$id" "$PROBE_TIMEOUT" sh -c \
        '. /etc/os-release 2>/dev/null && printf "%s %s" "${ID:-}" "${ID_LIKE:-}"' 2>/dev/null) || return 1

    local token
    for token in $os_release; do
        family=$(family_from_id "$token")
        if [[ -n $family ]]; then
            printf '%s' "$family"
            return 0
        fi
    done
    return 1
}

family_from_id() {
    case ${1,,} in
        debian | devuan | ubuntu | raspbian | linuxmint | pop) printf 'debian' ;;
        centos | fedora | rocky | almalinux | alma | rhel | ol | oracle | amzn) printf 'rhel' ;;
        alpine) printf 'alpine' ;;
        archlinux | arch | manjaro) printf 'arch' ;;
        opensuse | opensuse-leap | opensuse-tumbleweed | sles | suse) printf 'suse' ;;
        *) return 1 ;;
    esac
}

update_command_for() {
    case $1 in
        debian)
            printf '%s' 'export DEBIAN_FRONTEND=noninteractive; apt-get update -qq && apt-get -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold dist-upgrade && apt-get -y --purge autoremove && apt-get clean'
            ;;
        rhel)
            printf '%s' 'if command -v dnf >/dev/null 2>&1; then dnf -y upgrade && dnf -y clean packages; else yum -y update && yum -y clean packages; fi'
            ;;
        alpine) printf '%s' 'apk update && apk upgrade' ;;
        arch) printf '%s' 'pacman -Syu --noconfirm' ;;
        suse) printf '%s' 'zypper --non-interactive refresh && zypper --non-interactive dup' ;;
        *) return 1 ;;
    esac
}

# The container's root filesystem, not /boot -- an LXC guest shares the host
# kernel and its /boot is normally empty.
disk_summary() {
    local id=$1 out
    out=$(ct_exec "$id" "$PROBE_TIMEOUT" df -P / 2>/dev/null |
        awk 'NR == 2 { printf "%s used of %.1fG (%.1fG free)", $5, $2 / 1048576, $4 / 1048576 }') || return 1
    [[ -n $out ]] || return 1
    printf '%s' "$out"
}

# An LXC guest shares the host kernel, so "needs reboot" here means "restart the
# container to pick up replaced libraries and services", not a kernel upgrade.
needs_reboot() {
    local id=$1 family=$2
    case $family in
        debian)
            ct_exec "$id" "$PROBE_TIMEOUT" sh -c \
                'test -f /run/reboot-required || test -f /var/run/reboot-required' >/dev/null 2>&1 && return 0
            ;;
        rhel)
            # needs-restarting ships in dnf-utils/yum-utils and is absent from
            # minimal images. Absent means unknown, not "reboot needed".
            if ct_exec "$id" "$PROBE_TIMEOUT" sh -c 'command -v needs-restarting >/dev/null 2>&1' >/dev/null 2>&1; then
                ct_exec "$id" "$PROBE_TIMEOUT" needs-restarting -r >/dev/null 2>&1 || return 0
            fi
            ;;
        arch | alpine | suse)
            # No dependable in-guest indicator; checkrestart/needrestart are not
            # installed by default. Reported as unknown rather than guessed.
            :
            ;;
    esac
    return 1
}

# --- Container lifecycle -----------------------------------------------------

wait_until_ready() {
    local id=$1 deadline=$((SECONDS + START_TIMEOUT))
    while ((SECONDS < deadline)); do
        if ct_exec "$id" "$READY_PROBE_TIMEOUT" true >/dev/null 2>&1; then
            return 0
        fi
        sleep "$READY_POLL_INTERVAL"
    done
    return 1
}

start_container() {
    local id=$1
    log INFO "Starting container $id"
    if ! pct start "$id" >>"$LOG_SINK" 2>&1; then
        return 1
    fi
    STARTED_BY_US+=("$id")
    wait_until_ready "$id"
}

stop_container() {
    local id=$1
    log INFO "Returning container $id to stopped"
    if pct shutdown "$id" --timeout "$SHUTDOWN_TIMEOUT" >>"$LOG_SINK" 2>&1; then
        return 0
    fi
    log WARN "Graceful shutdown of container $id failed; forcing stop"
    pct stop "$id" >>"$LOG_SINK" 2>&1
}

# Called from the EXIT trap so an interrupted run does not leave containers
# running that were stopped before the script touched them.
restore_started_containers() {
    ((${#STARTED_BY_US[@]})) || return 0
    ((SKIP_STOPPED)) && return 0
    local id
    for id in "${STARTED_BY_US[@]}"; do
        if [[ $(container_status "$id") == running ]]; then
            stop_container "$id" || log WARN "Could not stop container $id during cleanup"
        fi
    done
    STARTED_BY_US=()
}

forget_started() {
    local id=$1 keep=() item
    for item in "${STARTED_BY_US[@]}"; do
        [[ $item == "$id" ]] || keep+=("$item")
    done
    STARTED_BY_US=(${keep[@]+"${keep[@]}"})
}

# --- The per-container workflow ----------------------------------------------

update_one() {
    local id=$1
    local name status family cmd disk attempt rc
    local started=0

    name=$(config_value "$id" hostname)
    [[ -n $name ]] || name="ct$id"

    if is_template "$id"; then
        log INFO "Skipping template $id ($name)"
        COUNT_TEMPLATE=$((COUNT_TEMPLATE + 1))
        return 0
    fi

    # Counted as a failure, not a skip: the container was scheduled for patching
    # and did not get patched. Saying "skipped" here while the summary counts it
    # under Failed is how an unpatched container goes unnoticed.
    if is_locked "$id"; then
        log WARN "Container $id ($name) not updated: locked by another PVE task (backup, snapshot or migration in progress)"
        FAILED+=("$id ($name): locked by another PVE task")
        return 1
    fi

    status=$(container_status "$id")
    case $status in
        running) ;;
        stopped)
            if ((SKIP_STOPPED)); then
                log INFO "Skipping stopped container $id ($name) (--skip-stopped)"
                return 0
            fi
            if ((DRY_RUN)); then
                log INFO "[dry-run] Would start, update and re-stop container $id ($name)"
                return 0
            fi
            if ! start_container "$id"; then
                log ERROR "Container $id ($name) did not become ready within ${START_TIMEOUT}s"
                FAILED+=("$id ($name): failed to start")
                return 1
            fi
            started=1
            ;;
        '')
            log ERROR "Container $id: cannot read status"
            FAILED+=("$id ($name): unreadable status")
            return 1
            ;;
        *)
            log WARN "Skipping container $id ($name): unexpected state '$status'"
            FAILED+=("$id ($name): unexpected state '$status'")
            return 1
            ;;
    esac

    if ! family=$(detect_family "$id"); then
        log ERROR "Container $id ($name): unsupported or undetectable distribution"
        FAILED+=("$id ($name): unsupported distribution")
        ((started)) && stop_container "$id" && forget_started "$id"
        return 1
    fi

    if disk=$(disk_summary "$id"); then
        log INFO "Updating $id ($name) -- $family, rootfs $disk"
    else
        log INFO "Updating $id ($name) -- $family"
    fi

    if ((DRY_RUN)); then
        log INFO "[dry-run] Would run the $family update for container $id ($name)"
        return 0
    fi

    cmd=$(update_command_for "$family") || {
        FAILED+=("$id ($name): no update command for $family")
        return 1
    }

    rc=1
    for ((attempt = 1; attempt <= RETRIES; attempt++)); do
        # Guest output is streamed and logged: a failing update has to be
        # diagnosable, which is why stderr is never discarded here.
        ct_exec "$id" "$UPDATE_TIMEOUT" sh -c "$cmd" 2>&1 | tee -a "$LOG_SINK"
        rc=${PIPESTATUS[0]}
        ((rc == 0)) && break

        if ((rc == 124)); then
            log WARN "Container $id ($name): update timed out after ${UPDATE_TIMEOUT}s (attempt $attempt/$RETRIES)"
        else
            log WARN "Container $id ($name): update failed with status $rc (attempt $attempt/$RETRIES)"
        fi
        ((attempt < RETRIES)) && sleep "$RETRY_DELAY"
    done

    if ((rc != 0)); then
        log ERROR "Container $id ($name): giving up after $RETRIES attempt(s)"
        FAILED+=("$id ($name): update failed (status $rc)")
    else
        log SUCCESS "Container $id ($name) updated"
        COUNT_UPDATED=$((COUNT_UPDATED + 1))
        if needs_reboot "$id" "$family"; then
            NEEDS_REBOOT+=("$id ($name)")
        fi
    fi

    if ((started)); then
        stop_container "$id" || log WARN "Could not return container $id to stopped"
        forget_started "$id"
    fi

    return "$((rc == 0 ? 0 : 1))"
}

# --- Interactive selection ---------------------------------------------------

# Terminal geometry, for sizing the whiptail dialogs. whiptail clamps to the
# real screen itself, so being approximate here is safe; what this prevents is
# the opposite problem, a dialog hard-coded to 20 rows that stays 20 rows on a
# 45-row terminal.
term_size() {
    local rows cols
    rows=$(tput lines 2>/dev/null) || rows=''
    cols=$(tput cols 2>/dev/null) || cols=''
    [[ $rows =~ ^[0-9]+$ ]] && ((rows > 0)) || rows=24
    [[ $cols =~ ^[0-9]+$ ]] && ((cols > 0)) || cols=80
    printf '%s %s' "$rows" "$cols"
}

select_exclusions() {
    command -v whiptail >/dev/null 2>&1 || {
        log WARN "whiptail not installed; skipping the exclusion picker"
        return 0
    }

    local menu=() id name idw=0 namew=0
    while read -r id; do
        name=$(config_value "$id" hostname)
        [[ -n $name ]] || name="ct$id"
        ((${#id} > idw)) && idw=${#id}
        ((${#name} > namew)) && namew=${#name}
        menu+=("$id" "$name" OFF)
    done < <(list_container_ids)

    local count=$((${#menu[@]} / 3))
    ((count)) || return 0

    local rows cols
    read -r rows cols < <(term_size)

    local title
    title="Containers on $(hostname)"

    # +8 is exact, and measured rather than guessed: top border, the prompt's
    # blank/text/blank, a blank, the button row, a blank, bottom border. Any
    # larger and whiptail leaves dead rows under the list -- the old fixed 20
    # against a list height of 10 left three of them. Any smaller and it
    # silently drops the prompt text instead of shrinking the box.
    local listh=$count maxlist=$((rows - 10))
    ((maxlist < 3)) && maxlist=3
    ((listh > maxlist)) && listh=$maxlist
    local height=$((listh + 8))

    # whiptail draws its own scrollbar when the list overflows, so the count is
    # the part it cannot show: "8 of 40" is a different decision from "8 of 9".
    local text='Select containers to skip:'
    ((listh < count)) && text="Select containers to skip ($count total):"
    local prompt="\n$text\n"

    # Wide enough for whichever is longest: a list row, the title, or the
    # prompt. whiptail lays a checklist row out as two spaces, "[ ]", a space,
    # the tag, two spaces, then the item, inside one column of border and one
    # of padding each side -- the id and name widths plus 12, plus two more for
    # the scrollbar when there is one. Sizing from the *measured* id width
    # matters on a node whose VMIDs have run past four digits: the previous
    # formula counted the name only, so those rows were silently clipped. And
    # the prompt has to be counted too, or the very notice that says the list
    # scrolled gets truncated mid-sentence.
    local width=$((idw + namew + 12))
    ((listh < count)) && width=$((width + 2))
    ((width < ${#title} + 8)) && width=$((${#title} + 8))
    ((width < ${#text} + 6)) && width=$((${#text} + 6))
    ((width < 40)) && width=40
    ((width > cols - 4)) && width=$((cols - 4))

    local raw
    raw=$(whiptail --backtitle "$SCRIPT_NAME" \
        --title "$title" \
        --checklist "$prompt" \
        "$height" "$width" "$listh" \
        "${menu[@]}" 3>&1 1>&2 2>&3) || return 0

    local token
    for token in $raw; do
        token=${token//\"/}
        [[ $token =~ ^[0-9]+$ ]] && EXCLUDED+=("$token")
    done
}

confirm() {
    if command -v whiptail >/dev/null 2>&1; then
        local msg
        msg="Update the LXC containers on $(hostname)?"
        local rows cols
        read -r rows cols < <(term_size)
        # Sized to the message rather than fixed at 60: a node with a long
        # fully-qualified hostname had the question wrapped or clipped.
        local width=$((${#msg} + 8))
        ((width < 40)) && width=40
        ((width > cols - 4)) && width=$((cols - 4))
        whiptail --backtitle "$SCRIPT_NAME" --title "$SCRIPT_NAME" \
            --yesno "$msg" 8 "$width"
        return
    fi
    local reply
    read -r -p "Update the LXC containers on $(hostname)? [y/N] " reply
    [[ ${reply,,} == y* ]]
}

# --- Reporting ---------------------------------------------------------------

summary() {
    local failed=${#FAILED[@]} reboot=${#NEEDS_REBOOT[@]} item

    printf '\n'
    log INFO "Summary for $(hostname):"
    printf '  Containers on node : %d\n' "$COUNT_TOTAL"
    printf '  Updated            : %d\n' "$COUNT_UPDATED"
    printf '  Skipped (excluded) : %d\n' "$COUNT_EXCLUDED"
    printf '  Skipped (template) : %d\n' "$COUNT_TEMPLATE"
    printf '  Failed             : %d\n' "$failed"
    printf '  Restart advised    : %d\n' "$reboot"
    printf '\n'

    if ((failed)); then
        log ERROR "Failures:"
        for item in "${FAILED[@]}"; do printf '  %s\n' "$item" >&2; done
        printf '\n'
    fi

    if ((reboot)); then
        log WARN "Restart advised (replaced libraries or services):"
        for item in "${NEEDS_REBOOT[@]}"; do printf '  %s\n' "$item" >&2; done
        printf '\n'
    fi

    ((LOG_READY)) && log INFO "Full log: $LOG_FILE"

    # Gauges, so "state" is a label rather than six separate metric names.
    obs_metric lzc_lxc_containers "$COUNT_TOTAL" state=total
    obs_metric lzc_lxc_containers "$COUNT_UPDATED" state=updated
    obs_metric lzc_lxc_containers "$COUNT_EXCLUDED" state=excluded
    obs_metric lzc_lxc_containers "$COUNT_TEMPLATE" state=template
    obs_metric lzc_lxc_containers "$failed" state=failed
    obs_metric lzc_lxc_containers "$reboot" state=restart_advised

    return 0
}

on_exit() {
    local rc=$?
    trap - EXIT INT TERM HUP
    restore_started_containers
    # Ships whatever was buffered, including on the interrupted path -- a run
    # that died half way is exactly the one worth seeing in the log store.
    obs_finish "$rc"
    ((LOCK_HELD)) && exec 9>&-
    exit "$rc"
}

on_signal() {
    log WARN "Interrupted -- restoring container states before exit"
    exit "$EX_INTERRUPT"
}

# --- Cluster -----------------------------------------------------------------

# Node names, one per line. `pvecm nodes` is the authoritative view of live
# membership; /etc/pve/nodes is the fallback, but it also retains directories for
# removed nodes, so the discovered list is always logged for the operator to see.
cluster_nodes() {
    local found=''

    if command -v pvecm >/dev/null 2>&1; then
        found=$(pvecm nodes 2>/dev/null | awk '$1 ~ /^[0-9]+$/ { print $3 }' | sed 's/(local)//')
    fi

    if [[ -z $found && -d /etc/pve/nodes ]]; then
        found=$(find /etc/pve/nodes -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null)
        [[ -n $found ]] && log WARN "pvecm gave no members; falling back to /etc/pve/nodes (may list removed nodes)"
    fi

    [[ -n $found ]] || return 1
    printf '%s\n' "$found" | awk 'NF'
}

# This node's name as the *cluster* knows it. `pvecm nodes` marks the local
# member, which is authoritative; `hostname` may return an FQDN and drift from
# the membership list. If they drift, run_cluster would fail to recognise itself
# and SSH to localhost, colliding with the lock it already holds.
local_node_name() {
    local name=''
    if command -v pvecm >/dev/null 2>&1; then
        name=$(pvecm nodes 2>/dev/null |
            awk '/\(local\)/ && $1 ~ /^[0-9]+$/ { print $3 }')
    fi
    [[ -n $name ]] || name=$(hostname -s 2>/dev/null)
    [[ -n $name ]] || name=$(hostname)
    printf '%s' "$name"
}

# The script text to run on a remote node. Normally the file itself; when this
# script was piped in from the network there is no file, so an equivalent one is
# reconstructed from the live function and variable definitions. Either way the
# remote node runs exactly the code this node is running -- it never re-fetches.

# Telemetry settings for the remote node, emitted ahead of the script body in
# both transport modes. Every consumer reads these as "${VAR:-}", so assigning
# them first is enough for the values to survive into the remote run.
_obs_remote_env() {
    local v
    for v in LZC_LOGS_URL LZC_LOGS_FORMAT LZC_METRICS_URL LZC_METRICS_FORMAT \
        LZC_OBS_JOB LZC_OBS_LABELS LZC_OBS_TIMEOUT LZC_OBS_TENANT \
        LZC_OBS_TOKEN_ENV LZC_OBS_USER LZC_OBS_PASSWORD_ENV LZC_OBS_BUFFER \
        LZC_OBS_DEBUG LZC_OBS_INSECURE LZC_OBS_RETRIES LZC_OBS_CONNECT_TIMEOUT; do
        [[ -n ${!v:-} ]] && printf '%s=%q\n' "$v" "${!v}"
    done

    # The credential itself, under the name the configuration points at. It
    # travels inside the encrypted SSH stream and never reaches a command line,
    # a process list, or a file on either node.
    #
    # The name is checked against the identifier grammar first. Unlike the loop
    # above, which walks a literal list, these two come from user configuration,
    # and `${!v}` is not a plain lookup: bash parses the value as a variable
    # reference, so a non-identifier is a fatal expansion error that kills this
    # script mid-fleet-update, and an array subscript inside it is *evaluated*
    # -- `LZC_OBS_TOKEN_ENV='x[$(...)]'` would run the substitution as root.
    for v in "${LZC_OBS_TOKEN_ENV:-}" "${LZC_OBS_PASSWORD_ENV:-}"; do
        [[ -n $v ]] || continue
        if [[ ! $v =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
            log WARN "Ignoring '$v': expected the NAME of an environment variable, not a value."
            continue
        fi
        [[ -n ${!v:-} ]] && printf '%s=%q\n' "$v" "${!v}"
    done

    # Cleared so each node reports under its own instance label.
    printf 'LZC_OBS_INSTANCE=\n'
}

remote_payload() {
    _obs_remote_env

    # Inlining the library means the remote node ships telemetry even when it
    # has no copy of it installed.
    [[ -n $OBS_LIB_PATH && -r $OBS_LIB_PATH ]] && cat "$OBS_LIB_PATH"

    if [[ -n $SELF_PATH ]]; then
        cat "$SELF_PATH"
        return
    fi

    printf 'set -uo pipefail\n'
    # The exit-code constants first. Without them the remote parses fine and
    # then dies on its first error path -- `die "$EX_LOCKED"` on a held lock --
    # with "EX_LOCKED: unbound variable" under set -u, at exactly the moment it
    # most needs to report cleanly.
    declare -p EX_FAIL EX_USAGE EX_PREREQ EX_NOROOT \
        EX_NOCONFIRM EX_LOCKED EX_INTERRUPT 2>/dev/null

    # Every tunable parse_args normalises must appear here, or the remote dies
    # inside _normalise_int before touching a container: `${!name}` on an unset
    # name under set -u aborts immediately. READY_PROBE_TIMEOUT and
    # READY_POLL_INTERVAL were missing, which broke piped cluster runs outright.
    # Keep this list in step with the normalise loop in parse_args.
    declare -p SCRIPT_NAME SCRIPT_VERSION LOG_FILE LOG_MAX_BYTES LOCK_FILE \
        START_TIMEOUT SHUTDOWN_TIMEOUT UPDATE_TIMEOUT PROBE_TIMEOUT \
        READY_PROBE_TIMEOUT READY_POLL_INTERVAL \
        RETRIES RETRY_DELAY SSH_USER SSH_TIMEOUT SSH_EXTRA_OPTS 2>/dev/null

    printf '%s\n' \
        'EXCLUDE_SPEC= INCLUDE_SPEC= NODES_SPEC= ASSUME_YES=1' \
        'SKIP_STOPPED=0 CLUSTER_MODE=0 DRY_RUN=0 USE_COLOR=never SELF_PATH=' \
        'declare -a EXCLUDED=() INCLUDED=() STARTED_BY_US=() FAILED=() NEEDS_REBOOT=()' \
        'declare -a NODES_OK=() NODES_FAILED=() NODES_SKIPPED=()' \
        'COUNT_TOTAL=0 COUNT_UPDATED=0 COUNT_TEMPLATE=0 COUNT_EXCLUDED=0' \
        'LOG_READY=0 LOG_SINK=/dev/null LOCK_HELD=0' \
        "YW='' BL='' RD='' GN='' CL=''"
    declare -f
    printf 'main "$@"\n'
}

run_remote_node() {
    local node=$1 rc
    local -a args=(--local-only --yes --color never
        --timeout "$UPDATE_TIMEOUT" --retries "$RETRIES")
    ((DRY_RUN)) && args+=(--dry-run)
    ((SKIP_STOPPED)) && args+=(--skip-stopped)
    [[ -n $EXCLUDE_SPEC ]] && args+=(--exclude "$EXCLUDE_SPEC")
    [[ -n $INCLUDE_SPEC ]] && args+=(--include "$INCLUDE_SPEC")

    local -a ssh_cmd=(ssh -o BatchMode=yes -o ConnectTimeout="$SSH_TIMEOUT")
    if [[ -n $SSH_EXTRA_OPTS ]]; then
        local -a extra
        read -r -a extra <<<"$SSH_EXTRA_OPTS"
        ssh_cmd+=("${extra[@]}")
    fi
    ssh_cmd+=("${SSH_USER}@${node}" "bash -s -- $(printf '%q ' "${args[@]}")")

    log INFO "--- node $node (remote) ---"
    remote_payload | "${ssh_cmd[@]}" 2>&1 | sed "s/^/[$node] /"
    rc=${PIPESTATUS[1]}

    case $rc in
        0)
            NODES_OK+=("$node")
            log SUCCESS "Node $node completed"
            ;;
        "$EX_LOCKED")
            # Not a failure, and deliberately not counted as one: the node is
            # already being updated by another run. Calling that a fault would
            # page someone for the one outcome that needs no action, which is
            # the whole reason 75 exists in the shared table.
            NODES_SKIPPED+=("$node: already running the updater")
            log INFO "Node $node: another run holds its lock; left alone"
            ;;
        255)
            NODES_FAILED+=("$node: unreachable over SSH")
            log ERROR "Node $node: SSH connection failed"
            ;;
        *)
            NODES_FAILED+=("$node: updater exited $rc")
            log ERROR "Node $node: updater exited $rc"
            ;;
    esac
}

run_cluster() {
    local -a nodes=()
    local listing rc
    if [[ -n $NODES_SPEC ]]; then
        IFS=', ' read -r -a nodes <<<"$NODES_SPEC"
    else
        # Same process-substitution trap as run_local_node: cluster_nodes
        # signals "membership could not be read" with a non-zero status, and
        # `mapfile < <(...)` would drop it.
        listing=$(cluster_nodes)
        rc=$?

        # On a working node /etc/pve/nodes always contains at least this host,
        # so reaching here means /etc/pve is not mounted -- a cluster whose
        # members cannot be read, not a standalone host. Degrading to "just do
        # the local node" would silently patch one node and report success for
        # a run the operator asked to cover the whole cluster.
        if ((rc != 0)); then
            log ERROR "Cannot determine cluster membership: pvecm reported no members and /etc/pve/nodes could not be read"
            log ERROR "Pass --nodes to name them explicitly, or --local-only for a deliberate single-node run"
            NODES_FAILED+=("$(hostname): cluster membership unreadable")
            return "$EX_FAIL"
        fi

        [[ -n $listing ]] && mapfile -t nodes <<<"$listing"
    fi

    if ((${#nodes[@]} == 0)); then
        log WARN "No cluster membership found; treating this as a standalone node"
        run_local_node
        return
    fi

    log INFO "Cluster nodes: ${nodes[*]}"

    local node local_node
    local_node=$(local_node_name)
    for node in "${nodes[@]}"; do
        # Compared on the short name: one side may carry a domain suffix.
        if [[ ${node%%.*} == "${local_node%%.*}" ]]; then
            log INFO "--- node $node (local) ---"
            run_local_node
            if ((${#FAILED[@]})); then
                NODES_FAILED+=("$node: ${#FAILED[@]} container(s) failed")
            else
                NODES_OK+=("$node")
            fi
        else
            run_remote_node "$node"
        fi
    done

    cluster_summary
}

cluster_summary() {
    local item
    printf '\n'
    log INFO "Cluster summary: ${#NODES_OK[@]} node(s) OK, ${#NODES_SKIPPED[@]} already running, ${#NODES_FAILED[@]} with problems"
    obs_metric lzc_lxc_nodes "${#NODES_OK[@]}" state=ok
    obs_metric lzc_lxc_nodes "${#NODES_SKIPPED[@]}" state=locked
    obs_metric lzc_lxc_nodes "${#NODES_FAILED[@]}" state=failed
    if ((${#NODES_SKIPPED[@]})); then
        for item in "${NODES_SKIPPED[@]}"; do printf '  %s\n' "$item"; done
        printf '\n'
    fi
    if ((${#NODES_FAILED[@]})); then
        for item in "${NODES_FAILED[@]}"; do printf '  %s\n' "$item" >&2; done
        printf '\n'
    fi
    return 0
}

# --- Main --------------------------------------------------------------------

run_local_node() {
    local ids=() id listing rc

    # Capture the status before the array. `pipefail` already gives
    # list_container_ids a non-zero status when `pct list` fails, but
    # `mapfile < <(...)` discards the status of a process substitution, so
    # reading it straight into the array throws that away.
    listing=$(list_container_ids)
    rc=$?

    # "Could not enumerate" is not "there is nothing here". `pct` still exists
    # when pvedaemon or pve-cluster is down, so preflight passes and this is the
    # first thing that notices. Reporting success would mean a node whose
    # containers were never even listed looks patched.
    if ((rc != 0)); then
        log ERROR "Cannot list containers on $(hostname): pct list failed (status $rc)"
        FAILED+=("$(hostname): pct list failed (status $rc); no container was inspected")
        return "$EX_FAIL"
    fi

    [[ -n $listing ]] && mapfile -t ids <<<"$listing"
    COUNT_TOTAL=${#ids[@]}

    if ((COUNT_TOTAL == 0)); then
        log WARN "No LXC containers found on this node"
        return 0
    fi

    for id in "${ids[@]}"; do
        if ((${#INCLUDED[@]})) && ! in_list "$id" INCLUDED; then
            continue
        fi
        if in_list "$id" EXCLUDED; then
            log INFO "Skipping excluded container $id"
            COUNT_EXCLUDED=$((COUNT_EXCLUDED + 1))
            continue
        fi
        update_one "$id"
    done

    summary
}

main() {
    parse_args "$@"
    setup_color
    banner

    local src=${BASH_SOURCE[0]:-}
    [[ -n $src && -r $src ]] && SELF_PATH=$src

    preflight
    acquire_lock
    _load_obs

    trap on_exit EXIT
    # HUP matters because cluster mode runs this over SSH: a dropped connection
    # sends the remote shell HUP, not TERM, and without it the cleanup that
    # returns containers to stopped would never run on that node.
    trap on_signal INT TERM HUP

    log INFO "Starting $SCRIPT_NAME v$SCRIPT_VERSION on $(hostname)"
    ((DRY_RUN)) && log INFO "Dry run: no container will be started, updated or stopped"

    parse_id_spec EXCLUDED "$EXCLUDE_SPEC" exclude
    parse_id_spec INCLUDED "$INCLUDE_SPEC" include

    if ((!ASSUME_YES)); then
        # Refuse rather than assume consent: an unattended run that nobody asked
        # for is exactly how a maintenance script surprises someone.
        if [[ ! -t 0 || ! -t 1 ]]; then
            die "$EX_NOCONFIRM" \
                "Refusing to run unattended without confirmation. Pass --yes (or set LZC_UPDATE_LXCS_YES=1)."
        fi
        confirm || {
            log INFO "Cancelled by user"
            return 0
        }
        ((${#INCLUDED[@]})) || select_exclusions
    fi

    ((${#EXCLUDED[@]})) && log INFO "Excluding: ${EXCLUDED[*]}"
    ((${#INCLUDED[@]})) && log INFO "Limiting to: ${INCLUDED[*]}"

    if ((CLUSTER_MODE)); then
        command -v ssh >/dev/null 2>&1 || die "$EX_PREREQ" "ssh not found; cluster mode needs it to reach other nodes."
        run_cluster
        ((${#NODES_FAILED[@]} == 0)) && return 0
        # Unreachable nodes and failed containers share exit 1, matching the
        # repo-wide table. The two are told apart by the lzc_lxc_nodes metric
        # and by the summary, not by overloading the exit status.
        return "$EX_FAIL"
    fi

    run_local_node
    ((${#FAILED[@]} == 0))
}

main "$@"
