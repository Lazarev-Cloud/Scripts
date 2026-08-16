# Host Metrics Exporter

Three files:

- `prometheus_unified_metrics.py` — a small Python exporter that serves host
  metrics over HTTP in Prometheus text format, prints them once to stdout, or
  writes them as a node_exporter textfile.
- `requirements.txt` — its pinned Python dependencies.
- `setup_prometheus_exporter.sh` — installs that exporter on a Linux host as a
  sandboxed systemd service running from its own virtual environment.

Run `python3 prometheus_unified_metrics.py --once` to see exactly which metrics
the exporter produces on your machine; that output is the authoritative list.
[The exporter](#the-exporter) documents the flags and metric names.

## Is this the right tool?

`node_exporter` already covers CPU, memory, filesystems, network, `hwmon`
temperatures and basic NVMe health, and it is packaged on every distribution
(`apt install prometheus-node-exporter`). If you are building real monitoring,
install that first. This exporter is for the case where you want one small,
readable, dependency-light Python file you can modify — a lab box, a NAS, a
single home server — rather than a fleet agent. The two can coexist: run the
exporter with `--no-collector host` and it stops emitting the CPU, memory,
filesystem and network series that node_exporter already provides.

# The exporter

`prometheus_unified_metrics.py` is a normal script and runs on any platform with
Python 3.9+, with or without the installer.

Every subsystem degrades on its own. A missing tool, a permission error or a
wedged disk produces `hostwatch_collector_up 0` for that one collector; the
scrape still returns 200 with everything else intact. The script never installs
anything and never mutates its own environment.

## Dependencies

| Package | Required? | Without it |
| --- | --- | --- |
| `prometheus-client` | **yes** | Exits 3 with instructions. |
| `psutil` | no | `host` and `sensors` report `up 0`; the rest still works. |
| `smartmontools` >= 7.0 | no | `smart` reports `up 0`. Needs **root**. |
| `nvidia-ml-py` (module `pynvml`) | no | `gpu` falls back to parsing `nvidia-smi`. |

`smartctl` needs root because it issues ATA_12/ATA_16 SCSI passthrough commands;
membership of the `disk` group is not sufficient.

## Modes

```bash
# Print one exposition to stdout and exit.
python3 prometheus_unified_metrics.py --once

# Serve /metrics on 127.0.0.1:9105 until SIGTERM or SIGINT.
python3 prometheus_unified_metrics.py

# Accept scrapes from other hosts (read "Scraping it" below first).
python3 prometheus_unified_metrics.py --bind 0.0.0.0

# Write a .prom file for node_exporter's textfile collector and exit.
python3 prometheus_unified_metrics.py \
    --textfile /var/lib/prometheus/node-exporter/hostwatch.prom

# Same, taking the path from LZC_EXPORTER_TEXTFILE.
python3 prometheus_unified_metrics.py --textfile

# Skip what node_exporter already covers.
python3 prometheus_unified_metrics.py --no-collector host
```

`--once` and `--textfile` combine; passing either one suppresses the server.

**Which mode runs is decided on the command line and nowhere else.** Setting
`LZC_EXPORTER_TEXTFILE` without also passing `--textfile` is a usage error
(exit 2), not a mode change. The variable supplies the path; the flag selects
the mode. This is not pedantry: the installed unit loads
`/etc/default/prometheus-unified-exporter.local`, and if that file could switch
the mode, one line in it would turn the running exporter into a process that
writes a file, exits **0**, and leaves nothing listening — which
`Restart=on-failure` does not restart and no alert can see. Refusing to start is
loud; that is the point.

HTTP routes are `/metrics`, `/` (a link to it), `/-/healthy` and `/-/ready`.
Anything else returns 404 rather than quietly serving metrics, so a typo in a
scrape config shows up as a failure instead of appearing to work.

## Options

Every option has an environment variable. Flags win over the environment.

| Flag | Environment variable | Default | Meaning |
| --- | --- | --- | --- |
| `--bind ADDR` | `LZC_EXPORTER_BIND` | `127.0.0.1` | Listen address, IPv4 or IPv6. |
| `--port PORT` | `LZC_EXPORTER_PORT` | `9105` | Listen port. |
| `--once` | — | off | Print one exposition to stdout and exit. |
| `--textfile [PATH]` | `LZC_EXPORTER_TEXTFILE` | unset | Write one exposition to PATH and exit. With no value, uses the variable. The variable **alone** is a usage error — see [Modes](#modes). |
| `--textfile-mode MODE` | `LZC_EXPORTER_TEXTFILE_MODE` | `0644` | Octal permissions for that file. Read as octal, so `640` means `0640`. |
| `--collector NAME` | `LZC_EXPORTER_COLLECTORS` | all | Enable only these. Repeatable; env var is comma separated. |
| `--no-collector NAME` | `LZC_EXPORTER_DISABLE_COLLECTORS` | none | Disable these. Repeatable. Wins over `--collector`. |
| `--smartctl PATH` | `LZC_EXPORTER_SMARTCTL` | `smartctl` | Name or absolute path of the `smartctl` binary. |
| `--nvidia-smi PATH` | `LZC_EXPORTER_NVIDIA_SMI` | `nvidia-smi` | Name or absolute path of the `nvidia-smi` binary. |
| `--timeout SECONDS` | `LZC_EXPORTER_TIMEOUT` | `8` | Hard timeout for **each external tool invocation** (`smartctl`, `nvidia-smi`). Must be finite and greater than 0. |
| `--smart-interval SECONDS` | `LZC_EXPORTER_SMART_INTERVAL` | `60` | Serve cached SMART data for this long. `0` queries every scrape. Must be finite. |
| `--mount-exclude REGEX` | `LZC_EXPORTER_MOUNT_EXCLUDE` | pseudo, container and snap mounts | Skip matching mountpoints. Empty keeps everything. |
| `--netdev-exclude REGEX` | `LZC_EXPORTER_NETDEV_EXCLUDE` | `veth`, `tap`, `fwbr`, `fwln`, `fwpr`, `vnet`, `docker`, `br-`, `virbr`, `cali`, `lxcbr` prefixes | Skip matching interfaces. Empty keeps everything. |
| `--log-level LEVEL` | `LZC_EXPORTER_LOG_LEVEL` | `info` | `debug`, `info`, `warning`, `error`. Case insensitive. |
| `--color WHEN` | — | `auto` | `auto`, `always`, `never`. Colours the log level on stderr only. |
| `-V, --version` | — | — | Print version and exit. |
| `-h, --help` | — | — | Print help and exit. |

`--bind` and `--port` read `LZC_EXPORTER_BIND` and `LZC_EXPORTER_PORT` — the same
two names the installer writes into the service environment file, so one spelling
covers both a hand-run copy and the installed unit.

`--color` is flag-only by design; `NO_COLOR` is the environment lever. Setting
`NO_COLOR` to any non-empty value disables colour ([no-color.org](https://no-color.org)),
and `auto` additionally requires stderr to be a terminal — so under systemd there
is never colour. An explicit `--color always` overrides `NO_COLOR`. The metrics
exposition on stdout is **never** coloured, whatever these are set to.

Logs go to stderr, metrics to stdout, so `metrics=$(… --once)` works while
diagnostics still reach the operator. Under systemd the timestamp is dropped
from each line, because journald adds its own.

The two exclude patterns are not cosmetic. On a Proxmox or Docker host, per-guest
`veth`/`tap` interfaces and per-container overlay mounts grow without bound, and
each one would otherwise become a permanent time series.

Keep `--timeout` well below your Prometheus `scrape_timeout`. It is the mechanism
that stops one dying disk from wedging the exporter. `nan` and `inf` are rejected
rather than accepted: both pass a naive range check (`nan <= 0` is false), and
either one silently removes the protection the setting exists to provide.

`--smartctl` and `--nvidia-smi` exist because a service `PATH` is not a login
`PATH`. If a collector reports `up 0` with "not on PATH" and you know the tool is
installed, point these at it — an absolute path is accepted and is checked for
executability, so a typo still degrades to `up 0` rather than crashing a scrape.

## Exit status

Every script in this repository uses one table. These are the codes this
exporter can produce:

| Code | Meaning |
| --- | --- |
| 0 | Success — a one-shot mode succeeded. |
| 1 | The work ran but something in it failed: could not bind the port, or could not write the textfile. |
| 2 | Usage error: unknown flag, missing or invalid argument value, unknown collector, unresolvable bind address, or `LZC_EXPORTER_TEXTFILE` set without `--textfile`. |
| 3 | Unsupported platform or a missing prerequisite tool — here, `prometheus_client` is not installed. |
| 130 | Interrupted (SIGINT/SIGTERM). |

The remaining repository-wide codes — 4 (must be run as root), 5 (refused:
confirmation needed, but no TTY and `--yes` was not given) and 75 (temporary
failure: another instance holds the lock) — do not apply to the exporter. It
needs no root, asks no questions and takes no lock.

SIGTERM, SIGINT and SIGHUP all stop the server cleanly and then exit **130**.
The shutdown is clean; 130 records only that a signal ended the run.

This matters for any **long-running** unit you write by hand: it needs
`SuccessExitStatus=130`, or every `systemctl stop` is recorded as a failure. The
unit `setup_prometheus_exporter.sh` writes carries that line. The
textfile-collector sample below does not need it — it is a `Type=oneshot` run
that finishes on its own and exits 0.

## Blast radius

The exporter reads sensors and runs `smartctl` and `nvidia-smi` **read-only**.
It installs no packages, loads no kernel modules, changes no configuration, and
writes exactly one file — the `--textfile` path, and only when you ask for it.
Root is needed only for the `smart` collector.

## Collectors

| Name | Source | Needs |
| --- | --- | --- |
| `host` | psutil, `os.getloadavg` | psutil |
| `sensors` | psutil `hwmon` bindings | psutil, Linux |
| `smart` | `smartctl --json` | smartmontools >= 7.0, root |
| `gpu` | NVML, else `nvidia-smi` | `nvidia-ml-py` or the driver utilities |

Each one reports its own health:

```
hostwatch_collector_up{collector="smart"} 0
hostwatch_collector_duration_seconds{collector="smart"} 0.41
```

`up 0` means "enabled but could not collect" — missing tool, permission error,
timeout, or unexpected failure. The reason is logged once and then suppressed
until it changes, so a permanently absent tool does not fill the journal.
Disable collectors that do not apply to your host rather than living with a
permanent 0:

```bash
python3 prometheus_unified_metrics.py --no-collector gpu --no-collector smart
```

## Metrics

Units follow Prometheus base-unit conventions: seconds, bytes, celsius, watts,
and ratios in 0–1 rather than percentages.

### Exporter

| Metric | Type | Labels |
| --- | --- | --- |
| `hostwatch_build_info` | gauge | `version`, `python_version` |
| `hostwatch_collector_up` | gauge | `collector` |
| `hostwatch_collector_duration_seconds` | gauge | `collector` |

Prometheus synthesises `up`, `scrape_duration_seconds` and
`scrape_samples_scraped` itself, so the exporter does not duplicate them. When
serving on Linux, the standard `process_*` self-metrics are exposed as well;
they are omitted in one-shot mode, where a short-lived process's resident set
size means nothing.

### `host`

| Metric | Type | Labels |
| --- | --- | --- |
| `hostwatch_host_info` | gauge | `os`, `release`, `version`, `machine` |
| `hostwatch_boot_time_seconds` | gauge | — |
| `hostwatch_cpu_seconds_total` | counter | `mode` |
| `hostwatch_cpu_count` | gauge | — |
| `hostwatch_load1`, `hostwatch_load5`, `hostwatch_load15` | gauge | — |
| `hostwatch_memory_total_bytes`, `_available_bytes`, `_used_bytes`, `_free_bytes` | gauge | — |
| `hostwatch_swap_total_bytes`, `_used_bytes`, `_free_bytes` | gauge | — |
| `hostwatch_filesystem_size_bytes`, `_used_bytes`, `_avail_bytes` | gauge | `device`, `mountpoint`, `fstype` |
| `hostwatch_network_receive_bytes_total`, `_transmit_bytes_total` | counter | `device` |
| `hostwatch_network_receive_packets_total`, `_transmit_packets_total` | counter | `device` |
| `hostwatch_network_receive_errors_total`, `_transmit_errors_total` | counter | `device` |
| `hostwatch_network_receive_drop_total`, `_transmit_drop_total` | counter | `device` |

CPU time is a cumulative counter, not an instantaneous percentage. Utilisation is
a query, not a metric:

```promql
1 - rate(hostwatch_cpu_seconds_total{mode="idle"}[5m])
    / ignoring(mode) hostwatch_cpu_count
```

`ignoring(mode)` is required, not decorative: the left side carries a `mode`
label and `hostwatch_cpu_count` does not, so a plain `/` finds no matching
series and returns an empty result with no error.

Load average is emitted only where the platform has a real one. On Windows psutil
simulates it from a background sampling thread — a different quantity under the
same name — so nothing is emitted there.

`_avail_bytes` is statvfs `f_bavail`: space available to an unprivileged user. It
excludes root-reserved blocks, so it is normally smaller than `size - used`.

### `sensors`

| Metric | Type | Labels |
| --- | --- | --- |
| `hostwatch_sensor_temperature_celsius` | gauge | `chip`, `sensor` |
| `hostwatch_sensor_temperature_high_celsius` | gauge | `chip`, `sensor` |
| `hostwatch_sensor_temperature_critical_celsius` | gauge | `chip`, `sensor` |
| `hostwatch_sensor_fan_rpm` | gauge | `chip`, `sensor` |

Chips reporting several unlabelled inputs get synthetic `input0`, `input1` names,
and a repeated label gets a numeric suffix, so no two samples in a family ever
share a label set — which is what stops Prometheus rejecting the whole scrape.

### `smart`

| Metric | Type | Labels |
| --- | --- | --- |
| `hostwatch_disk_info` | gauge | `device`, `model`, `serial`, `firmware`, `protocol` |
| `hostwatch_disk_health_ok` | gauge | `device` |
| `hostwatch_disk_temperature_celsius` | gauge | `device` |
| `hostwatch_disk_power_on_seconds_total` | counter | `device` |
| `hostwatch_disk_power_cycles_total` | counter | `device` |
| `hostwatch_disk_available_spare_ratio` | gauge | `device` |
| `hostwatch_disk_endurance_used_ratio` | gauge | `device` |
| `hostwatch_disk_media_errors_total` | counter | `device` |
| `hostwatch_disk_reallocated_sectors_total` | counter | `device` |
| `hostwatch_disk_pending_sectors` | gauge | `device` |
| `hostwatch_disk_uncorrectable_sectors` | gauge | `device` |
| `hostwatch_disk_interface_crc_errors_total` | counter | `device` |

Model and serial live only on `hostwatch_disk_info`. Join on `device` instead of
repeating them on every series:

```promql
hostwatch_disk_temperature_celsius
  * on(device) group_left(model, serial) hostwatch_disk_info
```

The NVMe ratios come from smartctl's percentages; `endurance_used_ratio` above
1.0 is legal and means the drive's rated endurance is spent. Pending and
uncorrectable sectors are gauges, not counters — pending sectors clear when the
drive reallocates them.

smartctl's exit status is a bitmask. Only bits 0 and 1 mean "no usable output";
the higher bits mean the drive is reporting a problem while still printing valid
JSON, so those readings are kept. A failing drive is exactly the one whose data
you need.

A drive that `--scan-open` reports twice under two `-d` types is emitted once.

Every one of these is read at most once per `--smart-interval` and served from
cache in between, so a value can be up to that many seconds old. Each `HELP`
string says so, with the interval you configured — the exposition is the place a
reader finds out, not this file. Set `--smart-interval 0` to read on every scrape
and the note disappears with the caching.

This is a small, vendor-comparable subset of SMART. For every attribute of every
drive, run [`smartctl_exporter`](https://github.com/prometheus-community/smartctl_exporter).

### `gpu`

| Metric | Type | Labels |
| --- | --- | --- |
| `hostwatch_gpu_info` | gauge | `gpu`, `uuid`, `name` |
| `hostwatch_gpu_utilization_ratio` | gauge | `gpu` |
| `hostwatch_gpu_memory_utilization_ratio` | gauge | `gpu` |
| `hostwatch_gpu_memory_total_bytes`, `_used_bytes`, `_free_bytes` | gauge | `gpu` |
| `hostwatch_gpu_temperature_celsius` | gauge | `gpu` |
| `hostwatch_gpu_fan_speed_ratio` | gauge | `gpu` |
| `hostwatch_gpu_power_watts`, `_power_limit_watts` | gauge | `gpu` |

`memory_utilization_ratio` is the fraction of time GPU memory was being read or
written — bandwidth activity, not occupancy. For occupancy use
`hostwatch_gpu_memory_used_bytes / hostwatch_gpu_memory_total_bytes`.

Readings a card does not support are absent rather than zero: consumer cards
report `[N/A]` fan speed and `[Not Supported]` power draw, and those produce no
series at all.

NVML is re-initialised on every scrape until it succeeds, so a driver reload, a
GPU reset, or an exporter that started before the driver was ready recovers on
its own.

For datacentre GPUs, [`dcgm-exporter`](https://github.com/NVIDIA/dcgm-exporter)
is the better answer.

## Alerting

```yaml
groups:
  - name: hostwatch
    rules:
      - alert: HostwatchCollectorDown
        expr: hostwatch_collector_up == 0
        for: 15m
        annotations:
          summary: '{{ $labels.collector }} on {{ $labels.instance }} is not collecting'

      - alert: DiskSmartFailing
        expr: hostwatch_disk_health_ok == 0
        for: 5m

      - alert: DiskPendingSectors
        expr: hostwatch_disk_pending_sectors > 0
        for: 30m

      - alert: NvmeEnduranceExhausted
        expr: hostwatch_disk_endurance_used_ratio > 0.9
```

## Textfile-collector mode

On a host that already runs node_exporter this is the better deployment: no
second listening port, and the privileged part is a short-lived process that can
be sandboxed harder than a daemon.

```ini
# /etc/systemd/system/hostwatch-textfile.service
[Unit]
Description=Collect hardware health into the node_exporter textfile directory
ConditionPathIsDirectory=/var/lib/prometheus/node-exporter

[Service]
Type=oneshot
ExecStart=/opt/prometheus-unified-exporter/venv/bin/python \
          /opt/prometheus-unified-exporter/prometheus_unified_metrics.py \
          --no-collector host \
          --textfile /var/lib/prometheus/node-exporter/hostwatch.prom
TimeoutStartSec=120
NoNewPrivileges=yes
ProtectSystem=strict
ReadWritePaths=/var/lib/prometheus/node-exporter
ProtectHome=yes
PrivateTmp=yes
PrivateNetwork=yes
# PrivateDevices must stay off here: it would hide /dev/nvme* and /dev/sd* and
# break smartctl. DeviceAllow is the narrower substitute.
DevicePolicy=closed
DeviceAllow=block-sd rw
DeviceAllow=block-blkext rw
DeviceAllow=char-nvme rw
```

Two lines carry more weight than they look:

- `ReadWritePaths=` is **required** whenever `ProtectSystem=strict` is set.
  Without it the whole hierarchy is read-only, the write fails with `EROFS`, and
  the unit fails — which at least is loud, unlike the mode below.
- `--textfile PATH` is on the command line, not `LZC_EXPORTER_TEXTFILE` in an
  environment file. That is deliberate and enforced; see [Modes](#modes).

`UMask=` is deliberately absent: the exporter `chmod`s the file to
`--textfile-mode` (`0644`) after writing it. node_exporter runs under its own
account, and a file created under the daemon unit's `UMask=0077` — or a root
cron job — would be `0600` and unreadable to it. The symptom there is
`node_textfile_scrape_error 1` on the *other* exporter rather than any error
from this one, which is why the mode is set explicitly rather than inherited.

```ini
# /etc/systemd/system/hostwatch-textfile.timer
[Unit]
Description=Periodic hardware health collection

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
RandomizedDelaySec=30s
Persistent=true

[Install]
WantedBy=timers.target
```

The write is atomic — a temporary file in the same directory, then a rename — so
node_exporter never reads a half-written file. Alert on staleness, because a
writer that stops running produces no failure of its own:

```promql
time() - node_textfile_mtime_seconds{file="hostwatch.prom"} > 900
```

## Design notes

- The mode — serve, `--once`, `--textfile` — is chosen on the command line and
  nowhere else. Environment variables supply values; they never select a mode.
  A daemon that an environment file can turn into a one-shot is a daemon that
  can stop serving while exiting 0, which no supervisor and no alert will catch.
- Collection is synchronous: everything happens inside the scrape, under a hard
  timeout, with no background refresh thread. The one exception is the SMART
  cache, which exists so scrapes never sit in a disk spin-up path, and which
  every affected `HELP` string declares.
- Metrics are rebuilt on every scrape, so a device that disappears stops
  producing series instead of reporting its last value forever.
- No metric carries a timestamp; Prometheus assigns those.
- Concurrent scrapes are serialised per collector, so two Prometheus servers
  cannot make the exporter run two `smartctl` scans against the same disks at
  once.

# The installer

`setup_prometheus_exporter.sh` provisions a host in one command and is safe to
run again: a second run compares what is on disk with what it would write, and
only touches — and only restarts — what actually changed. A converged host does
no package-manager work, no network access and no service restart.

## Requirements

Linux with systemd, run as root. It needs `systemctl` and `timeout`; everything
else (`python3`, `lm-sensors`, `nvme-cli`, `smartmontools`) it installs itself
through the distribution package manager.

Detected distributions: Debian/Ubuntu/Devuan/Mint/Pop (`apt`), RHEL/Fedora/
Rocky/Alma/Oracle/Amazon (`dnf`, `yum`), openSUSE/SLES (`zypper`),
Arch/Manjaro/EndeavourOS (`pacman`). Detection reads `ID` **and** `ID_LIKE` from
`/etc/os-release`, then falls back to whichever package manager is installed.

On Arch the package database is deliberately not synced: `pacman -Sy` without a
full upgrade produces a partial upgrade, which Arch does not support. Run
`pacman -Syu` yourself first if a package cannot be found.

## Running it

```bash
sudo ./setup_prometheus_exporter.sh -n     # print the plan, change nothing
sudo ./setup_prometheus_exporter.sh        # install (prompts once on a terminal)
sudo ./setup_prometheus_exporter.sh -y     # unattended
sudo ./setup_prometheus_exporter.sh --uninstall --yes
```

The installer **never downloads the exporter**. `prometheus_unified_metrics.py`
must already be on disk, next to the script or pointed at with `--src`. Fetching
an unpinned file from a branch and executing it as root is not an installation
method.

### From the network

Pin to a commit SHA and verify the hash before running, for both files:

```bash
REV=<40-char-commit-sha>
BASE=https://raw.githubusercontent.com/Lazarev-Cloud/Scripts/$REV/monitoring

curl -fsSL --proto '=https' --tlsv1.2 -o /tmp/prometheus_unified_metrics.py \
  "$BASE/prometheus_unified_metrics.py"
curl -fsSL --proto '=https' --tlsv1.2 -o /tmp/setup_prometheus_exporter.sh \
  "$BASE/setup_prometheus_exporter.sh"

sha256sum -c - <<'EOF'
<sha256>  /tmp/prometheus_unified_metrics.py
<sha256>  /tmp/setup_prometheus_exporter.sh
EOF

sudo bash /tmp/setup_prometheus_exporter.sh --yes
```

Produce the values from a checkout with `git rev-parse HEAD` and `sha256sum`.
A branch name is not a pin — it means "whatever was pushed most recently",
executed as root. A tag is not a pin either, because a tag can be moved.

If you pipe the installer instead (`curl … | bash`), every statement lives in a
function and `main` runs on the last line, so a truncated download executes
nothing. Flags then have to come after a literal `--`, or use the environment
variables, and `--src` must point at the payload:

```bash
LZC_EXPORTER_SRC=/tmp/prometheus_unified_metrics.py LZC_EXPORTER_YES=1 bash -c "$s"
```

## Options

Every flag has an environment variable, which is the easier route for
unattended runs.

| Flag | Environment variable | Meaning |
| --- | --- | --- |
| `-y, --yes` | `LZC_EXPORTER_YES=1` | Unattended; no prompts. |
| `-n, --dry-run` | — | Print the plan, change nothing. Works as non-root. |
| `--uninstall` | `LZC_EXPORTER_ACTION=uninstall` | Remove everything (see blast radius). |
| `--install-dir PATH` | `LZC_EXPORTER_INSTALL_DIR` | Install prefix (`/opt/prometheus-unified-exporter`). |
| `--service-name NAME` | `LZC_EXPORTER_SERVICE_NAME` | Unit name (`prometheus-unified-exporter`). |
| `--user NAME` | `LZC_EXPORTER_SERVICE_USER` | Service account (`prom-exporter`). |
| `--group NAME` | `LZC_EXPORTER_SERVICE_GROUP` | Service group (defaults to the user). |
| `--listen-address ADDR` | `LZC_EXPORTER_BIND` | Bind address (`127.0.0.1`). |
| `--port PORT` | `LZC_EXPORTER_PORT` | Bind port (`9105`). |
| `--src PATH` | `LZC_EXPORTER_SRC` | Path to the exporter. Default: next to the installer. |
| `--requirements PATH` | `LZC_EXPORTER_REQUIREMENTS` | pip requirements file. |
| `--sensors WHEN` | `LZC_EXPORTER_SENSORS` | `auto` (=yes), `yes`, `no`. |
| `--gpu WHEN` | `LZC_EXPORTER_GPU` | `auto`, `yes`, `no`. |
| `--disk-health` | `LZC_EXPORTER_DISK_HEALTH=1` | Run as root so SMART/NVMe temps work. |
| `--skip-packages` | `LZC_EXPORTER_SKIP_PACKAGES=1` | Never invoke the package manager. |
| `--force-pip` | `LZC_EXPORTER_FORCE_PIP=1` | Re-run pip even when nothing changed. |
| `--color WHEN` | — | `auto`, `always`, `never`. |
| `-V, --version` | — | Print version. |
| `-h, --help` | — | Print help. |

`--listen-address` and `--port` read `LZC_EXPORTER_BIND` and `LZC_EXPORTER_PORT`,
which are the same two names the exporter itself reads. The installer writes them
into the environment file, so the value follows the service rather than being
re-spelled on each side.

Tunables with no flag: `LZC_EXPORTER_UNIT_DIR` (`/etc/systemd/system`),
`LZC_EXPORTER_ENV_DIR` (`/etc/default`), `LZC_EXPORTER_ENV_FILE`,
`LZC_EXPORTER_PIP_PACKAGES`, `LZC_EXPORTER_GPU_PIP_PACKAGES`,
`LZC_EXPORTER_OS_RELEASE`, `LZC_EXPORTER_LOCK`
(`/run/lock/lzc-exporter.lock`).

### Timeouts

Each bounds a different thing, so each is listed with what it actually covers.
All must be **at least 1**: `timeout 0` means *no* limit and would silently
remove the protection the setting exists to provide.

| Variable | Default | Bounds |
| --- | --- | --- |
| `LZC_EXPORTER_PKG_TIMEOUT` | 900 | One package-manager invocation — one `apt-get update`, then one `apt-get install`. |
| `LZC_EXPORTER_PIP_TIMEOUT` | 600 | The single `pip install -r requirements.txt` run. |
| `LZC_EXPORTER_SYSTEMCTL_TIMEOUT` | 90 | Each `systemctl` call: enable, start, restart, disable. |
| `LZC_EXPORTER_HEALTH_TIMEOUT` | 10 | One attempt to fetch `/metrics` after the service starts. |
| `LZC_EXPORTER_HEALTH_RETRIES` | 15 | How many such attempts, one second apart. Minimum 1: `0` would skip the health check and report success for a service that never answered. |
| `LZC_EXPORTER_APT_CACHE_MAX_AGE` | 86400 | How old the apt index may be before it is refreshed. **May be 0**, meaning always refresh. |

### Accepted values

`LZC_EXPORTER_YES`, `LZC_EXPORTER_DISK_HEALTH`, `LZC_EXPORTER_SKIP_PACKAGES` and
`LZC_EXPORTER_FORCE_PIP` accept `1`/`true`/`yes`/`on` and `0`/`false`/`no`/`off`,
case insensitively. An empty value means off. Anything else is rejected as a
usage error (exit 2) before the run starts, rather than failing partway through
the install — a bare word such as `true` reaching an arithmetic context under
`set -u` would otherwise abort with `true: unbound variable`.

Numeric values are matched against a whole-number pattern and then read as
base ten, so a zero-padded value like `08` means 8 rather than being rejected as
an invalid octal literal.

Colour follows `NO_COLOR` ([no-color.org](https://no-color.org)): any non-empty
value disables it. `--color auto` additionally requires stdout to be a terminal.
`--color always` overrides `NO_COLOR`. `--color` is flag-only.

Values that end up inside the generated unit file are checked before anything is
written, because the installer runs as root and a newline in one of them would
otherwise append a directive of its own to `$UNIT_DIR/$SERVICE_NAME.service`:

- `--install-dir` must be absolute, at least two levels deep, free of `//`, free
  of `.` and `..` components, not a system directory, and free of whitespace.
  The `.`/`..` rule matters most: `--uninstall` passes this path to `rm -rf`, and
  `/opt/../..` resolves to `/`.
- `--listen-address` and `LZC_EXPORTER_ENV_DIR`/`LZC_EXPORTER_ENV_FILE` must not
  contain whitespace or control characters.
- `--user` and `--group` must match `[a-z_][a-z0-9_-]*`.
- `--service-name` must be a bare unit name, `--port` an integer in 1-65535.

## Exit status

Every script in this repository uses one table. These are the codes the
installer can produce:

| Code | Meaning |
| --- | --- |
| 0 | Success. |
| 1 | The work ran but something in it failed — including a service that installed but did not come up or did not serve `/metrics`. |
| 2 | Usage error: unknown flag, missing or invalid argument value. |
| 3 | Unsupported platform or a missing prerequisite tool: no systemd, no known package manager, payload missing. |
| 4 | Must be run as root. |
| 5 | Refused: confirmation needed, but no TTY and `--yes` was not given. |
| 75 | Temporary failure: another instance holds `/run/lock/lzc-exporter.lock`. `EX_TEMPFAIL`, so cron and systemd treat it as "retry later" rather than a real fault. |
| 130 | Interrupted (SIGINT/SIGTERM). |

A failed verification is a 1: the work ran and something in it failed. It is the
case worth alerting on, because the files are in place and the service was
enabled but never answered. The installer prints the last 30 journal lines and
re-runs the exporter in the foreground first, so the real error is visible
instead of "unit failed".

Declining the uninstall prompt is **not** an error — the installer says
`Cancelled; nothing was removed` and exits 0. Exit 5 is reserved for the case
where it could not ask at all: no terminal, and no `--yes`.

## Blast radius

**Install** — installs distribution packages (Python with `venv`, and unless
`--sensors no`, `lm-sensors` + `nvme-cli` + `smartmontools`); creates the system
account `prom-exporter`; creates `/opt/prometheus-unified-exporter` with a
virtual environment inside; writes
`/etc/systemd/system/prometheus-unified-exporter.service` and
`/etc/default/prometheus-unified-exporter`; enables and starts the service.

It does not run `sensors-detect`, does not load kernel modules, does not write
to `/etc/modules`, does not install GPU drivers and does not upgrade the system.

**`--uninstall`** — stops and disables the service, removes the unit, the managed
environment file, the install prefix (recursively) and the service account. It
does **not** remove the distribution packages it installed, does not touch
Prometheus, and does not delete
`/etc/default/prometheus-unified-exporter.local`, which is yours rather than the
installer's. Without a terminal to confirm on it refuses unless `--yes` is given.
The install prefix is validated before anything is deleted: it must be absolute,
at least two levels deep, and must not be a system directory.

## What the service looks like

`ExecStart` runs the virtual environment's interpreter directly. The bind
address and port come from the environment file, so changing where the exporter
listens is an edit plus `systemctl restart` — no re-install:

```
/etc/default/prometheus-unified-exporter
    LZC_EXPORTER_BIND=127.0.0.1
    LZC_EXPORTER_PORT=9105
```

That file is rendered whole on every install, so anything you add to it is lost
on the next run. The unit reads a second, optional file immediately after it:

```
/etc/default/prometheus-unified-exporter.local
```

The installer never writes, reads for configuration or deletes that one. Put your
own settings — the exporter's other `LZC_EXPORTER_*` variables, for instance —
there and they survive re-installs and uninstalls. A systemd drop-in
(`systemctl edit prometheus-unified-exporter`) works the same way for anything
that is not an environment variable.

Three variables are the exception, because the unit is **rendered from
install-time values** while `.local` is **read at start time**:

| Variable | What `.local` can and cannot do |
| --- | --- |
| `LZC_EXPORTER_TEXTFILE` | Setting it here stops the service starting. The exporter refuses with a usage error (exit 2) when this variable is set and `--textfile` is not passed — deliberately, so an environment file cannot turn a running service into a one-shot that exits `0` and silently stops serving. Unset it, or write a separate `Type=oneshot` unit and timer that passes `--textfile` explicitly; see [Textfile-collector mode](#textfile-collector-mode). |
| `LZC_EXPORTER_BIND` | Moves the listener but **not** the installer's own health check, which is built from the install-time address — so the next `setup_prometheus_exporter.sh` run fetches the old endpoint, gets nothing and exits `1` for a service that is in fact healthy. Crossing from a loopback bind to a routable one is worse: the unit keeps the `IPAddressDeny=any` + `IPAddressAllow=localhost` pair it was rendered with, and systemd drops the non-local traffic regardless. |
| `LZC_EXPORTER_PORT` | The same stale-health-check problem, and crossing below 1024 additionally fails the bind with `EACCES` and crash-loops: only an install rendered for a privileged port is granted `CAP_NET_BIND_SERVICE`. |

Change the bind address or the port by re-running the installer with
`--listen-address` / `--port`. That moves the unit, the managed environment file
and the health check together, which is the only way the three stay consistent.

A re-run reads `.local` and warns when it finds any of the three set there. It
never edits or removes the file.

The unit deliberately does **not** strip `LZC_EXPORTER_TEXTFILE` from the
environment. The exporter only accepts a textfile path named on the command line
(see [Modes](#modes)), so the variable reaching it produces a loud exit-2
refusal; the unit lands in `failed`, which an alert can see. Removing the
variable in the unit instead would silently ignore what the operator asked for.
The installer's warning on re-run is the second layer, and it fires at install
time — before the service is ever started.

`Type=exec` is used on systemd 240+, so a missing interpreter or an unusable
service account fails `systemctl start` instead of reporting success and dying
in restart backoff. On systemd 254+ the unit also gets exponential restart
backoff (`RestartSteps`, `RestartMaxDelaySec`).

### Sandboxing

By default the service runs as the unprivileged `prom-exporter` account with an
empty capability bounding set, `ProtectSystem=strict`, `PrivateDevices=yes`,
`PrivateTmp=yes`, `ProtectKernel*`, `RestrictNamespaces`, `LockPersonality`,
`SystemCallFilter=@system-service` and `SystemCallArchitectures=native`. When
the bind address is a loopback address it also gets `IPAddressDeny=any` with
`IPAddressAllow=localhost`. Check it yourself:

```bash
systemd-analyze security prometheus-unified-exporter
```

Two directives are deliberately absent:

- `ProcSubset=pid` would hide `/proc/stat`, `/proc/meminfo` and `/proc/net/dev`
  — everything the exporter reads. `ProtectProc=invisible` is set instead.
- `ProtectHome=yes` replaces `/home` with an empty tmpfs, which would silently
  drop the filesystem series for a host with `/home` on its own partition.
  `ProtectHome=read-only` is set instead.

`PrivateTmp=yes` **is** set, which means a host with `/tmp` or `/var/tmp` on a
separate filesystem will not report those two mounts.

The daemon's *mode* cannot be changed from an environment file, but that is
enforced by the exporter refusing such a configuration rather than by the unit
filtering the environment — see the table above.

### Hardware access

| What you want | What you get |
| --- | --- |
| CPU, memory, filesystems, network | Always. No privileges needed. |
| CPU/board temperatures (`hwmon`) | Always. Read from `/sys`, which survives the sandbox. |
| SMART / NVMe disk temperatures | Only with `--disk-health`. |
| NVIDIA GPU metrics | Only when a GPU is present and the driver is installed. |

`--disk-health` changes the service account to **root** and grants
`CAP_SYS_RAWIO`, `CAP_SYS_ADMIN` and `CAP_DAC_OVERRIDE` plus read/write access
to block devices. That is not a preference — `smartctl` issues ATA_12/ATA_16
SCSI passthrough commands, and membership of the `disk` group is not sufficient.
The rest of the sandbox stays on, so the hardening there buys containment, not
privilege reduction. Leave it off unless you want disk temperatures.

`--disk-health` is only useful with `smartctl` installed. Combining it with
`--sensors no` or `--skip-packages` on a host that does not already have
`smartmontools` gives you a service running as root that still reports no disk
temperatures, so the installer warns when it sees that combination.

GPU support is enabled automatically when `/dev/nvidia*` exists, `nvidia-smi` is
on `PATH`, or `lspci` reports an NVIDIA device. The unit then gets
`DeviceAllow=char-nvidia-frontend`/`char-nvidia-uvm` instead of
`PrivateDevices=yes`. Whether the in-process NVML bindings are also installed
depends on the dependency list (see below): `requirements.txt` ships them
commented out, because the right release depends on your driver branch, and the
exporter falls back to `nvidia-smi` without them.

The installer never installs an NVIDIA driver: driver packages are
kernel-specific and guessing the name is how a working host gets broken. Install
the driver yourself, then re-run.

When a subsystem is absent — no `hwmon` devices, no disks, no GPU — the
installer says so and the exporter simply emits no series for it.

## Python dependencies

Debian 13, Ubuntu 24.04, Fedora and openSUSE ship an externally-managed Python
([PEP 668](https://peps.python.org/pep-0668/)): `pip install` outside a virtual
environment fails, and `--break-system-packages` can leave `apt` unable to
reconcile its own `python3-*` packages. So the installer builds a virtual
environment at `<install-dir>/venv` and installs into that. Nothing is ever
installed into the system Python.

Requirements are resolved in this order:

1. `--requirements PATH` / `LZC_EXPORTER_REQUIREMENTS`,
2. a `requirements.txt` sitting next to the exporter — which this repository
   ships, so this is the normal case, and the exporter's dependencies can change
   without the installer needing to know,
3. the built-in fallback pins — `psutil==7.2.2`, plus `nvidia-ml-py==13.610.43`
   when GPU support is on. Override with `LZC_EXPORTER_PIP_PACKAGES` and
   `LZC_EXPORTER_GPU_PIP_PACKAGES`.

The installer logs which of the three it used. The resolved list is copied to
`<install-dir>/requirements.txt`, and pip is skipped only against proof that it
already installed exactly that list into this virtual environment: a copy of the
requirements written to `<install-dir>/venv/.requirements.installed` *after* pip
exits 0. A re-run whose requirements match that copy skips pip and stays
offline; `--force-pip` runs it regardless.

The proof deliberately is not `requirements.txt` itself. That file is written
before pip runs, so a failed pip would leave the new pins on disk with nothing
installed, and the next run would read them back as unchanged and skip the
install it was asked to perform.

Pinned versions still trust PyPI to serve the same artefact. If you need more
than that, supply a hash-pinned requirements file (`pip-compile
--generate-hashes`); when the file contains `--hash=` entries the installer adds
`--require-hashes` automatically. `PIP_INDEX_URL` is honoured if you export it,
so an internal mirror works without changing the script.

## Scraping it

```yaml
scrape_configs:
  - job_name: host-metrics
    static_configs:
      - targets: ['127.0.0.1:9105']
```

The default bind address is `127.0.0.1`, so the endpoint is not reachable from
the network until you ask for it. There is no authentication and no TLS: if you
set `--listen-address 0.0.0.0`, anyone who can reach the port can read your
host's hardware telemetry. Put it behind the firewall, a reverse proxy, or
scrape it over a private network.

Port 9105 is listed in the Prometheus
[default port allocations](https://github.com/prometheus/prometheus/wiki/Default-port-allocations)
as the Mesos exporter's port. Nothing enforces that registry, and the collision
only matters if you actually run a Mesos exporter on the same host — but if you
have a central Prometheus and a port convention, pick your own with `--port`
(and `--port` on the exporter, or `LZC_EXPORTER_PORT`, for a hand-run copy).

## Troubleshooting

```bash
systemctl status prometheus-unified-exporter
journalctl -u prometheus-unified-exporter -n 50
curl -s http://127.0.0.1:9105/metrics | head

# run it by hand, outside systemd, to separate a sandbox problem from a code problem
/opt/prometheus-unified-exporter/venv/bin/python \
  /opt/prometheus-unified-exporter/prometheus_unified_metrics.py --once
```

If it works by hand but not as a service, the sandbox is blocking something —
compare with `systemd-analyze security` and add a drop-in rather than editing
the generated unit, which is overwritten on the next install.

## Passing extra exporter flags

The installer only ever passes `--bind` and `--port`. Every other exporter
option — see [The exporter](#the-exporter) — belongs either in
`/etc/default/prometheus-unified-exporter.local`, since each one has a
`LZC_EXPORTER_*` variable, or in a systemd drop-in:

```bash
cat >> /etc/default/prometheus-unified-exporter.local <<'EOF'
LZC_EXPORTER_DISABLE_COLLECTORS=gpu,smart
LZC_EXPORTER_TIMEOUT=5
EOF
systemctl restart prometheus-unified-exporter
```

`LZC_EXPORTER_TEXTFILE` is the one variable that does **not** work here. The
unit does not strip it; the exporter refuses to start (usage error, exit `2`)
when it is set without `--textfile`, so setting it here stops the daemon rather
than configuring it. See the table in
[What the service looks like](#what-the-service-looks-like), and
[Textfile-collector mode](#textfile-collector-mode) for the supported way to
produce a `.prom` file. `LZC_EXPORTER_BIND` and `LZC_EXPORTER_PORT` carry the
caveats in that same table — re-run the installer instead.

```bash
systemctl edit prometheus-unified-exporter
# [Service]
# ExecStart=
# ExecStart=/opt/prometheus-unified-exporter/venv/bin/python \
#   /opt/prometheus-unified-exporter/prometheus_unified_metrics.py \
#   --bind ${LZC_EXPORTER_BIND} --port ${LZC_EXPORTER_PORT} --no-collector host
```

A drop-in survives re-installs; edits to the generated unit do not.

## Notes and limits

- Concurrent installer runs are refused via `flock` on
  `/run/lock/lzc-exporter.lock` (exit 75), overridable with `LZC_EXPORTER_LOCK`.
  The path is a fixed default rather than one derived from `--service-name`, so
  two installs on the same host serialise even under different service names —
  which is what you want, because they share one package manager.
- The installer ignores `SIGHUP`, so a dropped SSH session cannot interrupt it
  mid-`dpkg` and leave the package database half-configured.
- Only the Linux install path is covered here. On Windows or macOS, run the
  exporter directly and use the platform's own service manager.
- The installer manages the exporter, not Prometheus. It does not write scrape
  configuration, alerting rules or dashboards.
