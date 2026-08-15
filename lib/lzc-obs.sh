#!/usr/bin/env bash
#
# Shared observability helpers: ship structured logs and run metrics from a
# maintenance script to a remote collector.
#
# License: MIT
# Origin:  https://github.com/Lazarev-Cloud/Scripts
#
# This file is sourced, never executed. It defines obs_* functions and touches
# nothing else, so a script that sources it keeps full control of its own flow.
#
# Design rules this file obeys, because it runs inside root maintenance scripts:
#   * Shipping NEVER changes the outcome of the calling script. Every network
#     path is failure-tolerant and reports at most a warning.
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
#   LZC_OBS_TIMEOUT     Per-request timeout in seconds (10).
#   LZC_OBS_INSECURE    1 to accept self-signed TLS.
#   LZC_OBS_BUFFER      Buffered log lines before an automatic flush (500).
#   LZC_OBS_DEBUG       1 to print the payloads instead of sending them.

# Guard against double-sourcing.
[[ -n ${_LZC_OBS_LOADED:-} ]] && return 0
_LZC_OBS_LOADED=1

LZC_LOGS_URL="${LZC_LOGS_URL:-}"
LZC_LOGS_FORMAT="${LZC_LOGS_FORMAT:-jsonline}"
LZC_METRICS_URL="${LZC_METRICS_URL:-}"
LZC_METRICS_FORMAT="${LZC_METRICS_FORMAT:-prometheus}"
LZC_OBS_JOB="${LZC_OBS_JOB:-}"
LZC_OBS_INSTANCE="${LZC_OBS_INSTANCE:-}"
LZC_OBS_LABELS="${LZC_OBS_LABELS:-}"
LZC_OBS_TIMEOUT="${LZC_OBS_TIMEOUT:-10}"
LZC_OBS_RETRIES="${LZC_OBS_RETRIES:-1}"
LZC_OBS_CONNECT_TIMEOUT="${LZC_OBS_CONNECT_TIMEOUT:-5}"
LZC_OBS_INSECURE="${LZC_OBS_INSECURE:-0}"
LZC_OBS_BUFFER="${LZC_OBS_BUFFER:-500}"
LZC_OBS_DEBUG="${LZC_OBS_DEBUG:-0}"

_obs_log_buf=''
_obs_metric_buf=''
_obs_buffered=0
_obs_auth_cfg=''
_obs_started=0
_obs_disabled=0
_obs_warned=0

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

_obs_now_rfc3339() {
    date -u '+%Y-%m-%dT%H:%M:%SZ'
}

_obs_epoch() {
    date -u '+%s'
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
    obs_enabled || return 0

    [[ -n $LZC_OBS_JOB ]] || LZC_OBS_JOB=${1:-lzc-script}
    [[ -n $LZC_OBS_INSTANCE ]] || LZC_OBS_INSTANCE=$(hostname -s 2>/dev/null || hostname)

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
_obs_setup_auth() {
    local token='' password=''
    [[ -n ${LZC_OBS_TOKEN_ENV:-} ]] && token=${!LZC_OBS_TOKEN_ENV:-}
    [[ -n ${LZC_OBS_PASSWORD_ENV:-} ]] && password=${!LZC_OBS_PASSWORD_ENV:-}
    [[ -n $token || -n $password ]] || return 0

    _obs_auth_cfg=$(mktemp 2>/dev/null) || {
        _obs_warn "cannot create a temp file for credentials; shipping unauthenticated"
        _obs_auth_cfg=''
        return 0
    }
    chmod 600 "$_obs_auth_cfg" 2>/dev/null || true

    if [[ -n $token ]]; then
        printf 'header = "Authorization: Bearer %s"\n' "$token" >"$_obs_auth_cfg"
    else
        printf 'user = "%s:%s"\n' "${LZC_OBS_USER:-}" "$password" >"$_obs_auth_cfg"
    fi
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
        --connect-timeout "$LZC_OBS_CONNECT_TIMEOUT"
        --max-time "$LZC_OBS_TIMEOUT"
        --retry "$LZC_OBS_RETRIES" --retry-delay 1
        -X POST -H "Content-Type: $ctype" --data-binary @-)

    ((LZC_OBS_INSECURE)) && cmd+=(--insecure)
    [[ -n $_obs_auth_cfg ]] && cmd+=(--config "$_obs_auth_cfg")

    if [[ -n ${LZC_OBS_TENANT:-} ]]; then
        cmd+=(-H "AccountID: ${LZC_OBS_TENANT%%:*}")
        [[ $LZC_OBS_TENANT == *:* ]] && cmd+=(-H "ProjectID: ${LZC_OBS_TENANT##*:}")
    fi

    cmd+=("$url")

    if ((LZC_OBS_DEBUG)); then
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

    ((_obs_buffered >= LZC_OBS_BUFFER)) && obs_flush_logs
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

    case $LZC_LOGS_FORMAT in
        jsonline)
            _obs_post "$(_obs_logs_url)" 'application/stream+json' "$payload"
            ;;
        elasticsearch)
            local bulk='' l
            while IFS= read -r l; do
                [[ -n $l ]] && bulk+='{"create":{}}'$'\n'"$l"$'\n'
            done <<<"$payload"
            _obs_post "$LZC_LOGS_URL" 'application/json' "$bulk"
            ;;
        loki)
            _obs_post "$LZC_LOGS_URL" 'application/json' "$(_obs_loki_payload "$payload")"
            ;;
        *)
            _obs_warn "unknown LZC_LOGS_FORMAT '$LZC_LOGS_FORMAT'; expected jsonline, elasticsearch or loki"
            return 1
            ;;
    esac
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

    _obs_post "$url" 'text/plain' "$payload"
}

# --- Run summary -------------------------------------------------------------

# obs_finish <exit_code> — emits standard run metrics, then flushes everything.
# Safe to call from an EXIT trap.
obs_finish() {
    obs_enabled || return 0
    local rc=${1:-0} now
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
