#!/usr/bin/env bash
#
# Shared observability helpers: ship structured logs and run metrics from a
# maintenance script to a remote collector.
#
# License: MIT
# Origin:  https://github.com/Lazarev-Cloud/Scripts
#
# This file is sourced, never executed. It defines obs_* functions and, at
# source time, normalises its own LZC_OBS_* settings -- nothing else. A script
# that sources it keeps full control of its own flow.
#
# Design rules this file obeys, because it runs inside root maintenance scripts:
#   * Shipping NEVER changes the outcome of the calling script. Every network
#     path is failure-tolerant and reports at most a warning, and a malformed
#     setting warns and falls back to its default instead of exiting. Every
#     obs_* entry point returns 0, with one deliberate exception: obs_enabled
#     is a predicate, and returns 1 when shipping is not configured. Call it
#     as a condition, never bare. A caller under `set -e` cannot be aborted by
#     anything in here.
#   * No endpoint is hardcoded. If LZC_LOGS_URL / LZC_METRICS_URL are unset,
#     every function here is an inert no-op.
#   * Credentials are never passed on a command line. curl argv is world-visible
#     in /proc, so tokens go through a 0600 --config file that is removed on exit.
#
# Configuration (all optional):
#   LZC_LOGS_URL        Full ingestion URL.
#                       VictoriaLogs: http://HOST:9428/insert/jsonline
#                       Loki:         http://HOST:3100/loki/api/v1/push
#   LZC_LOGS_FORMAT     jsonline (default) | loki | elasticsearch
#   LZC_METRICS_URL     VictoriaMetrics: http://HOST:8428/api/v1/import/prometheus
#                       Pushgateway:     http://HOST:9091   (path is appended)
#   LZC_METRICS_FORMAT  prometheus (default) | pushgateway
#   LZC_OBS_JOB         Job label. Defaults to the calling script's basename.
#   LZC_OBS_INSTANCE    Instance label. Defaults to the hostname.
#   LZC_OBS_LABELS      Extra labels, "k=v,k2=v2". Applied to logs and metrics.
#   LZC_OBS_TOKEN_ENV   NAME of the env var holding a bearer token. Not the token.
#   LZC_OBS_USER        Username for basic auth.
#   LZC_OBS_PASSWORD_ENV NAME of the env var holding the password. Not the password.
#   LZC_OBS_TENANT      VictoriaLogs AccountID:ProjectID, e.g. "1:0".
#   LZC_OBS_TIMEOUT     Per-request timeout in seconds (10, minimum 1).
#   LZC_OBS_CONNECT_TIMEOUT  Connect timeout in seconds (5, minimum 1).
#   LZC_OBS_RETRIES     curl retry attempts per request (1, minimum 0).
#   LZC_OBS_INSECURE    Accept self-signed TLS (off).
#   LZC_OBS_BUFFER      Buffered log lines before an automatic flush (500, min 1).
#   LZC_OBS_DEBUG       Print the payloads instead of sending them (off).
#
# The numeric settings accept a whole number; the boolean ones accept
# 1/true/yes/on and 0/false/no/off, case-insensitively. Anything else warns on
# stderr and falls back to the default shown above -- see "Setting validation".

# Guard against double-sourcing.
[[ -n ${_LZC_OBS_LOADED:-} ]] && return 0
_LZC_OBS_LOADED=1

# Assigned through a helper that tolerates a readonly variable already present
# in the caller's environment. A bare assignment to a readonly name fails, and
# under a `set -e` caller using the plain sourcing snippet from
# docs/observability.md that aborts the whole script at source time -- this
# file failing closed on the caller is precisely what it must never do. A
# readonly value is already set, so keeping it is also the right outcome.
# printf -v onto a name that is readonly in the caller's environment fails, and
# a failure here would propagate the way the assignments above would have. The
# value is already fixed in that case, so keeping it is also correct.
# Writes the normalised value to a private name that logic reads, and mirrors
# it onto the public LZC_* name when that is writable. The private copy is what
# makes this safe: a caller may have made LZC_OBS_BUFFER readonly *and* invalid,
# in which case nothing can repair the public name -- and arithmetic on it would
# abort the caller with "bogus: unbound variable", which is the exact crash this
# whole validation section exists to prevent.
_obs_setpair() {
    _obs_set "$2" "$3"
    _obs_set "$1" "$3"
    return 0
}

