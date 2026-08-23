#!/usr/bin/env bash
#
# Network interface restart, with a rollback so a bad bounce self-recovers.
#
# Detects which subsystem owns the interface (NetworkManager, systemd-networkd,
# ifupdown, or plain iproute2), bounces it, waits for it to come back, and
# verifies connectivity. A rollback is armed BEFORE the interface goes down and
# is only cancelled once verification passes, so a run that is killed between
# "down" and "up" -- the classic way to strand a remote host -- still recovers.
#
# License: MIT
# Origin:  https://github.com/Lazarev-Cloud/Scripts
#
# Error model: `set -Eeuo pipefail`. This is a linear script: preflight, snapshot,
# arm rollback, bounce, verify, cancel. Aborting on the first unexpected failure
# is the correct behaviour here precisely because the rollback is already armed
# when the risky part starts -- a dead script leaves a recovering host, not a
# half-configured one. Every fallible command is still checked explicitly; -e is
# a backstop, not the error handling.
set -Eeuo pipefail
# bash >= 4.4. Not fatal if missing: the assignments below are all single
# commands, whose status set -e sees with or without this.
shopt -s inherit_errexit 2>/dev/null || true

# SSH hang-ups must not kill this script mid-bounce. An *ignored* disposition is
# inherited across execve(), so ip/nmcli/ifup children ignore HUP too; a
# *handled* one would be reset to default in the child. This must be `trap ''`.
trap '' HUP

readonly SCRIPT_NAME='Network Interface Restart'
readonly SCRIPT_VERSION='2.2'

# Exit codes, shared by every script in this repository. 75 is EX_TEMPFAIL from
# sysexits.h, which cron and systemd read as "retry later" rather than a fault.
readonly EX_FAIL=1 EX_USAGE=2 EX_PREREQ=3 EX_NOROOT=4
readonly EX_NOCONFIRM=5 EX_LOCKED=75 EX_INTERRUPT=130

# --- Tunables (env overridable, then flag overridable) -----------------------
IFACE="${LZC_NETWORK_RESTART_INTERFACE:-}"
MANAGER="${LZC_NETWORK_RESTART_MANAGER:-auto}"
ROLLBACK_SECS="${LZC_NETWORK_RESTART_ROLLBACK:-120}"
WAIT_SECS="${LZC_NETWORK_RESTART_WAIT:-60}"
SETTLE_SECS="${LZC_NETWORK_RESTART_SETTLE:-2}"
CHECK_HOST="${LZC_NETWORK_RESTART_CHECK_HOST:-auto}"
PING_COUNT="${LZC_NETWORK_RESTART_PING_COUNT:-3}"
PING_WAIT="${LZC_NETWORK_RESTART_PING_WAIT:-2}"
CMD_TIMEOUT="${LZC_NETWORK_RESTART_TIMEOUT:-30}"
STATE_DIR="${LZC_NETWORK_RESTART_STATE_DIR:-/run/network-restart}"
LOCK_FILE="${LZC_NETWORK_RESTART_LOCK:-/run/lock/lzc-network-restart.lock}"
ASSUME_YES="${LZC_NETWORK_RESTART_YES:-0}"
FORCE="${LZC_NETWORK_RESTART_FORCE:-0}"
DRY_RUN=0
USE_COLOR=auto

# --- Runtime state -----------------------------------------------------------
APPLY=0
RESOLVED_MANAGER=''
NM_PROFILE=''
SNAP_GATEWAY=''
SNAP_OWN_GATEWAY=''
SNAP_ADDRS=''
SNAP_OPERSTATE=''
SESSION_IFACE=''
SESSION_IP=''
OVER_SSH=0
RELATED=0
RUN_ID=''
CANCEL_FILE=''
RECOVER_FILE=''
WATCHDOG_UNIT=''
WATCHDOG_PID=''
WATCHDOG_ARMED=0
LOCK_HELD=0
YW='' BL='' RD='' GN='' CL=''

# --- Output ------------------------------------------------------------------

setup_color() {
    # NO_COLOR (https://no-color.org) is honoured before the auto-detection: any
    # non-empty value disables colour. An explicit --color always still wins,
    # which is the point of asking for it.
    if [[ -n ${NO_COLOR:-} && $USE_COLOR == auto ]]; then
        return 0
    fi
    if [[ $USE_COLOR == never ]] || { [[ $USE_COLOR == auto ]] && [[ ! -t 1 ]]; }; then
        return 0
    fi
    YW=$'\033[33m' BL=$'\033[36m' RD=$'\033[01;31m' GN=$'\033[1;92m' CL=$'\033[m'
}

log() {
    local level=$1
    shift
    case $level in
        ERROR) printf '%s[Error]%s %s\n' "$RD" "$CL" "$*" >&2 ;;
        WARN) printf '%s[Warning]%s %s\n' "$YW" "$CL" "$*" >&2 ;;
        INFO) printf '%s[Info]%s %s\n' "$BL" "$CL" "$*" ;;
        SUCCESS) printf '%s[OK]%s %s\n' "$GN" "$CL" "$*" ;;
        *) printf '%s\n' "$*" ;;
    esac
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

Restarts one network interface and verifies it came back, with an armed
rollback so a failed bounce recovers without a console.

Usage:
  network_restart.sh [options] [INTERFACE]

Blast radius:
  Takes INTERFACE down and brings it back up. Every connection through that
  interface drops. If it is the interface carrying your SSH session -- directly,
  or as a bridge port / bond slave underneath it -- you WILL be disconnected,
  and if the interface does not come back you lose the host until someone
  reaches its console. That case requires --force.

  Nothing else is touched: no other interface, no firewall, and no routing
  beyond re-adding the default route THIS interface itself owned, and only if
  nothing else has supplied one by the time the rollback runs. Configuration
  files are never written.

Safety:
  * The default is a dry run. Nothing happens without --yes.
  * A rollback is armed BEFORE the interface goes down, and cancelled only
    after connectivity is verified. If this script dies, is killed, or the
    verification fails, the rollback brings the interface back up after
    --rollback SECONDS.
  * SIGHUP is ignored, so a dropped SSH session cannot kill the run between
    "down" and "up".
  * An applying run takes an exclusive lock on $LOCK_FILE
    and exits 75 if another instance already holds it, so two runs can never
    bounce the same host at once. It is taken only once the run has decided it
    will change something: a plan, and a run refused by the SSH check, never
    take it and never create it.

