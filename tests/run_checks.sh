#!/usr/bin/env bash
#
# Runs the checks CI runs, locally, before you push.
#
# License: MIT
# Origin:  https://github.com/Lazarev-Cloud/Scripts
#
# Error model: this script deliberately does NOT use `set -e`. It is a batch
# driver -- the whole point is to run every check and report all of them, not
# to stop at the first failure and hide the rest. Every fallible step is
# checked explicitly.
set -uo pipefail

readonly SCRIPT_NAME='Local check runner'
readonly SCRIPT_VERSION='1.0'

readonly EX_FAIL=1 EX_USAGE=2 EX_PREREQ=3

# The linter versions are read out of the workflow rather than repeated here.
# Two copies of a pinned version is one copy that goes stale, and a local run
# that quietly uses a different shellcheck than CI is worse than no local run:
# it produces a clean result that CI then contradicts.
readonly WORKFLOW='.github/workflows/lint.yml'

REPO_ROOT=''
USE_COLOR=auto
QUIET=0
YW='' RD='' GN='' BL='' CL=''
FAILED=0
RAN=0
SKIPPED=()

setup_color() {
    if [[ $USE_COLOR == never ]] ||
        { [[ $USE_COLOR == auto ]] && { [[ -n ${NO_COLOR:-} ]] || [[ ! -t 1 ]]; }; }; then
        return 0
    fi
    YW=$'\033[33m' RD=$'\033[01;31m' GN=$'\033[1;92m' BL=$'\033[36m' CL=$'\033[m'
}

info() { ((QUIET)) || printf '%s\n' "$*"; }
head_line() { ((QUIET)) || printf '\n%s== %s ==%s\n' "$BL" "$*" "$CL"; }
ok() { printf '%s[OK]%s %s\n' "$GN" "$CL" "$*"; }
warn() { printf '%s[Warning]%s %s\n' "$YW" "$CL" "$*" >&2; }
err() { printf '%s[Error]%s %s\n' "$RD" "$CL" "$*" >&2; }

die() {
    local code=$1
    shift
    err "$*"
    exit "$code"
}

usage() {
    cat <<EOF
$SCRIPT_NAME v$SCRIPT_VERSION

Runs the same checks as .github/workflows/lint.yml, plus a few CI cannot do,
against your working tree. Read-only: it changes nothing and needs no root.

Usage:
  tests/run_checks.sh [options]

Options:
  -q, --quiet          Only print failures and the summary.
      --color WHEN     auto | always | never.
  -h, --help           Show this help.
  -V, --version        Show the version.

Checks:
  bash -n              every *.sh parses
  shellcheck           every *.sh, pinned to the version $WORKFLOW uses
  python              the exporter compiles
  yaml                 every workflow and _config.yml parses
  help                 every executable script answers --help with status 0
  modes                every runnable script is committed executable
  psscriptanalyzer     every *.ps1, when pwsh is available -- indicative only,
                       because CI analyses under Windows PowerShell 5.1, which
                       is what the scripts target

A check whose tool is missing is reported as skipped, never as passed.

Exit status:
  0    every check that ran passed
  1    at least one check failed
  2    usage error
  3    not run from a checkout of this repository
EOF
}

parse_args() {
    while (($#)); do
        case $1 in
            -q | --quiet) QUIET=1 ;;
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
}

resolve_root() {
    local self=${BASH_SOURCE[0]:-}
    [[ -n $self && -r $self ]] ||
        die "$EX_PREREQ" "Run this from a checkout; it has no source tree to check when piped in."
    REPO_ROOT=$(cd "$(dirname "$self")/.." && pwd) ||
        die "$EX_PREREQ" "Cannot resolve the repository root."
    [[ -r $REPO_ROOT/$WORKFLOW ]] ||
        die "$EX_PREREQ" "$REPO_ROOT does not look like the Scripts repository ($WORKFLOW is missing)."
}

# Every *.sh, discovered exactly the way the workflow discovers them. Kept
# identical on purpose: a local run that checks a different set of files than
# CI is a local run that can pass while CI fails.
sh_files() {
    find "$REPO_ROOT" -name '*.sh' -not -path "$REPO_ROOT/.git/*" -print0
}

pinned_version() {
    sed -n "s/^[[:space:]]*$1:[[:space:]]*\"\{0,1\}\([0-9.]\{1,\}\)\"\{0,1\}[[:space:]]*$/\1/p" \
        "$REPO_ROOT/$WORKFLOW" | head -n1
}

record() {
    local status=$1 name=$2
    RAN=$((RAN + 1))
    case $status in
        pass) ok "$name" ;;
        fail)
            err "$name"
            FAILED=$((FAILED + 1))
            ;;
    esac
}

skip() {
    SKIPPED+=("$1: $2")
    warn "skipped $1 -- $2"
}

# --- Checks -------------------------------------------------------------------

check_bash_n() {
    head_line 'bash -n'
    local rc=0
    sh_files | xargs -0 -r -n1 bash -n || rc=$?
    if ((rc == 0)); then
        record pass 'bash -n'
    else
        record fail 'bash -n'
    fi
}

check_shellcheck() {
    head_line 'shellcheck'
    if ! command -v shellcheck >/dev/null 2>&1; then
        skip shellcheck 'not installed; CI will still run it'
        return 0
    fi

    local want have
    want=$(pinned_version SHELLCHECK_VERSION)
    have=$(shellcheck --version 2>/dev/null | awk '/^version:/ { print $2 }')
    if [[ -n $want && -n $have && $want != "$have" ]]; then
        # Not fatal, but said plainly: a newer shellcheck ships new checks, so a
        # clean run here does not prove a clean run in CI, and vice versa.
        warn "local shellcheck is $have, CI pins $want; findings may differ"
    fi

    local rc=0
    sh_files | xargs -0 -r shellcheck -s bash || rc=$?
    if ((rc == 0)); then
        record pass 'shellcheck'
    else
        record fail 'shellcheck'
    fi
}

