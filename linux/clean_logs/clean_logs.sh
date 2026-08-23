#!/usr/bin/env bash
#
# System log cleaner.
#
# Frees disk space by deleting rotated log archives older than a cutoff, under
# an explicit list of directories, and by vacuuming the systemd journal with
# journalctl. It prints every path it will remove and the space that will be
# released, and it changes nothing at all unless --yes is given.
#
# License: MIT
# Origin:  https://github.com/Lazarev-Cloud/Scripts
#
# Error model: this script deliberately does NOT use `set -e`. It walks many
# independent files and must finish the sweep and report on all of them even
# when one unlink fails, so every fallible operation is checked explicitly and
# routed into ERRORS. Do not add `set -e`, and do not invoke this script as
# `clean_logs.sh || true` -- both move the error handling out of the script and
# reintroduce the "reported success, deleted nothing" bug this rewrite removes.
set -uo pipefail

readonly SCRIPT_NAME='System Log Cleaner'
readonly SCRIPT_VERSION='2.1'

# Exit codes, shared by every script in this repository. 75 is EX_TEMPFAIL from
# sysexits.h, which cron and systemd read as "retry later" rather than a fault.
#
# The repository's code 5 (confirmation needed, but no TTY and no --yes) has no
# constant here because this script has no prompt to refuse: a run without --yes
# is already a report, and a run with --yes never waits for a terminal. See the
# exit-status section of --help.
readonly EX_FAIL=1 EX_USAGE=2 EX_PREREQ=3 EX_NOROOT=4
readonly EX_LOCKED=75 EX_INTERRUPT=130

# --- Tunables (env overridable, then flag overridable) -----------------------
PATHS_SPEC="${LZC_CLEAN_LOGS_PATHS:-/var/log}"
MAX_AGE_DAYS="${LZC_CLEAN_LOGS_DAYS:-14}"
PATTERN_SPEC="${LZC_CLEAN_LOGS_PATTERNS:-}"
ACTIVE_PATTERN_SPEC="${LZC_CLEAN_LOGS_ACTIVE_PATTERNS:-*.log syslog messages}"
EXCLUDE_SPEC="${LZC_CLEAN_LOGS_EXCLUDE:-}"
DO_JOURNAL="${LZC_CLEAN_LOGS_JOURNAL:-1}"
JOURNAL_KEEP_SIZE="${LZC_CLEAN_LOGS_JOURNAL_KEEP_SIZE:-200M}"
JOURNAL_KEEP_TIME="${LZC_CLEAN_LOGS_JOURNAL_KEEP_TIME:-}"
DO_TRUNCATE="${LZC_CLEAN_LOGS_TRUNCATE:-0}"
TRUNCATE_MIN_BYTES="${LZC_CLEAN_LOGS_TRUNCATE_MIN:-104857600}"
LIST_LIMIT="${LZC_CLEAN_LOGS_LIST_LIMIT:-50}"
CMD_TIMEOUT="${LZC_CLEAN_LOGS_TIMEOUT:-60}"
LOCK_FILE="${LZC_CLEAN_LOGS_LOCK:-/run/lock/lzc-clean_logs.lock}"
ASSUME_YES="${LZC_CLEAN_LOGS_YES:-0}"
DRY_RUN=0
USE_COLOR="${LZC_CLEAN_LOGS_COLOR:-auto}"

# --- Safety invariants (not tunable, on purpose) -----------------------------

# journald owns these directories. Its files are an indexed, rotating database
# with an active writer; removing a .journal file with rm corrupts the store and
# loses history that journalctl would otherwise still serve. `journalctl
# --vacuum-*` is the only correct tool, and this script uses it. Any directory
# named `journal` under a scanned root is pruned as well, which covers the case
# where a root is a symlink and the absolute paths below no longer match.
readonly -a JOURNAL_DIRS=(/var/log/journal /run/log/journal)

# Directories that are never acceptable as a scan root. These are exact matches:
# /var and /home are refused, /var/log and /home/me/logs are fine. Passing a
# root this broad is always a mistake in a log cleaner, and the blast radius of
# honouring it is the whole system.
readonly -a FORBIDDEN_ROOTS=(
    / /bin /boot /dev /etc /home /lib /lib32 /lib64 /libx32
    /media /mnt /opt /proc /root /run /sbin /srv /sys /usr /var
)

# Rotated and archived log names, as produced by logrotate, savelog and the
# distro maintainer scripts.
#
# The digit classes are deliberately bounded to one and two digits. A greedy
# `*.[0-9]*` would also match /var/log/mysql/mysql-bin.000001 -- MySQL binary
# logs, whose deletion silently breaks replication and point-in-time recovery.
# Do not "generalise" these patterns; add a specific one instead.
readonly -a DEFAULT_PATTERNS=(
    '*.gz' '*.bz2' '*.xz' '*.zst' '*.lz4'
    '*.old'
    '*.[0-9]' '*.[0-9][0-9]'
    '*-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]'
)

