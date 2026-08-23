# Proxmox VE LXC Updater

`update-lxcs.sh` updates the packages inside every LXC container on a Proxmox VE
node, or across every node in a cluster. It runs interactively or fully
unattended, keeps going when a single container fails, and reports what broke.

Supported guests: Debian/Ubuntu/Devuan, RHEL/Fedora/Rocky/Alma, Alpine, Arch,
openSUSE. Containers whose `ostype` is `unmanaged` are identified by reading
`/etc/os-release` from inside the guest.

## Requirements

Runs as root on a Proxmox VE node. Needs `pct`, `timeout`, `flock`, and — for
cluster mode — `ssh`. `whiptail` is optional and only used for the interactive
picker.

## Running it

### From a checkout

```bash
sudo ./update-lxcs.sh              # interactive
sudo ./update-lxcs.sh -y           # unattended
sudo ./update-lxcs.sh --cluster    # every node in the cluster
```

### From the network

Fetch, verify, then run. Two things matter: pin to a **commit SHA**, and check
the hash before executing.

```bash
REV=<40-char-commit-sha>
SUM=<sha256-of-that-file>
URL=https://raw.githubusercontent.com/Lazarev-Cloud/Scripts/$REV/linux/proxmox/ve/update-lxcs.sh

curl -fsSL --proto '=https' --tlsv1.2 -o /tmp/update-lxcs.sh "$URL" \
  && echo "$SUM  /tmp/update-lxcs.sh" | sha256sum -c - \
  && sudo bash /tmp/update-lxcs.sh --cluster
```

Produce the two values from a checkout with:

```bash
git rev-parse HEAD
sha256sum linux/proxmox/ve/update-lxcs.sh
```

A branch name such as `refs/heads/main` is not a pin — it means "whatever was
pushed most recently", executed as root. A tag is not a pin either, because a
tag can be moved. A commit SHA is content-addressed and cannot be changed.

### The one-liner

If you want a single command, this is the shape to use:

```bash
s=$(curl -fsSL --proto '=https' --tlsv1.2 \
  "https://raw.githubusercontent.com/Lazarev-Cloud/Scripts/<SHA>/linux/proxmox/ve/update-lxcs.sh") \
  && [ -n "$s" ] && bash -c "$s" -- --cluster --yes
```

The `&& [ -n "$s" ]` is not decoration. Without it, a failed download leaves an
empty string, `bash -c ""` exits 0, and the run reports success while having
done nothing at all.

Note the `--` before the flags: `bash -c "$script" arg1 arg2` assigns `arg1` to
`$0`, so the first real argument is swallowed unless a placeholder precedes it.
Setting `LZC_UPDATE_LXCS_*` environment variables avoids the problem entirely:

```bash
LZC_UPDATE_LXCS_CLUSTER=1 LZC_UPDATE_LXCS_YES=1 bash -c "$s"
```

## Options

| Flag | Environment variable | Meaning |
| --- | --- | --- |
| `-y, --yes` | `LZC_UPDATE_LXCS_YES=1` | Unattended; no prompts. Required for cron. |
| `-n, --dry-run` | — | Report the plan, change nothing. |
| `-e, --exclude IDS` | `LZC_UPDATE_LXCS_EXCLUDE` | Skip these CT IDs. |
| `-i, --include IDS` | `LZC_UPDATE_LXCS_INCLUDE` | Update only these CT IDs. |
| `--skip-stopped` | `LZC_UPDATE_LXCS_SKIP_STOPPED=1` | Leave stopped containers alone. |
| `--timeout SECONDS` | `LZC_UPDATE_LXCS_UPDATE_TIMEOUT` | Per-container update timeout (1800). |
| `--retries N` | `LZC_UPDATE_LXCS_RETRIES` | Attempts per container (2). |
| `--log-file PATH` | `LZC_UPDATE_LXCS_LOG` | Log file (`/var/log/lxc-updater.log`). |
| `--color WHEN` | — | `auto`, `always`, `never`. |
| `-c, --cluster` | `LZC_UPDATE_LXCS_CLUSTER=1` | All nodes in the cluster. Implies `-y`. |
| `--nodes LIST` | `LZC_UPDATE_LXCS_NODES` | Explicit node names instead of discovery. |
| `--local-only` | — | Force single-node operation. |
| `--ssh-user USER` | `LZC_UPDATE_LXCS_SSH_USER` | SSH user for remote nodes (`root`). |

