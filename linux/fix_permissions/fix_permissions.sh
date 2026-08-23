#!/usr/bin/env bash
#
# Home directory ownership and permission repair.
#
# Gives one user back ownership of their home directory and clears
# group/other-writable bits, without flattening executable bits, setgid
# directories or anything outside that home. Credential directories (.ssh,
# .gnupg by default) are locked to 0700/0600 so SSH and GnuPG keep working.
# Reports first; changes nothing until asked.
#
# License: MIT
# Origin:  https://github.com/Lazarev-Cloud/Scripts
#
# Error model: this script deliberately does NOT use `set -e`. The scan phase
# checks every fallible step explicitly and refuses to apply anything derived
# from an incomplete scan; the apply phase has to survive individual chown/chmod
# failures (immutable files, live races) and report them, which `set -e` would
# turn into a silent half-finished run. Do not add `set -e`, and do not call
# this script as `fix_permissions.sh || true` -- both move the error handling
# somewhere it cannot see what failed.
set -uo pipefail

readonly SCRIPT_NAME='Home Permission Repair'
readonly SCRIPT_VERSION='2.1'

# Exit codes, shared by every script in this repository. 75 is EX_TEMPFAIL from
# sysexits.h, which cron and systemd read as "retry later" rather than a fault.
readonly EX_FAIL=1 EX_USAGE=2 EX_PREREQ=3 EX_NOROOT=4
readonly EX_NOCONFIRM=5 EX_LOCKED=75 EX_INTERRUPT=130

# --- Tunables (env overridable, then flag overridable) -----------------------
TARGET_USER="${LZC_FIX_PERMISSIONS_USER:-}"
TARGET_GROUP="${LZC_FIX_PERMISSIONS_GROUP:-}"
TARGET_HOME="${LZC_FIX_PERMISSIONS_HOME:-}"
PRIVATE_SPEC="${LZC_FIX_PERMISSIONS_PRIVATE_DIRS:-.ssh,.gnupg}"
EXCLUDE_SPEC="${LZC_FIX_PERMISSIONS_EXCLUDE:-}"
SCAN_TIMEOUT="${LZC_FIX_PERMISSIONS_SCAN_TIMEOUT:-600}"
APPLY_TIMEOUT="${LZC_FIX_PERMISSIONS_APPLY_TIMEOUT:-1800}"
BACKUP_TIMEOUT="${LZC_FIX_PERMISSIONS_BACKUP_TIMEOUT:-600}"
BACKUP_DIR="${LZC_FIX_PERMISSIONS_BACKUP_DIR:-/var/backups/fix-permissions}"
LOCK_FILE="${LZC_FIX_PERMISSIONS_LOCK:-/run/lock/lzc-fix_permissions.lock}"
MAX_LIST="${LZC_FIX_PERMISSIONS_MAX_LIST:-20}"
ASSUME_YES="${LZC_FIX_PERMISSIONS_YES:-0}"
STRICT="${LZC_FIX_PERMISSIONS_STRICT:-0}"
DO_CHOWN="${LZC_FIX_PERMISSIONS_CHOWN:-1}"
DO_CHMOD="${LZC_FIX_PERMISSIONS_CHMOD:-1}"
DO_BACKUP="${LZC_FIX_PERMISSIONS_BACKUP:-1}"
CROSS_FS="${LZC_FIX_PERMISSIONS_CROSS_FILESYSTEMS:-0}"
APPLY="${LZC_FIX_PERMISSIONS_APPLY:-0}"
USE_COLOR="${LZC_FIX_PERMISSIONS_COLOR:-auto}"
FORCE_DRY_RUN=0

# Canonical absolute paths that are never a home directory, whatever /etc/passwd
# or --home claims. `/` is rejected separately.
#
# Two lists, because "is the operating system" and "contains home directories"
# need opposite rules. A single exact-match list gets this wrong in the dangerous
# direction: it refuses /usr but accepts /usr/lib, so one --home typo aims a
# recursive chown at 25,000 system files.
#
# FORBIDDEN_TREES: the directory itself AND everything beneath it. These hold the
# operating system; nothing inside one is somebody's home.
readonly FORBIDDEN_TREES=(
    /bin /boot /dev /etc /lib /lib32 /lib64 /libx32 /proc /sbin /sys /usr
    /var/backups /var/cache /var/log /var/spool /var/tmp
)

# FORBIDDEN_ROOTS: the directory itself ONLY. Each of these legitimately holds
# home directories one level down, so the container is refused while its
# children stay usable. /var/lib is here rather than in the tree list because
# service accounts really do live under it -- postgres at /var/lib/postgresql,
# jenkins at /var/lib/jenkins -- and /var itself stays a root only so that
# www-data's /var/www keeps working.
# /root is deliberately absent from both: it is root's real home, and refusing
# it would make the script useless for the one account most likely to need it.
readonly FORBIDDEN_ROOTS=(
    /home /media /mnt /opt /run /srv /tmp /var
    /var/lib /var/local /var/mail /var/opt
    /nonexistent /var/empty
)

# --- Runtime state -----------------------------------------------------------
declare -a PRIVATE_DIRS=()
declare -a EXCLUDES=()
declare -a SAMPLE_OWN=()
declare -a SAMPLE_MODE=()
declare -a SAMPLE_REFUSED=()
FD_OWN='' FD_DIRS='' FD_FILES='' FD_PDIRS='' FD_PFILES='' FD_SNAP=''
TARGET_UID=''
TARGET_GID=''
HOME_DIR=''
WORK_DIR=''
BACKUP_FILE=''
DESIRED=0
COUNT_SCANNED=0
COUNT_CHOWN=0
COUNT_CHMOD=0
COUNT_SYMLINK=0
COUNT_OTHER=0
COUNT_SETID=0
COUNT_REFUSED=0
COUNT_UNREADABLE=0
# Paths that turned into symlinks between the scan and the apply. Not a failure
# -- nothing was changed and nothing was missed that should have been changed --
# but it is reported, because it means the tree moved under the run.
COUNT_RACED=0
FAILURES=0
YW='' BL='' RD='' GN='' CL=''

# --- Output ------------------------------------------------------------------