# --- Runtime state -----------------------------------------------------------
declare -a ROOTS=()
declare -a PATTERNS=()
declare -a ACTIVE_PATTERNS=()
declare -a EXCLUDES=()
declare -a NAME_EXPR=()
declare -a DEL_PATHS=()
declare -a DEL_BYTES=()
declare -a TRUNC_PATHS=()
declare -a TRUNC_BYTES=()
DEL_TOTAL=0
TRUNC_TOTAL=0
JOURNAL_BEFORE=0
JOURNAL_AFTER=0
JOURNAL_DONE=0
UNREADABLE=0
ERRORS=0
REMOVED_COUNT=0
REMOVED_BYTES=0
TRUNCATED_COUNT=0
TRUNCATED_BYTES=0
APPLY=0
TMP_DIR=''
LOCK_HELD=0
YW='' BL='' RD='' GN='' CL=''

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
    case $level in
        ERROR) printf '%s[Error]%s %s\n' "$RD" "$CL" "$*" >&2 ;;
        WARN) printf '%s[Warning]%s %s\n' "$YW" "$CL" "$*" >&2 ;;
        INFO) printf '%s[Info]%s %s\n' "$BL" "$CL" "$*" ;;
        SUCCESS) printf '%s[OK]%s %s\n' "$GN" "$CL" "$*" ;;
        *) printf '%s\n' "$*" ;;
    esac
}

# Code first, message second, and no default code: every call site has to name
# the exit code it means, so the standard table cannot be dodged by omission.
die() {
    local code=$1
    shift
    log ERROR "$*"
    exit "$code"
}

# Byte counts are printed in binary units because that is what df, du and ls -h
# report, and an operator comparing this output with df should not have to
# convert.
human_bytes() {
    local -a units=(B KiB MiB GiB TiB PiB)
    local whole=$1 frac=0 i=0
    while ((whole >= 1024 && i < 5)); do
        frac=$(((whole % 1024) * 10 / 1024))
        whole=$((whole / 1024))
        i=$((i + 1))
    done
    if ((i == 0)); then
        printf '%d %s' "$whole" "${units[i]}"
    else
        printf '%d.%d %s' "$whole" "$frac" "${units[i]}"
    fi
}

