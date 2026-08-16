#!/usr/bin/env bash
#
# Prometheus unified exporter installer.
#
# Installs prometheus_unified_metrics.py into its own Python virtual environment
# under /opt and runs it as a sandboxed systemd service. Re-running converges the
# host: nothing that is already correct is touched, and the service is only
# restarted when the unit, the environment file or the payload actually changed.
#
# License: MIT
# Origin:  https://github.com/Lazarev-Cloud/Scripts
#
# Error model: this is a linear installer. A half-finished install is worse than
# no install, so it uses `set -Eeuo pipefail` and aborts on the first unexpected
# failure. Every command whose non-zero status is *information* rather than a
# failure -- a missing tool, an absent device, an optional package -- is checked
# explicitly with `if` or `||`. Do not invoke this script as
# `setup_prometheus_exporter.sh || true`: that moves the error handling out of
# the script and defeats the whole model.
set -Eeuo pipefail
shopt -s inherit_errexit nullglob

# Cron and systemd hand over a nearly empty PATH. Append the standard locations
# rather than replacing PATH, so an operator's own choices still win.
PATH="${PATH:+$PATH:}/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export PATH

readonly SCRIPT_NAME='Prometheus Exporter Installer'
readonly SCRIPT_VERSION='2.0'
readonly PAYLOAD_NAME='prometheus_unified_metrics.py'

# Exit codes, shared by every script in this repository. 75 is EX_TEMPFAIL from
# sysexits.h, which cron and systemd read as "retry later" rather than a real
# fault. Documented in --help and in the README; keep all three in sync.
readonly EX_OK=0
readonly EX_FAIL=1
readonly EX_USAGE=2
readonly EX_PREREQ=3
readonly EX_NOROOT=4
readonly EX_NOCONFIRM=5
readonly EX_LOCKED=75
readonly EX_INTERRUPT=130

# --- Tunables (env overridable, then flag overridable) -----------------------
#
# Every user-facing knob is LZC_EXPORTER_*, so `env | grep LZC_` shows an
# operator everything that is configurable. The shell variables these land in are
# internal names and are deliberately shorter.
#
# LZC_EXPORTER_BIND and LZC_EXPORTER_PORT are shared with the exporter itself:
# this installer writes them into the environment file, and the exporter reads
# the same two names as the defaults for --bind and --port. One name per knob,
# whichever side of the install you are standing on.
INSTALL_DIR="${LZC_EXPORTER_INSTALL_DIR:-/opt/prometheus-unified-exporter}"
SERVICE_NAME="${LZC_EXPORTER_SERVICE_NAME:-prometheus-unified-exporter}"
SERVICE_USER="${LZC_EXPORTER_SERVICE_USER:-prom-exporter}"
SERVICE_GROUP="${LZC_EXPORTER_SERVICE_GROUP:-}"
UNIT_DIR="${LZC_EXPORTER_UNIT_DIR:-/etc/systemd/system}"
ENV_DIR="${LZC_EXPORTER_ENV_DIR:-/etc/default}"
ENV_FILE="${LZC_EXPORTER_ENV_FILE:-}"
LISTEN_ADDRESS="${LZC_EXPORTER_BIND:-127.0.0.1}"
LISTEN_PORT="${LZC_EXPORTER_PORT:-9105}"
PAYLOAD_SRC="${LZC_EXPORTER_SRC:-}"
REQUIREMENTS_SRC="${LZC_EXPORTER_REQUIREMENTS:-}"
PIP_SPEC_LIST="${LZC_EXPORTER_PIP_PACKAGES:-psutil==7.2.2}"
GPU_PIP_SPEC_LIST="${LZC_EXPORTER_GPU_PIP_PACKAGES:-nvidia-ml-py==13.610.43}"
SENSORS_MODE="${LZC_EXPORTER_SENSORS:-auto}"
GPU_MODE="${LZC_EXPORTER_GPU:-auto}"
DISK_HEALTH="${LZC_EXPORTER_DISK_HEALTH:-0}"
SKIP_PACKAGES="${LZC_EXPORTER_SKIP_PACKAGES:-0}"
FORCE_PIP="${LZC_EXPORTER_FORCE_PIP:-0}"
PKG_TIMEOUT="${LZC_EXPORTER_PKG_TIMEOUT:-900}"
PIP_TIMEOUT="${LZC_EXPORTER_PIP_TIMEOUT:-600}"
SYSTEMCTL_TIMEOUT="${LZC_EXPORTER_SYSTEMCTL_TIMEOUT:-90}"
HEALTH_TIMEOUT="${LZC_EXPORTER_HEALTH_TIMEOUT:-10}"
HEALTH_RETRIES="${LZC_EXPORTER_HEALTH_RETRIES:-15}"
APT_CACHE_MAX_AGE="${LZC_EXPORTER_APT_CACHE_MAX_AGE:-86400}"
OS_RELEASE_FILE="${LZC_EXPORTER_OS_RELEASE:-/etc/os-release}"
LOCK_FILE="${LZC_EXPORTER_LOCK:-/run/lock/lzc-exporter.lock}"
ASSUME_YES="${LZC_EXPORTER_YES:-0}"
ACTION="${LZC_EXPORTER_ACTION:-install}"
DRY_RUN=0
USE_COLOR=auto

# --- Runtime state -----------------------------------------------------------
SCRIPT_DIR=''
PAYLOAD_FILE=''
PKG_MANAGER=''
VENV_DIR=''
VENV_PYTHON=''
UNIT_FILE=''
SYSTEMD_VERSION=0
GPU_ENABLED=0
FILE_CHANGED=0
NEEDS_RESTART=0
TMP_DIR=''
LOCK_FD=''
# argv as the operator typed it, kept only so the "run as root" message can
# repeat it back. Nothing branches on it.
declare -a ORIGINAL_ARGS=()
YW='' BL='' RD='' GN='' CL=''

# --- Output ------------------------------------------------------------------

# Colour is opt-out on a terminal and never used off one. Anything other than
# `always` requires a TTY, so an unvalidated value cannot leak escape codes into
# a pipe before validate_args gets to reject it.
#
# NO_COLOR (https://no-color.org): any non-empty value disables colour. An
# explicit `--color always` still wins over it, because a flag the operator typed
# on this command line is a more specific instruction than an exported default.
setup_color() {
    if [[ $USE_COLOR == never ]]; then
        return 0
    fi
    if [[ $USE_COLOR != always ]]; then
        [[ -z ${NO_COLOR:-} ]] || return 0
        [[ -t 1 ]] || return 0
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
        STEP) printf '\n%s==>%s %s\n' "$GN" "$CL" "$*" ;;
        SUCCESS) printf '%s[OK]%s %s\n' "$GN" "$CL" "$*" ;;
        DRYRUN) printf '%s[dry-run]%s %s\n' "$YW" "$CL" "$*" ;;
        *) printf '%s\n' "$*" ;;
    esac
}

# Fails the run with a specific exit code. `die` is the generic form.
die_with() {
    local code=$1
    shift
    log ERROR "$*"
    exit "$code"
}

die() {
    die_with "$EX_FAIL" "$@"
}

