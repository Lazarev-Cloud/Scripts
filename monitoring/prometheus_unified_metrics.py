#!/usr/bin/env python3
"""Unified Prometheus metrics exporter for Linux and Windows.

The script detects the underlying platform, ensures Python dependencies are
available, and exposes a minimal set of machine metrics in Prometheus' text
format. Run it with ``--once`` to print metrics to stdout, or keep it running
as a lightweight HTTP server that serves ``/metrics``.
"""

import argparse
import http.server
import importlib
import importlib.util
import json
import platform
import shutil
import subprocess
import sys
from typing import List


def ensure_dependency(module_name: str) -> None:
    """Install a dependency with pip if it is missing."""
    if importlib.util.find_spec(module_name) is not None:
        return

    installer = shutil.which("pip") or shutil.which("pip3") or sys.executable
    if installer == sys.executable:
        install_command = [sys.executable, "-m", "pip", "install", module_name]
    else:
        install_command = [installer, "install", module_name]

    print(f"[setup] Installing missing dependency: {module_name}", file=sys.stderr)
    subprocess.check_call(install_command)


def load_psutil():  # type: ignore
    """Ensure psutil is installed and import it."""
    ensure_dependency("psutil")
    import psutil  # type: ignore

    return psutil


def load_optional_module(module_name: str):
    """Import an optional dependency if it is available."""

    if importlib.util.find_spec(module_name) is None:
        return None

    return importlib.import_module(module_name)