### Tunables with no flag

Environment-only, all seconds unless noted, all with a minimum of 1 except
`RETRY_DELAY` (minimum 0). Defaults in brackets.

| Variable | Meaning |
| --- | --- |
| `LZC_UPDATE_LXCS_LOCK` | Lock file [`/run/lock/lxc-updater.lock`]. |
| `LZC_UPDATE_LXCS_LOG_MAX_BYTES` | Rotate the log once it exceeds this [5242880]. |
| `LZC_UPDATE_LXCS_START_TIMEOUT` | Wait for a started container to become ready [60]. |
| `LZC_UPDATE_LXCS_READY_PROBE_TIMEOUT` | Each individual readiness probe [5]. |
| `LZC_UPDATE_LXCS_READY_POLL_INTERVAL` | Gap between readiness probes [2]. |
| `LZC_UPDATE_LXCS_SHUTDOWN_TIMEOUT` | Graceful shutdown before a forced stop [60]. |
| `LZC_UPDATE_LXCS_PROBE_TIMEOUT` | In-guest probes: distro detection, `df` [20]. |
| `LZC_UPDATE_LXCS_RETRY_DELAY` | Pause between update attempts [10]. |
| `LZC_UPDATE_LXCS_SSH_TIMEOUT` | SSH connect timeout [15]. |
| `LZC_UPDATE_LXCS_SSH_OPTS` | Extra `ssh` options, whitespace separated []. |

In a **file-mode** cluster run these apply to the node you launch from, not to
the remote nodes: only `--timeout`, `--retries`, `--exclude`, `--include`,
`--skip-stopped` and `--dry-run` travel over SSH as flags. Set them in the
remote environment, or on each node, if they need to apply fleet-wide.
| `--logs-url URL` | `LZC_LOGS_URL` | Ship structured logs to a collector. |
| `--metrics-url URL` | `LZC_METRICS_URL` | Ship run metrics to a collector. |

By default a stopped container is started, updated, and returned to stopped.