Options:
  -i, --interface NAME    Interface to restart. May also be given positionally.
  -y, --yes               Actually do it. Without this the run is a plan.
  -n, --dry-run           Plan only (the default). Wins over --yes.
  -f, --force             Proceed even when the interface carries this SSH
                          session. Read the blast radius first.
      --manager NAME      auto | networkmanager | networkd | ifupdown | iproute2
                          (default: $MANAGER).
      --rollback SECONDS  Rollback delay; 0 disables it (default: $ROLLBACK_SECS).
      --wait SECONDS      How long to wait, after the bounce, for the interface
                          to come back: first for the link to reach UP, then
                          again for a global IPv4 address to return if it had
                          one (default: $WAIT_SECS).
      --check-host HOST   Ping this after the bounce. 'auto' uses the default
                          gateway recorded before the bounce, 'none' skips the
                          check (default: $CHECK_HOST).
      --ping-count N      Packets for that ping. Minimum 1 (default: $PING_COUNT).
      --ping-wait SECONDS Per-packet reply timeout for that ping (ping -W).
                          Minimum 1 (default: $PING_WAIT).
      --settle SECONDS    Pause between taking the interface down and bringing
                          it back up; 0 for none (default: $SETTLE_SECS).
      --timeout SECONDS   Bounds each individual command this script runs --
                          one nmcli/networkctl/ifup/ip invocation, or the ping
                          -- not the wait for the interface to return, which is
                          --wait. Minimum 1 (default: $CMD_TIMEOUT).
      --state-dir DIR     Where the rollback script and its cancel token live
                          (default: $STATE_DIR).
      --color WHEN        auto | always | never (default: auto).
  -V, --version           Print version and exit.
  -h, --help              Print this help and exit.

Every option has an environment variable, which is the easier route from cron
or when piping this script in from the network. Booleans accept 1/true/yes/on
and 0/false/no/off, case-insensitively; anything else is a usage error:
  LZC_NETWORK_RESTART_INTERFACE=eth0    LZC_NETWORK_RESTART_YES=1
  LZC_NETWORK_RESTART_FORCE=1           LZC_NETWORK_RESTART_MANAGER=auto
  LZC_NETWORK_RESTART_ROLLBACK=120      LZC_NETWORK_RESTART_WAIT=60
  LZC_NETWORK_RESTART_CHECK_HOST=auto   LZC_NETWORK_RESTART_PING_COUNT=3
  LZC_NETWORK_RESTART_PING_WAIT=2       LZC_NETWORK_RESTART_TIMEOUT=30
  LZC_NETWORK_RESTART_SETTLE=2
  LZC_NETWORK_RESTART_STATE_DIR=/run/network-restart
  LZC_NETWORK_RESTART_LOCK=/run/lock/lzc-network-restart.lock

NO_COLOR (any non-empty value) disables colour, as does a non-terminal stdout.
--color always overrides both.

There is no prompt in either direction: the default is a plan, so a run without
--yes is always safe, and a run with --yes never blocks on a terminal that cron
does not have.

Exit status:
  0    plan printed, or the interface came back and verification passed
  1    the bounce or the verification failed -- the rollback is left ARMED
  2    usage error: unknown flag, missing option value, or a bad value
       (including an interface that does not exist on this host)
  3    a prerequisite is missing: ip, timeout, or flock
  4    --yes was given by a user who is not root
  5    refused: the target interface carries this SSH session and --force was
       not given. Nothing was changed
  75   another instance holds the lock (EX_TEMPFAIL, so cron and systemd treat
       it as "retry later" rather than a real fault)
  130  interrupted (SIGINT/SIGTERM) -- the rollback is left ARMED
EOF
}

# --- Argument parsing --------------------------------------------------------

# Accepts the spellings people actually write in cron files and unit files.
# Without this, LZC_NETWORK_RESTART_YES=true reaches (( )) as a bare word, and
# under `set -u` bash aborts with "true: unbound variable" before the script can
# say anything useful.
#
# $2 is the spelling the operator typed -- the flag and the environment
# variable, not the internal variable name. Answering someone who set
# LZC_NETWORK_RESTART_YES with "ASSUME_YES must be true or false" points them at
# a string that appears in no documentation and cannot be grepped for.
_normalise_bool() {
    local name=$1 label=$2 value
    case ${!name,,} in
        1 | true | yes | on) value=1 ;;
        0 | false | no | off | '') value=0 ;;
        *) die "$EX_USAGE" "$label must be 1/true/yes/on or 0/false/no/off, got '${!name}'" ;;
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
    ((value >= min)) || die "$EX_USAGE" "$label must be at least $min, got '${!name}'"
    printf -v "$name" '%s' "$value"
}

need_arg() {
    if (($2 < 2)); then
        die "$EX_USAGE" "$1 requires a value"
    fi
    if [[ ${3-} == -?* ]]; then
        die "$EX_USAGE" "$1 requires a value, but got the option '$3'"
    fi
}

