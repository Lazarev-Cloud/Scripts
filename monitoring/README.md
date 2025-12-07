# Unified Prometheus Metrics Exporter

A cross-platform Python script that discovers the host platform, ensures the
required Python dependency (`psutil`) is installed, and exposes common machine
metrics in Prometheus' text format. It works on both Linux and Windows without
extra configuration. Running the Linux setup helper requires root/sudo access
so it can install sensor tooling (for CPU/board/SSD temps) and GPU utilities.

## Requirements
- Python 3.8+
- Network access to install `psutil` on the first run (the script installs it
  automatically if missing)

## Usage

Print metrics once to stdout:
```bash
python prometheus_unified_metrics.py --once
```

Run the HTTP exporter (default port `9105`):
```bash
python prometheus_unified_metrics.py --port 9105
```

You can change the bind address with `--bind` (defaults to `0.0.0.0`). The
exporter serves metrics at `http://<bind>:<port>/metrics`.

To fully provision a host (install Python, sensor tooling, Python deps, copy the
exporter, and create a systemd service on Linux), run the helper script:

```bash
sudo bash setup_prometheus_exporter.sh
```

## Metrics Exposed
- `system_info`: basic OS, release, and architecture labels
- `system_cpu_usage_percent`: CPU usage percentage
- `system_load_average`: 1/5/15 minute load averages (0.0 on platforms without load)
- `system_memory_bytes`: total/available/used/free RAM
- `system_swap_bytes`: total/used/free swap
- `system_filesystem_bytes`: total/used/free per mounted filesystem
- `system_network_bytes_total`: bytes sent/received per network interface
- `system_temperature_celsius`: detected temperature sensors (CPU, chassis, etc.)
- `system_disk_temperature_celsius`: NVMe and SMART drive temperatures
- `system_gpu_*`: GPU inventory, memory, utilization, temperature, and fan speed

## Notes
- The script avoids `try/except` around imports by checking module availability
  before installation.
- Permissions: filesystem and network counters may omit entries if the executing
  user lacks access to specific mount points or interfaces.