usage() {
    cat <<EOF
$SCRIPT_NAME v$SCRIPT_VERSION

Installs $PAYLOAD_NAME as a sandboxed systemd service running from its own
Python virtual environment. Idempotent: re-run it to converge the host.

Usage:
  setup_prometheus_exporter.sh [options]

Options:
  -y, --yes                  Run unattended; skip all prompts.
  -n, --dry-run              Print the plan and change nothing. Works as non-root.
      --uninstall            Remove everything this script installs (see below).
      --install-dir PATH     Install prefix (default: $INSTALL_DIR).
                             Absolute, at least two levels deep, no '.' or '..'
                             components and no whitespace: it is passed to
                             \`rm -rf\` by --uninstall and written into the unit.
      --service-name NAME    systemd unit name (default: $SERVICE_NAME).
      --user NAME            Service account (default: $SERVICE_USER).
      --group NAME           Service group (default: same as the account).
      --listen-address ADDR  Bind address (default: $LISTEN_ADDRESS). No
                             whitespace: it is written into the unit verbatim.
      --port PORT            Bind port (default: $LISTEN_PORT).
      --src PATH             Path to $PAYLOAD_NAME. Default: next to this script.
      --requirements PATH    pip requirements file. Default: requirements.txt
                             next to the payload, else the built-in pins.
      --sensors WHEN         auto | yes | no. Install lm-sensors, nvme-cli and
                             smartmontools (default: auto = yes).
      --gpu WHEN             auto | yes | no. Grant the unit access to
                             /dev/nvidia* (and add the NVML bindings when the
                             built-in pins are in use). Default: auto = only
                             when an NVIDIA GPU is found.
      --disk-health          Run the service as root with raw block-device
                             access so SMART/NVMe temperatures can be read.
                             Off by default. See "Blast radius".
      --skip-packages        Never invoke the distribution package manager.
      --force-pip            Re-run pip even when requirements are unchanged.
      --color WHEN           auto | always | never (default: auto). Flag only.
                             auto emits colour on a terminal, and never when
                             NO_COLOR is set to any non-empty value.
  -V, --version              Print version and exit.
  -h, --help                 Print this help and exit.

Every option except --dry-run and --color has an environment variable, which is
the easier route for unattended runs:
  LZC_EXPORTER_YES=1              LZC_EXPORTER_ACTION=install|uninstall
  LZC_EXPORTER_INSTALL_DIR=/opt/...
  LZC_EXPORTER_SERVICE_NAME=...   LZC_EXPORTER_SERVICE_USER=prom-exporter
  LZC_EXPORTER_SERVICE_GROUP=...  LZC_EXPORTER_FORCE_PIP=1
  LZC_EXPORTER_BIND=127.0.0.1     LZC_EXPORTER_PORT=9105
  LZC_EXPORTER_SRC=/path/$PAYLOAD_NAME
  LZC_EXPORTER_REQUIREMENTS=/path/req.txt
  LZC_EXPORTER_PIP_PACKAGES='psutil==7.2.2'
  LZC_EXPORTER_GPU_PIP_PACKAGES='nvidia-ml-py==13.610.43'
  LZC_EXPORTER_SENSORS=auto       LZC_EXPORTER_GPU=auto
  LZC_EXPORTER_DISK_HEALTH=1      LZC_EXPORTER_SKIP_PACKAGES=1
  LZC_EXPORTER_UNIT_DIR=/etc/systemd/system
  LZC_EXPORTER_ENV_DIR=/etc/default   LZC_EXPORTER_ENV_FILE=/etc/default/NAME
  LZC_EXPORTER_OS_RELEASE=/etc/os-release
  LZC_EXPORTER_LOCK=/run/lock/lzc-exporter.lock

LZC_EXPORTER_BIND and LZC_EXPORTER_PORT are shared with the exporter itself:
they are what this installer writes into the environment file, and they are the
defaults the exporter reads for --bind and --port.

$ENV_DIR/$SERVICE_NAME.local is yours: this installer never writes, reads for
configuration or removes it, and the unit sources it after the managed file, so
settings there survive re-installs. Three variables are the exception, because
the unit is rendered from install-time values while that file is read at start
time:
  LZC_EXPORTER_TEXTFILE   the exporter refuses to start (exit 2) when this is
                          set without --textfile, so an environment file cannot
                          turn the service into a one-shot. Use a separate
                          Type=oneshot unit and timer that passes --textfile.
  LZC_EXPORTER_BIND       moves the listener but not this installer's health
                          check, which is aimed at the install-time address, so
                          a re-run reports a failure for a healthy service.
                          Going from a loopback bind to a routable one is worse
                          still: the unit keeps IPAddressAllow=localhost and
                          systemd drops the non-local traffic anyway.
  LZC_EXPORTER_PORT       same: the health check keeps using the install-time
                          port. Crossing below 1024 also fails the bind with
                          EACCES, because only a unit rendered for a privileged
                          port is granted CAP_NET_BIND_SERVICE.
Change the bind address or the port by re-running this installer with
--listen-address / --port, which moves the unit and the check together. A re-run
warns when it finds any of the three set in that file.

Timeouts, in seconds. Each bounds a different thing, so they are listed with
what they actually cover. All must be at least 1: \`timeout 0\` means NO limit
and would silently remove the protection.
  LZC_EXPORTER_PKG_TIMEOUT=900        per package-manager invocation (one
                                      \`apt-get update\`, one \`apt-get install\`)
  LZC_EXPORTER_PIP_TIMEOUT=600        for the single \`pip install -r\` run
  LZC_EXPORTER_SYSTEMCTL_TIMEOUT=90   per systemctl call (enable, start,
                                      restart, disable)
  LZC_EXPORTER_HEALTH_TIMEOUT=10      per attempt to fetch /metrics after start
  LZC_EXPORTER_HEALTH_RETRIES=15      how many such attempts, one second apart
  LZC_EXPORTER_APT_CACHE_MAX_AGE=86400  how old the apt index may be before it
                                      is refreshed. May be 0, meaning always.

The four boolean variables -- LZC_EXPORTER_YES, LZC_EXPORTER_DISK_HEALTH,
LZC_EXPORTER_SKIP_PACKAGES and LZC_EXPORTER_FORCE_PIP -- accept 1/true/yes/on
and 0/false/no/off, case insensitively. Anything else is a usage error reported
before any change is made, rather than a crash halfway through the install.

Blast radius:
  install    Installs distribution packages (Python, and unless --sensors no,
             lm-sensors + nvme-cli + smartmontools); creates the system account
             $SERVICE_USER; creates $INSTALL_DIR and a virtualenv inside it;
             writes $UNIT_DIR/$SERVICE_NAME.service and
             $ENV_DIR/$SERVICE_NAME; enables and starts the service.
             It never downloads the payload, never runs sensors-detect, never
             loads kernel modules and never installs a GPU driver.
  --disk-health
             Changes the service account to root and grants it CAP_SYS_RAWIO,
             CAP_SYS_ADMIN and CAP_DAC_OVERRIDE plus read/write access to block
             devices, because smartctl issues SCSI passthrough commands and no
             lesser privilege works. Without it the service runs unprivileged
             with PrivateDevices=yes and disk temperatures are simply absent.
  --uninstall
             Stops and disables the service, removes the unit, the managed
             environment file, $INSTALL_DIR (recursively) and the
             $SERVICE_USER account. Your own <env-file>.local is left alone.
             It does NOT remove distribution packages it may have installed and
             does NOT touch Prometheus itself. Requires --yes when there is no
             terminal to confirm on.

Exit status:
  0    success
  1    the work ran but something in it failed
  2    usage error (unknown flag, missing or invalid argument value)
  3    unsupported platform or a missing prerequisite tool
  4    must be run as root
  5    refused: confirmation needed, but no TTY and --yes was not given
  75   temporary failure: another instance holds $LOCK_FILE
  130  interrupted (SIGINT/SIGTERM)

A service that installs but then fails to come up, or comes up but never serves
/metrics, is a 1: the work ran and something in it failed. The journal and a
direct foreground run of the exporter are printed before exiting.

Running from a pipe (curl ... | bash) works: every statement lives in a
function and main runs on the last line, so a truncated download executes
nothing. Flags must then be passed after a literal \`--\`, and the payload must
already be on disk -- point --src or LZC_EXPORTER_SRC at it.
EOF
}

# --- Argument parsing --------------------------------------------------------

need_value() {
    (($1 >= 2)) || die_with "$EX_USAGE" "$2 requires a value (try --help)"
}

parse_args() {
    while (($#)); do
        case $1 in
            -y | --yes) ASSUME_YES=1 ;;
            -n | --dry-run) DRY_RUN=1 ;;
            --uninstall) ACTION=uninstall ;;
            --install) ACTION=install ;;
            --disk-health) DISK_HEALTH=1 ;;
            --skip-packages) SKIP_PACKAGES=1 ;;
            --force-pip) FORCE_PIP=1 ;;
            --install-dir)
                need_value $# "$1"
                INSTALL_DIR=$2
                shift
                ;;
            --service-name)
                need_value $# "$1"
                SERVICE_NAME=$2
                shift
                ;;
            --user)
                need_value $# "$1"
                SERVICE_USER=$2
                shift
                ;;
            --group)
                need_value $# "$1"
                SERVICE_GROUP=$2
                shift
                ;;
            --listen-address)
                need_value $# "$1"
                LISTEN_ADDRESS=$2
                shift
                ;;
            --port)
                need_value $# "$1"
                LISTEN_PORT=$2
                shift
                ;;
            --src)
                need_value $# "$1"
                PAYLOAD_SRC=$2
                shift
                ;;
            --requirements)
                need_value $# "$1"
                REQUIREMENTS_SRC=$2
                shift
                ;;
            --sensors)
                need_value $# "$1"
                SENSORS_MODE=$2
                shift
                ;;
            --gpu)
                need_value $# "$1"
                GPU_MODE=$2
                shift
                ;;
            --color)
                need_value $# "$1"
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
            *) die_with "$EX_USAGE" "Unknown option: $1 (try --help)" ;;
        esac
        shift
    done
}

# Booleans arrive from the environment as free text. Normalising them to 0/1
# before anything else means every later `((FLAG))` is arithmetic on a number:
# with an unnormalised LZC_EXPORTER_DISK_HEALTH=true, `((DISK_HEALTH))` evaluates
# the *identifier* `true`, which `set -u` aborts on halfway through the install.
# That is a real crash a user hits by writing the obvious thing in a cron file.
#
# normalise_bool <shell-variable> <name to show the user>
normalise_bool() {
    local name=$1 label=$2
    case ${!name,,} in
        1 | true | yes | on) printf -v "$name" '%s' 1 ;;
        0 | false | no | off | '') printf -v "$name" '%s' 0 ;;
        *)
            die_with "$EX_USAGE" \
                "$label must be 1/true/yes/on or 0/false/no/off, got '${!name}'"
            ;;
    esac
}

# normalise_int <shell-variable> <minimum> <name to show the user>
normalise_int() {
    local name=$1 min=$2 label=$3 value
    [[ ${!name} =~ ^[0-9]+$ ]] ||
        die_with "$EX_USAGE" "$label must be a whole number, got '${!name}'"
    # 10# forces base ten: a zero-padded value such as 08 is otherwise read as an
    # invalid octal literal and aborts the arithmetic that uses it.
    value=$((10#${!name}))
    ((value >= min)) ||
        die_with "$EX_USAGE" "$label must be at least $min, got '${!name}'"
    printf -v "$name" '%s' "$value"
}

validate_args() {
    # Booleans first: everything below may branch on them.
    normalise_bool ASSUME_YES '--yes / LZC_EXPORTER_YES'
    normalise_bool DISK_HEALTH '--disk-health / LZC_EXPORTER_DISK_HEALTH'
    normalise_bool SKIP_PACKAGES '--skip-packages / LZC_EXPORTER_SKIP_PACKAGES'
    normalise_bool FORCE_PIP '--force-pip / LZC_EXPORTER_FORCE_PIP'

    [[ $USE_COLOR =~ ^(auto|always|never)$ ]] ||
        die_with "$EX_USAGE" "--color must be auto, always or never, got '$USE_COLOR'"
    [[ $SENSORS_MODE =~ ^(auto|yes|no)$ ]] ||
        die_with "$EX_USAGE" "--sensors must be auto, yes or no, got '$SENSORS_MODE'"
    [[ $GPU_MODE =~ ^(auto|yes|no)$ ]] ||
        die_with "$EX_USAGE" "--gpu must be auto, yes or no, got '$GPU_MODE'"
    [[ $ACTION =~ ^(install|uninstall)$ ]] ||
        die_with "$EX_USAGE" "LZC_EXPORTER_ACTION must be install or uninstall, got '$ACTION'"

    # Minimum 1, never 0: each of these is handed to timeout(1), and `timeout 0`
    # means "no limit", which would silently remove the protection the setting
    # exists to provide. HEALTH_RETRIES is a loop bound; 0 would skip the health
    # check entirely and report success for a service that never answered.
    normalise_int PKG_TIMEOUT 1 'LZC_EXPORTER_PKG_TIMEOUT'
    normalise_int PIP_TIMEOUT 1 'LZC_EXPORTER_PIP_TIMEOUT'
    normalise_int SYSTEMCTL_TIMEOUT 1 'LZC_EXPORTER_SYSTEMCTL_TIMEOUT'
    normalise_int HEALTH_TIMEOUT 1 'LZC_EXPORTER_HEALTH_TIMEOUT'
    normalise_int HEALTH_RETRIES 1 'LZC_EXPORTER_HEALTH_RETRIES'
    # 0 is meaningful here: refresh the apt index on every run.
    normalise_int APT_CACHE_MAX_AGE 0 'LZC_EXPORTER_APT_CACHE_MAX_AGE'

    normalise_int LISTEN_PORT 1 '--port / LZC_EXPORTER_PORT'
    ((LISTEN_PORT <= 65535)) ||
        die_with "$EX_USAGE" "--port / LZC_EXPORTER_PORT must be 1-65535, got '$LISTEN_PORT'"

    [[ $SERVICE_NAME =~ ^[A-Za-z0-9_.@-]+$ ]] ||
        die_with "$EX_USAGE" "--service-name must be a bare systemd unit name, got '$SERVICE_NAME'"
    [[ $SERVICE_USER =~ ^[a-z_][a-z0-9_-]*$ ]] ||
        die_with "$EX_USAGE" "--user must be a valid account name, got '$SERVICE_USER'"

    assert_plain_text "--listen-address" "$LISTEN_ADDRESS"

    # Checked here rather than where it is used: requirements_source() runs
    # inside a command substitution, where `exit` would only kill the subshell
    # and the failure would be silently swallowed by the caller's `if`.
    [[ -z $REQUIREMENTS_SRC || -r $REQUIREMENTS_SRC ]] ||
        die_with "$EX_PREREQ" "--requirements points at '$REQUIREMENTS_SRC', which is not readable"

    assert_safe_prefix "$INSTALL_DIR"

    [[ -n $SERVICE_GROUP ]] || SERVICE_GROUP=$SERVICE_USER
    # Same rule as --user: the group name reaches the unit as `Group=` and
    # `install -g`, so it gets the same character set rather than none at all.
    [[ $SERVICE_GROUP =~ ^[a-z_][a-z0-9_-]*$ ]] ||
        die_with "$EX_USAGE" "--group must be a valid group name, got '$SERVICE_GROUP'"

    [[ -n $ENV_FILE ]] || ENV_FILE="$ENV_DIR/$SERVICE_NAME"
    # Checked after the default is applied, so this covers LZC_EXPORTER_ENV_DIR too.
    # ENV_FILE is written into the unit as `EnvironmentFile=-%s`, twice.
    assert_plain_text "The environment file path" "$ENV_FILE"

    UNIT_FILE="$UNIT_DIR/$SERVICE_NAME.service"
    VENV_DIR="$INSTALL_DIR/venv"
    VENV_PYTHON="$VENV_DIR/bin/python"
}

# Values that are written verbatim into the systemd unit must not be able to
# introduce a directive of their own: a newline in --listen-address would
# otherwise append e.g. `ExecStartPre=/bin/rm -rf /` to a root-owned unit file.
# Whitespace is refused along with the control characters because systemd splits
# ExecStart and EnvironmentFile on it, so a space would corrupt the unit anyway.
assert_plain_text() {
    local what=$1 value=$2
    [[ $value != *[[:space:]]* && $value != *[[:cntrl:]]* ]] ||
        die_with "$EX_USAGE" "$what must not contain whitespace or control characters, got '$value'"
}

# INSTALL_DIR is passed to `rm -rf` during uninstall, so refuse anything that
# could take a system directory with it.
assert_safe_prefix() {
    local dir=$1 trimmed
    [[ $dir == /* ]] || die_with "$EX_USAGE" "Install prefix must be an absolute path, got '$dir'"
    [[ $dir != *//* ]] || die_with "$EX_USAGE" "Install prefix must not contain '//', got '$dir'"
    assert_plain_text "Install prefix" "$dir"
    trimmed=${dir%/}
    # A '.' or '..' component walks straight through every check below:
    # '/opt/../..' is absolute, is not literally a system directory and is two
    # levels deep, yet it resolves to '/' by the time it reaches `rm -rf` during
    # uninstall. Reject traversal outright rather than trying to enumerate the
    # paths it can reach.
    case $trimmed/ in
        */../* | */./*)
            die_with "$EX_USAGE" "Install prefix must not contain '.' or '..' components, got '$dir'"
            ;;
    esac
    case $trimmed in
        '' | /bin | /boot | /dev | /etc | /home | /lib | /lib64 | /opt | /proc | /root | \
            /run | /sbin | /srv | /sys | /tmp | /usr | /var)
            die_with "$EX_USAGE" "Refusing to use '$dir' as the install prefix: it is a system directory"
            ;;
    esac
    # Require at least two path components, i.e. /opt/name and not /name.
    [[ ${trimmed#/} == */* ]] ||
        die_with "$EX_USAGE" "Install prefix must be at least two levels deep, got '$dir'"
}

# --- Small utilities ---------------------------------------------------------

have() {
    command -v "$1" >/dev/null 2>&1
}

is_interactive() {
    [[ -t 0 && -t 1 ]]
}

# Executes a command, or prints it when --dry-run is in effect.
run() {
    if ((DRY_RUN)); then
        log DRYRUN "$(printf '%q ' "$@")"
        return 0
    fi
    "$@"
}

resolve_script_dir() {
    local src=${BASH_SOURCE[0]:-} dir
    if [[ -z $src || $src == bash || $src == -* || ! -r $src ]]; then
        printf '%s' "$PWD"
        return 0
    fi
    dir=$(cd -- "$(dirname -- "$src")" >/dev/null 2>&1 && pwd) || dir=$PWD
    printf '%s' "$dir"
}

# Reads one KEY=value pair out of an os-release file. Parsed rather than sourced:
# /etc/os-release is shell syntax, and sourcing it would execute whatever it
# contains and clobber this script's variables.
os_release_field() {
    local key=$1 value
    [[ -r $OS_RELEASE_FILE ]] || return 1
    value=$(sed -n "s/^${key}=//p" "$OS_RELEASE_FILE" 2>/dev/null) || return 1
    [[ -n $value ]] || return 1
    value=${value%%$'\n'*}
    value=${value#[\"\']}
    value=${value%[\"\']}
    printf '%s' "$value"
}

# Three outcomes, not two, because the caller has to tell them apart:
#   0  confirmed (or --yes was given)
#   1  the operator was asked and declined -- a choice, not an error
#   2  no answer could be obtained (no terminal, or stdin closed)
# Collapsing 1 and 2 would report a deliberate "n" as a refusal-for-lack-of-TTY,
# which is exit 5, and that would be a lie about what happened.
confirm() {
    local prompt=$1 reply
    ((ASSUME_YES)) && return 0
    is_interactive || return 2
    read -r -p "$prompt [y/N] " reply || return 2
    [[ ${reply,,} == y* ]]
}

# --- Preflight ---------------------------------------------------------------

preflight_common() {
    [[ $(uname -s 2>/dev/null || printf 'unknown') == Linux ]] ||
        die_with "$EX_PREREQ" "This installer targets Linux with systemd. Run the exporter directly on other platforms."
    have systemctl ||
        die_with "$EX_PREREQ" "systemctl not found. This installer requires systemd."
    have timeout ||
        die_with "$EX_PREREQ" "timeout (coreutils) not found."

    if ((!DRY_RUN)) && [[ $EUID -ne 0 ]]; then
        die_with "$EX_NOROOT" "Run as root: sudo bash $0 ${ORIGINAL_ARGS[*]-}"
    fi

    detect_systemd_version
}

detect_systemd_version() {
    local out
    out=$(systemctl --version 2>/dev/null) || out=''
    out=${out%%$'\n'*}
    out=${out#systemd }
    out=${out%% *}
    out=${out//[!0-9]/}
    if [[ -n $out ]]; then
        SYSTEMD_VERSION=$out
    fi
}

acquire_lock() {
    ((DRY_RUN)) && return 0
    mkdir -p -- "$(dirname -- "$LOCK_FILE")" 2>/dev/null || true
    if ! exec {LOCK_FD}>"$LOCK_FILE" 2>/dev/null; then
        log WARN "Cannot open $LOCK_FILE; continuing without concurrency protection"
        LOCK_FD=''
        return 0
    fi
    flock -n "$LOCK_FD" ||
        die_with "$EX_LOCKED" "Another $SCRIPT_NAME run holds $LOCK_FILE. Refusing to run concurrently."
}

# --- Hardware detection ------------------------------------------------------
#
# Detection never gates the install: the exporter degrades on its own when a
# sensor, a disk or a GPU is absent. It decides two things -- what to tell the
# operator, and which device rules the systemd unit needs.

has_hwmon() {
    local entries=(/sys/class/hwmon/hwmon*)
    ((${#entries[@]} > 0))
}

has_block_disk() {
    local entries=(/sys/block/sd* /sys/block/nvme* /sys/block/vd* /sys/block/hd*)
    ((${#entries[@]} > 0))
}

has_nvidia_gpu() {
    # nullglob only removes patterns that actually contain wildcards, so the
    # fixed control-device path is tested with -e rather than globbed.
    local nodes=(/dev/nvidia[0-9]*)
    ((${#nodes[@]} > 0)) && return 0
    [[ -e /dev/nvidiactl ]] && return 0
    have nvidia-smi && return 0
    if have lspci; then
        timeout 10 lspci 2>/dev/null | grep -qi 'nvidia' && return 0
    fi
    return 1
}

report_hardware() {
    if has_hwmon; then
        log INFO "hwmon sensors present: CPU/board temperatures should be available"
    else
        log WARN "No /sys/class/hwmon devices: temperature metrics will be empty on this host"
    fi

    if has_block_disk; then
        if ((DISK_HEALTH)); then
            log INFO "Local disks present and --disk-health is on: SMART/NVMe temperatures enabled"
            # --disk-health exists only to run smartctl. If this run will not
            # install it and it is not already here, the service ends up running
            # as root for nothing -- say so rather than let it look enabled.
            if ! have smartctl && { [[ $SENSORS_MODE == no ]] || ((SKIP_PACKAGES)); }; then
                log WARN "--disk-health needs smartctl, which is absent and will not be installed"
                log WARN "here (--sensors no / --skip-packages). Install smartmontools, or the"
                log WARN "service will run as root and still report no disk temperatures."
            fi
        else
            log INFO "Local disks present, but --disk-health is off: disk temperatures will be absent"
        fi
    else
        log INFO "No local block devices found: disk temperature metrics will be empty"
    fi

    case $GPU_MODE in
        no) log INFO "GPU support disabled (--gpu no)" ;;
        yes)
            GPU_ENABLED=1
            has_nvidia_gpu || log WARN "--gpu yes was requested but no NVIDIA GPU was detected"
            ;;
        auto)
            if has_nvidia_gpu; then
                GPU_ENABLED=1
                log INFO "NVIDIA GPU detected: granting the unit access to /dev/nvidia*"
                if ! have nvidia-smi; then
                    log WARN "nvidia-smi is not installed, so GPU metrics will be empty."
                    log WARN "Install the driver package matching your kernel, then re-run."
                    log WARN "This script never guesses NVIDIA driver package names."
                fi
            else
                log INFO "No NVIDIA GPU detected: GPU metrics disabled"
            fi
            ;;
    esac
}

# --- Distribution packages ---------------------------------------------------

detect_pkg_manager() {
    local id='' id_like='' token
    id=$(os_release_field ID) || id=''
    id_like=$(os_release_field ID_LIKE) || id_like=''

    local -a tokens=()
    read -r -a tokens <<<"$id $id_like"

    for token in ${tokens[@]+"${tokens[@]}"}; do
        case ${token,,} in
            debian | ubuntu | raspbian | linuxmint | pop | devuan)
                printf 'apt'
                return 0
                ;;
            rhel | centos | fedora | rocky | almalinux | ol | oracle | amzn)
                if have dnf; then printf 'dnf'; else printf 'yum'; fi
                return 0
                ;;
            opensuse* | suse | sles)
                printf 'zypper'
                return 0
                ;;
            arch | archlinux | manjaro | endeavouros)
                printf 'pacman'
                return 0
                ;;
        esac
    done

    # ID/ID_LIKE said nothing useful (unmanaged images, derivatives that set
    # neither). Fall back to whichever package manager is actually installed.
    local candidate
    for candidate in apt-get dnf yum zypper pacman; do
        if have "$candidate"; then
            [[ $candidate == apt-get ]] && candidate=apt
            printf '%s' "$candidate"
            return 0
        fi
    done
    return 1
}

# Debian's package index is refreshed only when it is older than
# APT_CACHE_MAX_AGE, so a re-run does not hit the mirrors for nothing.
apt_index_is_stale() {
    local stamp now age
    stamp=$(stat -c %Y /var/lib/apt/periodic/update-success-stamp 2>/dev/null) ||
        stamp=$(stat -c %Y /var/lib/apt/lists 2>/dev/null) ||
        return 0
    now=$(date +%s)
    age=$((now - stamp))
    ((age > APT_CACHE_MAX_AGE))
}

pkg_install() {
    local -a packages=("$@")
    ((${#packages[@]})) || return 0

    case $PKG_MANAGER in
        apt)
            # noninteractive suppresses debconf; the force-conf* pair suppresses
            # dpkg's conffile prompt; Lock::Timeout waits for unattended-upgrades
            # instead of failing the install outright.
            local -a apt_opts=(
                -y
                -o DPkg::Lock::Timeout=300
                -o Dpkg::Use-Pty=0
                -o Dpkg::Options::=--force-confdef
                -o Dpkg::Options::=--force-confold
            )
            if apt_index_is_stale; then
                run env DEBIAN_FRONTEND=noninteractive timeout "$PKG_TIMEOUT" \
                    apt-get "${apt_opts[@]}" update || return 1
            else
                log INFO "apt index is fresh; skipping apt-get update"
            fi
            run env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l \
                timeout "$PKG_TIMEOUT" \
                apt-get "${apt_opts[@]}" install --no-install-recommends "${packages[@]}"
            ;;
        dnf)
            run timeout "$PKG_TIMEOUT" dnf install -y --setopt=install_weak_deps=False "${packages[@]}"
            ;;
        yum)
            run timeout "$PKG_TIMEOUT" yum install -y "${packages[@]}"
            ;;
        zypper)
            run timeout "$PKG_TIMEOUT" zypper --non-interactive install --no-recommends "${packages[@]}"
            ;;
        pacman)
            # --needed makes this idempotent. The database is deliberately not
            # synced: `pacman -Sy` without a full upgrade produces a partial
            # upgrade, which upstream Arch calls unsupported. Run `pacman -Syu`
            # yourself first if the install cannot find a package.
            run timeout "$PKG_TIMEOUT" pacman -S --needed --noconfirm "${packages[@]}"
            ;;
        *)
            return 1
            ;;
    esac
}

# Package names for one logical tool, per package manager.
pkg_name_for() {
    local tool=$1
    case "$PKG_MANAGER:$tool" in
        apt:python) printf 'python3 python3-venv' ;;
        dnf:python | yum:python) printf 'python3' ;;
        zypper:python) printf 'python3 python3-pip' ;;
        pacman:python) printf 'python' ;;
        apt:sensors) printf 'lm-sensors' ;;
        dnf:sensors | yum:sensors | pacman:sensors) printf 'lm_sensors' ;;
        zypper:sensors) printf 'sensors' ;;
        *:nvme) printf 'nvme-cli' ;;
        *:smart) printf 'smartmontools' ;;
        *) return 1 ;;
    esac
}

python_has_venv() {
    have python3 || return 1
    timeout 60 python3 -c 'import ensurepip, venv' >/dev/null 2>&1
}

ensure_system_packages() {
    if ((SKIP_PACKAGES)); then
        log INFO "Skipping the package manager (--skip-packages)"
        return 0
    fi

    PKG_MANAGER=$(detect_pkg_manager) || PKG_MANAGER=''
    if [[ -z $PKG_MANAGER ]]; then
        die_with "$EX_PREREQ" \
            "No supported package manager found. Install python3 (with venv) yourself and re-run with --skip-packages."
    fi
    log INFO "Package manager: $PKG_MANAGER"

    local -a required=() optional=() names=()
    if ! python_has_venv; then
        read -r -a names <<<"$(pkg_name_for python)"
        required+=("${names[@]}")
    fi

    if [[ $SENSORS_MODE != no ]]; then
        have sensors || { read -r -a names <<<"$(pkg_name_for sensors)" && optional+=("${names[@]}"); }
        have nvme || { read -r -a names <<<"$(pkg_name_for nvme)" && optional+=("${names[@]}"); }
        have smartctl || { read -r -a names <<<"$(pkg_name_for smart)" && optional+=("${names[@]}"); }
    fi

    if ((${#required[@]})); then
        log INFO "Installing required packages: ${required[*]}"
        pkg_install "${required[@]}" ||
            die "Failed to install required packages: ${required[*]}"
    else
        log INFO "Python with venv support is already present"
    fi

    if ((${#optional[@]})); then
        log INFO "Installing sensor tooling: ${optional[*]}"
        # Sensor tooling is genuinely optional: the exporter emits no series for
        # a tool it cannot find, so a failure here is a warning, not an abort.
        pkg_install "${optional[@]}" ||
            log WARN "Could not install ${optional[*]}; the matching metrics will be absent"
    elif [[ $SENSORS_MODE != no ]]; then
        log INFO "Sensor tooling is already present"
    fi

    if ((!DRY_RUN)) && ! python_has_venv; then
        die_with "$EX_PREREQ" \
            "python3 is present but 'import ensurepip, venv' fails. Install your distribution's Python venv package and re-run."
    fi
}

# --- Payload -----------------------------------------------------------------

locate_payload() {
    local candidate
    if [[ -n $PAYLOAD_SRC ]]; then
        [[ -r $PAYLOAD_SRC ]] ||
            die_with "$EX_PREREQ" "--src points at '$PAYLOAD_SRC', which is not readable"
        PAYLOAD_FILE=$PAYLOAD_SRC
        return 0
    fi

    for candidate in "$SCRIPT_DIR/$PAYLOAD_NAME" "$SCRIPT_DIR/monitoring/$PAYLOAD_NAME" \
        "$PWD/$PAYLOAD_NAME"; do
        if [[ -r $candidate ]]; then
            PAYLOAD_FILE=$candidate
            return 0
        fi
    done

    log ERROR "$PAYLOAD_NAME was not found next to this script."
    die_with "$EX_PREREQ" \
        "This installer never downloads it. Clone the repository, or point --src / LZC_EXPORTER_SRC at the file."
}

# Path of the requirements file that governs the venv, if there is one. An
# explicit --requirements wins; otherwise a requirements.txt shipped next to the
# exporter does, so the exporter can change its own dependencies without this
# installer having to know about it. Returns 1 when neither exists.
requirements_source() {
    if [[ -n $REQUIREMENTS_SRC ]]; then
        printf '%s' "$REQUIREMENTS_SRC"
        return 0
    fi
    if [[ -r ${PAYLOAD_FILE%/*}/requirements.txt ]]; then
        printf '%s' "${PAYLOAD_FILE%/*}/requirements.txt"
        return 0
    fi
    return 1
}

# The dependency list, printed to stdout. Deliberately free of `die`: it runs
# inside a command substitution, where exiting would only end the subshell.
requirements_content() {
    local source_file
    if source_file=$(requirements_source); then
        cat -- "$source_file"
        return 0
    fi

    local -a specs=()
    read -r -a specs <<<"$PIP_SPEC_LIST"
    if ((GPU_ENABLED)); then
        local -a gpu_specs=()
        read -r -a gpu_specs <<<"$GPU_PIP_SPEC_LIST"
        specs+=(${gpu_specs[@]+"${gpu_specs[@]}"})
    fi
    ((${#specs[@]})) || return 0
    printf '%s\n' "${specs[@]}"
}

# --- File rendering ----------------------------------------------------------
#
# Files are rendered whole and compared before being written, never appended to.
# FILE_CHANGED tells the caller whether anything actually moved.

render_file() {
    local path=$1 mode=$2 owner=$3 content=$4
    local tmp="$TMP_DIR/render"

    FILE_CHANGED=0
    printf '%s\n' "$content" >"$tmp" || die "Cannot write to $TMP_DIR"

    if [[ -f $path ]] && cmp -s "$tmp" "$path"; then
        log INFO "Unchanged: $path"
        return 0
    fi

    FILE_CHANGED=1
    if ((DRY_RUN)); then
        log DRYRUN "would write $path (mode $mode, owner $owner)"
        return 0
    fi

    install -D -m "$mode" -o "${owner%%:*}" -g "${owner##*:}" "$tmp" "$path" ||
        die "Cannot install $path"
    log SUCCESS "Wrote $path"
}

# --- Service account ---------------------------------------------------------

nologin_shell() {
    local candidate
    for candidate in /usr/sbin/nologin /sbin/nologin /bin/false; do
        if [[ -x $candidate ]]; then
            printf '%s' "$candidate"
            return 0
        fi
    done
    printf '/bin/false'
}

ensure_service_account() {
    # --disk-health runs the service as root, so no account is needed.
    if ((DISK_HEALTH)); then
        log INFO "--disk-health: the service will run as root; no service account is created"
        return 0
    fi

    if id -u "$SERVICE_USER" >/dev/null 2>&1; then
        log INFO "Service account $SERVICE_USER already exists"
        return 0
    fi

    if ! have useradd; then
        ((DRY_RUN)) ||
            die_with "$EX_PREREQ" "useradd not found; create the '$SERVICE_USER' system account yourself and re-run."
        log DRYRUN "useradd is not available here; a real run would need it"
    fi

    local shell
    shell=$(nologin_shell)
    log INFO "Creating system account $SERVICE_USER"
    run useradd --system --user-group --no-create-home --home-dir /nonexistent \
        --shell "$shell" --comment 'Prometheus unified exporter' "$SERVICE_USER" ||
        die "Could not create the system account $SERVICE_USER"
}

# --- Install tree and virtualenv ---------------------------------------------

install_tree() {
    log STEP "Installing the payload into $INSTALL_DIR"
    run install -d -m 0755 -o root -g root "$INSTALL_DIR" || die "Cannot create $INSTALL_DIR"

    local content
    content=$(cat -- "$PAYLOAD_FILE") || die "Cannot read $PAYLOAD_FILE"
    # Owned by root and not writable by the service account: the account that
    # runs this code must never be able to edit it.
    render_file "$INSTALL_DIR/$PAYLOAD_NAME" 0755 root:root "$content"
    ((FILE_CHANGED)) && NEEDS_RESTART=1

    local req_source
    if req_source=$(requirements_source); then
        log INFO "Dependencies from $req_source"
    else
        log INFO "Dependencies from the built-in pins (no requirements.txt beside the exporter)"
    fi

    content=$(requirements_content)
    [[ -n $content ]] ||
        die_with "$EX_USAGE" "The resolved dependency list is empty; check --requirements and LZC_EXPORTER_PIP_PACKAGES"
    render_file "$INSTALL_DIR/requirements.txt" 0644 root:root "$content"
}

ensure_venv() {
    # Written only after pip exits 0, and read to decide whether pip can be
    # skipped. It lives inside the venv because it describes what is installed
    # in the venv; if the venv is rebuilt it goes with it.
    local stamp="$VENV_DIR/.requirements.installed"

    log STEP "Preparing the Python virtual environment"
    if [[ -x $VENV_PYTHON ]]; then
        log INFO "Virtual environment already present at $VENV_DIR"
    else
        # Plain `python3 -m venv`: the bundled pip from ensurepip is installed
        # offline. `--upgrade-deps` would fetch an unpinned pip from PyPI on
        # every run, which is exactly the kind of unpinned network fetch this
        # installer avoids.
        log INFO "Creating $VENV_DIR"
        run python3 -m venv "$VENV_DIR" || die "Could not create the virtual environment at $VENV_DIR"
    fi

    if ((DRY_RUN)); then
        log DRYRUN "would install pinned requirements into $VENV_DIR"
        return 0
    fi

    # pip is skipped only against proof that pip already installed exactly this
    # requirement set into this venv. That proof cannot be
    # $INSTALL_DIR/requirements.txt: install_tree renders it BEFORE pip runs, so
    # after a failed pip the new pins are already on disk and the next run reads
    # them back as "Unchanged", skips pip, and goes on to enable, start and
    # verify the service. Since the exporter degrades rather than dies when an
    # optional dependency is missing, that run prints "Serving metrics" and
    # exits 0 having never installed anything -- a silent no-op reported as
    # convergence, and one that re-running could not repair.
    #
    # The stamp is a copy of the requirements the last successful pip actually
    # installed, so a failed pip simply leaves no proof and the next run tries
    # again. This keeps the re-run offline and instant in the normal case.
    if ((FORCE_PIP == 0)) && [[ -f $stamp ]] &&
        cmp -s "$stamp" "$INSTALL_DIR/requirements.txt"; then
        log INFO "Requirements already installed in $VENV_DIR; skipping pip"
        return 0
    fi

    local -a pip_args=(
        install
        --no-cache-dir
        --no-input
        --disable-pip-version-check
        --upgrade
        -r "$INSTALL_DIR/requirements.txt"
    )
    # --require-hashes fails the whole install unless *every* requirement,
    # including transitive ones, carries a hash. Enable it only when the file
    # actually provides hashes.
    if grep -q -- '--hash=' "$INSTALL_DIR/requirements.txt" 2>/dev/null; then
        pip_args+=(--require-hashes)
        log INFO "requirements.txt carries hashes: installing with --require-hashes"
    fi

    log INFO "Installing Python dependencies (PEP 668-safe: inside the venv, never the system Python)"
    timeout "$PIP_TIMEOUT" "$VENV_DIR/bin/pip" "${pip_args[@]}" ||
        die "pip failed to install $INSTALL_DIR/requirements.txt"

    # Only now is the skip above safe to take. If this write fails the next run
    # simply reinstalls, so it is not fatal -- but it is not silent either,
    # because a stamp that never appears means every run pays for pip.
    install -m 0644 -o root -g root "$INSTALL_DIR/requirements.txt" "$stamp" ||
        log WARN "Could not record $stamp; the next run will re-run pip"
}

# The venv is built by root but read by an unprivileged service account. A root
# umask of 077 would otherwise produce a tree the service cannot execute, and
# Type=exec would then fail the start with a bare EACCES.
fix_permissions() {
    ((DRY_RUN)) && return 0
    chmod -R a+rX -- "${INSTALL_DIR:?}" || log WARN "Could not relax permissions under $INSTALL_DIR"
}

# --- systemd -----------------------------------------------------------------

address_is_loopback() {
    case $1 in
        127.* | ::1 | '[::1]' | localhost) return 0 ;;
        *) return 1 ;;
    esac
}

render_env_content() {
    cat <<EOF
# Managed by setup_prometheus_exporter.sh. Rendered whole on every run, so
# edits here are overwritten. Change these two with the installer's flags.
# Put anything else -- the exporter's other LZC_EXPORTER_* variables, for
# instance -- in the file below, which this installer never writes and never
# removes:
#   $ENV_FILE.local
#
# Three variables are NOT freely overridable there, because the unit is rendered
# from the values below at install time while that file is read at start time:
#   LZC_EXPORTER_TEXTFILE  the exporter refuses to start (exit 2) when this is
#                          set without --textfile, so this file cannot turn the
#                          service into a one-shot. Use a timer for that.
#   LZC_EXPORTER_BIND      moves the listener but not the installer's health
#                          check, so a re-install reports a failure for a
#                          healthy service. Crossing from loopback to a routable
#                          address also leaves IPAddressAllow=localhost behind.
#   LZC_EXPORTER_PORT      the same, and crossing below 1024 fails the bind:
#                          only a unit rendered for a privileged port gets
#                          CAP_NET_BIND_SERVICE.
# Re-run the installer with --listen-address / --port instead: that moves the
# unit, this file and the health check together.
LZC_EXPORTER_BIND=$LISTEN_ADDRESS
LZC_EXPORTER_PORT=$LISTEN_PORT
EOF
}

# Reads the effective value of one KEY out of an environment file, without
# sourcing it: that file is operator-authored, and sourcing would execute it.
# systemd takes the last assignment of a name, so this takes the last non-empty
# one. Returns 1 when the key is absent.
env_file_value() {
    local file=$1 key=$2 value
    [[ -r $file ]] || return 1
    value=$(sed -n "s/^[[:space:]]*${key}=//p" "$file" 2>/dev/null) || return 1
    [[ -n $value ]] || return 1
    value=${value##*$'\n'}
    value=${value%$'\r'}
    # systemd skips the whitespace between '=' and the value and ignores what
    # trails it, so `LZC_EXPORTER_BIND=  127.0.0.1` reaches the exporter as
    # `127.0.0.1`. Trim the same way: the checks below have to judge the value
    # the service will actually see, not the bytes in the file. An all-whitespace
    # value trims to empty and is reported absent, which is what systemd does
    # with it too.
    value=${value#"${value%%[![:space:]]*}"}
    value=${value%"${value##*[![:space:]]}"}
    value=${value#[\"\']}
    value=${value%[\"\']}
    [[ -n $value ]] || return 1
    printf '%s' "$value"
}

# The unit is rendered from install-time values, but <env-file>.local is read at
# start time. Most variables are harmless there -- that is the whole point of the
# file -- but three change the *shape* the unit was rendered for, and the result
# is a service that starts and then misbehaves in a way with no obvious cause.
# Warn, never fail: an ineffective variable is not a reason to refuse an install,
# and the operator may be mid-migration.
check_local_env_overrides() {
    local local_file="$ENV_FILE.local" value effective_addr effective_port
    [[ -r $local_file ]] || return 0

    if value=$(env_file_value "$local_file" LZC_EXPORTER_TEXTFILE); then
        log WARN "$local_file sets LZC_EXPORTER_TEXTFILE=$value. The exporter refuses to start"
        log WARN "(usage error, exit 2) when that is set without --textfile, so an environment"
        log WARN "file cannot turn this service into a one-shot. Unset it, or write a separate"
        log WARN "Type=oneshot unit and timer that passes --textfile explicitly."
    fi

    if value=$(env_file_value "$local_file" LZC_EXPORTER_BIND); then
        if address_is_loopback "$LISTEN_ADDRESS" && ! address_is_loopback "$value"; then
            log WARN "$local_file sets LZC_EXPORTER_BIND=$value, but this unit is rendered for a"
            log WARN "loopback bind and carries IPAddressAllow=localhost. The exporter would listen"
            log WARN "on $value while systemd still dropped non-local traffic. Re-run this installer"
            log WARN "with --listen-address $value instead."
        fi
    fi

    if value=$(env_file_value "$local_file" LZC_EXPORTER_PORT); then
        if [[ $value =~ ^[0-9]+$ ]] && ((10#$value < 1024 && LISTEN_PORT >= 1024)); then
            log WARN "$local_file sets LZC_EXPORTER_PORT=$value, a privileged port, but this unit"
            log WARN "was rendered for an unprivileged one and so carries no CAP_NET_BIND_SERVICE."
            log WARN "The bind would fail with EACCES. Re-run this installer with --port $value instead."
        fi
    fi

    # Staying inside the class is still not free, and this is the case the two
    # checks above miss. The unit takes --bind/--port from the environment at
    # start time, but verify_service builds its URL from the install-time values,
    # so ANY difference -- 9105 to 9200 is enough -- aims the health check at an
    # endpoint nothing is listening on. The service comes up, answers on the port
    # the operator asked for, and the install still exits 1 having reported it
    # dead. Warn rather than resolve it here: an environment file is not the only
    # way to override the two (a `systemctl edit` drop-in does it as well), so
    # nothing short of asking systemd what it resolved could be relied upon.
    effective_addr=$(env_file_value "$local_file" LZC_EXPORTER_BIND) ||
        effective_addr=$LISTEN_ADDRESS
    effective_port=$(env_file_value "$local_file" LZC_EXPORTER_PORT) ||
        effective_port=$LISTEN_PORT
    if [[ $effective_addr != "$LISTEN_ADDRESS" || $effective_port != "$LISTEN_PORT" ]]; then
        log WARN "$local_file points the service at $effective_addr:$effective_port, but this run"
        log WARN "verifies $(metrics_url), which is where the install-time values point. The service"
        log WARN "can be perfectly healthy and this install still fail. Re-run with"
        log WARN "--listen-address $effective_addr --port $effective_port to move the whole install,"
        log WARN "or drop those two from $local_file."
    fi
}

# Device rules for the unit. Empty output means "no device access at all", which
# lets the caller use PrivateDevices=yes instead.
render_device_rules() {
    ((DISK_HEALTH || GPU_ENABLED)) || return 0
    printf 'DevicePolicy=closed\n'
    if ((DISK_HEALTH)); then
        printf 'DeviceAllow=block-sd rw\n'
        printf 'DeviceAllow=block-blkext rw\n'
        printf 'DeviceAllow=block-device-mapper r\n'
        printf 'DeviceAllow=char-nvme rw\n'
    fi
    if ((GPU_ENABLED)); then
        printf 'DeviceAllow=char-nvidia-frontend rw\n'
        printf 'DeviceAllow=char-nvidia-uvm rw\n'
    fi
}

render_unit_content() {
    local exec_python="$VENV_DIR/bin/python"
    local exec_script="$INSTALL_DIR/$PAYLOAD_NAME"
    local service_type='simple'
    # Type=exec waits for execve() to succeed, so a missing interpreter or an
    # unusable service account fails `systemctl start` instead of reporting
    # success and dying in restart backoff. It needs systemd 240+.
    ((SYSTEMD_VERSION >= 240)) && service_type='exec'

    printf '[Unit]\n'
    printf 'Description=Unified Prometheus host metrics exporter\n'
    printf 'Documentation=https://github.com/Lazarev-Cloud/Scripts\n'
    printf 'After=network-online.target\n'
    printf 'Wants=network-online.target\n'
    printf 'StartLimitIntervalSec=300\n'
    printf 'StartLimitBurst=5\n'
    printf '\n[Service]\n'
    printf 'Type=%s\n' "$service_type"

    if ((DISK_HEALTH)); then
        printf 'User=root\n'
    else
        printf 'User=%s\n' "$SERVICE_USER"
        printf 'Group=%s\n' "$SERVICE_GROUP"
    fi

    # Defaults first, then the environment file, so the file wins and the unit
    # still starts if somebody removes it.
    printf 'Environment=LZC_EXPORTER_BIND=%s\n' "$LISTEN_ADDRESS"
    printf 'Environment=LZC_EXPORTER_PORT=%s\n' "$LISTEN_PORT"
    printf 'EnvironmentFile=-%s\n' "$ENV_FILE"
    # A second, optional file that this installer never writes: operator settings
    # put here survive re-installs, whereas the managed file above is rendered
    # whole every time. Later files win, so it can also override the two values.
    printf 'EnvironmentFile=-%s.local\n' "$ENV_FILE"
    # Nothing here strips LZC_EXPORTER_TEXTFILE from the environment. The
    # exporter refuses to start (usage error, exit 2) when that variable is set
    # without --textfile, precisely so an environment file cannot turn a running
    # service into a one-shot. Unsetting it here would swallow that deliberate,
    # self-explaining refusal and silently ignore what the operator asked for.
    # A loud failure the operator can read beats a silent one they cannot.
    # check_local_env_overrides warns about it at install time as well.
    # shellcheck disable=SC2016 # ${LZC_EXPORTER_BIND}/${LZC_EXPORTER_PORT} must
    # reach the unit file literally: systemd expands them from EnvironmentFile at
    # start time, so an operator can change the bind address with a drop-in and a
    # restart instead of re-running this installer.
    printf 'ExecStart=%s %s --bind ${LZC_EXPORTER_BIND} --port ${LZC_EXPORTER_PORT}\n' \
        "$exec_python" "$exec_script"
    printf 'Restart=on-failure\n'
    printf 'RestartSec=5\n'
    # The exporter exits 130 when a signal stops it, which is the repository-wide
    # code for "interrupted" and is exactly how systemd stops it. Without this,
    # every `systemctl stop` would leave the unit in the failed state.
    printf 'SuccessExitStatus=130\n'
    if ((SYSTEMD_VERSION >= 254)); then
        printf 'RestartSteps=4\n'
        printf 'RestartMaxDelaySec=120\n'
    fi
    printf 'TimeoutStartSec=30\n'
    printf 'Nice=10\n'

    printf '\n# --- sandboxing ---\n'
    printf 'NoNewPrivileges=yes\n'
    if ((DISK_HEALTH)); then
        # smartctl issues ATA_12/ATA_16 SCSI passthrough commands; upstream
        # smartctl_exporter states plainly that the disk group is not enough and
        # root is required. Hardening here buys containment, not privilege
        # reduction -- say so rather than pretending otherwise.
        #
        # The bounding set caps root as well: systemd applies it before execve,
        # and a uid-0 process comes out of exec with exactly the capabilities
        # left in it. So a privileged port needs CAP_NET_BIND_SERVICE listed
        # here too -- running as root does not grant it back. Without it,
        # `--disk-health --port 80` binds nothing, fails with EACCES and
        # crash-loops under Restart=on-failure.
        local caps='CAP_SYS_RAWIO CAP_SYS_ADMIN CAP_DAC_OVERRIDE'
        if ((LISTEN_PORT < 1024)); then
            caps+=' CAP_NET_BIND_SERVICE'
        fi
        printf 'CapabilityBoundingSet=%s\n' "$caps"
        printf 'SystemCallFilter=@system-service @raw-io\n'
    elif ((LISTEN_PORT < 1024)); then
        # A privileged port is an explicit operator choice, so grant exactly the
        # one capability that makes it work and nothing else.
        printf 'CapabilityBoundingSet=CAP_NET_BIND_SERVICE\n'
        printf 'AmbientCapabilities=CAP_NET_BIND_SERVICE\n'
        printf 'SystemCallFilter=@system-service\n'
    else
        printf 'CapabilityBoundingSet=\n'
        printf 'AmbientCapabilities=\n'
        printf 'SystemCallFilter=@system-service\n'
    fi
    printf 'SystemCallErrorNumber=EPERM\n'
    printf 'SystemCallArchitectures=native\n'
    printf 'ProtectSystem=strict\n'
    # read-only, not yes: ProtectHome=yes replaces /home with an empty tmpfs, and
    # a host with /home on its own filesystem would then lose that series.
    printf 'ProtectHome=read-only\n'
    printf 'PrivateTmp=yes\n'
    printf 'ProtectKernelTunables=yes\n'
    printf 'ProtectKernelModules=yes\n'
    printf 'ProtectKernelLogs=yes\n'
    printf 'ProtectControlGroups=yes\n'
    printf 'ProtectClock=yes\n'
    printf 'ProtectHostname=yes\n'
    # ProtectProc hides other users' processes. ProcSubset=pid is deliberately
    # NOT set: it would also hide /proc/stat, /proc/meminfo and /proc/net/dev,
    # which is everything the exporter reads.
    printf 'ProtectProc=invisible\n'
    printf 'RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX\n'
    printf 'RestrictNamespaces=yes\n'
    printf 'RestrictRealtime=yes\n'
    printf 'RestrictSUIDSGID=yes\n'
    printf 'LockPersonality=yes\n'
    printf 'UMask=0077\n'

    local device_rules
    device_rules=$(render_device_rules)
    if [[ -n $device_rules ]]; then
        printf '%s\n' "$device_rules"
    else
        # Nothing under /dev is needed, so give the service a minimal /dev.
        printf 'PrivateDevices=yes\n'
    fi

    if address_is_loopback "$LISTEN_ADDRESS"; then
        printf 'IPAddressDeny=any\n'
        printf 'IPAddressAllow=localhost\n'
    fi

    printf '\n[Install]\n'
    printf 'WantedBy=multi-user.target\n'
}

configure_service() {
    log STEP "Configuring systemd"

    local content
    content=$(render_env_content)
    render_file "$ENV_FILE" 0644 root:root "$content"
    ((FILE_CHANGED)) && NEEDS_RESTART=1

    content=$(render_unit_content)
    render_file "$UNIT_FILE" 0644 root:root "$content"
    local unit_changed=$FILE_CHANGED
    ((unit_changed)) && NEEDS_RESTART=1

    if ((unit_changed)); then
        run systemctl daemon-reload || die "systemctl daemon-reload failed"
    fi

    if ((!DRY_RUN)) && have systemd-analyze; then
        if ! timeout 60 systemd-analyze verify "$UNIT_FILE" 2>&1; then
            log WARN "systemd-analyze verify reported problems with $UNIT_FILE (see above)"
        fi
    fi

    run timeout "$SYSTEMCTL_TIMEOUT" systemctl enable "$SERVICE_NAME" ||
        die "Could not enable $SERVICE_NAME"

    if ((DRY_RUN)); then
        log DRYRUN "would start (or restart) $SERVICE_NAME"
        return 0
    fi

    if ((NEEDS_RESTART)); then
        log INFO "Restarting $SERVICE_NAME (configuration or payload changed)"
        timeout "$SYSTEMCTL_TIMEOUT" systemctl restart "$SERVICE_NAME" ||
            die "Could not restart $SERVICE_NAME"
    elif ! systemctl is-active --quiet "$SERVICE_NAME"; then
        log INFO "Starting $SERVICE_NAME"
        timeout "$SYSTEMCTL_TIMEOUT" systemctl start "$SERVICE_NAME" ||
            die "Could not start $SERVICE_NAME"
    else
        log INFO "$SERVICE_NAME is already running with the current configuration"
    fi
}

# --- Verification ------------------------------------------------------------

metrics_url() {
    local addr=$LISTEN_ADDRESS
    case $addr in
        0.0.0.0 | '') addr=127.0.0.1 ;;
        '::' | '[::]') addr='[::1]' ;;
        \[*\]) ;;
        *:*) addr="[$addr]" ;;
    esac
    printf 'http://%s:%s/metrics' "$addr" "$LISTEN_PORT"
}

fetch_metrics() {
    local url=$1
    if have curl; then
        timeout "$HEALTH_TIMEOUT" curl --fail --silent --show-error \
            --max-time "$HEALTH_TIMEOUT" -o /dev/null "$url" >/dev/null 2>&1
        return
    fi
    timeout "$HEALTH_TIMEOUT" "$VENV_PYTHON" -c \
        'import sys, urllib.request; urllib.request.urlopen(sys.argv[1], timeout=5).read()' \
        "$url" >/dev/null 2>&1
}

# Runs the exporter in the foreground so its traceback reaches the operator
# instead of a bare "unit failed". Only ever called after the service failed.
diagnose_failure() {
    if have journalctl; then
        log ERROR "Recent journal for $SERVICE_NAME:"
        timeout 30 journalctl -u "$SERVICE_NAME" --no-pager -n 30 >&2 ||
            log WARN "Could not read the journal"
    fi
    log ERROR "Running the exporter directly to capture the underlying error:"
    # -u LZC_EXPORTER_TEXTFILE: the exporter refuses to start (exit 2) when that
    # variable is set without --textfile. This diagnostic inherits the
    # installer's environment, not the unit's, so an operator who exported it
    # would get that usage error here instead of the traceback they came for --
    # a misleading diagnosis at the exact moment the real one matters.
    timeout 30 env -u LZC_EXPORTER_TEXTFILE \
        "$VENV_PYTHON" "$INSTALL_DIR/$PAYLOAD_NAME" --once >/dev/null ||
        log ERROR "The exporter itself failed to run (output above)"
}

verify_service() {
    if ((DRY_RUN)); then
        log DRYRUN "would verify that $SERVICE_NAME is active and serving $(metrics_url)"
        return 0
    fi

    log STEP "Verifying"

    if ! systemctl is-active --quiet "$SERVICE_NAME"; then
        diagnose_failure
        die "$SERVICE_NAME is not active. See 'journalctl -u $SERVICE_NAME'."
    fi
    log SUCCESS "$SERVICE_NAME is active"

    local url attempt
    url=$(metrics_url)
    for ((attempt = 1; attempt <= HEALTH_RETRIES; attempt++)); do
        if fetch_metrics "$url"; then
            log SUCCESS "Serving metrics at $url"
            return 0
        fi
        sleep 1
    done

    diagnose_failure
    die "$SERVICE_NAME is active but $url did not answer in $HEALTH_RETRIES attempts (${HEALTH_TIMEOUT}s each, one second apart)."
}

# --- Uninstall ---------------------------------------------------------------

remove_service_account() {
    id -u "$SERVICE_USER" >/dev/null 2>&1 || return 0

    local uid
    uid=$(id -u "$SERVICE_USER" 2>/dev/null) || return 0
    if ((uid == 0)) || ((uid >= 1000)); then
        log WARN "Not removing '$SERVICE_USER' (uid $uid): it does not look like a system account this script created"
        return 0
    fi

    have userdel || {
        log WARN "userdel not found; leaving the account '$SERVICE_USER' in place"
        return 0
    }

    # Never `userdel -r`: a misconfigured home directory would take a real
    # directory with it. The account is created with no home anyway.
    #
    # Returned before the call rather than left to `run`: `run` reports success
    # in --dry-run, and the branch below would then print "[OK] Removed the
    # account" for an account nothing touched. render_file returns early for the
    # same reason.
    if ((DRY_RUN)); then
        log DRYRUN "would remove the account $SERVICE_USER (userdel $SERVICE_USER)"
        return 0
    fi
    if run userdel "$SERVICE_USER"; then
        log SUCCESS "Removed the account $SERVICE_USER"
    else
        log WARN "userdel refused to remove '$SERVICE_USER'; leaving it in place"
    fi
}

do_uninstall() {
    log STEP "Uninstalling $SERVICE_NAME"
    log INFO "This removes: $UNIT_FILE, $ENV_FILE, $INSTALL_DIR (recursively) and the account $SERVICE_USER."
    log INFO "It does not remove distribution packages."

    if ((!DRY_RUN)); then
        local answer=0
        # `|| answer=$?` rather than a bare call: under `set -e` a non-zero
        # return from a plain statement would abort before the case is reached.
        confirm "Remove $SERVICE_NAME and everything listed above?" || answer=$?
        case $answer in
            0) ;;
            1)
                log INFO "Cancelled; nothing was removed"
                return 0
                ;;
            *)
                die_with "$EX_NOCONFIRM" \
                    "Refusing to uninstall without confirmation. Pass --yes (or LZC_EXPORTER_YES=1) for unattended removal."
                ;;
        esac
    fi

    if systemctl list-unit-files "$SERVICE_NAME.service" >/dev/null 2>&1; then
        run timeout "$SYSTEMCTL_TIMEOUT" systemctl disable --now "$SERVICE_NAME" ||
            log WARN "Could not disable $SERVICE_NAME (it may already be gone)"
    fi

    if [[ -f $UNIT_FILE ]]; then
        run rm -f -- "$UNIT_FILE" || log WARN "Could not remove $UNIT_FILE"
    fi
    run systemctl daemon-reload || log WARN "systemctl daemon-reload failed"
    # reset-failed exits non-zero when the unit was never in a failed state,
    # which is the normal case and not an error worth reporting.
    run systemctl reset-failed "$SERVICE_NAME" 2>/dev/null ||
        log INFO "No failed state to reset for $SERVICE_NAME"

    if [[ -f $ENV_FILE ]]; then
        run rm -f -- "$ENV_FILE" || log WARN "Could not remove $ENV_FILE"
    fi
    # Operator-authored, never installed by this script, so never removed by it.
    if [[ -f "$ENV_FILE.local" ]]; then
        log INFO "Left in place (yours, not ours): $ENV_FILE.local"
    fi

    if [[ -d $INSTALL_DIR ]]; then
        # assert_safe_prefix already refused '/', system directories and
        # single-level paths; :? is the last line of defence against an empty
        # expansion here.
        run rm -rf -- "${INSTALL_DIR:?}" || die "Could not remove $INSTALL_DIR"
    fi

    remove_service_account

    log SUCCESS "Uninstalled $SERVICE_NAME"
}

# --- Traps -------------------------------------------------------------------

on_exit() {
    local rc=$?
    trap - EXIT INT TERM HUP ERR
    [[ -n $TMP_DIR && -d $TMP_DIR ]] && rm -rf -- "${TMP_DIR:?}"
    [[ -n $LOCK_FD ]] && exec {LOCK_FD}>&-
    exit "$rc"
}

on_err() {
    local line=$1 cmd=$2 rc=$3
    log ERROR "Failed at line $line: '$cmd' (status $rc)"
    exit "$rc"
}

on_signal() {
    log WARN "Interrupted"
    exit "$EX_INTERRUPT"
}

# --- Main --------------------------------------------------------------------

show_plan() {
    log STEP "Plan"
    printf '  action           : %s\n' "$ACTION"
    printf '  install prefix   : %s\n' "$INSTALL_DIR"
    printf '  payload          : %s\n' "$PAYLOAD_FILE"
    printf '  service unit     : %s\n' "$UNIT_FILE"
    printf '  environment file : %s\n' "$ENV_FILE"
    printf '  runs as          : %s\n' "$( ((DISK_HEALTH)) && printf 'root (--disk-health)' || printf '%s' "$SERVICE_USER")"
    printf '  binds to         : %s:%s\n' "$LISTEN_ADDRESS" "$LISTEN_PORT"
    printf '  verified via     : %s\n' "$(metrics_url)"
    printf '  systemd          : %s\n' "$SYSTEMD_VERSION"
    printf '  gpu metrics      : %s\n' "$( ((GPU_ENABLED)) && printf 'enabled' || printf 'disabled')"
    printf '  disk temperatures: %s\n' "$( ((DISK_HEALTH)) && printf 'enabled' || printf 'disabled')"
}

do_install() {
    log STEP "Checking the host"
    report_hardware
    check_local_env_overrides
    ensure_system_packages
    locate_payload
    show_plan

    if ((!DRY_RUN)) && ! ((ASSUME_YES)) && is_interactive; then
        confirm "Proceed with the installation?" || {
            log INFO "Cancelled"
            return 0
        }
    fi

    ensure_service_account
    install_tree
    ensure_venv
    fix_permissions
    configure_service
    verify_service

    log STEP "Done"
    log INFO "Scrape target : $LISTEN_ADDRESS:$LISTEN_PORT (checked at $(metrics_url))"
    log INFO "Service status: systemctl status $SERVICE_NAME"
    log INFO "Logs          : journalctl -u $SERVICE_NAME -f"
    log INFO "Remove it     : $0 --uninstall --yes"
}

main() {
    ORIGINAL_ARGS=("$@")
    parse_args "$@"
    setup_color
    validate_args

    trap 'on_err "$LINENO" "$BASH_COMMAND" "$?"' ERR
    trap on_exit EXIT
    trap on_signal INT TERM
    # An install interrupted mid-dpkg by a dropped SSH session leaves the package
    # database half-configured. Ignoring HUP is inherited across execve(), so the
    # package manager ignores it too.
    trap '' HUP

    # The venv is built by root and read by an unprivileged account.
    umask 022

    SCRIPT_DIR=$(resolve_script_dir)
    preflight_common
    acquire_lock

    TMP_DIR=$(mktemp -d) || die "Cannot create a temporary directory"

    if [[ $ACTION == uninstall ]]; then
        do_uninstall
        return "$EX_OK"
    fi

    do_install
    return "$EX_OK"
}

main "$@"