parse_args() {
    local positional=''
    while (($#)); do
        case $1 in
            -i | --interface)
                need_arg "$1" $# "${2-}"
                IFACE=$2
                shift
                ;;
            -y | --yes) ASSUME_YES=1 ;;
            -n | --dry-run) DRY_RUN=1 ;;
            -f | --force) FORCE=1 ;;
            --manager)
                need_arg "$1" $# "${2-}"
                MANAGER=$2
                shift
                ;;
            --rollback)
                need_arg "$1" $# "${2-}"
                ROLLBACK_SECS=$2
                shift
                ;;
            --wait)
                need_arg "$1" $# "${2-}"
                WAIT_SECS=$2
                shift
                ;;
            --check-host)
                need_arg "$1" $# "${2-}"
                CHECK_HOST=$2
                shift
                ;;
            --ping-count)
                need_arg "$1" $# "${2-}"
                PING_COUNT=$2
                shift
                ;;
            --ping-wait)
                need_arg "$1" $# "${2-}"
                PING_WAIT=$2
                shift
                ;;
            --settle)
                need_arg "$1" $# "${2-}"
                SETTLE_SECS=$2
                shift
                ;;
            --timeout)
                need_arg "$1" $# "${2-}"
                CMD_TIMEOUT=$2
                shift
                ;;
            --state-dir)
                need_arg "$1" $# "${2-}"
                STATE_DIR=$2
                shift
                ;;
            --color)
                need_arg "$1" $# "${2-}"
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
            --) ;;
            -*) die "$EX_USAGE" "Unknown option: $1 (try --help)" ;;
            *)
                [[ -z $positional ]] ||
                    die "$EX_USAGE" "only one interface may be given (got '$positional' and '$1')"
                positional=$1
                ;;
        esac
        shift
    done

    [[ -n $positional && -z $IFACE ]] && IFACE=$positional
    [[ -n $positional && -n $IFACE && $IFACE != "$positional" ]] &&
        die "$EX_USAGE" "interface given twice and they disagree: '$IFACE' and '$positional'"

    [[ $USE_COLOR =~ ^(auto|always|never)$ ]] ||
        die "$EX_USAGE" "--color must be auto, always or never"
    [[ $MANAGER =~ ^(auto|networkmanager|networkd|ifupdown|iproute2)$ ]] ||
        die "$EX_USAGE" "--manager must be auto, networkmanager, networkd, ifupdown or iproute2"

    # Validated before the first arithmetic use below, which is the whole point:
    # a bare word reaching (( )) under `set -u` is a crash, not a message.
    _normalise_bool ASSUME_YES '--yes (LZC_NETWORK_RESTART_YES)'
    _normalise_bool FORCE '--force (LZC_NETWORK_RESTART_FORCE)'

    # Minimum 1 for anything handed to timeout(1): `timeout 0` means NO limit,
    # so accepting 0 would silently remove the protection the option exists to
    # provide. --wait 0 would make the post-bounce polling loop give up before
    # its first check, `ping -c 0` is rejected by ping itself, and `ping -W 0`
    # is either rejected or means "wait forever" depending on the ping build.
    _normalise_int CMD_TIMEOUT 1 '--timeout (LZC_NETWORK_RESTART_TIMEOUT)'
    _normalise_int WAIT_SECS 1 '--wait (LZC_NETWORK_RESTART_WAIT)'
    _normalise_int PING_COUNT 1 '--ping-count (LZC_NETWORK_RESTART_PING_COUNT)'
    _normalise_int PING_WAIT 1 '--ping-wait (LZC_NETWORK_RESTART_PING_WAIT)'
    # 0 is meaningful for both: --rollback 0 disables the rollback (documented),
    # and --settle 0 asks for no pause between down and up.
    _normalise_int ROLLBACK_SECS 0 '--rollback (LZC_NETWORK_RESTART_ROLLBACK)'
    _normalise_int SETTLE_SECS 0 '--settle (LZC_NETWORK_RESTART_SETTLE)'

    [[ -n $STATE_DIR ]] || die "$EX_USAGE" "--state-dir must not be empty"

    # --dry-run beats --yes so that adding -n to a known-good command line is
    # always a safe way to preview it.
    if ((DRY_RUN)); then
        APPLY=0
    elif ((ASSUME_YES)); then
        APPLY=1
    fi
}

# --- Interface topology ------------------------------------------------------

# `ip -o link` prints the device as "eth0:" or "eth0@if12:". Normalise both.
link_name() {
    local n=${1%:}
    printf '%s' "${n%%@*}"
}

iface_exists() {
    ip -o link show dev "$1" >/dev/null 2>&1
}

iface_master() {
    ip -o link show dev "$1" 2>/dev/null | sed -n 's/.* master \([^ ]*\).*/\1/p' | head -n 1
}

# The device this one sits on top of, which is NOT the same relationship as
# `master`. A VLAN or macvlan child is not enslaved to anything -- it has no
# master at all -- and iproute2 renders the link in the device name instead:
# "vmbr0.100@vmbr0". Walking only masters therefore cannot see the single most
# common Proxmox layout, where the management address lives on a VLAN child of
# the bridge whose port is the physical NIC.
#
# veth and some tunnels print "@if12", an ifindex rather than a name, and for a
# veth the peer usually lives in another namespace. Resolve what is resolvable
# here and report nothing for the rest: a parent that cannot be named is not a
# parent this script can reason about, and inventing one would be worse than
# admitting the gap.
iface_parent() {
    local field raw parent idx path
    field=$(ip -o link show dev "$1" 2>/dev/null | awk '{ print $2 }') || return 0
    raw=${field%:}
    [[ $raw == *@* ]] || return 0
    parent=${raw##*@}
    [[ -n $parent ]] || return 0

    if [[ $parent =~ ^if([0-9]+)$ ]]; then
        idx=${BASH_REMATCH[1]}
        for path in /sys/class/net/*/ifindex; do
            [[ -r $path ]] || continue
            [[ $(cat "$path" 2>/dev/null) == "$idx" ]] || continue
            path=${path%/ifindex}
            printf '%s' "${path##*/}"
            return 0
        done
        return 0
    fi

    printf '%s' "$parent"
}

iface_operstate() {
    ip -o link show dev "$1" 2>/dev/null | sed -n 's/.* state \([^ ]*\).*/\1/p' | head -n 1
}

# The chain of enclosing devices: eth0 -> bond0 -> vmbr0. Bounded so a
# pathological/looped configuration cannot spin here.
master_chain() {
    local dev=$1 depth=0 parent
    while ((depth < 8)); do
        parent=$(iface_master "$dev") || parent=''
        [[ -n $parent ]] || break
        printf '%s\n' "$parent"
        dev=$parent
        depth=$((depth + 1))
    done
}