Templates are skipped and counted separately — there is nothing to patch in one.
A container locked by another PVE task is different: it is reported as a
**failure**, because it was scheduled for patching and did not get patched. See
[Notes and limits](#notes-and-limits) if a nightly run keeps colliding with your
backup window.

## Cluster mode

Node names come from `pvecm nodes`, falling back to `/etc/pve/nodes` when
`pvecm` reports nothing. The discovered list is always logged — check it, since
the fallback also lists nodes that were removed from the cluster. Override with
`--nodes`.

Remote nodes are handled over SSH, relying on the passwordless root trust that
`pvecm` sets up between cluster members. The initiating node sends **its own
copy of the script** down the SSH pipe; remote nodes never re-download anything,
so every node runs identical code and there is only one artifact to verify.
That holds even when the script was piped in from the network and has no file on
disk. Nodes are processed in sequence, each keeping its own log and its own lock.

VMIDs are unique cluster-wide, so `--exclude` and `--include` work across nodes.

## Exit status

The [repo-wide table](../../../docs/exit-codes.md) applies:

| Code | Meaning |
| --- | --- |
| 0 | Everything selected was updated or deliberately skipped. |
| 1 | A container failed, or a cluster node could not be reached. |
| 2 | Usage error. |
| 3 | Not a Proxmox VE node, or a required tool is missing. |
| 4 | Not running as root. |
| 5 | Confirmation needed, but there is no terminal and `--yes` was not given. |
| 75 | Another instance holds the lock. Try again later. |
| 130 | Interrupted. |

Failed containers and unreachable nodes share exit 1. To tell them apart in
monitoring, use the `lzc_lxc_nodes{state="failed"}` metric rather than reading
the exit status.

## Shipping logs and metrics

Set an endpoint and the run reports itself to VictoriaLogs, Loki, VictoriaMetrics
or a Pushgateway. Nothing is sent unless you configure a URL.

```bash
sudo ./update-lxcs.sh --cluster \
  --logs-url    http://logs.example:9428/insert/jsonline \
  --metrics-url http://metrics.example:8428/api/v1/import/prometheus
```

Logs arrive as one JSON object per line, tagged `job` and `instance`, with
`_stream_fields=job,instance` appended automatically for VictoriaLogs:

```json
{"_time":"2026-08-15T03:00:12Z","_msg":"Container 101 (db) updated","level":"SUCCESS","job":"update-lxcs","instance":"pve1"}
```

Metrics use a `state` label rather than six metric names, so one query covers
the whole fleet:

```
lzc_lxc_containers{job="update-lxcs",instance="pve1",state="updated"} 12
lzc_lxc_containers{job="update-lxcs",instance="pve1",state="failed"} 1
lzc_script_success{job="update-lxcs",instance="pve1"} 0
lzc_script_duration_seconds{job="update-lxcs",instance="pve1"} 412
```

In cluster mode every node reports under its own `instance` label. The library
and its settings travel to each node inside the SSH stream, so remote nodes ship
telemetry without needing anything installed.

Common settings (see `lib/lzc-obs.sh` for the full list):

| Variable | Meaning |
| --- | --- |
| `LZC_LOGS_FORMAT` | `jsonline` (default), `loki`, `elasticsearch` |
| `LZC_METRICS_FORMAT` | `prometheus` (default), `pushgateway` |
| `LZC_OBS_JOB` / `LZC_OBS_INSTANCE` | Override the job and instance labels. |
| `LZC_OBS_LABELS` | Extra labels, `env=home,site=hel1`. |
| `LZC_OBS_TENANT` | VictoriaLogs `AccountID:ProjectID`, e.g. `1:0`. |
| `LZC_OBS_TOKEN_ENV` | **Name** of the env var holding a bearer token. |
| `LZC_OBS_DEBUG` | `1` prints payloads instead of sending them. |

`LZC_OBS_TOKEN_ENV` takes the *name* of a variable, never the secret itself:

```bash
export VL_TOKEN='...'                 # the secret, only in the environment
export LZC_OBS_TOKEN_ENV=VL_TOKEN     # the name, safe to put in cron
```

The token is passed to `curl` through a mode-0600 config file that is deleted on
exit, so it never appears in the process list where any local user could read it.

Shipping is best-effort and never changes the outcome of a run: an unreachable
collector produces one warning line and the update proceeds normally.

## Scheduling

```
# /etc/cron.d/lxc-updater — Sunday 03:00, whole cluster, from one node only
0 3 * * 0 root /usr/local/sbin/update-lxcs.sh --cluster --exclude 100,101
```

Concurrent runs on the same node are refused via `flock` on
`/run/lock/lxc-updater.lock`. The log rotates once past 5 MB.

## Notes and limits

- A container held by a running backup, snapshot or migration cannot be updated,
  and is reported as a failure rather than passed over quietly. If a scheduled
  run keeps colliding with `vzdump`, move the schedule out of the backup window
  or `--exclude` the containers concerned — the alternative, treating "busy" as
  success, hides a container that is silently never patched.
- An LXC guest shares the host kernel, so "restart advised" means services and
  libraries were replaced, not that a new kernel is waiting.
- Reboot detection is reliable on Debian/Ubuntu (`/run/reboot-required`) and on
  RHEL only when `needs-restarting` is installed (`dnf-utils`). Arch, Alpine and
  openSUSE have no dependable indicator and are reported as unknown rather than
  guessed.
- There is no snapshot or rollback. If you want one, take it before the run.
- The script does not update the Proxmox host itself, or any VMs.
