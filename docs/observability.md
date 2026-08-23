# Shipping logs and metrics

Any script that sources [`lib/lzc-obs.sh`](../lib/lzc-obs.sh) can report itself
to a remote collector. Nothing is sent unless you configure an endpoint, and
shipping never changes what a script does or what it returns.

## Quick start

```bash
export LZC_LOGS_URL=http://logs.example:9428/insert/jsonline
export LZC_METRICS_URL=http://metrics.example:8428/api/v1/import/prometheus
sudo -E lzc-update-lxcs --cluster --yes
```

## Supported collectors

| Target | `LZC_LOGS_FORMAT` | URL to use |
| --- | --- | --- |
| VictoriaLogs | `jsonline` (default) | `http://HOST:9428/insert/jsonline` |
| Grafana Loki | `loki` | `http://HOST:3100/loki/api/v1/push` |
| Elasticsearch / OpenSearch | `elasticsearch` | `http://HOST:9200/_bulk` |

| Target | `LZC_METRICS_FORMAT` | URL to use |
| --- | --- | --- |
| VictoriaMetrics | `prometheus` (default) | `http://HOST:8428/api/v1/import/prometheus` |
| Prometheus Pushgateway | `pushgateway` | `http://HOST:9091` (the path is appended) |

For VictoriaLogs the `_stream_fields=job,instance` parameter is appended
automatically unless your URL already sets it.

## What gets sent

Logs are one JSON object per line, tagged with `job` and `instance`:

```json
{"_time":"2026-08-15T03:00:12Z","_msg":"Container 101 (db) updated","level":"SUCCESS","job":"update-lxcs","instance":"pve1"}
```

Metrics use a `state` label rather than a separate metric name per outcome, so a
single query covers a whole fleet:

```
lzc_script_success{job="update-lxcs",instance="pve1"} 0
lzc_script_exit_code{job="update-lxcs",instance="pve1"} 1
lzc_script_duration_seconds{job="update-lxcs",instance="pve1"} 412
lzc_script_last_run_timestamp_seconds{job="update-lxcs",instance="pve1"} 1786746795
lzc_lxc_containers{job="update-lxcs",instance="pve1",state="updated"} 12
lzc_lxc_containers{job="update-lxcs",instance="pve1",state="failed"} 1
```

`lzc_script_*` come from every instrumented script. Anything else is
script-specific and documented in that script's README.

Useful queries:

```promql
# anything that failed in the last day
lzc_script_success == 0

# a scheduled job that stopped running at all
time() - lzc_script_last_run_timestamp_seconds > 86400
```

## Settings

| Variable | Meaning |
| --- | --- |
| `LZC_LOGS_URL` | Log ingestion URL. Unset disables log shipping. |
| `LZC_METRICS_URL` | Metric ingestion URL. Unset disables metric shipping. |
| `LZC_LOGS_FORMAT` | `jsonline`, `loki`, `elasticsearch`. |
| `LZC_METRICS_FORMAT` | `prometheus`, `pushgateway`. |
| `LZC_OBS_JOB` | Job label. Defaults to the script's name. |
| `LZC_OBS_INSTANCE` | Instance label. Defaults to the short hostname. |
| `LZC_OBS_LABELS` | Extra labels applied to both, `env=home,site=hel1`. |
| `LZC_OBS_TENANT` | VictoriaLogs `AccountID:ProjectID`, e.g. `1:0`. |
| `LZC_OBS_TOKEN_ENV` | **Name** of the variable holding a bearer token. |
| `LZC_OBS_USER`, `LZC_OBS_PASSWORD_ENV` | Basic auth; again the variable *name*. |
| `LZC_OBS_TIMEOUT`, `LZC_OBS_CONNECT_TIMEOUT` | Per-request limits (10s, 5s; minimum 1). |
| `LZC_OBS_RETRIES` | Retries per request (1; minimum 0). |
| `LZC_OBS_INSECURE` | Accept self-signed TLS (off). |
| `LZC_OBS_BUFFER` | Log lines buffered before a flush (500; minimum 1). |
| `LZC_OBS_DEBUG` | Print payloads instead of sending them (off). |

The booleans accept `1/true/yes/on` and `0/false/no/off`, case-insensitively;
the numeric ones accept a whole number. A value that is neither prints a
warning naming the variable and falls back to the default in the table.

This is the one place in the repository where a bad setting does **not** exit
`2`. Everywhere else, an unparseable value is a usage error and the script
refuses to run. Here it cannot be: the library is loaded inside root
maintenance scripts, and a typo in a telemetry variable must not be able to
fail a run that would otherwise have succeeded.

## Credentials

`LZC_OBS_TOKEN_ENV` takes the **name** of a variable, never the secret:

```bash
export VL_TOKEN='...'                 # the secret, only in the environment
export LZC_OBS_TOKEN_ENV=VL_TOKEN     # the name, safe to commit to a cron file
```

The token reaches `curl` through a mode-0600 config file that is deleted when
the script exits. It is never passed as a command-line argument, because
process arguments are readable by every user on the machine via `/proc`.

Use `LZC_OBS_DEBUG=1` to see exactly what would be sent without sending it, and
without a token being involved at all.

## Failure behaviour

An unreachable collector produces **one** warning line on stderr and the script
carries on. It does not retry for minutes, does not change the exit code, and
does not repeat the warning for every batch. Observability that can break the
thing it observes is worse than no observability.

That holds under `set -e` too, which is the part that is easy to get wrong.
Every `obs_*` entry point returns 0, and every `curl` inside them is `|| true`
at the call site — not merely swallowed by a `return 0` at the end of the
function, because `set -e` aborts at the failing command itself and never
reaches it. A dead collector cannot take a `set -Eeuo pipefail` script down
with it.

## Adding it to your own script

```bash
# Fallback no-ops so every call below is safe when the library is absent.
obs_init() { :; }; obs_log() { :; }; obs_metric() { :; }; obs_finish() { :; }

for lib in "${LZC_LIB:-}" /usr/local/lib/lzc/lzc-obs.sh /usr/lib/lzc/lzc-obs.sh; do
    [[ -n $lib && -r $lib ]] && { . "$lib"; break; }
done
obs_init my-script

obs_log INFO "starting"          # buffered, flushed at the end
obs_metric my_thing_total 42 state=ok
trap 'obs_finish $?' EXIT        # emits run metrics and flushes
```