# Every device between $1 and the wire, following both relationships: masters
# (enslavement) and parents (VLAN/macvlan link). A device can have both -- a
# VLAN child can itself be a bridge port -- so this is a small graph rather
# than a chain, and it is walked with an explicit stack, deduplicated, and
# bounded so a pathological or looped configuration cannot spin here.
uplink_chain() {
    local -a stack=("$1")
    local seen=" $1 " dev next steps=0
    while ((${#stack[@]} > 0 && steps < 32)); do
        dev=${stack[-1]}
        unset 'stack[-1]'
        steps=$((steps + 1))
        for next in "$(iface_master "$dev")" "$(iface_parent "$dev")"; do
            [[ -n $next ]] || continue
            [[ $seen == *" $next "* ]] && continue
            seen+="$next "
            stack+=("$next")
            printf '%s\n' "$next"
        done
    done
}

iface_for_ip() {
    local want=$1
    [[ -n $want ]] || return 0
    ip -o addr show 2>/dev/null |
        awk -v want="$want" '{ split($4, a, "/"); if (a[1] == want) { print $2; exit } }'
}

# --- SSH detection -----------------------------------------------------------

# sudo scrubs SSH_* from the environment by default, so the environment check
# alone produces false negatives for the single most common invocation
# (`sudo ./network_restart.sh`). Walking the parent chain catches that case.
over_ssh() {
    [[ -n ${SSH_CONNECTION:-} || -n ${SSH_CLIENT:-} || -n ${SSH_TTY:-} ]] && return 0
    [[ -r /proc/self/status ]] || return 1
    local pid=$PPID depth=0 comm
    while ((depth < 20)) && [[ -n $pid && $pid -gt 1 ]]; do
        comm=$(cat "/proc/$pid/comm" 2>/dev/null) || return 1
        case $comm in
            sshd | sshd-session | sshd-auth | dropbear) return 0 ;;
        esac
        pid=$(awk '/^PPid:/ { print $2; exit }' "/proc/$pid/status" 2>/dev/null) || return 1
        [[ $pid =~ ^[0-9]+$ ]] || return 1
        depth=$((depth + 1))
    done
    return 1
}

session_server_ip() {
    # SSH_CONNECTION is "<client ip> <client port> <server ip> <server port>".
    local conn=${SSH_CONNECTION:-}
    [[ -n $conn ]] || return 0
    awk '{ print $3 }' <<<"$conn"
}

# Is the target interface part of the path carrying this SSH session?
#
# Checking only "does the session IP live on this interface" is not enough. On a
# Proxmox host the session IP sits on vmbr0 while the physical NIC is enp1s0;
# bouncing enp1s0 drops the bridge's uplink and strands the box even though the
# IP is not on enp1s0. Bonds and VLANs have the same shape. So the test is a
# relationship test, and anything unknown counts as related.
target_carries_session() {
    local target=$1 session=$2
    [[ -n $session ]] || return 0 # unknown session interface: assume the worst
    [[ $target == "$session" ]] && return 0

    local item
    # target is enslaved to the session-carrying device: bouncing a bridge port
    # can take down the path the bridge forwards over. Masters only, on
    # purpose. The parent relationship does not work this way -- taking down
    # vmbr0.100 leaves vmbr0 and every other VLAN on it up -- so walking
    # parents here would refuse restarts that are perfectly safe.
    while read -r item; do
        [[ $item == "$session" ]] && return 0
    done < <(master_chain "$target")

    # the session-carrying device sits under the target. Here parents DO count:
    # bouncing vmbr0 (or enp1s0 beneath it) takes vmbr0.100 down with it.
    while read -r item; do
        [[ $item == "$target" ]] && return 0
    done < <(uplink_chain "$session")

    # Both hang off the same bridge, bond, or parent NIC. Comparing only the
    # immediate masters missed the stock Proxmox layout entirely: with the
    # address on vmbr0.100 and the target enp1s0, neither device is enslaved to
    # the other and neither has the other in its chain, but both reach vmbr0 --
    # and bouncing the port takes the VLAN, and the session, down with it. Which
    # port actually forwards the session cannot be determined from
    # configuration, so any shared ancestor counts as related.
    local -a tchain=() schain=()
    mapfile -t tchain < <(uplink_chain "$target")
    mapfile -t schain < <(uplink_chain "$session")
    local t s
    for t in ${tchain[@]+"${tchain[@]}"}; do
        for s in ${schain[@]+"${schain[@]}"}; do
            [[ $t == "$s" ]] && return 0
        done
    done

    return 1
}

# --- Manager detection -------------------------------------------------------

unit_active() {
    command -v systemctl >/dev/null 2>&1 || return 1
    systemctl is-active --quiet "$1" 2>/dev/null
}

nm_manages() {
    command -v nmcli >/dev/null 2>&1 || return 1
    unit_active NetworkManager || return 1
    local state
    state=$(timeout "$CMD_TIMEOUT" nmcli -t -f DEVICE,STATE device status 2>/dev/null |
        awk -F: -v d="$IFACE" '$1 == d { print $2; exit }') || state=''
    [[ -n $state && $state != unmanaged ]]
}

networkd_manages() {
    command -v networkctl >/dev/null 2>&1 || return 1
    unit_active systemd-networkd || return 1
    local setup
    setup=$(timeout "$CMD_TIMEOUT" networkctl list --no-legend --no-pager 2>/dev/null |
        awk -v d="$IFACE" '$2 == d { print $NF; exit }') || setup=''
    [[ -n $setup && $setup != unmanaged && $setup != linger ]]
}

ifupdown_manages() {
    command -v ifup >/dev/null 2>&1 || return 1
    # The dot is a regex wildcard, and VLAN interfaces are named with one
    # (eth0.100). Unescaped, a stanza for a differently named interface such as
    # eth0x100 would match and this host would be misdetected as ifupdown-
    # managed. preflight already limits IFACE to [A-Za-z0-9._:-], so the dot is
    # the only metacharacter that can reach here.
    #
    # The replacement is single-quoted on purpose. Written bare as {IFACE//./\\.}
    # bash strips the backslash during quote removal and the result is the
    # unescaped name again -- the substitution silently does nothing, which is
    # indistinguishable from working until you test it against a name like
    # eth0x100. Quoting the replacement is what actually puts a backslash there.
    local re=${IFACE//./'\.'}
    local f
    for f in /etc/network/interfaces /etc/network/interfaces.d/*; do
        [[ -f $f ]] || continue
        grep -Eq "^[[:space:]]*(iface|auto|allow-hotplug)[[:space:]]+.*\<${re}\>" "$f" 2>/dev/null &&
            return 0
    done
    return 1
}

detect_manager() {
    if [[ $MANAGER != auto ]]; then
        printf '%s' "$MANAGER"
        return 0
    fi
    if nm_manages; then
        printf 'networkmanager'
    elif networkd_manages; then
        printf 'networkd'
    elif ifupdown_manages; then
        printf 'ifupdown'
    else
        printf 'iproute2'
    fi
}

# --- Preflight and snapshot --------------------------------------------------

preflight() {
    command -v ip >/dev/null 2>&1 ||
        die "$EX_PREREQ" "ip (iproute2) not found; this script needs it"
    command -v timeout >/dev/null 2>&1 || die "$EX_PREREQ" "timeout (coreutils) not found"

    if [[ -z $IFACE ]]; then
        log ERROR "no interface given. Available interfaces:"
        ip -o link show 2>/dev/null |
            awk '{ n = $2; sub(/:$/, "", n); sub(/@.*/, "", n); print "  " n }' >&2
        exit "$EX_USAGE"
    fi
    [[ $IFACE =~ ^[A-Za-z0-9._:-]+$ ]] || die "$EX_USAGE" "implausible interface name: '$IFACE'"
    iface_exists "$IFACE" || die "$EX_USAGE" "no such interface: $IFACE"

    if ((APPLY)) && [[ $EUID -ne 0 ]]; then
        die "$EX_NOROOT" "--yes needs root to change interface state"
    fi

    RESOLVED_MANAGER=$(detect_manager)
    if [[ $MANAGER != auto && $RESOLVED_MANAGER != iproute2 ]]; then
        log INFO "Manager forced to $RESOLVED_MANAGER (not autodetected)"
    fi
}

# Taken only on the applying path, and only once the run has decided it is
# actually going to change something, so a plan or a refusal never blocks -- and
# is never blocked by -- a run that is genuinely bouncing an interface.
acquire_lock() {
    command -v flock >/dev/null 2>&1 ||
        die "$EX_PREREQ" "flock (util-linux) not found; refusing to bounce an interface without a lock"
    mkdir -p -- "$(dirname "$LOCK_FILE")" 2>/dev/null || true
    exec 9>"$LOCK_FILE" || die "$EX_FAIL" "Cannot open lock file $LOCK_FILE"
    # The lock file is deliberately never deleted. Two processes can each hold a
    # lock on a different inode at the same path if one unlinks it and the next
    # recreates it, which defeats the point.
    flock -n 9 ||
        die "$EX_LOCKED" "Another $SCRIPT_NAME run holds $LOCK_FILE. Refusing to run concurrently."
    LOCK_HELD=1
}

# Everything the verification and the rollback need is captured BEFORE the
# bounce. Reading the default gateway afterwards is useless: taking the
# interface down removes the route, so the check would silently degrade to
# "the link is up" and call a dead network healthy.
snapshot() {
    SNAP_OPERSTATE=$(iface_operstate "$IFACE") || SNAP_OPERSTATE=''

    # Two different gateways, deliberately.
    #
    # SNAP_OWN_GATEWAY is the default route that belongs to THIS interface, and
    # it is the only one the rollback may recreate. SNAP_GATEWAY is the host's
    # default gateway wherever it lives, and it is only a ping target.
    # Conflating them is how a bridge-port bounce ends up re-adding vmbr0's
    # default route via enp1s0 and blackholing the host.
    SNAP_OWN_GATEWAY=$(ip -4 route show default dev "$IFACE" 2>/dev/null |
        awk '/via/ { print $3; exit }') || SNAP_OWN_GATEWAY=''
    SNAP_GATEWAY=$SNAP_OWN_GATEWAY
    if [[ -z $SNAP_GATEWAY ]]; then
        SNAP_GATEWAY=$(ip -4 route show default 2>/dev/null | awk '/via/ { print $3; exit }') ||
            SNAP_GATEWAY=''
    fi
    SNAP_ADDRS=$(ip -o -4 addr show dev "$IFACE" scope global 2>/dev/null |
        awk '{ print $4 }' | paste -sd' ' -) || SNAP_ADDRS=''

    if [[ $RESOLVED_MANAGER == networkmanager ]] && command -v nmcli >/dev/null 2>&1; then
        NM_PROFILE=$(timeout "$CMD_TIMEOUT" nmcli -g GENERAL.CONNECTION device show "$IFACE" 2>/dev/null) ||
            NM_PROFILE=''
        [[ $NM_PROFILE == '--' ]] && NM_PROFILE=''
    fi

    if over_ssh; then
        OVER_SSH=1
        SESSION_IP=$(session_server_ip) || SESSION_IP=''
        if [[ -n $SESSION_IP ]]; then
            SESSION_IFACE=$(link_name "$(iface_for_ip "$SESSION_IP")") || SESSION_IFACE=''
        fi
        if target_carries_session "$IFACE" "$SESSION_IFACE"; then
            RELATED=1
        fi
    fi
}

# --- Rollback ----------------------------------------------------------------

recovery_commands() {
    # Every interpolated value is quoted with %q, never wrapped in literal
    # single quotes. IFACE is regex-gated in preflight, but NM_PROFILE is
    # whatever NetworkManager reports, and profile names are routinely SSIDs
    # containing an apostrophe ("Bob's iPhone"). Writing that as '$NM_PROFILE'
    # produced a rollback script with an unterminated quote: bash executed the
    # first few lines, then aborted at the parse error, so the link came back up
    # but the profile re-apply, the default-route restore and the state cleanup
    # were all silently skipped -- the rollback reported itself armed and then
    # only half ran. A profile name containing a quote plus a shell
    # metacharacter injected commands into a script this host runs as root.
    # Do not go back to '$var'.
    printf 'ip link set dev %q up || true\n' "$IFACE"
    case $RESOLVED_MANAGER in
        networkmanager)
            printf 'nmcli device connect %q || true\n' "$IFACE"
            if [[ -n $NM_PROFILE ]]; then
                printf 'nmcli connection up id %q || true\n' "$NM_PROFILE"
            fi
            ;;
        networkd)
            printf 'networkctl up %q 2>/dev/null || networkctl reconfigure %q || true\n' \
                "$IFACE" "$IFACE"
            ;;
        ifupdown)
            printf 'ifup %q || true\n' "$IFACE"
            ;;
        iproute2) ;;
    esac
    # Restores only the default route this interface itself owned, and only if
    # nothing else has supplied one by then. DHCP or the network manager winning
    # this race is the desired outcome, not a conflict to resolve.
    if [[ -n $SNAP_OWN_GATEWAY ]]; then
        printf '%s\n' 'if ! ip -4 route show default | grep -q .; then'
        printf '    ip route add default via %q dev %q || true\n' \
            "$SNAP_OWN_GATEWAY" "$IFACE"
        printf '%s\n' 'fi'
    fi
    # Explicit: this function feeds a pipeline under `set -e` + pipefail, where
    # an incidental non-zero from the last branch would abort the whole run.
    return 0
}