check_python() {
    head_line 'python'
    local target=$REPO_ROOT/monitoring/prometheus_unified_metrics.py
    [[ -r $target ]] || {
        skip python 'exporter not present'
        return 0
    }
    if ! command -v python3 >/dev/null 2>&1; then
        skip python 'python3 not installed'
        return 0
    fi
    if python3 -m py_compile "$target"; then
        record pass 'py_compile'
    else
        record fail 'py_compile'
    fi
}

check_yaml() {
    head_line 'yaml'
    if ! command -v python3 >/dev/null 2>&1; then
        skip yaml 'python3 not installed'
        return 0
    fi
    if ! python3 -c 'import yaml' 2>/dev/null; then
        skip yaml 'PyYAML not installed'
        return 0
    fi

    local f rc=0
    while IFS= read -r f; do
        if ! python3 -c 'import sys,yaml; yaml.safe_load(open(sys.argv[1]))' "$f"; then
            err "  invalid YAML: ${f#"$REPO_ROOT"/}"
            rc=1
        fi
    done < <(find "$REPO_ROOT/.github" -name '*.yml' -o -name '*.yaml' 2>/dev/null
        [[ -r $REPO_ROOT/_config.yml ]] && printf '%s\n' "$REPO_ROOT/_config.yml")
    if ((rc == 0)); then
        record pass 'yaml'
    else
        record fail 'yaml'
    fi
}

# CI cannot do this one: it needs to actually execute each script. A --help that
# exits non-zero, or dies on an unset variable before printing anything, is the
# single most common way one of these scripts breaks without shellcheck noticing.
check_help() {
    head_line 'help'
    local f rel rc=0
    while IFS= read -r -d '' f; do
        rel=${f#"$REPO_ROOT"/}
        # lib/ holds sourced libraries, which have no command-line interface.
        [[ $rel == lib/* ]] && continue
        if ! bash "$f" --help >/dev/null 2>&1; then
            err "  --help failed: $rel"
            rc=1
        fi
    done < <(sh_files)
    if ((rc == 0)); then
        record pass '--help on every script'
    else
        record fail '--help on every script'
    fi
}

# Also beyond CI. Every README documents `./script.sh`, so a script committed
# without the executable bit is a broken instruction on a fresh clone -- which
# is exactly what happened once already.
check_modes() {
    head_line 'modes'
    if ! command -v git >/dev/null 2>&1; then
        skip modes 'git not installed'
        return 0
    fi
    if ! git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
        skip modes 'not a git working tree'
        return 0
    fi

    local mode path rc=0
    while read -r mode _ _ path; do
        [[ $path == lib/* ]] && continue
        if [[ $mode != 100755 ]]; then
            err "  not executable in git: $path (git update-index --chmod=+x '$path')"
            rc=1
        fi
    done < <(git -C "$REPO_ROOT" ls-files -s '*.sh')
    if ((rc == 0)); then
        record pass 'executable bits'
    else
        record fail 'executable bits'
    fi
}

check_psscriptanalyzer() {
    head_line 'psscriptanalyzer'
    if ! command -v pwsh >/dev/null 2>&1; then
        skip psscriptanalyzer 'pwsh not installed; CI runs this under Windows PowerShell 5.1'
        return 0
    fi
    if ! pwsh -NoProfile -Command 'if (-not (Get-Module -ListAvailable PSScriptAnalyzer)) { exit 1 }' >/dev/null 2>&1; then
        skip psscriptanalyzer 'PSScriptAnalyzer module not installed'
        return 0
    fi

    # Indicative only. pwsh 7 parses some constructs differently from Windows
    # PowerShell 5.1, which is what these scripts target and what CI analyses
    # under, so a clean result here is encouraging rather than conclusive.
    warn 'analysing under pwsh 7; CI uses Windows PowerShell 5.1, results can differ'
    local rc=0
    pwsh -NoProfile -Command "
        \$ErrorActionPreference = 'Stop'
        \$files = Get-ChildItem -Path '$REPO_ROOT' -Recurse -Filter *.ps1 -File |
            Where-Object { \$_.FullName -notmatch '[\\\\/]\.git[\\\\/]' }
        if (-not \$files) { exit 0 }
        \$findings = @()
        foreach (\$f in \$files) {
            \$findings += Invoke-ScriptAnalyzer -Path \$f.FullName -Severity Error, Warning, Information
        }
        if (\$findings.Count -gt 0) {
            \$findings | Format-Table -AutoSize RuleName, Severity, ScriptName, Line, Message |
                Out-String -Width 4096 | Write-Host
            exit 1
        }
    " || rc=$?
    if ((rc == 0)); then
        record pass 'PSScriptAnalyzer'
    else
        record fail 'PSScriptAnalyzer'
    fi
}

summary() {
    printf '\n'
    if ((${#SKIPPED[@]})); then
        local item
        warn "${#SKIPPED[@]} check(s) skipped:"
        for item in "${SKIPPED[@]}"; do printf '  %s\n' "$item" >&2; done
    fi

    if ((FAILED)); then
        err "$FAILED of $RAN check(s) failed."
        return "$EX_FAIL"
    fi
    ok "All $RAN check(s) passed."
    return 0
}

main() {
    parse_args "$@"
    setup_color
    resolve_root

    info "$SCRIPT_NAME v$SCRIPT_VERSION -- $REPO_ROOT"

    check_bash_n
    check_shellcheck
    check_python
    check_yaml
    check_help
    check_modes
    check_psscriptanalyzer

    summary
}

main "$@"