class MetricCollector:
    """Collects system metrics in Prometheus exposition format."""

    def __init__(self) -> None:
        self.psutil = load_psutil()
        self.pynvml = load_optional_module("pynvml")
        self._nvml_ready = False
        if self.pynvml:
            try:
                self.pynvml.nvmlInit()
                self._nvml_ready = True
            except Exception:
                self._nvml_ready = False

    @staticmethod
    def _label_value(value: str) -> str:
        return value.replace("\\", "\\\\").replace("\"", "\\\"")

    def _system_info(self) -> List[str]:
        os_name = platform.system() or "unknown"
        release = platform.release() or "unknown"
        version = platform.version() or "unknown"
        architecture = platform.machine() or "unknown"

        return [
            "# HELP system_info Basic host information",
            "# TYPE system_info gauge",
            (
                "system_info{os=\"%s\",release=\"%s\",version=\"%s\","
                "architecture=\"%s\"} 1"
                % (
                    self._label_value(os_name),
                    self._label_value(release),
                    self._label_value(version),
                    self._label_value(architecture),
                )
            ),
        ]

    def _cpu_metrics(self) -> List[str]:
        cpu_percent = self.psutil.cpu_percent(interval=0.2)
        load1, load5, load15 = (0.0, 0.0, 0.0)
        if hasattr(self.psutil, "getloadavg") or hasattr(self.psutil, "cpu_count"):
            try:
                load1, load5, load15 = self.psutil.getloadavg()  # type: ignore[attr-defined]
            except (AttributeError, OSError):
                load1 = load5 = load15 = 0.0

        lines = [
            "# HELP system_cpu_usage_percent CPU utilization percentage",
            "# TYPE system_cpu_usage_percent gauge",
            f"system_cpu_usage_percent{{}} {cpu_percent:.2f}",
            "# HELP system_load_average CPU load average over 1, 5, and 15 minutes",
            "# TYPE system_load_average gauge",
            f"system_load_average{{interval=\"1m\"}} {load1:.2f}",
            f"system_load_average{{interval=\"5m\"}} {load5:.2f}",
            f"system_load_average{{interval=\"15m\"}} {load15:.2f}",
        ]
        return lines

    def _memory_metrics(self) -> List[str]:
        vm = self.psutil.virtual_memory()
        swap = self.psutil.swap_memory()
        return [
            "# HELP system_memory_bytes System memory in bytes",
            "# TYPE system_memory_bytes gauge",
            f"system_memory_bytes{{type=\"total\"}} {vm.total}",
            f"system_memory_bytes{{type=\"available\"}} {vm.available}",
            f"system_memory_bytes{{type=\"used\"}} {vm.used}",
            f"system_memory_bytes{{type=\"free\"}} {vm.free}",
            "# HELP system_swap_bytes Swap memory in bytes",
            "# TYPE system_swap_bytes gauge",
            f"system_swap_bytes{{type=\"total\"}} {swap.total}",
            f"system_swap_bytes{{type=\"used\"}} {swap.used}",
            f"system_swap_bytes{{type=\"free\"}} {swap.free}",
        ]

    def _disk_metrics(self) -> List[str]:
        lines: List[str] = [
            "# HELP system_filesystem_bytes Filesystem capacity and usage in bytes",
            "# TYPE system_filesystem_bytes gauge",
        ]
        for part in self.psutil.disk_partitions(all=False):
            try:
                usage = self.psutil.disk_usage(part.mountpoint)
            except PermissionError:
                continue
            mount_label = self._label_value(part.mountpoint)
            lines.extend(
                [
                    f"system_filesystem_bytes{{mount=\"{mount_label}\",type=\"total\"}} {usage.total}",
                    f"system_filesystem_bytes{{mount=\"{mount_label}\",type=\"used\"}} {usage.used}",
                    f"system_filesystem_bytes{{mount=\"{mount_label}\",type=\"free\"}} {usage.free}",
                ]
            )
        return lines

    def _network_metrics(self) -> List[str]:
        counters = self.psutil.net_io_counters(pernic=True)
        lines: List[str] = [
            "# HELP system_network_bytes_total Total bytes sent/received per interface",
            "# TYPE system_network_bytes_total counter",
        ]
        for iface, stats in counters.items():
            iface_label = self._label_value(iface)
            lines.extend(
                [
                    f"system_network_bytes_total{{interface=\"{iface_label}\",direction=\"sent\"}} {stats.bytes_sent}",
                    f"system_network_bytes_total{{interface=\"{iface_label}\",direction=\"received\"}} {stats.bytes_recv}",
                ]
            )
        return lines

    def _temperature_metrics(self) -> List[str]:
        if not hasattr(self.psutil, "sensors_temperatures"):
            return []

        try:
            temps = self.psutil.sensors_temperatures(fahrenheit=False) or {}
        except (NotImplementedError, OSError):
            return []
        lines: List[str] = [
            "# HELP system_temperature_celsius Reported temperature sensors",
            "# TYPE system_temperature_celsius gauge",
        ]
        for sensor, entries in temps.items():
            sensor_label = self._label_value(sensor)
            for entry in entries:
                label = self._label_value(entry.label or sensor)
                lines.append(
                    f"system_temperature_celsius{{name=\"{sensor_label}\",sensor=\"{label}\"}} {entry.current}"
                )

        return lines if len(lines) > 2 else []

    def _gpu_metrics(self) -> List[str]:
        if not self._nvml_ready or not self.pynvml:
            return []

        nvml = self.pynvml
        try:
            count = nvml.nvmlDeviceGetCount()
        except nvml.NVMLError:
            return []

        lines: List[str] = [
            "# HELP system_gpu_info GPU device information",
            "# TYPE system_gpu_info gauge",
            "# HELP system_gpu_memory_bytes GPU memory usage in bytes",
            "# TYPE system_gpu_memory_bytes gauge",
            "# HELP system_gpu_utilization_percent GPU utilization percent",
            "# TYPE system_gpu_utilization_percent gauge",
            "# HELP system_gpu_temperature_celsius GPU temperature in Celsius",
            "# TYPE system_gpu_temperature_celsius gauge",
            "# HELP system_gpu_fan_speed_percent GPU fan speed percentage",
            "# TYPE system_gpu_fan_speed_percent gauge",
        ]

        for idx in range(count):
            try:
                handle = nvml.nvmlDeviceGetHandleByIndex(idx)
            except nvml.NVMLError:
                continue

            try:
                name_raw = nvml.nvmlDeviceGetName(handle)
                name = name_raw.decode() if hasattr(name_raw, "decode") else str(name_raw)
            except nvml.NVMLError:
                name = "unknown"

            try:
                uuid_raw = nvml.nvmlDeviceGetUUID(handle)
                uuid = uuid_raw.decode() if hasattr(uuid_raw, "decode") else str(uuid_raw)
            except nvml.NVMLError:
                uuid = "unknown"

            name_label = self._label_value(name)
            uuid_label = self._label_value(uuid)
            lines.append(
                f"system_gpu_info{{index=\"{idx}\",name=\"{name_label}\",uuid=\"{uuid_label}\"}} 1"
            )

            try:
                mem = nvml.nvmlDeviceGetMemoryInfo(handle)
                lines.extend(
                    [
                        f"system_gpu_memory_bytes{{index=\"{idx}\",type=\"total\"}} {mem.total}",
                        f"system_gpu_memory_bytes{{index=\"{idx}\",type=\"used\"}} {mem.used}",
                        f"system_gpu_memory_bytes{{index=\"{idx}\",type=\"free\"}} {mem.free}",
                    ]
                )
            except nvml.NVMLError:
                pass

            try:
                util = nvml.nvmlDeviceGetUtilizationRates(handle)
                lines.append(
                    f"system_gpu_utilization_percent{{index=\"{idx}\",type=\"core\"}} {util.gpu}"
                )
                lines.append(
                    f"system_gpu_utilization_percent{{index=\"{idx}\",type=\"memory\"}} {util.memory}"
                )
            except nvml.NVMLError:
                pass

            try:
                temp = nvml.nvmlDeviceGetTemperature(handle, nvml.NVML_TEMPERATURE_GPU)
                lines.append(f"system_gpu_temperature_celsius{{index=\"{idx}\"}} {temp}")
            except nvml.NVMLError:
                pass

            try:
                fan_speed = nvml.nvmlDeviceGetFanSpeed(handle)
                lines.append(f"system_gpu_fan_speed_percent{{index=\"{idx}\"}} {fan_speed}")
            except nvml.NVMLError:
                pass

        return lines

    def _storage_temperature_metrics(self) -> List[str]:
        lines: List[str] = [
            "# HELP system_disk_temperature_celsius Storage temperature readings",
            "# TYPE system_disk_temperature_celsius gauge",
        ]

        nvme_path = shutil.which("nvme")
        if nvme_path:
            try:
                nvme_list = subprocess.run(
                    [nvme_path, "list", "-o", "json"],
                    check=True,
                    capture_output=True,
                    text=True,
                )
                nvme_devices = json.loads(nvme_list.stdout).get("Devices", [])
            except Exception:
                nvme_devices = []

            for dev in nvme_devices:
                dev_path = dev.get("DevicePath") or dev.get("Name")
                if not dev_path:
                    continue
                try:
                    nvme_log = subprocess.run(
                        [nvme_path, "smart-log", "-o", "json", dev_path],
                        check=True,
                        capture_output=True,
                        text=True,
                    )
                    log_json = json.loads(nvme_log.stdout)
                    temp = log_json.get("temperature") or log_json.get("composite_temperature")
                except Exception:
                    temp = None

                if temp is not None:
                    dev_label = self._label_value(dev_path)
                    lines.append(
                        f"system_disk_temperature_celsius{{device=\"{dev_label}\",type=\"nvme\"}} {temp}"
                    )

        smartctl_path = shutil.which("smartctl")
        if smartctl_path:
            try:
                scan = subprocess.run(
                    [smartctl_path, "--scan-open", "-j"],
                    check=True,
                    capture_output=True,
                    text=True,
                )
                devices = json.loads(scan.stdout).get("devices", [])
            except Exception:
                devices = []

            for dev in devices:
                name = dev.get("name")
                if not name:
                    continue
                try:
                    info = subprocess.run(
                        [smartctl_path, "-Aj", name],
                        check=True,
                        capture_output=True,
                        text=True,
                    )
                    info_json = json.loads(info.stdout)
                    temp_data = info_json.get("temperature", {})
                    temp = temp_data.get("current") or temp_data.get("drive_temperature")
                except Exception:
                    temp = None

                if temp is not None:
                    dev_label = self._label_value(name)
                    lines.append(
                        f"system_disk_temperature_celsius{{device=\"{dev_label}\",type=\"smart\"}} {temp}"
                    )

        return lines if len(lines) > 2 else []

    def collect(self) -> List[str]:
        metrics: List[str] = []
        metrics.extend(self._system_info())
        metrics.extend(self._cpu_metrics())
        metrics.extend(self._memory_metrics())
        metrics.extend(self._disk_metrics())
        metrics.extend(self._network_metrics())
        metrics.extend(self._temperature_metrics())
        metrics.extend(self._storage_temperature_metrics())
        metrics.extend(self._gpu_metrics())
        return metrics