rollback_plan() {
    recovery_commands | sed 's/^/    /'
}

# The longest verification can legitimately take: the link wait, then the
# address wait, then the ping. Used only to warn -- see arm_rollback.
verify_budget() {
    local budget=$((WAIT_SECS + CMD_TIMEOUT))
    [[ -n $SNAP_ADDRS ]] && budget=$((budget + WAIT_SECS))
    printf '%s' "$budget"
}

arm_rollback() {
    ((ROLLBACK_SECS > 0)) || {
        log WARN 'Rollback disabled (--rollback 0): a failed bounce will NOT self-recover.'
        return 0
    }

    # A rollback that fires while verification is still running is not dangerous
    # -- every recovery command is idempotent -- but it does make the final
    # "Rollback cancelled" a false statement, because by then it has already
    # run. Warn rather than adjust: raising --rollback silently would extend the
    # window in which a genuinely dead host stays dead, which is the operator's
    # call and not this script's.
    local budget
    budget=$(verify_budget)
    if ((ROLLBACK_SECS < budget)); then
        log WARN "--rollback ${ROLLBACK_SECS}s is shorter than the worst-case verification time (${budget}s);"
        log WARN 'the rollback may fire while this run is still verifying. Raise --rollback to avoid that.'
    fi

    mkdir -p -- "$STATE_DIR" || die "$EX_FAIL" "cannot create state directory $STATE_DIR"
    # Stale state from a run that was killed before it could tidy up. Only files
    # older than a day, so a concurrent run is never disturbed.
    #
    # Restricted to the two names this script itself creates. Without that name
    # filter this is `find <operator-supplied dir> -type f -delete` running as
    # root: --state-dir is a normal option, and pointing it at a directory that
    # already holds something else -- /etc, /root/.ssh -- deleted every regular
    # file in it that happened to be a day old. The loop only ever meant "clean
    # up my own leftovers", so it now says exactly that. Both suffixes are safe
    # to match on: RUN_ID is "${IFACE}.$$.$(date +%s)" and IFACE is gated to
    # [A-Za-z0-9._:-] in preflight, so the suffix is always the last component.
    find "$STATE_DIR" -maxdepth 1 -type f \
        \( -name '*.cancel' -o -name '*.recover.sh' \) \
        -mmin +1440 -delete 2>/dev/null || true

    RUN_ID="${IFACE}.$$.$(date +%s)"
    CANCEL_FILE="$STATE_DIR/$RUN_ID.cancel"
    RECOVER_FILE="$STATE_DIR/$RUN_ID.recover.sh"

    {
        printf '%s\n' '#!/usr/bin/env bash'
        printf '%s\n' '# Generated by network_restart.sh. Safe to delete when no run is active.'
        printf '%s\n' 'set -uo pipefail'
        printf '%s\n' 'export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'
        printf 'if [[ -e %q ]]; then rm -f -- %q %q; exit 0; fi\n' \
            "$CANCEL_FILE" "$CANCEL_FILE" "$RECOVER_FILE"
        printf 'logger -t network-restart %q 2>/dev/null || true\n' \
            "rollback: restoring $IFACE after a restart that did not verify"
        recovery_commands
        printf 'rm -f -- %q\n' "$RECOVER_FILE"
    } >"$RECOVER_FILE" || die "$EX_FAIL" "cannot write the rollback script to $RECOVER_FILE"
    chmod 0700 -- "$RECOVER_FILE" || true

    # systemd-run puts the rollback in its own cgroup, outside this session, so
    # it survives the SSH connection dying and even this script being SIGKILLed.
    # Without --pty or --scope the unit is started by PID 1, not forked from
    # here, so it inherits none of this process's descriptors -- in particular
    # not the lock on fd 9. The setsid fallback below does fork, and has to
    # close it explicitly.
    if command -v systemd-run >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
        # Dots are meaningful in systemd unit names (they introduce the unit
        # type suffix), so RUN_ID's dots are flattened here. A rejected name
        # would silently demote every systemd host to the weaker setsid
        # fallback behind a warning nobody reads.
        WATCHDOG_UNIT="network-restart-rollback-${RUN_ID//./-}"
        if systemd-run --quiet --collect \
            --unit="$WATCHDOG_UNIT" \
            --on-active="${ROLLBACK_SECS}s" \
            --timer-property=AccuracySec=1s \
            --description="network_restart rollback for $IFACE" \
            /usr/bin/env bash "$RECOVER_FILE" >/dev/null 2>&1; then
            WATCHDOG_ARMED=1
            log INFO "Rollback armed as transient unit $WATCHDOG_UNIT (fires in ${ROLLBACK_SECS}s)"
            return 0
        fi
        log WARN 'systemd-run refused; falling back to a detached background rollback'
        WATCHDOG_UNIT=''
    fi

    # setsid detaches from the controlling terminal so the SSH tty going away
    # does not take the rollback with it.
    #
    # 9>&- is load-bearing. This child is forked from here and would otherwise
    # inherit the open lock descriptor, holding the flock for the whole rollback
    # delay after this script has exited -- so the very next run, the one an
    # operator makes while retrying a failed bounce, would be turned away with
    # 75 by a process that is only sleeping.
    setsid bash -c "sleep $ROLLBACK_SECS; exec bash $(printf '%q' "$RECOVER_FILE")" \
        9>&- </dev/null >/dev/null 2>&1 &
    WATCHDOG_PID=$!
    disown "$WATCHDOG_PID" 2>/dev/null || true
    WATCHDOG_ARMED=1
    log INFO "Rollback armed as detached pid $WATCHDOG_PID (fires in ${ROLLBACK_SECS}s)"
}

