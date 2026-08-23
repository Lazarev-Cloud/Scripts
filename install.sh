#!/usr/bin/env bash
#
# Installs the Linux scripts in this repository as ordinary commands.
#
# License: MIT
# Origin:  https://github.com/Lazarev-Cloud/Scripts
#
# Linear installer: any failure should stop it before it leaves a half-installed
# tree behind, so `set -e` is the right error model here. This is the opposite
# choice from the batch scripts, which must survive individual failures.
set -euo pipefail

readonly SCRIPT_NAME='Lazarev Cloud Scripts installer'
readonly SCRIPT_VERSION='1.0'

readonly EX_FAIL=1 EX_USAGE=2 EX_PREREQ=3 EX_NOROOT=4 EX_NOCONFIRM=5

PREFIX="${LZC_INSTALL_PREFIX:-/usr/local}"
BIN_DIR=''
LIB_DIR=''
COMPLETION_DIR="${LZC_INSTALL_COMPLETION_DIR:-}"
ASSUME_YES="${LZC_INSTALL_YES:-0}"
DRY_RUN=0
UNINSTALL=0
USE_COLOR=auto
SOURCE_DIR=''

YW='' RD='' GN='' CL=''

# Every Linux script this installer knows about, as "relative/path:command-name".
readonly SCRIPTS=(
    'linux/clean_logs/clean_logs.sh:lzc-clean-logs'
    'linux/fix_apt_lock/fix_apt_lock.sh:lzc-fix-apt-lock'
    'linux/fix_broken_packages/fix_broken_packages.sh:lzc-fix-broken-packages'
    'linux/fix_dnf_lock/fix_dnf_lock.sh:lzc-fix-dnf-lock'
    'linux/fix_permissions/fix_permissions.sh:lzc-fix-permissions'
    'linux/maintenance/maintenance.sh:lzc-maintenance'
    'linux/network_restart/network_restart.sh:lzc-network-restart'
    'linux/proxmox/ve/update-lxcs.sh:lzc-update-lxcs'
    'linux/update_upgrade/update_upgrade.sh:lzc-update-upgrade'
)

setup_color() {
    if [[ $USE_COLOR == never ]] ||
        { [[ $USE_COLOR == auto ]] && { [[ -n ${NO_COLOR:-} ]] || [[ ! -t 1 ]]; }; }; then
        return
    fi
    YW=$'\033[33m' RD=$'\033[01;31m' GN=$'\033[1;92m' CL=$'\033[m'
}

info() { printf '%s\n' "$*"; }
warn() { printf '%s[Warning]%s %s\n' "$YW" "$CL" "$*" >&2; }
ok() { printf '%s[OK]%s %s\n' "$GN" "$CL" "$*"; }

die() {
    local code=$1
    shift
    printf '%s[Error]%s %s\n' "$RD" "$CL" "$*" >&2
    exit "$code"
}

usage() {
    cat <<EOF
$SCRIPT_NAME v$SCRIPT_VERSION

Installs the Linux scripts as lzc-* commands, plus the shared observability
library and bash completion.

Usage:
  ./install.sh [options]

Options:
  -y, --yes            Do not prompt.
  -n, --dry-run        Show what would happen; change nothing.
      --prefix PATH    Install prefix (default: $PREFIX).
                       Binaries go to PREFIX/sbin, the library to PREFIX/lib/lzc.
      --uninstall      Remove everything this installer created.
      --color WHEN     auto | always | never.
  -h, --help           Show this help.
  -V, --version        Show the version.

Environment:
  LZC_INSTALL_PREFIX          Same as --prefix.
  LZC_INSTALL_YES             Same as --yes. Accepts 1/true/yes/on.
  LZC_INSTALL_COMPLETION_DIR  Override the bash-completion directory.

Installed commands:
$(printf '  %s\n' "${SCRIPTS[@]#*:}")

Exit status:
  0 success   2 usage error   3 missing prerequisite   4 not root
  5 confirmation needed but no terminal

This installer only copies files that are already on this machine. It never
downloads anything. To install from the network, fetch a pinned commit first --
see docs/curl-bash.md.
EOF
}