def create_handler(collector: MetricCollector):
    class MetricsHandler(http.server.BaseHTTPRequestHandler):
        def do_GET(self) -> None:  # noqa: N802 (BaseHTTPRequestHandler naming)
            if self.path != "/metrics":
                self.send_response(404)
                self.end_headers()
                self.wfile.write(b"Not Found")
                return

            metrics = "\n".join(collector.collect()) + "\n"
            payload = metrics.encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; version=0.0.4")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)

        def log_message(self, format: str, *args) -> None:  # noqa: A003
            return

    return MetricsHandler


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Expose cross-platform host metrics for Prometheus." 
    )
    parser.add_argument(
        "--bind",
        default="0.0.0.0",
        help="Address to bind the HTTP server (default: 0.0.0.0)",
    )
    parser.add_argument(
        "--port", type=int, default=9105, help="Port for the HTTP server (default: 9105)"
    )
    parser.add_argument(
        "--once",
        action="store_true",
        help="Print metrics once to stdout instead of running the server.",
    )
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    collector = MetricCollector()

    if args.once:
        print("\n".join(collector.collect()))
        return

    handler_cls = create_handler(collector)
    server = http.server.ThreadingHTTPServer((args.bind, args.port), handler_cls)
    print(
        f"[info] Serving /metrics on http://{args.bind}:{args.port}. Press Ctrl+C to stop.",
        file=sys.stderr,
    )
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("[info] Shutting down server", file=sys.stderr)
        server.server_close()


if __name__ == "__main__":
    main()