cancel_rollback() {
    ((WATCHDOG_ARMED)) || return 0
    # The cancel token goes first. Even if stopping the unit or killing the pid
    # fails, the rollback script checks this file and turns itself into a no-op.
    : >"$CANCEL_FILE" 2>/dev/null || true
    if [[ -n $WATCHDOG_UNIT ]]; then
        systemctl stop "$WATCHDOG_UNIT.timer" >/dev/null 2>&1 || true
        systemctl stop "$WATCHDOG_UNIT.service" >/dev/null 2>&1 || true
        systemctl reset-failed "$WATCHDOG_UNIT.service" >/dev/null 2>&1 || true
    fi
    if [[ -n $WATCHDOG_PID ]]; then
        kill "$WATCHDOG_PID" >/dev/null 2>&1 || true
    fi
    rm -f -- "$CANCEL_FILE" "$RECOVER_FILE" 2>/dev/null || true
    WATCHDOG_ARMED=0
    log INFO 'Rollback cancelled'
}

# --- The bounce --------------------------------------------------------------

# Runs one command under the per-command timeout and reports what it said when
# it fails.
#
# Discarding stderr here was a real defect: a failed bounce printed "Failed to
# restart eth0" and nothing else, at the exact moment the link may be down and
# the host unreachable -- so the one message that would have named the cause
# ("Error: Connection activation failed: no suitable device found") was thrown
# away. Output is captured into a variable rather than a temp file because this
# script has no TMP_DIR and adding one adds failure modes to preflight and to
# the exit path.
#
# The real status is returned, not a flattened 1, so callers and the operator
# can tell a timeout (124) from a refusal. `local out` is declared separately
# from the assignment on purpose: `local out=$(...)` would make `local`'s own
# status the one bash sees and the failure would vanish (ShellCheck SC2155).
run_step() {
    local desc=$1
    shift
    local out rc=0
    log INFO "$desc"
    out=$(timeout "$CMD_TIMEOUT" "$@" 2>&1) || rc=$?
    ((rc == 0)) && return 0

    if ((rc == 124)); then
        log WARN "  timed out after ${CMD_TIMEOUT}s"
    fi
    # Bounded: some of these tools are chatty, and a wall of text at the point
    # the operator is deciding whether they still have a host is not help.
    local line n=0
    while IFS= read -r line && ((n < 3)); do
        [[ -n $line ]] || continue
        log WARN "  $line"
        n=$((n + 1))
    done <<<"$out"
    return "$rc"
}