setup_color() {
    # NO_COLOR is honoured per no-color.org: any non-empty value disables colour.
    # It is checked inside the `auto` branch only, so --color always still wins.
    if [[ $USE_COLOR == never ]] ||
        { [[ $USE_COLOR == auto ]] && { [[ -n ${NO_COLOR:-} ]] || [[ ! -t 1 ]]; }; }; then
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

Repairs ownership and permissions inside a single user's home directory.

Usage:
  fix_permissions.sh [options]

BLAST RADIUS
  Every file, directory, symlink and socket beneath one home directory is
  chown'ed to that user and has its group/other write bits cleared. On a large
  home that is tens of thousands of inodes. There is no undo built into the
  filesystem, so by default an ownership+mode snapshot of every path this run
  is about to change is written with getfacl first (see --backup-dir); restore
  it with \`setfacl --restore=FILE\`. Symlinks are not in the snapshot, so the
  chown -h applied to them is not reversed by a restore.

  What this does NOT do, on purpose:
    * never chmod 777, and never adds a group or other permission bit that the
      path did not already have -- the only bits it sets are the owner's
    * never strips the executable bit from files (your ~/bin keeps working)
    * never follows a symlink: links have their own ownership fixed with
      chown -h and are never chmod'ed, so a link pointing at /etc/shadow
      cannot be used to redirect this script out of the home directory
    * never touches /, a system directory, or anything inside one, whatever
      /etc/passwd says -- and refuses the directories that merely hold homes
      (/home, /srv, /var) so a missing user name cannot widen the target
    * never crosses a filesystem boundary unless asked

Options:
      --apply               Make the changes. Prompts when interactive.
  -y, --yes                 Make the changes without prompting. Implies --apply
                            and is the only way to run this from cron.
  -n, --dry-run             Report only. This is the default, and it wins if
                            combined with --apply or --yes.
  -u, --user NAME           User whose home to repair. Default: the invoking
                            user (\$SUDO_USER under sudo), currently '${TARGET_USER:-$(default_user)}'.
  -g, --group NAME          Group to set. Default: the user's primary group.
      --home PATH           Repair this directory instead of the passwd home.
      --strict              Also remove all group and other access (0700/0600
                            everywhere), not just the write bits.
      --private DIRS        Comma-separated dirs, relative to the home, locked
                            to 0700 dirs / 0600 files (default: $PRIVATE_SPEC).
      --exclude GLOB        Skip this subtree. Matched against the whole path
                            below the home, and '*' crosses '/', so
                            --exclude .cache prunes ~/.cache, while
                            --exclude '*/node_modules' prunes every one below a
                            subdirectory but NOT ~/node_modules itself. Pass
                            both forms to catch both. Repeatable.
      --cross-filesystems   Descend into mounted filesystems (default: no).
      --no-chown            Fix modes only, leave ownership alone.
      --no-chmod            Fix ownership only, leave modes alone.
      --no-backup           Skip the getfacl snapshot and accept that the run
                            cannot be undone. Without this, a host with no
                            getfacl refuses to apply (exit 3) rather than make
                            thousands of irreversible changes unrecorded.
      --backup-dir PATH     Where to write the snapshot (default: $BACKUP_DIR).
      --timeout SECONDS     Bounds the scan of the home directory: the single
                            find(1) walk that builds the plan (default: $SCAN_TIMEOUT).
      --apply-timeout SEC   Bounds each chown/chmod batch on its own, not the
                            apply phase as a whole (default: $APPLY_TIMEOUT).
      --backup-timeout SEC  Bounds the getfacl snapshot of the change set
                            (default: $BACKUP_TIMEOUT). All three are seconds and
                            must be at least 1: 'timeout 0' means no limit,
                            which would remove the protection entirely.
      --max-list N          Example paths to print per category (default: $MAX_LIST).
      --lock-file PATH      Concurrency lock (default: $LOCK_FILE).
      --color WHEN          auto | always | never (default: auto).
  -V, --version             Print version and exit.
  -h, --help                Print this help and exit.

Colour is used only when stdout is a terminal, and NO_COLOR (any non-empty
value, see no-color.org) turns it off; --color always overrides both.

An --apply run takes an exclusive flock on the lock file and exits 75 if another
run holds it. A dry run takes no lock, so it still works as an unprivileged user.

Every option has an environment variable, which is the easier route when this
script is piped in from the network. Boolean variables accept 1/true/yes/on and
0/false/no/off, in any case:
  LZC_FIX_PERMISSIONS_USER=alice  LZC_FIX_PERMISSIONS_YES=1
  LZC_FIX_PERMISSIONS_APPLY=1  LZC_FIX_PERMISSIONS_STRICT=1
  LZC_FIX_PERMISSIONS_HOME=/srv/alice  LZC_FIX_PERMISSIONS_GROUP=alice
  LZC_FIX_PERMISSIONS_PRIVATE_DIRS=.ssh,.gnupg,.aws,.kube
  LZC_FIX_PERMISSIONS_EXCLUDE=.cache  LZC_FIX_PERMISSIONS_CROSS_FILESYSTEMS=1
  LZC_FIX_PERMISSIONS_CHOWN=0  LZC_FIX_PERMISSIONS_CHMOD=0
  LZC_FIX_PERMISSIONS_BACKUP=0
  LZC_FIX_PERMISSIONS_BACKUP_DIR=/var/backups/fix-permissions
  LZC_FIX_PERMISSIONS_SCAN_TIMEOUT=600  LZC_FIX_PERMISSIONS_APPLY_TIMEOUT=1800
  LZC_FIX_PERMISSIONS_BACKUP_TIMEOUT=600  LZC_FIX_PERMISSIONS_MAX_LIST=20
  LZC_FIX_PERMISSIONS_LOCK=$LOCK_FILE  LZC_FIX_PERMISSIONS_COLOR=never

LZC_FIX_PERMISSIONS_YES only suppresses the prompt: unlike the -y flag it does
not imply --apply, so a stray value in an environment file cannot turn a dry run
destructive. Pair it with LZC_FIX_PERMISSIONS_APPLY=1.

What gets set:
  home and normal directories   owner rwx, group/other write cleared
                                (setgid and sticky bits preserved)
  normal files                  owner rw, group/other write cleared,
                                setuid/setgid cleared, execute bits untouched
  $PRIVATE_SPEC directories       0700
  files inside them             0600
  symlinks                      ownership only
  sockets, fifos, devices       ownership only

  With --strict, "group/other write cleared" becomes "group/other access
  removed entirely". SSH also requires that the home directory itself is not
  group- or other-writable, which the default rule already guarantees.

Requires root to change ownership. A dry run works as any user, but only
reports on the paths that user can actually see.

Exit status:
  0    nothing to change, dry run finished, or every change applied
  1    the work ran but something in it failed: a change could not be applied,
       the scan timed out, or the snapshot could not be written
  2    usage error: unknown flag, missing value, or an invalid one -- which
       includes an unknown user or group, and a home directory that is /, is a
       system directory, is inside one, or is a directory that merely holds
       home directories
  3    a required tool is missing (GNU find, timeout, xargs, flock, or getfacl
       when a snapshot was not waived with --no-backup)
  4    must be run as root (changing ownership does; --no-chown does not)
  5    changes are pending but there is no terminal to confirm at and no --yes
  75   another instance holds the lock; try again later
  130  interrupted
EOF
}

# --- Argument parsing --------------------------------------------------------

need_value() {
    (($1 >= 2)) || die "$EX_USAGE" "$2 requires a value (try --help)"
}

parse_args() {
    while (($#)); do
        case $1 in
            --apply) APPLY=1 ;;
            -y | --yes)
                APPLY=1
                ASSUME_YES=1
                ;;
            -n | --dry-run) FORCE_DRY_RUN=1 ;;
            -u | --user)
                need_value $# "$1"
                TARGET_USER=$2
                shift
                ;;
            -g | --group)
                need_value $# "$1"
                TARGET_GROUP=$2
                shift
                ;;
            --home)
                need_value $# "$1"
                TARGET_HOME=$2
                shift
                ;;
            --strict) STRICT=1 ;;
            --private)
                need_value $# "$1"
                PRIVATE_SPEC=$2
                shift
                ;;
            --exclude)
                need_value $# "$1"
                EXCLUDE_SPEC="${EXCLUDE_SPEC:+$EXCLUDE_SPEC,}$2"
                shift
                ;;
            --cross-filesystems) CROSS_FS=1 ;;
            --no-chown) DO_CHOWN=0 ;;
            --no-chmod) DO_CHMOD=0 ;;
            --no-backup) DO_BACKUP=0 ;;
            --backup-dir)
                need_value $# "$1"
                BACKUP_DIR=$2
                shift
                ;;
            --timeout)
                need_value $# "$1"
                SCAN_TIMEOUT=$2
                shift
                ;;
            --apply-timeout)
                need_value $# "$1"
                APPLY_TIMEOUT=$2
                shift
                ;;
            --backup-timeout)
                need_value $# "$1"
                BACKUP_TIMEOUT=$2
                shift
                ;;
            --max-list)
                need_value $# "$1"
                MAX_LIST=$2
                shift
                ;;
            --lock-file)
                need_value $# "$1"
                LOCK_FILE=$2
                shift
                ;;
            --color)
                need_value $# "$1"
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
    for name in ASSUME_YES STRICT DO_CHOWN DO_CHMOD DO_BACKUP CROSS_FS APPLY; do
        _normalise_bool "$name"
    done

    # Minimum 1, not 0: `timeout 0` means "no limit", so accepting 0 here would
    # silently remove the very protection these options exist to provide.
    for name in SCAN_TIMEOUT APPLY_TIMEOUT BACKUP_TIMEOUT; do
        _normalise_int "$name" 1
    done
    # 0 is meaningful here: it prints the counts with no example paths.
    _normalise_int MAX_LIST 0

    # After normalisation, so a bad boolean is still reported rather than
    # overwritten. -n wins over --apply and --yes, which is the documented
    # precedence and the reason it is safe to put both in a cron line.
    ((FORCE_DRY_RUN)) && APPLY=0

    ((DO_CHOWN || DO_CHMOD)) || die "$EX_USAGE" "--no-chown and --no-chmod together leave nothing to do"

    split_spec PRIVATE_DIRS "$PRIVATE_SPEC"
    split_spec EXCLUDES "$EXCLUDE_SPEC"

    local item
    for item in ${PRIVATE_DIRS[@]+"${PRIVATE_DIRS[@]}"}; do
        [[ $item == /* ]] && die "$EX_USAGE" "--private entries are relative to the home directory: '$item'"
        [[ $item == *..* ]] && die "$EX_USAGE" "--private entries may not contain '..': '$item'"
    done
    for item in ${EXCLUDES[@]+"${EXCLUDES[@]}"}; do
        [[ $item == /* ]] && die "$EX_USAGE" "--exclude globs are relative to the home directory: '$item'"
    done
    return 0
}

# Accepts the spellings people actually write in cron files and unit files.
# Without this, LZC_FIX_PERMISSIONS_YES=true reaches (( )) as a bare word and the
# script dies with "true: unbound variable" before doing anything.
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

# Splits a comma/space separated list into the named array, dropping blanks.
split_spec() {
    local -n out=$1
    local spec=$2 token
    out=()
    [[ -n $spec ]] || return 0
    local raw
    IFS=', ' read -r -a raw <<<"$spec"
    for token in ${raw[@]+"${raw[@]}"}; do
        [[ -n $token ]] && out+=("$token")
    done
    return 0
}

# --- Target resolution -------------------------------------------------------

# Under sudo, $USER is root on most distros (env_reset + set_logname), so the
# obvious `$USER` default silently retargets /home/root. $SUDO_USER is the
# invoking human; fall back to the real user id only when not under sudo.
default_user() {
    if [[ -n ${SUDO_USER:-} ]]; then
        printf '%s' "$SUDO_USER"
        return 0
    fi
    id -un 2>/dev/null
}

# name:passwd:uid:gid:gecos:home:shell, from getent when it exists so NSS
# (LDAP, SSSD, systemd-homed) is consulted, from /etc/passwd otherwise.
passwd_entry() {
    local user=$1 entry=''
    if command -v getent >/dev/null 2>&1; then
        entry=$(getent passwd "$user" 2>/dev/null)
    fi
    if [[ -z $entry && -r /etc/passwd ]]; then
        entry=$(awk -F: -v u="$user" '$1 == u { print; exit }' /etc/passwd 2>/dev/null)
    fi
    [[ -n $entry ]] || return 1
    printf '%s' "$entry"
}

group_gid() {
    local group=$1
    if [[ $group =~ ^[0-9]+$ ]]; then
        printf '%s' "$group"
        return 0
    fi
    local entry=''
    if command -v getent >/dev/null 2>&1; then
        entry=$(getent group "$group" 2>/dev/null)
    fi
    if [[ -z $entry && -r /etc/group ]]; then
        entry=$(awk -F: -v g="$group" '$1 == g { print; exit }' /etc/group 2>/dev/null)
    fi
    [[ -n $entry ]] || return 1
    printf '%s' "$(cut -d: -f3 <<<"$entry")"
}

# A string prefix test is not enough: `--home /home/x/../..` and a symlinked
# home both defeat it. Everything below runs against the canonical path.
canonicalize() {
    local path=$1 resolved=''
    if command -v readlink >/dev/null 2>&1; then
        resolved=$(readlink -f -- "$path" 2>/dev/null)
    fi
    if [[ -z $resolved ]] && command -v realpath >/dev/null 2>&1; then
        resolved=$(realpath -- "$path" 2>/dev/null)
    fi
    [[ -n $resolved ]] || resolved=$path
    printf '%s' "$resolved"
}

# Runs against the canonicalised path, so `--home /home/x/../..` and a symlinked
# home cannot slip past a prefix test.
refuse_unsafe_home() {
    local path=$1 entry

    [[ -n $path ]] || die "$EX_USAGE" "No home directory to work on."
    [[ $path == /* ]] || die "$EX_USAGE" "Home directory must be an absolute path, got '$path'"
    [[ $path == / ]] && die "$EX_USAGE" "Refusing to operate on / -- that is the entire filesystem, not a home directory."

    for entry in "${FORBIDDEN_TREES[@]}"; do
        [[ $path == "$entry" || $path == "$entry"/* ]] &&
            die "$EX_USAGE" "Refusing to operate on '$path': it is inside the system directory '$entry'."
    done

    for entry in "${FORBIDDEN_ROOTS[@]}"; do
        [[ $path == "$entry" ]] &&
            die "$EX_USAGE" "Refusing to operate on '$path': it holds home directories, it is not one. Point --home at the home itself."
    done

    [[ -d $path ]] || die "$EX_USAGE" "'$path' is not a directory."
    return 0
}

resolve_target() {
    [[ -n $TARGET_USER ]] || TARGET_USER=$(default_user)
    [[ -n $TARGET_USER ]] || die "$EX_USAGE" "Cannot determine which user to work on; pass --user."

    local entry passwd_home=''
    if entry=$(passwd_entry "$TARGET_USER"); then
        TARGET_UID=$(cut -d: -f3 <<<"$entry")
        TARGET_GID=$(cut -d: -f4 <<<"$entry")
        passwd_home=$(cut -d: -f6 <<<"$entry")
    else
        die "$EX_USAGE" "No such user: '$TARGET_USER'. Nothing was changed."
    fi

    [[ $TARGET_UID =~ ^[0-9]+$ ]] || die "$EX_USAGE" "User '$TARGET_USER' has an unreadable uid."
    [[ $TARGET_GID =~ ^[0-9]+$ ]] || die "$EX_USAGE" "User '$TARGET_USER' has an unreadable gid."

    if [[ -n $TARGET_GROUP ]]; then
        local gid
        gid=$(group_gid "$TARGET_GROUP") ||
            die "$EX_USAGE" "No such group: '$TARGET_GROUP'."
        [[ $gid =~ ^[0-9]+$ ]] || die "$EX_USAGE" "Group '$TARGET_GROUP' has an unreadable gid."
        TARGET_GID=$gid
    fi

    local requested=${TARGET_HOME:-$passwd_home}
    [[ -n $requested ]] ||
        die "$EX_USAGE" "User '$TARGET_USER' has no home directory in passwd; pass --home."

    HOME_DIR=$(canonicalize "$requested")
    refuse_unsafe_home "$HOME_DIR"

    if [[ $HOME_DIR != "$requested" ]]; then
        log INFO "Home '$requested' resolves to '$HOME_DIR'"
    fi
    if [[ -n $TARGET_HOME && -n $passwd_home && $HOME_DIR != "$(canonicalize "$passwd_home")" ]]; then
        log WARN "--home '$HOME_DIR' is not $TARGET_USER's passwd home ($passwd_home)"
    fi
    return 0
}

preflight() {
    # Checked before the tools: "run me with sudo" is the more useful message
    # when both apply, and this is the only privilege this script needs.
    if ((APPLY && DO_CHOWN)) && [[ $EUID -ne 0 ]]; then
        die "$EX_NOROOT" "Changing ownership needs root. Re-run with sudo, or pass --no-chown."
    fi

    command -v find >/dev/null 2>&1 || die "$EX_PREREQ" "find (findutils) not found."
    command -v timeout >/dev/null 2>&1 || die "$EX_PREREQ" "timeout (coreutils) not found."
    command -v xargs >/dev/null 2>&1 || die "$EX_PREREQ" "xargs (findutils) not found."

    # -printf is a GNU extension. Everything downstream parses its output, so
    # probe for it rather than producing garbage on busybox or BSD find.
    find "$HOME_DIR" -maxdepth 0 -printf '' >/dev/null 2>&1 ||
        die "$EX_PREREQ" "This script needs GNU find (-printf); the find on PATH does not support it."

    # Only an --apply run locks, so a dry run does not need util-linux either.
    ((APPLY)) && { command -v flock >/dev/null 2>&1 ||
        die "$EX_PREREQ" "flock (util-linux) not found; it is required to apply changes."; }

    # Checked here rather than at the point of use so an --apply run that cannot
    # record an undo point fails before it scans and before it prompts, instead
    # of after the operator has already confirmed. Refusing is the deliberate
    # choice: the alternative is applying tens of thousands of irreversible
    # changes with nothing recorded, on exactly the minimal hosts where a
    # warning is least likely to be read. --no-backup still buys that, but it
    # now has to be asked for.
    if ((APPLY && DO_BACKUP)) && ! command -v getfacl >/dev/null 2>&1; then
        die "$EX_PREREQ" \
            "getfacl not found, so no undo snapshot can be taken and this run would be irreversible. Install the 'acl' package, or pass --no-backup to accept that deliberately."
    fi

    if [[ $EUID -ne 0 ]]; then
        log WARN "Not running as root: directories you cannot read are invisible to this scan."
    fi
    return 0
}

# Held across the scan as well as the apply, because the apply executes a plan
# the scan produced: a second run mutating the same tree in between would make
# that plan describe a filesystem that no longer exists.
#
# A dry run does not lock. It changes nothing, and /run/lock is root-owned, so
# locking unconditionally would stop an unprivileged user from running the
# report at all -- which is the mode this script is meant to be used in first.
acquire_lock() {
    ((APPLY)) || return 0

    mkdir -p "$(dirname "$LOCK_FILE")" 2>/dev/null || true
    # A brace group, not a subshell: fd 9 has to survive into the rest of the
    # run, while the shell's own "cannot open" message is silenced for the
    # duration of the redirection so the handled case reports itself once.
    if ! { exec 9>"$LOCK_FILE"; } 2>/dev/null; then
        # Root cannot fail to open this for a benign reason, so treat it as a
        # fault. An unprivileged --no-chown run legitimately cannot write to
        # /run/lock; it can only touch modes on files it already owns, and the
        # operation is idempotent, so it proceeds with a warning rather than
        # losing the ability to run at all.
        [[ $EUID -eq 0 ]] && die "$EX_LOCKED" "Cannot open lock file $LOCK_FILE"
        log WARN "Cannot open lock file $LOCK_FILE; continuing without a concurrency lock."
        log WARN "Set LZC_FIX_PERMISSIONS_LOCK (or --lock-file) to a writable path to get one."
        return 0
    fi
    flock -n 9 ||
        die "$EX_LOCKED" "Another $SCRIPT_NAME run holds $LOCK_FILE. Refusing to run concurrently."
    return 0
}

# --- Mode arithmetic ---------------------------------------------------------

is_private() {
    local rel=$1 d
    for d in ${PRIVATE_DIRS[@]+"${PRIVATE_DIRS[@]}"}; do
        [[ $rel == "$d" || $rel == "$d"/* ]] && return 0
    done
    return 1
}

# Sets the global DESIRED rather than echoing, because this runs once per inode
# and a command substitution would fork a subshell for every one of them.
compute_mode() {
    local ftype=$1 perm=$2 priv=$3
    local special=$((perm & 07000))
    local base=$((perm & 00777))
    local new

    if ((priv)); then
        # Credential stores are set outright, not adjusted: SSH refuses a key
        # that any other account can read, and GnuPG warns on the same.
        if [[ $ftype == d ]]; then DESIRED=$((00700)); else DESIRED=$((00600)); fi
        return 0
    fi

    new=$base
    if [[ $ftype == d ]]; then
        new=$((new | 00700))
    else
        new=$((new | 00600))
        # A setuid/setgid regular file under someone's home is a liability, and
        # the kernel clears both on chown anyway -- preserving them here would
        # mean putting them back after the chown took them away. The sticky bit
        # is kept: it is meaningless on a regular file on Linux, so clearing it
        # would be a change this script has no reason to make -- and the chmod
        # spec used to apply this (a-s) does not clear it either, so predicting
        # otherwise would make the dry run disagree with the result.
        special=$((special & 01000))
    fi
    new=$((new & ~00022))
    ((STRICT)) && new=$((new & ~00077))
    DESIRED=$((special | new))
    return 0
}

# The one invariant this script must never break: it may add owner bits, but it
# may never hand out a group, other, setuid or setgid bit that was not already
# there. The rules above satisfy it by construction, so this costs nothing and
# exists to catch a future edit to compute_mode.
loosens_access() {
    local perm=$1 want=$2
    (((want & 07077) & ~perm))
}

# --- Scan --------------------------------------------------------------------

# One held descriptor per batch. Bash's {varname}> form needs a plain variable
# name -- an associative-array element is not accepted there -- so the five are
# spelled out rather than looped over.
open_batches() {
    exec {FD_OWN}>"$WORK_DIR/own" || die "$EX_FAIL" "Cannot write to $WORK_DIR"
    exec {FD_DIRS}>"$WORK_DIR/dirs" || die "$EX_FAIL" "Cannot write to $WORK_DIR"
    exec {FD_FILES}>"$WORK_DIR/files" || die "$EX_FAIL" "Cannot write to $WORK_DIR"
    exec {FD_PDIRS}>"$WORK_DIR/pdirs" || die "$EX_FAIL" "Cannot write to $WORK_DIR"
    exec {FD_PFILES}>"$WORK_DIR/pfiles" || die "$EX_FAIL" "Cannot write to $WORK_DIR"
    exec {FD_SNAP}>"$WORK_DIR/snap" || die "$EX_FAIL" "Cannot write to $WORK_DIR"
    return 0
}

# Idempotent: the scan closes the batches so the apply phase reads complete
# files, and the EXIT trap closes them again if the run died before that.
close_batches() {
    [[ -n $FD_OWN ]] && {
        exec {FD_OWN}>&-
        FD_OWN=''
    }
    [[ -n $FD_DIRS ]] && {
        exec {FD_DIRS}>&-
        FD_DIRS=''
    }
    [[ -n $FD_FILES ]] && {
        exec {FD_FILES}>&-
        FD_FILES=''
    }
    [[ -n $FD_PDIRS ]] && {
        exec {FD_PDIRS}>&-
        FD_PDIRS=''
    }
    [[ -n $FD_PFILES ]] && {
        exec {FD_PFILES}>&-
        FD_PFILES=''
    }
    [[ -n $FD_SNAP ]] && {
        exec {FD_SNAP}>&-
        FD_SNAP=''
    }
    return 0
}

record() {
    case $1 in
        own) printf '%s\0' "$2" >&"$FD_OWN" ;;
        dirs) printf '%s\0' "$2" >&"$FD_DIRS" ;;
        files) printf '%s\0' "$2" >&"$FD_FILES" ;;
        pdirs) printf '%s\0' "$2" >&"$FD_PDIRS" ;;
        pfiles) printf '%s\0' "$2" >&"$FD_PFILES" ;;
        snap) printf '%s\0' "$2" >&"$FD_SNAP" ;;
        *) return 1 ;;
    esac
}

build_find_args() {
    local -n args=$1
    args=("$HOME_DIR")
    ((CROSS_FS)) || args+=(-xdev)

    if ((${#EXCLUDES[@]})); then
        local pattern first=1
        args+=('(')
        for pattern in "${EXCLUDES[@]}"; do
            ((first)) || args+=(-o)
            first=0
            args+=(-path "$HOME_DIR/$pattern")
        done
        # The -o is what stops -printf firing on the pruned directory itself.
        args+=(')' -prune -o)
    fi

    args+=(-printf '%y\t%m\t%U\t%G\t%p\0')
    return 0
}

scan() {
    local -a find_args=()
    build_find_args find_args

    local rc=0
    timeout "$SCAN_TIMEOUT" find "${find_args[@]}" \
        >"$WORK_DIR/scan" 2>"$WORK_DIR/scan.err" || rc=$?

    case $rc in
        0) ;;
        1)
            # find exits 1 when some paths could not be read. As root that
            # should not happen; as a normal user it is expected and the count
            # goes into the report so nobody mistakes a partial view for a
            # clean bill of health.
            COUNT_UNREADABLE=$(wc -l <"$WORK_DIR/scan.err" 2>/dev/null) || COUNT_UNREADABLE=0
            log WARN "$COUNT_UNREADABLE path(s) could not be read during the scan; they are not in this report."
            ;;
        124)
            log ERROR "Scan of $HOME_DIR did not finish within ${SCAN_TIMEOUT}s."
            log ERROR "Nothing was changed. Raise --timeout, or narrow the tree with --exclude."
            return "$EX_FAIL"
            ;;
        *)
            log ERROR "find failed with status $rc; nothing was changed."
            [[ -s $WORK_DIR/scan.err ]] && head -n 5 "$WORK_DIR/scan.err" >&2
            return "$EX_FAIL"
            ;;
    esac

    local rec ftype fmode fuid fgid fpath rel perm priv touched
    while IFS= read -r -d '' rec; do
        # Split by parameter expansion, not `IFS=$'\t' read`: tab is IFS
        # whitespace, so read would collapse runs of tabs and mangle any path
        # that contains one.
        ftype=${rec%%$'\t'*}
        rec=${rec#*$'\t'}
        fmode=${rec%%$'\t'*}
        rec=${rec#*$'\t'}
        fuid=${rec%%$'\t'*}
        rec=${rec#*$'\t'}
        fgid=${rec%%$'\t'*}
        fpath=${rec#*$'\t'}

        [[ $fmode =~ ^[0-7]{1,4}$ ]] || continue
        [[ $fuid =~ ^[0-9]+$ && $fgid =~ ^[0-9]+$ ]] || continue
        COUNT_SCANNED=$((COUNT_SCANNED + 1))

        touched=0
        if ((DO_CHOWN)) && [[ $fuid != "$TARGET_UID" || $fgid != "$TARGET_GID" ]]; then
            COUNT_CHOWN=$((COUNT_CHOWN + 1))
            record own "$fpath"
            touched=1
            if ((${#SAMPLE_OWN[@]} < MAX_LIST)); then
                SAMPLE_OWN+=("$(printf '%s:%s -> %s:%s  %q' \
                    "$fuid" "$fgid" "$TARGET_UID" "$TARGET_GID" "$fpath")")
            fi
        fi

        case $ftype in
            f | d) ;;
            l)
                # Never snapshotted: getfacl would report the link's target, so
                # a restore could reach outside the home. setfacl cannot undo
                # chown -h on a link anyway.
                COUNT_SYMLINK=$((COUNT_SYMLINK + 1))
                continue
                ;;
            *)
                COUNT_OTHER=$((COUNT_OTHER + 1))
                continue
                ;;
        esac

        if ((DO_CHMOD)); then
            perm=$((8#$fmode))
            [[ $ftype == f ]] && ((perm & 06000)) && COUNT_SETID=$((COUNT_SETID + 1))

            rel=${fpath#"$HOME_DIR"/}
            priv=0
            [[ $fpath != "$HOME_DIR" ]] && is_private "$rel" && priv=1

            compute_mode "$ftype" "$perm" "$priv"
            if ((DESIRED != perm)); then
                if loosens_access "$perm" "$DESIRED"; then
                    COUNT_REFUSED=$((COUNT_REFUSED + 1))
                    if ((${#SAMPLE_REFUSED[@]} < MAX_LIST)); then
                        SAMPLE_REFUSED+=("$(printf '%04o -> %04o  %q' "$perm" "$DESIRED" "$fpath")")
                    fi
                else
                    COUNT_CHMOD=$((COUNT_CHMOD + 1))
                    touched=1
                    if ((priv)); then
                        if [[ $ftype == d ]]; then record pdirs "$fpath"; else record pfiles "$fpath"; fi
                    else
                        if [[ $ftype == d ]]; then record dirs "$fpath"; else record files "$fpath"; fi
                    fi
                    if ((${#SAMPLE_MODE[@]} < MAX_LIST)); then
                        SAMPLE_MODE+=("$(printf '%04o -> %04o  %q' "$perm" "$DESIRED" "$fpath")")
                    fi
                fi
            fi
        fi

        # The snapshot covers exactly what this run will modify -- not the whole
        # tree -- so it honours --exclude and the filesystem boundary, and stays
        # proportional to the change set instead of the size of the home.
        ((touched)) && record snap "$fpath"
    done <"$WORK_DIR/scan"

    # Flush every batch before the apply phase reads the files back.
    close_batches
    return 0
}

# --- Reporting ---------------------------------------------------------------

report() {
    local item shown

    printf '\n'
    log INFO "Target"
    printf '  User             : %s (uid %s, gid %s)\n' "$TARGET_USER" "$TARGET_UID" "$TARGET_GID"
    printf '  Home directory   : %s\n' "$HOME_DIR"
    printf '  Mode             : %s\n' \
        "$( ((APPLY)) && printf 'APPLY -- changes will be written' || printf 'DRY RUN -- nothing will be changed')"
    printf '  Rule set         : %s\n' \
        "$( ((STRICT)) && printf 'strict (0700 dirs / 0600 files)' || printf 'default (clear group+other write)')"
    ((${#EXCLUDES[@]})) && printf '  Excluded         : %s\n' "${EXCLUDES[*]}"
    ((CROSS_FS)) && printf '  Filesystems      : crossing mount points\n'
    printf '\n'

    log INFO "Findings"
    printf '  Paths scanned    : %d\n' "$COUNT_SCANNED"
    printf '  Ownership fixes  : %d\n' "$COUNT_CHOWN"
    printf '  Permission fixes : %d\n' "$COUNT_CHMOD"
    printf '  Symlinks         : %d (ownership only, never chmod)\n' "$COUNT_SYMLINK"
    printf '  Other inodes     : %d (sockets/fifos/devices, ownership only)\n' "$COUNT_OTHER"
    ((COUNT_SETID)) && printf '  setuid/setgid    : %d file(s), bits will be cleared\n' "$COUNT_SETID"
    ((COUNT_UNREADABLE)) && printf '  Unreadable       : %d path(s) not visible to this scan\n' "$COUNT_UNREADABLE"
    ((COUNT_REFUSED)) && printf '  Refused          : %d path(s) whose computed mode would have loosened access\n' "$COUNT_REFUSED"
    printf '\n'

    if ((${#SAMPLE_OWN[@]})); then
        log INFO "Ownership changes (first ${#SAMPLE_OWN[@]} of $COUNT_CHOWN):"
        for item in "${SAMPLE_OWN[@]}"; do printf '  chown %s\n' "$item"; done
        shown=${#SAMPLE_OWN[@]}
        ((COUNT_CHOWN > shown)) && printf '  ... and %d more\n' "$((COUNT_CHOWN - shown))"
        printf '\n'
    fi

    if ((${#SAMPLE_MODE[@]})); then
        log INFO "Permission changes (first ${#SAMPLE_MODE[@]} of $COUNT_CHMOD):"
        for item in "${SAMPLE_MODE[@]}"; do printf '  chmod %s\n' "$item"; done
        shown=${#SAMPLE_MODE[@]}
        ((COUNT_CHMOD > shown)) && printf '  ... and %d more\n' "$((COUNT_CHMOD - shown))"
        printf '\n'
    fi

    if ((${#SAMPLE_REFUSED[@]})); then
        log WARN "Refused, would have granted access that was not already there:"
        for item in "${SAMPLE_REFUSED[@]}"; do printf '  %s\n' "$item" >&2; done
        printf '\n'
    fi
    return 0
}

# --- Apply -------------------------------------------------------------------

confirm() {
    local prompt=$1 reply
    if [[ -t 0 ]]; then
        read -r -p "$prompt [y/N] " reply || return 1
    else
        # `curl ... | bash` leaves the script itself on stdin, so ask the
        # terminal directly. Under cron /dev/tty exists but cannot be opened,
        # and this returns non-zero instead of hanging.
        printf '%s [y/N] ' "$prompt"
        read -r reply </dev/tty 2>/dev/null || return 1
    fi
    [[ ${reply,,} == y* ]]
}

take_backup() {
    ((DO_BACKUP)) || return 0

    # getfacl's presence was settled in preflight, so this is reached only when
    # a snapshot can actually be taken.
    if ! mkdir -p "$BACKUP_DIR" 2>/dev/null; then
        die "$EX_FAIL" "Cannot create backup directory '$BACKUP_DIR'. Use --backup-dir, or --no-backup to proceed without one."
    fi

    BACKUP_FILE="$BACKUP_DIR/${TARGET_USER}-$(date -u '+%Y%m%dT%H%M%SZ').facl"
    log INFO "Recording current ownership and modes in $BACKUP_FILE"

    # No special-casing for awkward file names: the snapshot format is escaped,
    # not raw. getfacl writes a newline in a name as \012 and a literal
    # backslash as \\, and setfacl --restore decodes both, so such a path round
    # trips through the undo unchanged. Verified against acl 2.3.2 -- do not add
    # a warning here on the assumption that a line-based format cannot carry it.

    # Only the paths this run will touch, fed from the scan. Walking the whole
    # home instead would ignore --exclude, follow the tree across mount points
    # the scan deliberately skipped, and take far longer than the run itself.
    #
    # Created under umask 0077 rather than created-then-chmod'ed: the snapshot
    # is a complete structural listing of somebody's home, and the chmod-after
    # form leaves it world-readable for the length of the walk.
    local rc=0 prev_umask
    prev_umask=$(umask)
    umask 0077
    timeout "$BACKUP_TIMEOUT" xargs -0 -r getfacl -p -- <"$WORK_DIR/snap" \
        >"$BACKUP_FILE" 2>"$WORK_DIR/backup.err" || rc=$?
    umask "$prev_umask"

    if ((rc != 0)) || [[ ! -s $BACKUP_FILE ]]; then
        [[ -s $WORK_DIR/backup.err ]] && head -n 5 "$WORK_DIR/backup.err" >&2
        die "$EX_FAIL" "Snapshot failed (status $rc). Nothing was changed. Raise --backup-timeout if it timed out, or pass --no-backup to accept an irreversible run."
    fi

    # Belt and braces: umask only constrains creation, and the file may already
    # have existed with looser bits.
    chmod 0600 "$BACKUP_FILE" 2>/dev/null || log WARN "Could not restrict permissions on $BACKUP_FILE"
    log SUCCESS "Snapshot written. Undo this run with: setfacl --restore=$BACKUP_FILE"
    return 0
}

# Re-checks a chmod batch for symlinks immediately before it is applied.
#
# The scan already classifies symlinks out of the chmod lists, but the scan and
# the apply are separated by the report, and by an interactive confirmation that
# can sit there for minutes. `chmod` follows symlinks given on the command line
# and has no --no-dereference, so without this the owner of the home -- the one
# person guaranteed to be able to write in it -- can replace a listed regular
# file with a link to /etc/shadow after the plan is printed and have root chmod
# the target instead. `chown -h` is already immune; chmod is what needs this.
#
# This narrows the window from "the length of the whole report and prompt" to
# the interval between this lstat and chmod's own path resolution. That last
# gap cannot be closed from a shell script: it needs openat(O_NOFOLLOW) and
# fchmod, which bash has no way to call. A path dropped here is reported rather
# than skipped quietly -- it means the tree changed mid-run, which is worth
# knowing about whether or not anyone was attacking.
# `src`/`dst` rather than `in`/`out`: `out` is the nameref array in
# parse_id_spec, and reusing the name here makes shellcheck read this string
# assignment as clobbering that array (SC2178/SC2128).
drop_symlinks() {
    local src=$1 dst=$2 p dropped=0
    while IFS= read -r -d '' p; do
        if [[ -L $p ]]; then
            dropped=$((dropped + 1))
            continue
        fi
        printf '%s\0' "$p"
    done <"$src" >"$dst"

    if ((dropped)); then
        log WARN "$dropped path(s) became symlinks between the scan and the apply and were not chmod'ed."
        COUNT_RACED=$((COUNT_RACED + dropped))
    fi
    return 0
}

# Runs one batch through xargs. Returns non-zero if any invocation failed, so
# the caller can turn that into exit 1 instead of a cheerful "done".
run_batch() {
    local file=$1 label=$2
    shift 2
    [[ -s $file ]] || return 0

    local rc=0
    timeout "$APPLY_TIMEOUT" xargs -0 -r "$@" -- <"$file" || rc=$?
    case $rc in
        0) return 0 ;;
        124)
            log ERROR "$label: timed out after ${APPLY_TIMEOUT}s, partially applied."
            ;;
        123)
            log ERROR "$label: one or more paths could not be changed."
            ;;
        *)
            log ERROR "$label: failed with status $rc."
            ;;
    esac
    return 1
}

apply_changes() {
    local dir_spec file_spec

    if ((STRICT)); then
        dir_spec='u+rwx,go-rwx'
        file_spec='u+rw,go-rwx,a-s'
    else
        dir_spec='u+rwx,go-w'
        file_spec='u+rw,go-w,a-s'
    fi

    # Ownership first: the kernel clears setuid/setgid on chown, so doing it the
    # other way round would leave modes that no longer match what was reported.
    # chown -h is what keeps a symlink pointing at /etc/shadow from turning this
    # into a way to hand that file to an unprivileged user.
    if ((DO_CHOWN)); then
        run_batch "$WORK_DIR/own" 'chown' chown -h "$TARGET_UID:$TARGET_GID" ||
            FAILURES=$((FAILURES + 1))
    fi

    if ((DO_CHMOD)); then
        # Every chmod list is re-checked for symlinks first; see drop_symlinks.
        local batch
        for batch in dirs files pdirs pfiles; do
            [[ -s $WORK_DIR/$batch ]] || continue
            drop_symlinks "$WORK_DIR/$batch" "$WORK_DIR/$batch.safe"
            mv -f "$WORK_DIR/$batch.safe" "$WORK_DIR/$batch"
        done

        run_batch "$WORK_DIR/dirs" 'chmod directories' chmod "$dir_spec" ||
            FAILURES=$((FAILURES + 1))
        run_batch "$WORK_DIR/files" 'chmod files' chmod "$file_spec" ||
            FAILURES=$((FAILURES + 1))
        # Five digits, not four, and not by accident: GNU chmod leaves the
        # setuid/setgid bits of a *directory* alone for a numeric mode shorter
        # than five digits, so `chmod 0700` on a setgid .ssh/ is a no-op for
        # that bit. compute_mode predicts 0700 with the special bits cleared,
        # so a four-digit mode here makes the dry run lie and the run never
        # converge -- every re-run reports the same path again. Do not shorten.
        run_batch "$WORK_DIR/pdirs" 'chmod private directories' chmod 00700 ||
            FAILURES=$((FAILURES + 1))
        run_batch "$WORK_DIR/pfiles" 'chmod private files' chmod 00600 ||
            FAILURES=$((FAILURES + 1))
    fi
    return 0
}

# --- Lifecycle ---------------------------------------------------------------

on_exit() {
    local rc=$?
    trap - EXIT INT TERM
    close_batches
    [[ -n $WORK_DIR && -d $WORK_DIR ]] && rm -rf -- "${WORK_DIR:?}"
    exit "$rc"
}

on_signal() {
    log WARN "Interrupted. Changes already written are not rolled back."
    ((DO_BACKUP)) && [[ -s ${BACKUP_FILE:-} ]] &&
        log WARN "Restore point: setfacl --restore=$BACKUP_FILE"
    exit "$EX_INTERRUPT"
}

# --- Main --------------------------------------------------------------------

main() {
    parse_args "$@"
    setup_color

    resolve_target
    preflight
    acquire_lock

    WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fix-permissions.XXXXXX") ||
        die "$EX_FAIL" "Cannot create a working directory under ${TMPDIR:-/tmp}"
    trap on_exit EXIT
    trap on_signal INT TERM

    open_batches

    local rc=0
    scan || rc=$?
    if ((rc != 0)); then
        return "$rc"
    fi

    report

    if ((COUNT_CHOWN == 0 && COUNT_CHMOD == 0)); then
        log SUCCESS "Nothing to change in $HOME_DIR"
        return 0
    fi

    if ((!APPLY)); then
        log INFO "Dry run: nothing was changed. Re-run with --apply (or --yes for cron) to write these changes."
        return 0
    fi

    if ((!ASSUME_YES)); then
        if [[ -t 1 ]]; then
            confirm "Apply $((COUNT_CHOWN + COUNT_CHMOD)) change(s) to $HOME_DIR?" || {
                log INFO "Cancelled. Nothing was changed."
                return 0
            }
        else
            log ERROR "Refusing to change $HOME_DIR unattended without --yes."
            return "$EX_NOCONFIRM"
        fi
    fi

    take_backup
    apply_changes

    if ((FAILURES)); then
        log ERROR "$FAILURES batch(es) reported failures; see the messages above."
        return "$EX_FAIL"
    fi

    log SUCCESS "Applied $COUNT_CHOWN ownership and $((COUNT_CHMOD - COUNT_RACED)) permission change(s) under $HOME_DIR"
    ((COUNT_RACED)) && log WARN "$COUNT_RACED planned permission change(s) were skipped: the path became a symlink after the scan. Re-run to pick them up."
    [[ -n $BACKUP_FILE ]] && log INFO "Undo with: setfacl --restore=$BACKUP_FILE"
    return 0
}

main "$@"