normalise_bool() {
    local name=$1 value
    case ${!name,,} in
        1 | true | yes | on) value=1 ;;
        0 | false | no | off | '') value=0 ;;
        *) die "$EX_USAGE" "$name must be true or false, got '${!name}'" ;;
    esac
    printf -v "$name" '%s' "$value"
}

parse_args() {
    while (($#)); do
        case $1 in
            -y | --yes) ASSUME_YES=1 ;;
            -n | --dry-run) DRY_RUN=1 ;;
            --uninstall) UNINSTALL=1 ;;
            --prefix)
                [[ $# -ge 2 ]] || die "$EX_USAGE" "--prefix requires a path"
                PREFIX=$2
                shift
                ;;
            --color)
                [[ $# -ge 2 ]] || die "$EX_USAGE" "--color requires auto, always or never"
                USE_COLOR=$2
                shift
                ;;
            -h | --help)
                usage
                exit 0
                ;;
            -V | --version)
                printf '%s v%s\n' "$SCRIPT_NAME" "$SCRIPT_VERSION"
                exit 0
                ;;
            --) shift ;;
            *) die "$EX_USAGE" "Unknown option: $1 (try --help)" ;;
        esac
        shift
    done

    [[ $USE_COLOR =~ ^(auto|always|never)$ ]] ||
        die "$EX_USAGE" "--color must be auto, always or never"
    normalise_bool ASSUME_YES

    [[ $PREFIX == /* ]] || die "$EX_USAGE" "--prefix must be an absolute path, got '$PREFIX'"
    BIN_DIR="$PREFIX/sbin"
    LIB_DIR="$PREFIX/lib/lzc"
    [[ -n $COMPLETION_DIR ]] || COMPLETION_DIR="$PREFIX/share/bash-completion/completions"
}

# The repository root, resolved from this script's own location. Running the
# installer from a pipe leaves it with no source tree to copy, which is a clear
# error rather than something to guess at.
resolve_source() {
    local self=${BASH_SOURCE[0]:-}
    [[ -n $self && -r $self ]] ||
        die "$EX_PREREQ" "Run this from a checkout: it installs files from the repository, and there is none when piped in."
    SOURCE_DIR=$(cd "$(dirname "$self")" && pwd)
    [[ -d $SOURCE_DIR/linux && -r $SOURCE_DIR/lib/lzc-obs.sh ]] ||
        die "$EX_PREREQ" "$SOURCE_DIR does not look like the Scripts repository."
}

preflight() {
    # A dry run writes nothing, so it stays usable without sudo -- previewing
    # what an installer will do should not itself require privilege.
    if ((!DRY_RUN)); then
        [[ $EUID -eq 0 ]] ||
            die "$EX_NOROOT" "This installer must be run as root (writes to $PREFIX)."
    fi
    if ((!ASSUME_YES && !DRY_RUN)); then
        [[ -t 0 && -t 1 ]] ||
            die "$EX_NOCONFIRM" "No terminal to confirm on. Pass --yes."
    fi
}

confirm() {
    ((ASSUME_YES || DRY_RUN)) && return 0
    local reply verb='Install'
    ((UNINSTALL)) && verb='Remove'
    read -r -p "$verb ${#SCRIPTS[@]} commands under $PREFIX? [y/N] " reply
    [[ ${reply,,} == y* ]]
}

run() {
    if ((DRY_RUN)); then
        printf '  would: %s\n' "$*"
        return 0
    fi
    "$@"
}

install_all() {
    info "Installing into $PREFIX"
    run install -d -m 0755 "$BIN_DIR" "$LIB_DIR" "$COMPLETION_DIR"

    # The library first: the scripts look for it and degrade silently if absent,
    # so installing it last would leave a window where telemetry is disabled.
    run install -m 0644 "$SOURCE_DIR/lib/lzc-obs.sh" "$LIB_DIR/lzc-obs.sh"
    ok "library  -> $LIB_DIR/lzc-obs.sh"

    local entry rel name missing=0
    for entry in "${SCRIPTS[@]}"; do
        rel=${entry%%:*}
        name=${entry#*:}
        if [[ ! -r $SOURCE_DIR/$rel ]]; then
            warn "missing from the checkout, skipped: $rel"
            missing=$((missing + 1))
            continue
        fi
        run install -m 0755 "$SOURCE_DIR/$rel" "$BIN_DIR/$name"
        ok "command  -> $BIN_DIR/$name"
    done

    write_completion

    printf '\n'
    if ((missing)); then
        warn "$missing script(s) were missing from the checkout."
    fi
    info "Done. $BIN_DIR is usually already on root's PATH; if not, add it."
    info "Every command supports --help. Start with: $(printf '%s' "${SCRIPTS[0]#*:}") --help"
    ((missing == 0))
}

write_completion() {
    local names=() entry
    for entry in "${SCRIPTS[@]}"; do names+=("${entry#*:}"); done

    if ((DRY_RUN)); then
        printf '  would: write %s/lzc\n' "$COMPLETION_DIR"
        return 0
    fi

    # Completes the long options each script advertises in --help, by asking the
    # script itself. Nothing to keep in sync by hand.
    cat >"$COMPLETION_DIR/lzc" <<'COMPLETION'
# bash completion for the lzc-* maintenance commands
_lzc_complete() {
    local cur prev
    cur=${COMP_WORDS[COMP_CWORD]}
    prev=${COMP_WORDS[COMP_CWORD-1]}

    case $prev in
        --color) COMPREPLY=($(compgen -W 'auto always never' -- "$cur")); return ;;
        --prefix|--log-file) COMPREPLY=($(compgen -f -- "$cur")); return ;;
    esac

    if [[ $cur == -* ]]; then
        local opts
        opts=$("${COMP_WORDS[0]}" --help 2>/dev/null |
            grep -oE '(^|[[:space:]])--[a-z][a-z-]*' | tr -d ' ' | sort -u)
        COMPREPLY=($(compgen -W "$opts" -- "$cur"))
    fi
}
COMPLETION
    printf 'complete -F _lzc_complete %s\n' "${names[*]}" >>"$COMPLETION_DIR/lzc"
    ok "completion -> $COMPLETION_DIR/lzc"
}

uninstall_all() {
    info "Removing from $PREFIX"
    local entry name removed=0
    for entry in "${SCRIPTS[@]}"; do
        name=${entry#*:}
        if [[ -e $BIN_DIR/$name ]]; then
            run rm -f "$BIN_DIR/$name"
            ok "removed  $BIN_DIR/$name"
            removed=$((removed + 1))
        fi
    done

    [[ -e $LIB_DIR/lzc-obs.sh ]] && { run rm -f "$LIB_DIR/lzc-obs.sh"; removed=$((removed + 1)); }
    [[ -e $COMPLETION_DIR/lzc ]] && { run rm -f "$COMPLETION_DIR/lzc"; removed=$((removed + 1)); }
    # Only if we emptied it; never recursive.
    [[ -d $LIB_DIR ]] && run rmdir --ignore-fail-on-non-empty "$LIB_DIR"

    printf '\n'
    if ((removed == 0)); then
        warn "Nothing to remove under $PREFIX."
    else
        info "Removed $removed item(s). Log files under /var/log and lock files under"
        info "/run/lock are left alone; delete them yourself if you want them gone."
    fi
    return 0
}

main() {
    parse_args "$@"
    setup_color
    resolve_source
    preflight

    ((DRY_RUN)) && info "Dry run: nothing will be written."

    confirm || {
        info "Cancelled."
        return 0
    }

    if ((UNINSTALL)); then
        uninstall_all
    else
        install_all || return "$EX_FAIL"
    fi
}

main "$@"