bounce() {
    case $RESOLVED_MANAGER in
        networkmanager)
            run_step "nmcli device disconnect $IFACE" nmcli device disconnect "$IFACE" ||
                log WARN "nmcli device disconnect failed; continuing to the connect step"
            sleep "$SETTLE_SECS"
            run_step "nmcli device connect $IFACE" nmcli device connect "$IFACE" ||
                return 1
            ;;
        networkd)
            # `networkctl up/down` is not present in every systemd release, and
            # probing the version is less reliable than trying it, so fall back
            # to iproute2 when the verb is rejected.
            run_step "networkctl down $IFACE" networkctl down "$IFACE" ||
                run_step "ip link set $IFACE down" ip link set dev "$IFACE" down ||
                return 1
            sleep "$SETTLE_SECS"
            run_step "networkctl up $IFACE" networkctl up "$IFACE" ||
                run_step "ip link set $IFACE up" ip link set dev "$IFACE" up ||
                return 1
            run_step "networkctl reconfigure $IFACE" networkctl reconfigure "$IFACE" || true
            ;;
        ifupdown)
            run_step "ifdown $IFACE" ifdown "$IFACE" ||
                log WARN "ifdown failed (often just means it was already down); continuing"
            sleep "$SETTLE_SECS"
            run_step "ifup $IFACE" ifup "$IFACE" || return 1
            ;;
        iproute2)
            run_step "ip link set $IFACE down" ip link set dev "$IFACE" down || return 1
            sleep "$SETTLE_SECS"
            run_step "ip link set $IFACE up" ip link set dev "$IFACE" up || return 1
            ;;
        *)
            log ERROR "no handler for manager '$RESOLVED_MANAGER'"
            return 1
            ;;
    esac
    return 0
}

# --- Verification ------------------------------------------------------------

wait_for_link() {
    local deadline=$((SECONDS + WAIT_SECS)) state
    while ((SECONDS < deadline)); do
        state=$(iface_operstate "$IFACE") || state=''
        [[ $state == UP || $state == UNKNOWN ]] && return 0
        sleep 1
    done
    return 1
}

wait_for_address() {
    # Only demanded when the interface had a global address before the bounce.
    # An unnumbered bridge port legitimately has none, and failing it there
    # would arm a rollback for a healthy interface.
    [[ -n $SNAP_ADDRS ]] || return 0
    local deadline=$((SECONDS + WAIT_SECS)) got
    while ((SECONDS < deadline)); do
        got=$(ip -o -4 addr show dev "$IFACE" scope global 2>/dev/null | awk 'NR == 1 { print $4 }') || got=''
        [[ -n $got ]] && return 0
        sleep 1
    done
    return 1
}

# Prints the host to ping, or returns 1 when there is nothing to check.
connectivity_target() {
    case $CHECK_HOST in
        none) return 1 ;;
        auto)
            if [[ -z $SNAP_GATEWAY ]]; then
                return 1
            fi
            printf '%s' "$SNAP_GATEWAY"
            ;;
        *) printf '%s' "$CHECK_HOST" ;;
    esac
    return 0
}

check_connectivity() {
    local target
    target=$(connectivity_target) || {
        log INFO 'Connectivity check skipped (no target)'
        return 0
    }
    if ! command -v ping >/dev/null 2>&1; then
        log WARN 'ping not installed; connectivity not verified'
        return 0
    fi
    log INFO "Pinging $target"
    timeout "$CMD_TIMEOUT" ping -n -c "$PING_COUNT" -W "$PING_WAIT" "$target" >/dev/null 2>&1
}

verify() {
    if ! wait_for_link; then
        log ERROR "$IFACE did not come back up within ${WAIT_SECS}s"
        return 1
    fi
    log SUCCESS "$IFACE is up"

    if ! wait_for_address; then
        log ERROR "$IFACE has no global IPv4 address after ${WAIT_SECS}s (had: $SNAP_ADDRS)"
        return 1
    fi

    if ! check_connectivity; then
        log ERROR 'Connectivity check failed'
        return 1
    fi
    log SUCCESS 'Connectivity verified'
    return 0
}

# --- Reporting ---------------------------------------------------------------