# Wraps a whitespace-separated list into indented lines no wider than $2.
#
# Used for the parts of --help and the report that are generated from a
# configurable default. Interpolating such a list straight into a heredoc
# produces one line as long as the list happens to be -- the dnf lock list
# reached 216 columns that way -- and it silently gets worse every time a
# default gains an entry, which is exactly the kind of thing nobody notices in
# review.
wrap_list() {
    local indent=$1 width=$2 spec=$3
    local -a items=()
    read -r -a items <<<"$spec"
    ((${#items[@]})) || return 0

    local item line=''
    for item in "${items[@]}"; do
        if [[ -z $line ]]; then
            line="$indent$item"
        elif ((${#line} + 1 + ${#item} <= width)); then
            line+=" $item"
        else
            printf '%s\n' "$line"
            line="$indent$item"
        fi
    done
    [[ -n $line ]] && printf '%s\n' "$line"
    return 0
}

usage() {
    cat <<EOF
$SCRIPT_NAME v$SCRIPT_VERSION

Deletes rotated log archives older than a cutoff and vacuums the systemd
journal. Prints the full plan first and changes nothing without --yes.

Usage:
  clean_logs.sh [options]

Blast radius:
  Deletes regular files under the directories given by --path (default
  /var/log) whose names match the rotated-archive patterns AND whose mtime is
  older than --days. Nothing outside those directories is ever touched: the
  scan is rooted there, symlinks are never followed out, and directories named
  \`journal\` are pruned. Roots such as /, /etc, /usr, /var and /home are
  refused outright.

  The default patterns are deliberately narrow, and the digit classes are
  bounded to one and two digits so that MySQL binary logs (mysql-bin.000001)
  and similar numbered data files never match:
$(wrap_list '    ' 76 "${DEFAULT_PATTERNS[*]}")

  With --truncate-active it additionally truncates -- not deletes -- live log
  files larger than --truncate-larger-than. That destroys their current
  contents. It is off by default.

  The systemd journal is shrunk with \`journalctl --vacuum-size/--vacuum-time\`,
  never with rm. Vacuuming only removes *archived* journal files; the active
  one is kept, so the space reclaimed is normally less than the total journal
  size.

Options:
  -y, --yes                    Actually delete. Without it this is a report.
  -n, --dry-run                Report only (the default). Wins over --yes.
  -p, --path DIR               Directory to clean. Repeatable.
                               (default: $PATHS_SPEC)
  -d, --days N                 Delete archives older than N*24h (default: $MAX_AGE_DAYS).
                               N=0 means "older than 24 hours".
  -x, --exclude GLOB           Skip paths matching this glob. Repeatable.
      --pattern GLOB           Filename glob that marks a rotated archive.
                               Repeatable, and REPLACES the built-in list
                               rather than adding to it. Matched against the
                               file name only, never the directory.
      --active-pattern GLOB    Same, for the live-log list --truncate-active
                               works from (default: $ACTIVE_PATTERN_SPEC).
      --no-journal             Do not touch the systemd journal.
      --journal-size SIZE      Journal size to keep, journalctl syntax
                               (default: $JOURNAL_KEEP_SIZE).
      --journal-time TIME      Journal age to keep, journalctl syntax
                               (default: --days as Nd).
      --truncate-active        Also truncate live logs. DESTROYS their contents.
      --truncate-larger-than N Byte threshold for the above.
                               Default: $TRUNCATE_MIN_BYTES.
      --list-limit N           Paths to print per section, 0 = all.
                               Default: $LIST_LIMIT.
      --timeout SECONDS        Wall-clock limit for each single du call that
                               measures the journal and for the journalctl
                               vacuum call. It does NOT bound the file scan or
                               the run as a whole (default: $CMD_TIMEOUT).
      --color WHEN             auto | always | never (default: auto).
  -V, --version                Print version and exit.
  -h, --help                   Print this help and exit.

Colour is written only when stdout is a terminal, and never when NO_COLOR is
set to a non-empty value. --color always overrides both.

A flag beats the environment variable it shadows. For the list-valued options
that means replace, not merge: any --path discards LZC_CLEAN_LOGS_PATHS, any
--pattern discards LZC_CLEAN_LOGS_PATTERNS, any --active-pattern discards
LZC_CLEAN_LOGS_ACTIVE_PATTERNS. --exclude is the exception and adds to
LZC_CLEAN_LOGS_EXCLUDE, because an exclusion can only ever shrink the sweep.

Every option has an environment variable, which is the easier route from cron
or when piping this script in from the network. Boolean variables accept
1/true/yes/on and 0/false/no/off, in any case:
  LZC_CLEAN_LOGS_YES=1        LZC_CLEAN_LOGS_PATHS=/var/log:/srv/app/logs
  LZC_CLEAN_LOGS_DAYS=14      LZC_CLEAN_LOGS_EXCLUDE='*/audit/*'
  LZC_CLEAN_LOGS_JOURNAL=0    LZC_CLEAN_LOGS_JOURNAL_KEEP_SIZE=200M
  LZC_CLEAN_LOGS_JOURNAL_KEEP_TIME=14d
  LZC_CLEAN_LOGS_TRUNCATE=1   LZC_CLEAN_LOGS_TRUNCATE_MIN=104857600
  LZC_CLEAN_LOGS_PATTERNS='*.gz *.[0-9]'        (whitespace-separated globs)
  LZC_CLEAN_LOGS_ACTIVE_PATTERNS='*.log'        (whitespace-separated globs)
  LZC_CLEAN_LOGS_LIST_LIMIT=50   LZC_CLEAN_LOGS_TIMEOUT=60
  LZC_CLEAN_LOGS_LOCK=/run/lock/lzc-clean_logs.lock

There is no prompt in either direction. The default is a report, so a run
without --yes is safe to schedule, and a run with --yes never blocks waiting
for a terminal that cron does not have.

Requires GNU findutils and GNU coreutils (find -printf, du -sb, timeout,
mktemp). --yes additionally requires root and flock (util-linux).

Exit status:
  0    report produced, or every requested change succeeded
  1    the sweep ran but at least one delete, truncate or vacuum failed
  2    usage error: unknown flag, missing or invalid argument value, or a
       refused scan root
  3    unsupported platform or a missing prerequisite tool
  4    --yes was given but the script is not running as root
  5    not used: this script never prompts, so there is no confirmation to
       refuse -- a run without --yes is already a report
  75   another run of this script holds the lock (EX_TEMPFAIL: cron and
       systemd read it as "retry later", not as a fault)
  130  interrupted (SIGINT/SIGTERM)
EOF
}

# --- Argument parsing --------------------------------------------------------

# $1 option name, $2 remaining argument count, $3 the candidate value.
# A value that looks like another option is always a forgotten argument, and
# swallowing it produces a confusing error several options later. A lone "-" is
# allowed through since it is a conventional value, not an option.
need_arg() {
    if (($2 < 2)); then
        die "$EX_USAGE" "$1 requires a value"
    fi
    if [[ ${3-} == -?* ]]; then
        die "$EX_USAGE" "$1 requires a value, but got the option '$3'"
    fi
}

parse_args() {
    # Flag values go straight into arrays. Joining them into a
    # colon-separated string first would corrupt any path that contains a
    # colon; the env-var form is the one that has to accept a separator.
    #
    # Deliberately not named `pats`: matches_any() and build_name_expr() both
    # declare `local -n pats=`, and a caller-side local of that name makes the
    # nameref circular. Bash fails that at runtime and ShellCheck does not catch
    # it.
    local -a path_flags=() exclude_flags=()
    local -a pattern_flags=() active_pattern_flags=()
    while (($#)); do
        case $1 in
            -y | --yes) ASSUME_YES=1 ;;
            -n | --dry-run) DRY_RUN=1 ;;
            -p | --path)
                need_arg "$1" $# "${2-}"
                path_flags+=("$2")
                shift
                ;;
            -d | --days)
                need_arg "$1" $# "${2-}"
                MAX_AGE_DAYS=$2
                shift
                ;;
            -x | --exclude)
                need_arg "$1" $# "${2-}"
                exclude_flags+=("$2")
                shift
                ;;
            --pattern)
                need_arg "$1" $# "${2-}"
                pattern_flags+=("$2")
                shift
                ;;
            --active-pattern)
                need_arg "$1" $# "${2-}"
                active_pattern_flags+=("$2")
                shift
                ;;
            --no-journal) DO_JOURNAL=0 ;;
            --journal-size)
                need_arg "$1" $# "${2-}"
                JOURNAL_KEEP_SIZE=$2
                shift
                ;;
            --journal-time)
                need_arg "$1" $# "${2-}"
                JOURNAL_KEEP_TIME=$2
                shift
                ;;
            --truncate-active) DO_TRUNCATE=1 ;;
            --truncate-larger-than)
                need_arg "$1" $# "${2-}"
                TRUNCATE_MIN_BYTES=$2
                shift
                ;;
            --list-limit)
                need_arg "$1" $# "${2-}"
                LIST_LIMIT=$2
                shift
                ;;
            --timeout)
                need_arg "$1" $# "${2-}"
                CMD_TIMEOUT=$2
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
            *) die "$EX_USAGE" "Unknown option: $1 (try --help)" ;;
        esac
        shift
    done

    # --path replaces the env-provided default; --exclude adds to it.
    if ((${#path_flags[@]})); then
        ROOTS=("${path_flags[@]}")
        PATHS_SPEC=''
    fi
    ((${#exclude_flags[@]})) && EXCLUDES+=("${exclude_flags[@]}")

    # --pattern and --active-pattern REPLACE their lists rather than adding to
    # them, matching --path and the env vars they shadow. Adding would be the
    # dangerous direction for a delete filter: someone narrowing the sweep to
    # `--pattern '*.gz'` means only that, and silently keeping the eight
    # built-in patterns underneath would delete far more than they asked for.
    if ((${#pattern_flags[@]})); then
        PATTERNS=("${pattern_flags[@]}")
        PATTERN_SPEC=''
    fi
    if ((${#active_pattern_flags[@]})); then
        ACTIVE_PATTERNS=("${active_pattern_flags[@]}")
        ACTIVE_PATTERN_SPEC=''
    fi

    [[ $USE_COLOR =~ ^(auto|always|never)$ ]] || die "$EX_USAGE" "--color must be auto, always or never"

    # Minimums differ per option and are not interchangeable:
    #   --days 0        is documented as "older than 24 hours"
    #   --list-limit 0  is documented as "print every path"
    #   --timeout 0     would mean NO limit to timeout(1), silently removing the
    #                   protection the option exists to provide -- hence min 1.
    _normalise_int MAX_AGE_DAYS 0 '--days (LZC_CLEAN_LOGS_DAYS)'
    _normalise_int TRUNCATE_MIN_BYTES 0 '--truncate-larger-than (LZC_CLEAN_LOGS_TRUNCATE_MIN)'
    _normalise_int LIST_LIMIT 0 '--list-limit (LZC_CLEAN_LOGS_LIST_LIMIT)'
    _normalise_int CMD_TIMEOUT 1 '--timeout (LZC_CLEAN_LOGS_TIMEOUT)'

    # The env-settable booleans reach `((...))`, which evaluates its operand as
    # an arithmetic *expression*, not as a number. LZC_CLEAN_LOGS_YES=true --
    # the obvious thing to type -- made bash resolve a variable named `true`,
    # and under `set -u` that aborted the run with "true: unbound variable"
    # instead of a usable message. A value naming a defined array goes further
    # and runs the command substitution in its subscript. Normalise before the
    # first arithmetic use below, not at the point of use.
    _normalise_bool ASSUME_YES '--yes (LZC_CLEAN_LOGS_YES)'
    _normalise_bool DO_JOURNAL 'LZC_CLEAN_LOGS_JOURNAL'
    _normalise_bool DO_TRUNCATE '--truncate-active (LZC_CLEAN_LOGS_TRUNCATE)'

    [[ $JOURNAL_KEEP_SIZE =~ ^[0-9]+[KMGT]?$ ]] ||
        die "$EX_USAGE" "--journal-size must look like 200M, got '$JOURNAL_KEEP_SIZE'"
    # Derived after MAX_AGE_DAYS has been through 10#, so --days 08 becomes 8d
    # and not the 08d that journalctl would have to make sense of.
    #
    # Floored at 1d. --days 0 is documented as "older than 24 hours" for files,
    # but 0d is not the journal equivalent of that: depending on the systemd
    # release a zero retention is read either as "no time limit at all" or as
    # "discard every archived file", and those are opposite outcomes. Neither is
    # what --days 0 promises, so the derived value says what the flag means.
    # An explicit --journal-time is never rewritten.
    if [[ -z $JOURNAL_KEEP_TIME ]]; then
        if ((MAX_AGE_DAYS < 1)); then
            JOURNAL_KEEP_TIME='1d'
        else
            JOURNAL_KEEP_TIME="${MAX_AGE_DAYS}d"
        fi
    fi
    [[ $JOURNAL_KEEP_TIME =~ ^[0-9]+(s|m|h|d|w|month|y)$ ]] ||
        die "$EX_USAGE" "--journal-time must look like 14d, got '$JOURNAL_KEEP_TIME'"

    # --dry-run beats --yes so that adding -n to a known-good command line is
    # always a safe way to preview it, whatever else is on that line.
    if ((DRY_RUN)); then
        APPLY=0
    elif ((ASSUME_YES)); then
        APPLY=1
    fi
}

# Accepts the spellings people actually write in cron files and unit files, and
# normalises them to 1/0 so every later arithmetic context is safe.
#
# $2 is the spelling the operator typed -- the flag and the environment
# variable, not the internal variable name. Naming ASSUME_YES at someone who
# set LZC_CLEAN_LOGS_YES points them at a string that appears in no
# documentation and cannot be grepped for.
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

# Splits a colon- or newline-separated spec into the named array.
split_spec() {
    local -n out=$1
    local spec=$2 item
    [[ -n $spec ]] || return 0
    local saved_ifs=$IFS
    IFS=$':\n'
    # Word splitting on the IFS above is the entire point of this expansion.
    # shellcheck disable=SC2206
    local parts=($spec)
    IFS=$saved_ifs
    for item in ${parts[@]+"${parts[@]}"}; do
        [[ -n $item ]] && out+=("$item")
    done
}

# Splits a whitespace-separated glob list. Globs must not be expanded here, so
# noglob is set for the duration.
split_globs() {
    local -n glob_out=$1
    local spec=$2 item
    [[ -n $spec ]] || return 0
    set -o noglob
    # Word splitting is intended: this is a list of patterns, not one pattern.
    # shellcheck disable=SC2206
    local parts=($spec)
    set +o noglob
    for item in ${parts[@]+"${parts[@]}"}; do
        [[ -n $item ]] && glob_out+=("$item")
    done
}

resolve_path() {
    local p=$1 resolved=''
    if command -v realpath >/dev/null 2>&1; then
        resolved=$(realpath -m -- "$p" 2>/dev/null)
    fi
    [[ -n $resolved ]] || resolved=$(readlink -f -- "$p" 2>/dev/null)
    [[ -n $resolved ]] || resolved=$p
    # Strip a trailing slash so prefix comparisons stay unambiguous.
    [[ $resolved == / ]] || resolved=${resolved%/}
    printf '%s' "$resolved"
}

# Drops duplicate and nested scan roots, keeping the outermost.
#
# Without this, `--path /var/log --path /var/log/nginx` walks everything under
# nginx/ twice: each file is listed twice and its size counted twice. The apply
# path survives that (the second unlink finds the file gone and warns), but the
# dry-run report -- the thing the operator makes the delete decision from --
# would overstate both the file count and the space freed.
dedupe_roots() {
    local -a kept=()
    local a b keep
    for a in "${ROOTS[@]}"; do
        keep=1
        for b in ${kept[@]+"${kept[@]}"}; do
            if [[ $a == "$b" || $a == "$b"/* ]]; then
                keep=0
                break
            fi
        done
        ((keep)) || continue
        # Anything already kept that sits under this root is now redundant.
        local -a survivors=()
        for b in ${kept[@]+"${kept[@]}"}; do
            [[ $b == "$a"/* ]] && continue
            survivors+=("$b")
        done
        kept=(${survivors[@]+"${survivors[@]}"} "$a")
    done
    if ((${#kept[@]} != ${#ROOTS[@]})); then
        log INFO "Overlapping roots collapsed to: ${kept[*]}"
    fi
    ROOTS=("${kept[@]}")
}

is_forbidden_root() {
    local candidate=$1 item
    for item in "${FORBIDDEN_ROOTS[@]}"; do
        [[ $candidate == "$item" ]] && return 0
    done
    return 1
}

in_journal_dir() {
    local candidate=$1 item
    for item in "${JOURNAL_DIRS[@]}"; do
        [[ $candidate == "$item" || $candidate == "$item"/* ]] && return 0
    done
    # Belt and braces for the symlinked-root case: any path component named
    # `journal` means journald territory.
    [[ $candidate == */journal/* ]] && return 0
    return 1
}

matches_any() {
    local subject=$1
    local -n pats=$2
    local p
    for p in ${pats[@]+"${pats[@]}"}; do
        # $p is unquoted so that case treats it as a glob, which is the point.
        # shellcheck disable=SC2254
        case $subject in
            $p) return 0 ;;
        esac
    done
    return 1
}

is_excluded() {
    local candidate=$1
    ((${#EXCLUDES[@]})) || return 1
    matches_any "$candidate" EXCLUDES
}

# --- Preflight ---------------------------------------------------------------

preflight() {
    local tool
    for tool in find du timeout mktemp; do
        command -v "$tool" >/dev/null 2>&1 ||
            die "$EX_PREREQ" "$tool not found; this script needs GNU coreutils and findutils"
    done

    # -printf is a GNU findutils extension and the script's size accounting
    # depends on it. Fail loudly here rather than producing an empty report.
    #
    # Probed against / and not against `.`: a cron job whose working directory
    # has been deleted gets ENOENT from find, which is indistinguishable here
    # from "no -printf support" and would report a missing-findutils error for
    # what is really a missing cwd. -maxdepth 0 never descends, so naming / is
    # a stat of one inode, not a walk of the filesystem.
    find -P / -maxdepth 0 -printf '' >/dev/null 2>&1 ||
        die "$EX_PREREQ" "this find does not support -printf; GNU findutils is required"

    if ((APPLY)) && [[ $EUID -ne 0 ]]; then
        die "$EX_NOROOT" "--yes needs root to delete files under the system log directories"
    fi

    split_spec ROOTS "$PATHS_SPEC"
    ((${#ROOTS[@]})) || die "$EX_USAGE" "no scan root given (--path)"

    local i resolved
    for i in "${!ROOTS[@]}"; do
        resolved=$(resolve_path "${ROOTS[i]}")
        is_forbidden_root "$resolved" &&
            die "$EX_USAGE" "refusing to clean '$resolved': too broad for a log cleaner"
        [[ -d $resolved ]] || die "$EX_USAGE" "not a directory: ${ROOTS[i]} (resolved to $resolved)"
        ROOTS[i]=$resolved
    done
    dedupe_roots

    split_globs PATTERNS "$PATTERN_SPEC"
    ((${#PATTERNS[@]})) || PATTERNS=("${DEFAULT_PATTERNS[@]}")
    split_globs ACTIVE_PATTERNS "$ACTIVE_PATTERN_SPEC"
    ((DO_TRUNCATE)) && ((${#ACTIVE_PATTERNS[@]} == 0)) &&
        die "$EX_USAGE" \
            "--truncate-active needs at least one pattern from --active-pattern (LZC_CLEAN_LOGS_ACTIVE_PATTERNS)"
    split_spec EXCLUDES "$EXCLUDE_SPEC"

    TMP_DIR=$(mktemp -d 2>/dev/null) || die "$EX_FAIL" "cannot create a temporary directory"

    if [[ $EUID -ne 0 ]]; then
        log WARN "Not running as root; some paths may be unreadable."
    fi
}

# Only taken when something is actually going to change: two concurrent report
# runs cannot corrupt anything, and refusing them would make the script
# annoying to use interactively while a cron sweep is in progress.
acquire_lock() {
    ((APPLY)) || return 0
    # A guard that silently degrades to no guard is not a guard: two concurrent
    # --yes runs delete each other's candidates and misreport what they freed.
    # A dry run needs none of this, which is why the check sits below the APPLY
    # gate rather than in preflight.
    command -v flock >/dev/null 2>&1 ||
        die "$EX_PREREQ" "flock (util-linux) not found; it is required to serialise --yes runs"
    mkdir -p -- "$(dirname -- "$LOCK_FILE")" 2>/dev/null || true
    exec 9>"$LOCK_FILE" || die "$EX_LOCKED" "cannot open lock file $LOCK_FILE"
    flock -n 9 || die "$EX_LOCKED" "another $SCRIPT_NAME run holds $LOCK_FILE"
    LOCK_HELD=1
}

# --- Scanning ----------------------------------------------------------------

build_name_expr() {
    local -n pats=$1
    NAME_EXPR=()
    local p first=1
    for p in "${pats[@]}"; do
        if ((first)); then
            NAME_EXPR+=(-name "$p")
            first=0
        else
            NAME_EXPR+=(-o -name "$p")
        fi
    done
}

# find is invoked with -P (never follow symlinks) and -type f, so the walk
# cannot leave the root through a symlinked subdirectory and cannot return a
# symlink as a candidate. That is what bounds the blast radius; the textual
# prefix check below is a second, cheap line of defence.
scan_rotated() {
    local err_file="$TMP_DIR/find.err"
    : >"$err_file"

    build_name_expr PATTERNS

    local root blocks path
    for root in "${ROOTS[@]}"; do
        while IFS=$'\t' read -r -d '' blocks path; do
            [[ $path == "$root"/* ]] || continue
            in_journal_dir "$path" && continue
            is_excluded "$path" && continue
            [[ $blocks =~ ^[0-9]+$ ]] || blocks=0
            DEL_PATHS+=("$path")
            DEL_BYTES+=("$((blocks * 512))")
            DEL_TOTAL=$((DEL_TOTAL + blocks * 512))
        done < <(find -P "$root" -mindepth 1 \
            -type d -name journal -prune -o \
            -type f \( "${NAME_EXPR[@]}" \) -mtime "+$MAX_AGE_DAYS" \
            -printf '%b\t%p\0' 2>>"$err_file")
    done

    count_unreadable "$err_file"
}

# Adds this find's stderr line count to the unreadable tally. Both scans feed it,
# so a permission error during the truncate scan is reported too rather than
# being written to a file nothing ever reads.
#
# wc rather than grep: wc is coreutils, which preflight already requires, and
# grep was otherwise this script's only use of a package it never checked for.
# The redirection is deliberate -- `wc -l FILE` prints the file name too, and on
# some implementations pads the count, so the digit filter below keeps this
# robust either way rather than silently scoring every such run as zero.
count_unreadable() {
    local n
    n=$(wc -l <"$1" 2>/dev/null) || n=0
    n=${n//[!0-9]/}
    [[ -n $n ]] || n=0
    UNREADABLE=$((UNREADABLE + n))
}

scan_active() {
    ((DO_TRUNCATE)) || return 0
    local err_file="$TMP_DIR/find-active.err"
    : >"$err_file"

    build_name_expr ACTIVE_PATTERNS

    local root blocks path base
    for root in "${ROOTS[@]}"; do
        while IFS=$'\t' read -r -d '' blocks path; do
            [[ $path == "$root"/* ]] || continue
            in_journal_dir "$path" && continue
            is_excluded "$path" && continue
            # A file that is already a rotated archive is deletion's business,
            # not truncation's.
            base=${path##*/}
            matches_any "$base" PATTERNS && continue
            [[ $blocks =~ ^[0-9]+$ ]] || blocks=0
            TRUNC_PATHS+=("$path")
            TRUNC_BYTES+=("$((blocks * 512))")
            TRUNC_TOTAL=$((TRUNC_TOTAL + blocks * 512))
        done < <(find -P "$root" -mindepth 1 \
            -type d -name journal -prune -o \
            -type f \( "${NAME_EXPR[@]}" \) -size "+${TRUNCATE_MIN_BYTES}c" \
            -printf '%b\t%p\0' 2>>"$err_file")
    done

    count_unreadable "$err_file"
}

# --- The systemd journal -----------------------------------------------------

journal_available() {
    ((DO_JOURNAL)) || return 1
    command -v journalctl >/dev/null 2>&1 || return 1
    local d
    for d in "${JOURNAL_DIRS[@]}"; do
        [[ -d $d ]] && return 0
    done
    return 1
}

journal_bytes() {
    local total=0 d size
    for d in "${JOURNAL_DIRS[@]}"; do
        [[ -d $d ]] || continue
        size=$(timeout "$CMD_TIMEOUT" du -sb -- "$d" 2>/dev/null | awk 'NR == 1 { print $1 }')
        [[ $size =~ ^[0-9]+$ ]] || continue
        total=$((total + size))
    done
    printf '%s' "$total"
}

vacuum_journal() {
    log INFO "Vacuuming the systemd journal to $JOURNAL_KEEP_SIZE / $JOURNAL_KEEP_TIME"
    if ! timeout "$CMD_TIMEOUT" journalctl \
        --vacuum-size="$JOURNAL_KEEP_SIZE" \
        --vacuum-time="$JOURNAL_KEEP_TIME" >/dev/null 2>"$TMP_DIR/journal.err"; then
        log ERROR "journalctl vacuum failed: $(head -n 3 "$TMP_DIR/journal.err" 2>/dev/null | tr '\n' ' ')"
        ERRORS=$((ERRORS + 1))
        return 1
    fi
    JOURNAL_AFTER=$(journal_bytes)
    JOURNAL_DONE=1
    return 0
}

# --- Applying ----------------------------------------------------------------

remove_files() {
    ((${#DEL_PATHS[@]})) || return 0
    local i path bytes
    for i in "${!DEL_PATHS[@]}"; do
        path=${DEL_PATHS[i]}
        bytes=${DEL_BYTES[i]}
        # Re-check immediately before unlinking. rm never follows a symlink, so
        # a file swapped for one between the scan and now costs us the symlink,
        # not its target -- but a directory swap would be a different story.
        if [[ -L $path || ! -f $path ]]; then
            log WARN "Skipping $path: no longer a plain file"
            continue
        fi
        if rm -f -- "$path" 2>"$TMP_DIR/rm.err"; then
            REMOVED_COUNT=$((REMOVED_COUNT + 1))
            REMOVED_BYTES=$((REMOVED_BYTES + bytes))
        else
            log ERROR "Failed to remove $path: $(head -n 1 "$TMP_DIR/rm.err" 2>/dev/null)"
            ERRORS=$((ERRORS + 1))
        fi
    done
}

# Truncation is a data-destroying operation on a file something is probably
# still writing to, which is why it is opt-in. The redirection below follows
# symlinks, so the symlink check right before it is load-bearing, not decorative.
truncate_files() {
    ((DO_TRUNCATE)) || return 0
    ((${#TRUNC_PATHS[@]})) || return 0
    local i path bytes
    for i in "${!TRUNC_PATHS[@]}"; do
        path=${TRUNC_PATHS[i]}
        bytes=${TRUNC_BYTES[i]}
        if [[ -L $path || ! -f $path ]]; then
            log WARN "Skipping $path: no longer a plain file"
            continue
        fi
        if : >"$path" 2>"$TMP_DIR/trunc.err"; then
            TRUNCATED_COUNT=$((TRUNCATED_COUNT + 1))
            TRUNCATED_BYTES=$((TRUNCATED_BYTES + bytes))
        else
            log ERROR "Failed to truncate $path: $(head -n 1 "$TMP_DIR/trunc.err" 2>/dev/null)"
            ERRORS=$((ERRORS + 1))
        fi
    done
}

# --- Reporting ---------------------------------------------------------------

print_list() {
    local title=$1
    local -n paths=$2
    local -n sizes=$3
    local count=${#paths[@]} shown=0 i

    printf '\n%s (%d):\n' "$title" "$count"
    ((count)) || {
        printf '  none\n'
        return 0
    }
    for i in "${!paths[@]}"; do
        if ((LIST_LIMIT > 0 && shown >= LIST_LIMIT)); then
            printf '  ... and %d more (--list-limit 0 to see them all)\n' "$((count - shown))"
            break
        fi
        printf '  %12s  %s\n' "$(human_bytes "${sizes[i]}")" "${paths[i]}"
        shown=$((shown + 1))
    done
}

report_plan() {
    printf '%s v%s\n\n' "$SCRIPT_NAME" "$SCRIPT_VERSION"
    printf 'Roots        : %s\n' "${ROOTS[*]}"
    printf 'Older than   : %s day(s)\n' "$MAX_AGE_DAYS"
    # Continuation lines are indented to the width of the label, so the
    # wrapped patterns line up under the first one instead of under the label.
    printf 'Patterns     : %s\n' "$(wrap_list '' 62 "${PATTERNS[*]}" | sed '2,$s/^/               /')"
    ((${#EXCLUDES[@]})) && printf 'Excluding    : %s\n' "${EXCLUDES[*]}"
    if ((APPLY)); then
        printf 'Mode         : %sAPPLY -- files will be deleted%s\n' "$RD" "$CL"
    else
        printf 'Mode         : DRY RUN -- nothing will change (pass --yes to apply)\n'
    fi

    print_list 'Rotated log archives to remove' DEL_PATHS DEL_BYTES
    if ((DO_TRUNCATE)); then
        print_list "Live logs to truncate (larger than $(human_bytes "$TRUNCATE_MIN_BYTES"))" \
            TRUNC_PATHS TRUNC_BYTES
    fi

    printf '\nsystemd journal:\n'
    if journal_available; then
        printf '  current on disk : %s\n' "$(human_bytes "$JOURNAL_BEFORE")"
        printf '  vacuum target   : keep %s and %s\n' "$JOURNAL_KEEP_SIZE" "$JOURNAL_KEEP_TIME"
        printf '  note            : journalctl --vacuum-* removes archived journal\n'
        printf '                    files only; the active file is never removed,\n'
        printf '                    so expect to reclaim less than the total above.\n'
    elif ((!DO_JOURNAL)); then
        printf '  skipped (--no-journal)\n'
    elif ! command -v journalctl >/dev/null 2>&1; then
        printf '  skipped (journalctl not installed)\n'
    else
        printf '  skipped (no journal directory on this host)\n'
    fi

    if ((UNREADABLE)); then
        printf '\n'
        log WARN "$UNREADABLE path(s) unreadable during the scan; run as root for a full report."
    fi
}

report_result() {
    printf '\nSummary:\n'
    if ((APPLY)); then
        printf '  Archives removed  : %d file(s), %s\n' \
            "$REMOVED_COUNT" "$(human_bytes "$REMOVED_BYTES")"
        if ((DO_TRUNCATE)); then
            printf '  Live logs cleared : %d file(s), %s\n' \
                "$TRUNCATED_COUNT" "$(human_bytes "$TRUNCATED_BYTES")"
        fi
        if ((JOURNAL_DONE)); then
            local delta=$((JOURNAL_BEFORE - JOURNAL_AFTER))
            ((delta < 0)) && delta=0
            printf '  Journal reclaimed : %s (now %s)\n' \
                "$(human_bytes "$delta")" "$(human_bytes "$JOURNAL_AFTER")"
        fi
        printf '  Failures          : %d\n' "$ERRORS"
    else
        printf '  Archives to remove: %d file(s), %s\n' \
            "${#DEL_PATHS[@]}" "$(human_bytes "$DEL_TOTAL")"
        if ((DO_TRUNCATE)); then
            printf '  Live logs to clear: %d file(s), %s\n' \
                "${#TRUNC_PATHS[@]}" "$(human_bytes "$TRUNC_TOTAL")"
        fi
        printf '  Nothing was changed. Re-run with --yes to apply.\n'
    fi
    printf '\n'
    printf 'Space held open by a running process is not released until that\n'
    printf 'process closes the file, so df may lag these numbers.\n'
}

# --- Lifecycle ---------------------------------------------------------------

on_exit() {
    local rc=$?
    trap - EXIT INT TERM HUP
    if [[ -n $TMP_DIR && -d $TMP_DIR ]]; then
        rm -rf -- "${TMP_DIR:?}"
    fi
    if ((LOCK_HELD)); then
        exec 9>&-
    fi
    exit "$rc"
}

on_signal() {
    log WARN 'Interrupted'
    exit "$EX_INTERRUPT"
}

# --- Main --------------------------------------------------------------------

main() {
    parse_args "$@"
    setup_color

    # Armed before preflight, because preflight is what creates TMP_DIR: a
    # signal arriving in between would otherwise leave the directory behind and
    # exit with bash's own code instead of 130.
    trap on_exit EXIT
    trap on_signal INT TERM HUP

    preflight
    acquire_lock

    scan_rotated
    scan_active
    if journal_available; then
        JOURNAL_BEFORE=$(journal_bytes)
    fi

    report_plan

    if ((APPLY)); then
        printf '\n'
        remove_files
        truncate_files
        if journal_available; then
            # No `|| true` here on purpose. There is no `set -e` in this script,
            # so a non-zero return is not fatal, and vacuum_journal has already
            # logged and counted the failure into ERRORS by the time it returns.
            # Appending `|| true` would only hide that from the next reader.
            vacuum_journal
        fi
    fi

    report_result

    ((ERRORS == 0)) || return "$EX_FAIL"
    return 0
}

main "$@"