_obs_set() {
    local decl
    # Assigning to a readonly name is a *fatal* shell error -- `|| true` does
    # not rescue it, the shell exits there and then -- so the only safe move is
    # not to assign at all. A readonly value is already fixed by the caller, so
    # leaving it is the right outcome as well as the survivable one.
    decl=$(declare -p "$1" 2>/dev/null) || decl=''
    [[ $decl =~ ^declare\ -[a-zA-Z]*r ]] && return 0
    printf -v "$1" '%s' "$2"
    return 0
}

_obs_default() {
    local name=$1 value=$2
    [[ -n ${!name:-} ]] && return 0
    _obs_set "$name" "$value"
    return 0
}

_obs_default LZC_LOGS_URL ''
_obs_default LZC_LOGS_FORMAT 'jsonline'
_obs_default LZC_METRICS_URL ''
_obs_default LZC_METRICS_FORMAT 'prometheus'
_obs_default LZC_OBS_JOB ''
_obs_default LZC_OBS_INSTANCE ''
_obs_default LZC_OBS_LABELS ''
_obs_default LZC_OBS_TIMEOUT '10'
_obs_default LZC_OBS_RETRIES '1'
_obs_default LZC_OBS_CONNECT_TIMEOUT '5'
_obs_default LZC_OBS_INSECURE '0'
_obs_default LZC_OBS_BUFFER '500'
_obs_default LZC_OBS_DEBUG '0'

_obs_log_buf=''
_obs_metric_buf=''
_obs_buffered=0
_obs_auth_cfg=''
_obs_started=0
_obs_disabled=0
_obs_warned=0
# Normalised copies of the tunables. Logic reads these, never the public LZC_*
# names, so a caller cannot make one readonly-and-invalid and take the run down.
_obs_timeout=10
_obs_connect_timeout=5
_obs_retries=1
_obs_buffer=500
_obs_insecure=0
_obs_debug=0

# --- Small utilities ---------------------------------------------------------

obs_enabled() {
    ((_obs_disabled)) && return 1
    [[ -n $LZC_LOGS_URL || -n $LZC_METRICS_URL ]]
}

_obs_warn() {
    # One single-line warning per run. A broken collector must not drown the
    # real output, and curl emits one error line per retry attempt.
    ((_obs_warned)) && return 0
    _obs_warned=1
    printf '[obs] %s\n' "$(printf '%s' "$*" | tr '\n' ' ' | tr -s ' ')" >&2
}

# Separate from _obs_warn, which is deliberately once-per-run: that budget
# exists to stop a dead collector emitting a line per retry. A bad setting is a
# fixed, tiny set that cannot flood, and silently reporting only the first of
# three typos would be worse than the noise.
_obs_config_warn() {
    printf '[obs] %s\n' "$*" >&2
}

# --- Setting validation ------------------------------------------------------
#
# Every numeric and boolean knob is normalised before anything does arithmetic
# on it. Without this, LZC_OBS_DEBUG=true reaches `(( ))` as a bare word and,
# under the `set -u` that every caller in this repository uses, aborts the
# whole maintenance run with "true: unbound variable" -- the exact failure
# CONTRIBUTING.md names, and the exact opposite of this file's first design
# rule.
#
# A bad value warns and falls back to the default rather than exiting. That is
# the one place this library deliberately differs from the scripts, which
# reject a bad setting with exit 2: a typo in a telemetry variable must never
# be able to fail a root maintenance run that would otherwise have succeeded.

_obs_norm_bool() {
    local name=$1 dest=$2 default=$3
    case ${!name:-} in
        '') _obs_setpair "$name" "$dest" "$default" ;;
        *)
            case ${!name,,} in
                1 | true | yes | on) _obs_setpair "$name" "$dest" 1 ;;
                0 | false | no | off) _obs_setpair "$name" "$dest" 0 ;;
                *)
                    _obs_config_warn "$name must be true or false, got '${!name}'; using $default"
                    _obs_setpair "$name" "$dest" "$default"
                    ;;
            esac
            ;;
    esac
}