report_plan() {
    printf '%s v%s\n\n' "$SCRIPT_NAME" "$SCRIPT_VERSION"
    printf 'Interface    : %s (state %s)\n' "$IFACE" "${SNAP_OPERSTATE:-unknown}"
    printf 'Managed by   : %s\n' "$RESOLVED_MANAGER"
    [[ -n $NM_PROFILE ]] && printf 'NM profile   : %s\n' "$NM_PROFILE"
    printf 'Addresses    : %s\n' "${SNAP_ADDRS:-none}"
    printf 'Gateway      : %s\n' "${SNAP_GATEWAY:-none}"
    if ((OVER_SSH)); then
        printf 'SSH session  : yes, via %s\n' "${SESSION_IFACE:-unknown}"
    else
        printf 'SSH session  : no\n'
    fi
    if ((APPLY)); then
        printf 'Mode         : %sAPPLY -- the interface will go down%s\n' "$RD" "$CL"
    else
        printf 'Mode         : DRY RUN -- nothing will change (pass --yes to apply)\n'
    fi

    printf '\nWould run:\n'
    case $RESOLVED_MANAGER in
        networkmanager) printf '    nmcli device disconnect %s\n    nmcli device connect %s\n' "$IFACE" "$IFACE" ;;
        networkd) printf '    networkctl down %s\n    networkctl up %s\n' "$IFACE" "$IFACE" ;;
        ifupdown) printf '    ifdown %s\n    ifup %s\n' "$IFACE" "$IFACE" ;;
        iproute2) printf '    ip link set dev %s down\n    ip link set dev %s up\n' "$IFACE" "$IFACE" ;;
    esac

    printf '\nRollback (armed before the bounce, cancelled only after verification):\n'
    if ((ROLLBACK_SECS > 0)); then
        printf '  after %ss, unless cancelled:\n' "$ROLLBACK_SECS"
        printf '  state in %s\n' "$STATE_DIR"
        rollback_plan
    else
        printf '    disabled (--rollback 0)\n'
    fi

    printf '\nVerification (worst case %ss):\n' "$(verify_budget)"
    printf '    link up within %ss\n' "$WAIT_SECS"
    [[ -n $SNAP_ADDRS ]] && printf '    global IPv4 address returns within %ss\n' "$WAIT_SECS"
    local target
    if target=$(connectivity_target); then
        printf '    ping %s (%s packets, %ss each)\n' "$target" "$PING_COUNT" "$PING_WAIT"
        # An honest report of what the check does and does not prove. When this
        # interface owned no default route, the target is the host's gateway
        # wherever it lives, so a reply may arrive entirely over some other
        # interface. Binding the ping with -I is not the fix: an unnumbered
        # bridge port has no source address to bind to and the check would fail
        # on a perfectly healthy link.
        if [[ $CHECK_HOST == auto && -z $SNAP_OWN_GATEWAY ]]; then
            printf '      note: %s is the host default gateway, not one this\n' "$target"
            printf '            interface owns, so a reply does not by itself\n'
            printf '            prove %s recovered. --check-host sets it.\n' "$IFACE"
        fi
    else
        printf '    no connectivity check\n'
    fi

    # The same comparison arm_rollback makes, repeated here because arm_rollback
    # only runs under --yes -- i.e. the operator first saw this warning one step
    # before the link went down, having already made the decision from a plan
    # that printed "after 120s" and "worst case 150s" side by side and said
    # nothing. The plan is the documented way to decide; the check belongs where
    # the decision is made, and stays in arm_rollback so a failed run's log has
    # it too.
    if ((ROLLBACK_SECS > 0)) && ((ROLLBACK_SECS < $(verify_budget))); then
        printf '    note: --rollback %ss is shorter than this, so the rollback may\n' "$ROLLBACK_SECS"
        printf '          fire while the run is still verifying. Harmless (recovery\n'
        printf '          is idempotent) but "Rollback cancelled" would then be\n'
        printf '          reported for one that already ran. Raise --rollback.\n'
    fi
    printf '\n'
}

warn_about_ssh() {
    ((OVER_SSH)) || return 0
    if ((RELATED)); then
        log WARN "This is an SSH session and $IFACE carries it${SESSION_IFACE:+ (session is on $SESSION_IFACE)}."
        log WARN 'You will be disconnected. If the interface does not come back you lose this host.'
    else
        log WARN "This is an SSH session on ${SESSION_IFACE:-another interface}; $IFACE looks unrelated to it."
        log WARN 'That determination comes from the current link topology and can be wrong.'
    fi
}

# --- Lifecycle ---------------------------------------------------------------

on_err() {
    log ERROR "failed at line $1: '$2' (status $3)"
}

on_exit() {
    local rc=$?
    trap - EXIT INT TERM ERR
    if ((WATCHDOG_ARMED)); then
        log WARN "Rollback is still ARMED and will restore $IFACE in up to ${ROLLBACK_SECS}s."
    fi
    # Closing the descriptor releases the flock. The file itself stays.
    #
    # Spelled as an `if` rather than `((LOCK_HELD)) && exec 9>&-` because that
    # list carries status 1 when no lock was held; harmless while `exit` follows
    # it, but it silently becomes this function's return status the moment
    # anyone moves it to the end. Under errexit that is an aborted run.
    if ((LOCK_HELD)); then
        exec 9>&-
    fi
    exit "$rc"
}

on_signal() {
    log WARN 'Interrupted; leaving the rollback armed'
    exit "$EX_INTERRUPT"
}

# --- Main --------------------------------------------------------------------

main() {
    parse_args "$@"
    setup_color

    # Installed before anything can fail, so an unexpected error during
    # preflight is diagnosed rather than exiting silently.
    trap 'on_err "$LINENO" "$BASH_COMMAND" "$?"' ERR
    trap on_exit EXIT
    trap on_signal INT TERM

    preflight
    snapshot

    report_plan
    warn_about_ssh

    if ((!APPLY)); then
        log INFO 'Dry run: nothing was changed. Re-run with --yes to apply.'
        return 0
    fi

    # The refusal comes before the lock, deliberately. A refused run must change
    # nothing whatsoever -- not even create the lock file -- and must report 5.
    # Locking first would let a host with no flock(1) answer "prerequisite
    # missing" (3) to what is really a safety refusal, so the operator would
    # never find out that the interface they named carries their own session.
    if ((OVER_SSH)) && ((RELATED)) && ((!FORCE)); then
        die "$EX_NOCONFIRM" \
            "refusing: $IFACE carries this SSH session. Re-run with --force if you accept losing it."
    fi

    # Everything from here on can change the system, so this is where the lock
    # belongs. A run that loses the race exits 75 here, before it has armed or
    # bounced anything -- so the snapshot it took a moment ago is discarded
    # rather than acted upon.
    acquire_lock

    arm_rollback

    if ! bounce; then
        log ERROR "Failed to restart $IFACE"
        return 1
    fi

    if ! verify; then
        log ERROR "$IFACE did not verify; the rollback is left armed deliberately."
        return 1
    fi

    cancel_rollback
    log SUCCESS "$IFACE restarted and verified"
    return 0
}

main "$@"