_obs_norm_int() {
    local name=$1 dest=$2 default=$3 min=$4 value
    if [[ -z ${!name:-} ]]; then
        _obs_setpair "$name" "$dest" "$default"
        return 0
    fi
    # Bounded to nine digits, not just "digits": $((10#...)) wraps silently on
    # a value past 2^63, so a 20-digit LZC_OBS_TIMEOUT would sail through the
    # minimum-1 check as a huge positive number and hand curl an effectively
    # unlimited --max-time -- the exact outcome the minimum exists to prevent.
    if [[ ! ${!name} =~ ^[0-9]{1,9}$ ]]; then
        _obs_config_warn "$name must be a whole number, got '${!name}'; using $default"
        _obs_setpair "$name" "$dest" "$default"
        return 0
    fi
    # 10# forces base ten: a zero-padded value such as 08 is otherwise read as
    # an invalid octal literal and aborts the arithmetic.
    value=$((10#${!name}))
    if ((value < min)); then
        _obs_config_warn "$name must be at least $min, got '${!name}'; using $default"
        value=$default
    fi
    _obs_setpair "$name" "$dest" "$value"
}

# Idempotent, and called twice on purpose: once when this file is sourced, so a
# caller that never reaches obs_init is still safe, and again from obs_init, so
# a value assigned from a flag parsed after the source is normalised too. The
# second pass sees an already-normalised value and says nothing.
_obs_normalise_settings() {
    # Minimum 1 on the timeouts, not 0: curl reads 0 as "no limit", which
    # silently removes the very bound these settings exist to provide.
    _obs_norm_int LZC_OBS_TIMEOUT _obs_timeout 10 1
    _obs_norm_int LZC_OBS_CONNECT_TIMEOUT _obs_connect_timeout 5 1
    _obs_norm_int LZC_OBS_RETRIES _obs_retries 1 0
    _obs_norm_int LZC_OBS_BUFFER _obs_buffer 500 1
    _obs_norm_bool LZC_OBS_INSECURE _obs_insecure 0
    _obs_norm_bool LZC_OBS_DEBUG _obs_debug 0
}

# Both use printf's %(...)T, which is a bash builtin, rather than date(1).
# date was the last external command in here that was called unguarded, and a
# host without it -- the same minimal container the hostname fallback above
# already anticipates -- turned a successful run into exit 127 under `set -e`,
# because obs_finish runs from the caller's EXIT trap. A builtin cannot be
# missing. TZ=UTC because %(...)T formats in local time, where date -u did not.
_obs_now_rfc3339() {
    TZ=UTC printf '%(%Y-%m-%dT%H:%M:%SZ)T\n' -1
}

_obs_epoch() {
    printf '%(%s)T\n' -1
}

# Escapes a value for embedding in a JSON string.
_obs_json_escape() {
    local s=$1
    s=${s//\\/\\\\}
    s=${s//\"/\\\"}
    s=${s//$'\n'/\\n}
    s=${s//$'\r'/\\r}
    s=${s//$'\t'/\\t}
    # Strip any remaining control characters rather than emit invalid JSON.
    printf '%s' "$s" | tr -d '\000-\010\013\014\016-\037'
}

# Escapes a value for a Prometheus label.
_obs_prom_escape() {
    local s=$1
    s=${s//\\/\\\\}
    s=${s//\"/\\\"}
    s=${s//$'\n'/ }
    printf '%s' "$s"
}

# --- Setup -------------------------------------------------------------------

# obs_init [job_name]
obs_init() {
    # Before the obs_enabled check, not after: a script that sets a knob from a
    # flag it parsed after sourcing this file must still get a validated value,
    # whether or not shipping turns out to be configured.
    _obs_normalise_settings
    obs_enabled || return 0

    [[ -n $LZC_OBS_JOB ]] || LZC_OBS_JOB=${1:-lzc-script}
    # $HOSTNAME last, and it is not decoration: bash always sets it, whereas
    # both hostname calls fail together on a minimal container with no
    # net-tools and no coreutils hostname. Without the fallback the assignment
    # fails and takes a `set -e` caller with it -- and cluster mode clears
    # LZC_OBS_INSTANCE for every remote node, so that path is the common one,
    # not the exotic one.
    if [[ -z $LZC_OBS_INSTANCE ]]; then
        LZC_OBS_INSTANCE=$(hostname -s 2>/dev/null || hostname 2>/dev/null) || LZC_OBS_INSTANCE=''
        [[ -n $LZC_OBS_INSTANCE ]] || LZC_OBS_INSTANCE=${HOSTNAME:-unknown}
    fi

    if ! command -v curl >/dev/null 2>&1; then
        _obs_warn "curl not found; remote log and metric shipping disabled"
        _obs_disabled=1
        return 0
    fi

    _obs_setup_auth
    _obs_started=$(_obs_epoch)
    return 0
}

# Credentials go into a 0600 curl config file, never onto the command line.
# Reads the value of the variable *named* by $1, on stdout.
#
# The name is validated first, and that is not a formality. `${!name}` is not a
# plain lookup: bash parses the value as a variable reference, so a name that
# is not an identifier is a fatal expansion error -- `LZC_OBS_TOKEN_ENV=my-token`,
# which is exactly what someone writes by hand, kills the calling script with
# "my-token: invalid variable name" even under `set -uo pipefail`. Worse, bash
# evaluates an array subscript inside that reference, so a value of
# `x[$(rm -rf /)]` executes the substitution. This library is sourced by scripts
# running as root, and its settings arrive from cron files, unit files and MDM
# payloads; a telemetry variable must not be a code path.
_obs_env_value() {
    local name=$1
    [[ -n $name ]] || return 0
    if [[ ! $name =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
        _obs_config_warn "ignoring '$name': expected the NAME of an environment variable, not a value"
        return 0
    fi
    printf '%s' "${!name:-}"
}

_obs_setup_auth() {
    local token='' password=''
    token=$(_obs_env_value "${LZC_OBS_TOKEN_ENV:-}")
    password=$(_obs_env_value "${LZC_OBS_PASSWORD_ENV:-}")
    [[ -n $token || -n $password ]] || return 0

    _obs_auth_cfg=$(mktemp 2>/dev/null) || {
        _obs_warn "cannot create a temp file for credentials; shipping unauthenticated"
        _obs_auth_cfg=''
        return 0
    }
    chmod 600 "$_obs_auth_cfg" 2>/dev/null || true

    # Checked: an unwritable config file would otherwise leave curl reading a
    # truncated or empty one and shipping unauthenticated without saying so.
    if [[ -n $token ]]; then
        printf 'header = "Authorization: Bearer %s"\n' "$token" >"$_obs_auth_cfg" || {
            _obs_warn "cannot write the credentials file; shipping unauthenticated"
            rm -f "$_obs_auth_cfg"
            _obs_auth_cfg=''
        }
    else
        printf 'user = "%s:%s"\n' "${LZC_OBS_USER:-}" "$password" >"$_obs_auth_cfg" || {
            _obs_warn "cannot write the credentials file; shipping unauthenticated"
            rm -f "$_obs_auth_cfg"
            _obs_auth_cfg=''
        }
    fi
    return 0
}

# Call from the script's EXIT trap.
obs_cleanup() {
    [[ -n $_obs_auth_cfg ]] && rm -f "$_obs_auth_cfg"
    _obs_auth_cfg=''
    return 0
}

# --- curl plumbing -----------------------------------------------------------

# _obs_post <url> <content-type> <payload>
_obs_post() {
    local url=$1 ctype=$2 payload=$3
    # Kept deliberately impatient: a dead collector must cost the maintenance
    # run seconds, not minutes. Shipping is best-effort by design.
    local -a cmd=(curl --silent --show-error --fail
        --connect-timeout "$_obs_connect_timeout"
        --max-time "$_obs_timeout"
        --retry "$_obs_retries" --retry-delay 1
        -X POST -H "Content-Type: $ctype" --data-binary @-)

    ((_obs_insecure)) && cmd+=(--insecure)
    [[ -n $_obs_auth_cfg ]] && cmd+=(--config "$_obs_auth_cfg")

    if [[ -n ${LZC_OBS_TENANT:-} ]]; then
        cmd+=(-H "AccountID: ${LZC_OBS_TENANT%%:*}")
        [[ $LZC_OBS_TENANT == *:* ]] && cmd+=(-H "ProjectID: ${LZC_OBS_TENANT##*:}")
    fi

    cmd+=("$url")

    if ((_obs_debug)); then
        printf '[obs] POST %s (%s)\n%s\n' "$url" "$ctype" "$payload" >&2
        return 0
    fi

    local err
    if ! err=$(printf '%s' "$payload" | "${cmd[@]}" 2>&1); then
        _obs_warn "shipping to ${url%%\?*} failed: ${err:-unknown error}"
        return 1
    fi
    return 0
}

# --- Logs --------------------------------------------------------------------

# Appends _stream_fields to a VictoriaLogs URL unless the caller already set it.
_obs_logs_url() {
    local url=$LZC_LOGS_URL
    [[ $LZC_LOGS_FORMAT == jsonline ]] || {
        printf '%s' "$url"
        return
    }
    [[ $url == *_stream_fields=* ]] && {
        printf '%s' "$url"
        return
    }
    if [[ $url == *\?* ]]; then
        printf '%s&_stream_fields=job,instance' "$url"
    else
        printf '%s?_stream_fields=job,instance' "$url"
    fi
}

# obs_log <level> <message> [key=value ...]
obs_log() {
    obs_enabled || return 0
    [[ -n $LZC_LOGS_URL ]] || return 0

    local level=$1 msg=$2
    shift 2

    local line
    line=$(printf '{"_time":"%s","_msg":"%s","level":"%s","job":"%s","instance":"%s"' \
        "$(_obs_now_rfc3339)" \
        "$(_obs_json_escape "$msg")" \
        "$(_obs_json_escape "$level")" \
        "$(_obs_json_escape "$LZC_OBS_JOB")" \
        "$(_obs_json_escape "$LZC_OBS_INSTANCE")")

    local pair k v
    for pair in "$@"; do
        k=${pair%%=*}
        v=${pair#*=}
        line+=$(printf ',"%s":"%s"' "$(_obs_json_escape "$k")" "$(_obs_json_escape "$v")")
    done

    if [[ -n $LZC_OBS_LABELS ]]; then
        local -a extra
        IFS=',' read -r -a extra <<<"$LZC_OBS_LABELS"
        for pair in "${extra[@]}"; do
            [[ $pair == *=* ]] || continue
            k=${pair%%=*}
            v=${pair#*=}
            line+=$(printf ',"%s":"%s"' "$(_obs_json_escape "$k")" "$(_obs_json_escape "$v")")
        done
    fi

    line+='}'
    _obs_log_buf+="$line"$'\n'
    _obs_buffered=$((_obs_buffered + 1))

    ((_obs_buffered >= _obs_buffer)) && obs_flush_logs
    return 0
}

obs_flush_logs() {
    obs_enabled || return 0
    [[ -n $_obs_log_buf ]] || return 0

    local payload=$_obs_log_buf
    # Cleared before the POST so a failure cannot cause the same lines to be
    # retried forever by a later flush.
    _obs_log_buf=''
    _obs_buffered=0

    # Every _obs_post is `|| true`, and not only because this function returns
    # 0 below: under `set -e` -- the documented error model for the linear
    # scripts in this repository -- the shell aborts at the failing command
    # itself, long before any `return` at the end of the function is reached.
    # A dead collector must cost a warning on stderr and nothing else.
    case $LZC_LOGS_FORMAT in
        jsonline)
            _obs_post "$(_obs_logs_url)" 'application/stream+json' "$payload" || true
            ;;
        elasticsearch)
            local bulk='' l
            while IFS= read -r l; do
                [[ -n $l ]] && bulk+='{"create":{}}'$'\n'"$l"$'\n'
            done <<<"$payload"
            _obs_post "$LZC_LOGS_URL" 'application/json' "$bulk" || true
            ;;
        loki)
            _obs_post "$LZC_LOGS_URL" 'application/json' "$(_obs_loki_payload "$payload")" || true
            ;;
        *)
            _obs_warn "unknown LZC_LOGS_FORMAT '$LZC_LOGS_FORMAT'; expected jsonline, elasticsearch or loki"
            ;;
    esac

    return 0
}

# Wraps buffered NDJSON into a single Loki push request.
_obs_loki_payload() {
    local ndjson=$1 values='' l ts msg
    while IFS= read -r l; do
        [[ -n $l ]] || continue
        # Nanosecond timestamps are required by Loki; second precision is fine.
        ts="$(_obs_epoch)000000000"
        msg=$(_obs_json_escape "$l")
        values+="${values:+,}[\"$ts\",\"$msg\"]"
    done <<<"$ndjson"
    printf '{"streams":[{"stream":{"job":"%s","instance":"%s"},"values":[%s]}]}' \
        "$(_obs_json_escape "$LZC_OBS_JOB")" \
        "$(_obs_json_escape "$LZC_OBS_INSTANCE")" \
        "$values"
}

# --- Metrics -----------------------------------------------------------------

# obs_metric <name> <value> [label=value ...]
# Names should follow Prometheus conventions: base units, _seconds/_bytes
# suffixes, and no _total unless the value is a monotonic counter.
obs_metric() {
    obs_enabled || return 0
    [[ -n $LZC_METRICS_URL ]] || return 0

    local name=$1 value=$2
    shift 2

    local labels
    labels=$(printf 'job="%s",instance="%s"' \
        "$(_obs_prom_escape "$LZC_OBS_JOB")" \
        "$(_obs_prom_escape "$LZC_OBS_INSTANCE")")

    local pair k v
    for pair in "$@"; do
        [[ $pair == *=* ]] || continue
        k=${pair%%=*}
        v=${pair#*=}
        labels+=$(printf ',%s="%s"' "$k" "$(_obs_prom_escape "$v")")
    done

    if [[ -n $LZC_OBS_LABELS ]]; then
        local -a extra
        IFS=',' read -r -a extra <<<"$LZC_OBS_LABELS"
        for pair in "${extra[@]}"; do
            [[ $pair == *=* ]] || continue
            k=${pair%%=*}
            v=${pair#*=}
            labels+=$(printf ',%s="%s"' "$k" "$(_obs_prom_escape "$v")")
        done
    fi

    _obs_metric_buf+="${name}{${labels}} ${value}"$'\n'
    return 0
}

obs_flush_metrics() {
    obs_enabled || return 0
    [[ -n $_obs_metric_buf ]] || return 0

    local payload=$_obs_metric_buf
    _obs_metric_buf=''

    local url=$LZC_METRICS_URL
    if [[ $LZC_METRICS_FORMAT == pushgateway ]]; then
        # Pushgateway takes job and instance from the URL path.
        url="${url%/}/metrics/job/${LZC_OBS_JOB}/instance/${LZC_OBS_INSTANCE}"
    fi

    # Always 0, for the same reason as obs_flush_logs.
    _obs_post "$url" 'text/plain' "$payload" || true
    return 0
}

# --- Run summary -------------------------------------------------------------

# obs_finish <exit_code> — emits standard run metrics, then flushes everything.
# Safe to call from an EXIT trap.
obs_finish() {
    obs_enabled || return 0
    local rc=${1:-0} now
    # Validated for the same reason every other number here is: `$((rc == 0))`
    # on a non-numeric rc is an unbound-variable abort, and obs_finish is
    # called from EXIT traps, where the argument is whatever `$?` happened to
    # be -- or, if a caller gets it wrong, whatever it passed instead.
    [[ $rc =~ ^-?[0-9]{1,9}$ ]] || rc=0
    now=$(_obs_epoch)

    if [[ -n $LZC_METRICS_URL ]]; then
        obs_metric lzc_script_success "$((rc == 0 ? 1 : 0))"
        obs_metric lzc_script_exit_code "$rc"
        obs_metric lzc_script_last_run_timestamp_seconds "$now"
        ((_obs_started)) && obs_metric lzc_script_duration_seconds "$((now - _obs_started))"
    fi

    obs_flush_logs
    obs_flush_metrics
    obs_cleanup
    return 0
}

# The one statement this file executes at source time. It assigns nothing
# outside its own LZC_OBS_* settings, so a script that sources this library and
# never calls obs_init still cannot be killed by a mistyped telemetry variable.
#
# `|| true` because this is now the file's last statement and therefore its
# source status. update-lxcs.sh does `. "$lib" || return 0`, so a non-zero here
# would silently abandon the library it just loaded -- no OBS_LIB_PATH, no
# inlining into the cluster ssh stream, no obs_init, and no error to say so.
# It must be `|| true` rather than `return 0`: this file is also cat'd into an
# ssh stream, where a top-level `return` is an error.
_obs_normalise_settings || true
