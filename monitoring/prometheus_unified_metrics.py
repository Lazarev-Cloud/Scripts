#!/usr/bin/env python3
#
# Unified host metrics exporter for Prometheus.
#
# Exposes CPU/memory/filesystem/network counters, lm-sensors temperatures and
# fans, SMART/NVMe drive health, and NVIDIA GPU telemetry, either over HTTP at
# /metrics, once to stdout, or as a node_exporter textfile-collector .prom file.
#
# License: MIT
# Origin:  https://github.com/Lazarev-Cloud/Scripts
# Requires: Python 3.9+ and prometheus_client. psutil, smartmontools and the
#           NVIDIA utilities are all optional; each one only affects its own
#           collector.
#
# Error model: a scrape must never fail because one subsystem is broken or
# absent. Every collector runs inside a guard that converts any exception,
# timeout, or missing tool into hostwatch_collector_up{collector="..."} 0 plus
# zero device series, and the scrape still returns 200 with everything else. The
# only fatal errors are: a missing prometheus_client (exit 3), a bad command
# line (exit 2), and failure to bind the listen socket or write the textfile
# (exit 1). A signal stops the server cleanly and exits 130. Nothing here
# installs software, and nothing writes outside the path given to --textfile.
#
# One rule follows from that model rather than from taste: which mode the
# process runs in is decided on the command line and nowhere else. An
# environment variable may supply a value, never select a mode - see
# resolve_textfile() for why a service that can be turned into a one-shot by an
# environment file is a service that can die without failing.

"""Unified host metrics exporter for Prometheus.

Run ``prometheus_unified_metrics.py --help`` for usage.
"""

from __future__ import annotations

import argparse
import errno
import json
import logging
import math
import os
import platform
import re
import shutil
import signal
import socket
import socketserver
import subprocess
import sys
import threading
import time
import wsgiref.simple_server
from typing import (
    Any,
    Callable,
    Dict,
    Iterable,
    Iterator,
    List,
    NoReturn,
    Optional,
    Sequence,
    Tuple,
)

try:
    from prometheus_client import (
        CollectorRegistry,
        Info,
        ProcessCollector,
        generate_latest,
        make_wsgi_app,
        write_to_textfile,
    )
    from prometheus_client.core import (
        CounterMetricFamily,
        GaugeMetricFamily,
        InfoMetricFamily,
        Metric,
    )
    from prometheus_client.registry import Collector
except ImportError as _exc:  # pragma: no cover - exercised only without the dep
    sys.stderr.write(
        "error: prometheus_client is required but not importable (%s).\n"
        "       Install it into the interpreter that runs this script, e.g.\n"
        "         python3 -m venv /opt/prometheus-unified-exporter/venv\n"
        "         /opt/prometheus-unified-exporter/venv/bin/pip install "
        "-r requirements.txt\n"
        "       This script deliberately does NOT install anything itself.\n" % _exc
    )
    # Literal 3, not EXIT_MISSING_DEPENDENCY: the constants are defined below,
    # and this guard has to work before any of them exist.
    raise SystemExit(3)

SCRIPT_NAME = "prometheus_unified_metrics.py"
SCRIPT_VERSION = "2.1"

# Single-word application prefix, per Prometheus naming practices. Deliberately
# NOT configurable: metric names are a contract with every dashboard and alert
# rule written against this exporter.
NS = "hostwatch"

# Exit codes, shared by every script in this repository. Documented in --help and
# in the README; keep all three in sync. The codes this exporter cannot produce
# (4 root required, 5 confirmation refused, 75 lock held) are not defined here.
EXIT_OK = 0
EXIT_FAILURE = 1
EXIT_USAGE = 2
EXIT_MISSING_DEPENDENCY = 3  # raised as a literal by the import guard above
# A signal stopped us. Under systemd this is the normal `systemctl stop` path, so
# the unit this repository installs carries SuccessExitStatus=130 to match; a
# unit written by hand needs the same line or every stop is recorded as a failure.
EXIT_INTERRUPT = 130

# How often the main thread checks whether a signal asked it to stop. Bounds
# worst-case shutdown latency; systemd's default TimeoutStopSec is 90s.
SHUTDOWN_POLL_SECONDS = 0.5
# Longest we wait for in-flight scrapes to drain before exiting anyway.
SHUTDOWN_JOIN_SECONDS = 10.0

# --- Tunables. Every one has a flag and an environment variable. --------------
#
# Every user-facing variable is LZC_EXPORTER_*, the namespace this repository
# uses, so `env | grep LZC_` shows an operator everything that is configurable.
# LZC_EXPORTER_BIND and LZC_EXPORTER_PORT are the same two names that
# setup_prometheus_exporter.sh writes into the service environment file, so the
# installed unit and a hand-run copy are configured identically.
DEFAULT_BIND = os.environ.get("LZC_EXPORTER_BIND", "127.0.0.1")
DEFAULT_PORT = os.environ.get("LZC_EXPORTER_PORT", "9105")
DEFAULT_TIMEOUT = os.environ.get("LZC_EXPORTER_TIMEOUT", "8")
DEFAULT_SMART_INTERVAL = os.environ.get("LZC_EXPORTER_SMART_INTERVAL", "60")
DEFAULT_LOG_LEVEL = os.environ.get("LZC_EXPORTER_LOG_LEVEL", "info")
# Supplies the path for a bare `--textfile`. It cannot select textfile mode on
# its own; resolve_textfile() refuses that and says why.
DEFAULT_TEXTFILE = os.environ.get("LZC_EXPORTER_TEXTFILE", "")
# Permissions for the file --textfile writes. node_exporter usually runs under
# its own account, so the default is world-readable: prometheus_client's writer
# creates the file with the ambient umask, and a service with UMask=0077 or a
# root cron job would otherwise produce a 0600 file that node_exporter reports
# as node_textfile_scrape_error 1 rather than as an error from this script.
DEFAULT_TEXTFILE_MODE = os.environ.get("LZC_EXPORTER_TEXTFILE_MODE", "0644")
DEFAULT_COLLECTORS = os.environ.get("LZC_EXPORTER_COLLECTORS", "")
DEFAULT_DISABLED = os.environ.get("LZC_EXPORTER_DISABLE_COLLECTORS", "")
# External tools, overridable because a service PATH is not a login PATH:
# smartctl lives in /usr/sbin or /usr/local/sbin on different distributions, and
# a collector that can only say "not on PATH" is a collector you cannot fix
# without editing this file.
DEFAULT_SMARTCTL = os.environ.get("LZC_EXPORTER_SMARTCTL", "smartctl")
DEFAULT_NVIDIA_SMI = os.environ.get("LZC_EXPORTER_NVIDIA_SMI", "nvidia-smi")
# Pseudo, container and snap mounts. Without this a Docker or Proxmox host grows
# one filesystem series per container layer, which is unbounded cardinality.
DEFAULT_MOUNT_EXCLUDE = os.environ.get(
    "LZC_EXPORTER_MOUNT_EXCLUDE",
    r"^/(dev|proc|sys|run)($|/)|^/var/lib/(docker|containers|kubelet)/|^/snap/",
)
# Virtual and per-guest interfaces. On a Proxmox node these grow with the guest
# count, so they are excluded by default and can be re-included with an empty
# pattern.
DEFAULT_NETDEV_EXCLUDE = os.environ.get(
    "LZC_EXPORTER_NETDEV_EXCLUDE",
    r"^(veth|tap|fwbr|fwln|fwpr|vnet|docker|br-|virbr|cali|lxcbr)",
)

LOG = logging.getLogger("hostwatch")


# --- Small helpers ------------------------------------------------------------


def usage_error(message: str) -> "NoReturn":
    """Fail with the documented usage exit status.

    `raise SystemExit("text")` prints the text but exits 1, which would
    contradict the exit-code table in --help. Bad input has to exit 2.
    """
    sys.stderr.write("%s: error: %s\n" % (SCRIPT_NAME, message))
    raise SystemExit(EXIT_USAGE)


def compile_pattern(pattern: str, what: str) -> Optional[re.Pattern]:
    """Compile an exclusion regex. An empty pattern means 'exclude nothing'."""
    if not pattern:
        return None
    try:
        return re.compile(pattern)
    except re.error as exc:
        usage_error("invalid %s regex %r: %s" % (what, pattern, exc))


def run_command(argv: Sequence[str], timeout: float) -> Optional[Tuple[int, str]]:
    """Run an external tool and return (returncode, stdout).

    Returns None when the tool is not on PATH, could not be executed, or did not
    finish within `timeout`. Never raises: a missing or wedged tool must degrade
    to "no data", not to a failed scrape. The timeout is the reason this
    exporter cannot be stalled by a dying disk.
    """
    exe = shutil.which(argv[0])
    if exe is None:
        LOG.debug("tool not on PATH: %s", argv[0])
        return None
    try:
        proc = subprocess.run(
            [exe, *argv[1:]],
            capture_output=True,
            text=True,
            errors="replace",
            timeout=timeout,
            check=False,
        )
    except subprocess.TimeoutExpired:
        LOG.warning("timed out after %.1fs: %s", timeout, " ".join(argv))
        return None
    except OSError as exc:
        LOG.warning("could not execute %s: %s", argv[0], exc)
        return None
    if proc.stderr.strip():
        LOG.debug("%s stderr: %s", argv[0], proc.stderr.strip()[:500])
    return proc.returncode, proc.stdout


def parse_json(text: str, source: str) -> Optional[Any]:
    """Parse JSON, returning None instead of raising on malformed output.

    Some lm-sensors and smartctl builds emit subtly malformed JSON; a tool that
    lies about its own output format must degrade, not crash the exporter.
    """
    try:
        return json.loads(text)
    except (ValueError, TypeError) as exc:
        LOG.warning("%s produced unparseable JSON: %s", source, exc)
        return None


def as_float(value: Any) -> Optional[float]:
    """Coerce a value to float, tolerating None and vendor sentinels.

    nvidia-smi emits '[N/A]' and '[Not Supported]' for unsupported readings on
    consumer cards, and float() raises on both.
    """
    if value is None or isinstance(value, bool):
        return None
    try:
        result = float(value)
    except (TypeError, ValueError, OverflowError):
        # OverflowError, not just the obvious two: json.loads yields Python
        # ints of arbitrary precision, so one drive reporting an absurd raw
        # SMART attribute raises here. It is an ArithmeticError, so the old
        # two-name tuple missed it, and the exception escaped as far as the
        # collector guard -- taking every disk's series down with it and
        # reporting hostwatch_collector_up 0 for the whole subsystem. This
        # function's contract is per-field degradation; one bad field must
        # cost that field only.
        return None
    if not math.isfinite(result):
        # NaN and both infinities. NaN was already rejected; infinity was not,
        # so a huge value serialized as +Inf. Prometheus accepts that token, so
        # it broke nothing, but it contradicts _finite() -- which rejects both
        # for CLI arguments -- and an infinite reading is not a measurement.
        return None
    return result


def unique_key(seen: set, candidate: str, fallback: str) -> str:
    """Return a label value that has not been used yet within this family.

    Two samples with identical label sets make Prometheus reject the entire
    scrape, so unlabelled hwmon sensors (several chips report an empty label for
    every input) must be disambiguated rather than emitted verbatim.
    """
    key = candidate or fallback
    if key not in seen:
        seen.add(key)
        return key
    suffix = 2
    while "%s_%d" % (key, suffix) in seen:
        suffix += 1
    key = "%s_%d" % (key, suffix)
    seen.add(key)
    return key


def import_optional(module_name: str) -> Optional[Any]:
    """Import a module if it is installed, else return None. Never installs."""
    import importlib
    import importlib.util

    try:
        if importlib.util.find_spec(module_name) is None:
            return None
        return importlib.import_module(module_name)
    except Exception as exc:  # a broken install must not kill the exporter
        LOG.warning("optional module %s is present but unusable: %s", module_name, exc)
        return None


# --- Collector base -----------------------------------------------------------


class SubsystemUnavailable(Exception):
    """The subsystem cannot be read here, and that is an expected condition.

    Raised for a missing tool, an unsupported platform or a permission error.
    Distinguished from an unexpected exception purely so the log stays readable:
    both produce `<ns>_collector_up 0`, but this one does not print a traceback
    on every single scrape.
    """


class Subsystem:
    """A fallible data source wrapped so it can never break a scrape.

    Subclasses implement `collect_families()` and may raise freely. `run()`
    guarantees the exporter contract: never propagate, always report an
    up/duration pair, and never emit stale device series for hardware that has
    gone away (every family is rebuilt from scratch on each scrape, which is why
    exporter metrics must never use module-level Gauge objects).
    """

    name = "subsystem"
    #: Serve cached families for this long. 0 disables caching. Only used where
    #: collection is genuinely expensive or has side effects (spinning up idle
    #: disks), never as a general-purpose background refresh.
    cache_seconds = 0.0

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._cache: Optional[Tuple[float, List[Metric], float, float]] = None
        self._last_error: Optional[str] = None

    # -- to be implemented by subclasses --

    def collect_families(self) -> Iterable[Metric]:
        raise NotImplementedError

    def unavailable_reason(self) -> Optional[str]:
        """Human-readable reason this subsystem cannot work here, or None.

        Used for a startup log line. It never gates collection: the
        authoritative runtime signal is `<ns>_collector_up`.
        """
        return None

    # -- the guarded entry point --

    def run(self) -> Tuple[List[Metric], float, float]:
        """Return (families, up, duration_seconds). Never raises."""
        # Serialising per subsystem keeps concurrent scrapes from spawning a
        # second smartctl scan against the same disks.
        with self._lock:
            return self._run_locked()

    def _run_locked(self) -> Tuple[List[Metric], float, float]:
        if self._cache is not None and self.cache_seconds > 0:
            cached_at, families, ok, elapsed = self._cache
            age = time.monotonic() - cached_at
            if age < self.cache_seconds:
                LOG.debug("collector %s: serving cache (age %.1fs)", self.name, age)
                return families, ok, elapsed

        started = time.monotonic()
        try:
            families = list(self.collect_families())
            ok = 1.0
            if self._last_error is not None:
                LOG.info("collector %s recovered", self.name)
                self._last_error = None
        except SubsystemUnavailable as exc:
            families, ok = [], 0.0
            self._note_failure(str(exc), traceback=False)
        except Exception as exc:  # noqa: BLE001 - deliberately broad, see docstring
            families, ok = [], 0.0
            self._note_failure("%s: %s" % (type(exc).__name__, exc), traceback=True)
        elapsed = time.monotonic() - started

        if self.cache_seconds > 0:
            self._cache = (time.monotonic(), families, ok, elapsed)
        return families, ok, elapsed

    def _note_failure(self, message: str, traceback: bool) -> None:
        """Log a failure once, then stay quiet until it changes.

        A collector whose tool is absent fails on every scrape. Logging the same
        error every 15 seconds forever buries everything else in the journal, so
        only the first occurrence of each distinct message is logged loudly.
        """
        if message == self._last_error:
            LOG.debug("collector %s still failing: %s", self.name, message)
            return
        self._last_error = message
        if traceback:
            LOG.exception("collector %s failed: %s", self.name, message)
        else:
            LOG.warning("collector %s unavailable: %s", self.name, message)


class ExporterCollector(Collector):
    """The single registered collector, aggregating every subsystem.

    One collector rather than one per subsystem because the exposition format
    allows exactly one HELP and one TYPE line per metric family: if each
    subsystem yielded its own `<ns>_collector_up` family, the output would carry
    four copies of that header and Prometheus would reject the whole scrape.
    """

    def __init__(self, subsystems: Sequence[Subsystem]) -> None:
        self._subsystems = list(subsystems)

    def collect(self) -> Iterator[Metric]:
        # A cache hit in Subsystem.run() replays the stored (families, up,
        # duration) triple, so these two families are served from the cache
        # alongside the data they describe. Saying "the last attempt" without
        # that qualifier reads as a scrape-time signal, which is exactly the
        # misreading the cache note on the disk families exists to prevent.
        # Conditional, so the wording stays true when nothing caches (no smart
        # collector, or --smart-interval 0).
        note = (
            " Where a collector caches (see --smart-interval), this describes "
            "the cached attempt rather than the current scrape."
            if any(getattr(s, "cache_seconds", 0) > 0 for s in self._subsystems)
            else ""
        )
        up = GaugeMetricFamily(
            "%s_collector_up" % NS,
            "1 if this collector gathered its data on the last attempt, 0 if the "
            "required tool was missing or the attempt failed." + note,
            labels=["collector"],
        )
        duration = GaugeMetricFamily(
            "%s_collector_duration_seconds" % NS,
            "Seconds the last collection attempt for this collector took." + note,
            labels=["collector"],
        )
        for subsystem in self._subsystems:
            families, ok, elapsed = subsystem.run()
            yield from families
            up.add_metric([subsystem.name], ok)
            duration.add_metric([subsystem.name], elapsed)
        yield up
        yield duration


# --- Host collector (psutil) --------------------------------------------------


class HostCollector(Subsystem):
    """CPU, memory, filesystem, network and uptime, via psutil.

    On a Linux host running node_exporter this collector is redundant; disable
    it with --no-collector host. It exists so the exporter is useful on hosts
    where node_exporter is not deployed, including Windows.
    """

    name = "host"

    def __init__(self, mount_exclude: Optional[re.Pattern], netdev_exclude: Optional[re.Pattern]) -> None:
        super().__init__()
        self._psutil = import_optional("psutil")
        self._mount_exclude = mount_exclude
        self._netdev_exclude = netdev_exclude

    def unavailable_reason(self) -> Optional[str]:
        if self._psutil is None:
            return "psutil is not installed"
        return None

    def collect_families(self) -> Iterable[Metric]:
        psutil = self._psutil
        if psutil is None:
            raise SubsystemUnavailable("psutil is not installed")

        yield self._host_info()
        yield from self._uptime(psutil)
        yield from self._cpu(psutil)
        yield from self._load()
        yield from self._memory(psutil)
        yield from self._filesystems(psutil)
        yield from self._network(psutil)

    def _host_info(self) -> Metric:
        info = InfoMetricFamily(
            "%s_host" % NS,
            "Operating system identity of the scraped host.",
        )
        info.add_metric(
            [],
            {
                "os": platform.system() or "unknown",
                "release": platform.release() or "unknown",
                "version": platform.version() or "unknown",
                "machine": platform.machine() or "unknown",
            },
        )
        return info

    def _uptime(self, psutil: Any) -> Iterable[Metric]:
        try:
            boot = float(psutil.boot_time())
        except Exception:  # noqa: BLE001 - psutil raises OSError variants per platform
            return
        family = GaugeMetricFamily(
            "%s_boot_time_seconds" % NS,
            "Unix timestamp of the last boot. Uptime is time() minus this.",
        )
        family.add_metric([], boot)
        yield family

    def _cpu(self, psutil: Any) -> Iterable[Metric]:
        # Cumulative counter, not an instantaneous percentage: the old exporter
        # slept 200 ms inside the scrape to compute one. rate() over this gives
        # the same answer for free and works across any window.
        times = psutil.cpu_times()
        seconds = CounterMetricFamily(
            "%s_cpu_seconds_total" % NS,
            "Cumulative CPU time across all logical CPUs, by mode. For a 0-1 "
            "utilisation ratio: 1 - rate(...{mode=\"idle\"}[5m]) "
            "/ ignoring(mode) hostwatch_cpu_count",
            labels=["mode"],
        )
        # Aggregate, not per-core: per-core detail multiplies series by the core
        # count for information node_exporter already provides.
        for mode in times._fields:
            value = as_float(getattr(times, mode, None))
            if value is not None:
                seconds.add_metric([mode], value)
        yield seconds

        count = as_float(psutil.cpu_count(logical=True))
        if count:
            family = GaugeMetricFamily(
                "%s_cpu_count" % NS, "Number of logical CPUs visible to the host."
            )
            family.add_metric([], count)
            yield family

    def _load(self) -> Iterable[Metric]:
        # os.getloadavg, not psutil.getloadavg: on Windows psutil *simulates* a
        # load average from a background sampling thread, which is a different
        # quantity wearing the same name. Better to emit nothing.
        getloadavg = getattr(os, "getloadavg", None)
        if getloadavg is None:
            return
        try:
            load1, load5, load15 = getloadavg()
        except OSError:
            return
        for window, value in (("1", load1), ("5", load5), ("15", load15)):
            family = GaugeMetricFamily(
                "%s_load%s" % (NS, window),
                "%s-minute load average." % window,
            )
            family.add_metric([], float(value))
            yield family

    def _memory(self, psutil: Any) -> Iterable[Metric]:
        vm = psutil.virtual_memory()
        # One metric per quantity. The old exporter used a `type` label, which
        # makes sum() over the family meaningless.
        for suffix, attr, help_text in (
            ("total", "total", "Total physical memory."),
            ("available", "available", "Memory available for new allocations without swapping."),
            ("used", "used", "Memory in use, excluding cache and buffers."),
            ("free", "free", "Memory not used for anything at all."),
        ):
            value = as_float(getattr(vm, attr, None))
            if value is None:
                continue
            family = GaugeMetricFamily(
                "%s_memory_%s_bytes" % (NS, suffix), help_text
            )
            family.add_metric([], value)
            yield family

        swap = psutil.swap_memory()
        for suffix, attr, help_text in (
            ("total", "total", "Total swap space."),
            ("used", "used", "Swap space in use."),
            ("free", "free", "Swap space not in use."),
        ):
            value = as_float(getattr(swap, attr, None))
            if value is None:
                continue
            family = GaugeMetricFamily("%s_swap_%s_bytes" % (NS, suffix), help_text)
            family.add_metric([], value)
            yield family

    def _filesystems(self, psutil: Any) -> Iterable[Metric]:
        labels = ["device", "mountpoint", "fstype"]
        size = GaugeMetricFamily(
            "%s_filesystem_size_bytes" % NS, "Filesystem capacity.", labels=labels
        )
        used = GaugeMetricFamily(
            "%s_filesystem_used_bytes" % NS, "Filesystem space in use.", labels=labels
        )
        avail = GaugeMetricFamily(
            "%s_filesystem_avail_bytes" % NS,
            "Filesystem space available to an unprivileged user. This is "
            "statvfs f_bavail, so it excludes root-reserved blocks and is "
            "normally smaller than size minus used.",
            labels=labels,
        )

        seen: set = set()
        for part in psutil.disk_partitions(all=False):
            mount = part.mountpoint or ""
            if self._mount_exclude is not None and self._mount_exclude.search(mount):
                LOG.debug("filesystem %s excluded by pattern", mount)
                continue
            if mount in seen:
                continue
            try:
                usage = psutil.disk_usage(mount)
            except (PermissionError, OSError) as exc:
                LOG.debug("cannot stat %s: %s", mount, exc)
                continue
            seen.add(mount)
            values = [part.device or "", mount, part.fstype or ""]
            size.add_metric(values, float(usage.total))
            used.add_metric(values, float(usage.used))
            avail.add_metric(values, float(usage.free))

        yield size
        yield used
        yield avail

    def _network(self, psutil: Any) -> Iterable[Metric]:
        try:
            counters = psutil.net_io_counters(pernic=True) or {}
        except Exception:  # noqa: BLE001 - not implemented on some platforms
            return

        # Receive and transmit are separate metrics, not a `direction` label:
        # summing bytes sent and bytes received is never a meaningful number.
        specs = (
            ("receive_bytes_total", "bytes_recv", "Bytes received."),
            ("transmit_bytes_total", "bytes_sent", "Bytes transmitted."),
            ("receive_packets_total", "packets_recv", "Packets received."),
            ("transmit_packets_total", "packets_sent", "Packets transmitted."),
            ("receive_errors_total", "errin", "Receive errors."),
            ("transmit_errors_total", "errout", "Transmit errors."),
            ("receive_drop_total", "dropin", "Inbound packets dropped."),
            ("transmit_drop_total", "dropout", "Outbound packets dropped."),
        )
        families = {
            suffix: CounterMetricFamily(
                "%s_network_%s" % (NS, suffix),
                "%s Cumulative since boot." % help_text,
                labels=["device"],
            )
            for suffix, _attr, help_text in specs
        }

        for device, stats in counters.items():
            if self._netdev_exclude is not None and self._netdev_exclude.search(device):
                LOG.debug("network device %s excluded by pattern", device)
                continue
            for suffix, attr, _help in specs:
                value = as_float(getattr(stats, attr, None))
                if value is not None:
                    families[suffix].add_metric([device], value)

        yield from families.values()


# --- Sensors collector (lm-sensors / hwmon via psutil) ------------------------


class SensorsCollector(Subsystem):
    """Board and CPU temperatures and fan speeds.

    Reads psutil's hwmon bindings rather than shelling out to `sensors -j`: no
    subprocess, no JSON, and it works whether or not lm-sensors userspace is
    installed. Linux only; psutil exposes no equivalent on Windows.
    """

    name = "sensors"

    def __init__(self) -> None:
        super().__init__()
        self._psutil = import_optional("psutil")

    def unavailable_reason(self) -> Optional[str]:
        if self._psutil is None:
            return "psutil is not installed"
        if not hasattr(self._psutil, "sensors_temperatures"):
            return "this platform exposes no hwmon sensors (Linux only)"
        return None

    def collect_families(self) -> Iterable[Metric]:
        psutil = self._psutil
        if psutil is None:
            raise SubsystemUnavailable("psutil is not installed")
        if not hasattr(psutil, "sensors_temperatures"):
            raise SubsystemUnavailable(
                "this platform exposes no hwmon sensors (Linux only)"
            )

        temps = psutil.sensors_temperatures(fahrenheit=False) or {}
        if not temps and not getattr(psutil, "sensors_fans", None):
            raise SubsystemUnavailable("no hwmon chip reported any reading")

        labels = ["chip", "sensor"]
        current = GaugeMetricFamily(
            "%s_sensor_temperature_celsius" % NS,
            "Current temperature reported by an hwmon chip sensor.",
            labels=labels,
        )
        high = GaugeMetricFamily(
            "%s_sensor_temperature_high_celsius" % NS,
            "Vendor high-temperature threshold for this sensor, where reported.",
            labels=labels,
        )
        critical = GaugeMetricFamily(
            "%s_sensor_temperature_critical_celsius" % NS,
            "Vendor critical-temperature threshold for this sensor, where reported.",
            labels=labels,
        )

        for chip, entries in temps.items():
            seen: set = set()
            for index, entry in enumerate(entries):
                sensor = unique_key(seen, getattr(entry, "label", "") or "", "input%d" % index)
                value = as_float(getattr(entry, "current", None))
                if value is not None:
                    current.add_metric([chip, sensor], value)
                value = as_float(getattr(entry, "high", None))
                if value is not None:
                    high.add_metric([chip, sensor], value)
                value = as_float(getattr(entry, "critical", None))
                if value is not None:
                    critical.add_metric([chip, sensor], value)

        yield current
        yield high
        yield critical

        fans_fn = getattr(psutil, "sensors_fans", None)
        if fans_fn is None:
            return
        try:
            fans = fans_fn() or {}
        except Exception:  # noqa: BLE001 - not implemented everywhere
            return
        rpm = GaugeMetricFamily(
            "%s_sensor_fan_rpm" % NS,
            "Fan speed reported by an hwmon chip, in revolutions per minute.",
            labels=labels,
        )
        for chip, entries in fans.items():
            seen = set()
            for index, entry in enumerate(entries):
                sensor = unique_key(seen, getattr(entry, "label", "") or "", "fan%d" % index)
                value = as_float(getattr(entry, "current", None))
                if value is not None:
                    rpm.add_metric([chip, sensor], value)
        yield rpm


# --- SMART collector (smartctl) ----------------------------------------------

# smartctl's exit status is a bitmask (smartctl(8) RETURN VALUES). Bits 0 and 1
# mean the command line was wrong or the device could not be opened - there is
# no usable output. Bits 2 and above mean things like "SMART status check
# returned DISK FAILING", where stdout is still complete, valid JSON. The old
# exporter used check=True and so discarded data for exactly the failing disks
# an operator most needs to see.
SMARTCTL_FATAL_MASK = 0b11


class SmartCollector(Subsystem):
    """Drive health from smartmontools.

    Covers SATA, SAS and NVMe through a single tool; smartmontools >= 7.0 is
    required for --json. Needs root: smartctl issues ATA_12/ATA_16 SCSI
    passthrough commands, and membership of the `disk` group is not sufficient.

    Results are cached for `cache_seconds` so a scrape never sits in the disk
    spin-up path. For exhaustive per-attribute SMART data, run
    prometheus-community/smartctl_exporter instead; this collector deliberately
    exposes only the handful of readings that are comparable across vendors.
    """

    name = "smart"

    def __init__(self, timeout: float, cache_seconds: float, smartctl: str = DEFAULT_SMARTCTL) -> None:
        super().__init__()
        self._timeout = timeout
        self.cache_seconds = cache_seconds
        self._smartctl = smartctl

    def unavailable_reason(self) -> Optional[str]:
        if shutil.which(self._smartctl) is None:
            return (
                "%s is not on PATH and is not an executable path (install "
                "smartmontools >= 7.0, or point --smartctl at it)" % self._smartctl
            )
        if hasattr(os, "geteuid") and os.geteuid() != 0:
            return "not running as root; smartctl needs raw device access"
        return None

    def _cache_note(self) -> str:
        """The HELP suffix that declares this family is served from a cache.

        The Prometheus exporter guidelines require a metric that is cached
        rather than read at scrape time to say so in its HELP string, because
        the alternative is an operator reading a 60-second-old temperature as if
        it were current. Generated from the configured interval rather than
        written out, so the text cannot drift from the behaviour.
        """
        if self.cache_seconds <= 0:
            return ""
        # Deliberately terse: it is appended to twelve HELP strings, and the
        # reason caching exists at all belongs in the class docstring, not
        # twelve times in the exposition.
        return (
            " Cached: read at most every %g seconds (--smart-interval), so it "
            "can lag the scrape by that much." % self.cache_seconds
        )

    def _devices(self) -> List[Tuple[str, str]]:
        result = run_command([self._smartctl, "--json", "--scan-open"], self._timeout)
        if result is None:
            raise SubsystemUnavailable(
                "%s is not on PATH, or it did not respond within the timeout"
                % self._smartctl
            )
        _rc, stdout = result
        payload = parse_json(stdout, "smartctl --scan-open")
        if not isinstance(payload, dict):
            raise SubsystemUnavailable("smartctl --scan-open returned no usable JSON")

        devices: List[Tuple[str, str]] = []
        seen: set = set()
        for entry in payload.get("devices") or []:
            if not isinstance(entry, dict):
                continue
            name = entry.get("name")
            # One physical drive can be reported twice under different -d types
            # (sat and scsi, say). Keep the first; emitting both would duplicate
            # every series for that drive.
            if not name or name in seen:
                continue
            seen.add(name)
            devices.append((name, entry.get("type") or "auto"))
        return devices

    def _device_payload(self, name: str, dev_type: str) -> Optional[dict]:
        result = run_command(
            [self._smartctl, "--json", "-H", "-i", "-A", "-d", dev_type, name],
            self._timeout,
        )
        if result is None:
            return None
        returncode, stdout = result
        payload = parse_json(stdout, "smartctl %s" % name)
        if not isinstance(payload, dict):
            return None
        if returncode & SMARTCTL_FATAL_MASK:
            LOG.warning(
                "smartctl could not read %s (exit status %d)", name, returncode
            )
            return None
        if returncode:
            # Bits 2..7: the drive is reporting a problem. That is data, not an
            # error - keep the payload and let the metrics say so.
            LOG.debug("smartctl reports condition bits for %s (exit %d)", name, returncode)
        return payload

    def collect_families(self) -> Iterable[Metric]:
        devices = self._devices()

        # Every family below is built through these helpers so the cache note is
        # appended in one place. A metric added later cannot accidentally omit
        # it.
        note = self._cache_note()

        def gauge(suffix: str, help_text: str) -> GaugeMetricFamily:
            return GaugeMetricFamily(
                "%s_%s" % (NS, suffix), help_text + note, labels=["device"]
            )

        def counter(suffix: str, help_text: str) -> CounterMetricFamily:
            return CounterMetricFamily(
                "%s_%s" % (NS, suffix), help_text + note, labels=["device"]
            )

        info = InfoMetricFamily(
            "%s_disk" % NS,
            "Drive identity. Join on `device` to attach model and serial to the "
            "other disk metrics without repeating them on every series." + note,
            labels=["device"],
        )
        healthy = gauge(
            "disk_health_ok",
            "1 if the drive's SMART overall-health self-assessment passed, 0 if "
            "it failed.",
        )
        temperature = gauge(
            "disk_temperature_celsius",
            "Current drive temperature (smartctl temperature.current).",
        )
        power_on = counter(
            "disk_power_on_seconds_total",
            "Cumulative powered-on time (smartctl power_on_time.hours, "
            "converted from hours to seconds).",
        )
        power_cycles = counter(
            "disk_power_cycles_total",
            "Cumulative power cycle count.",
        )
        spare_ratio = gauge(
            "disk_available_spare_ratio",
            "NVMe available spare capacity as a ratio of 0-1 (smartctl "
            "nvme_smart_health_information_log.available_spare, converted from "
            "percent).",
        )
        wear_ratio = gauge(
            "disk_endurance_used_ratio",
            "NVMe endurance consumed as a ratio of 0-1 (smartctl "
            "nvme_smart_health_information_log.percentage_used, converted from "
            "percent). Values above 1 are legal and mean the rated endurance is "
            "exhausted.",
        )
        media_errors = counter(
            "disk_media_errors_total",
            "NVMe media and data integrity errors.",
        )
        realloc = counter(
            "disk_reallocated_sectors_total",
            "ATA SMART attribute 5 (Reallocated_Sector_Ct) raw value.",
        )
        pending = gauge(
            "disk_pending_sectors",
            "ATA SMART attribute 197 (Current_Pending_Sector) raw value. A "
            "gauge, not a counter: pending sectors clear when reallocated.",
        )
        uncorrectable = gauge(
            "disk_uncorrectable_sectors",
            "ATA SMART attribute 198 (Offline_Uncorrectable) raw value.",
        )
        crc_errors = counter(
            "disk_interface_crc_errors_total",
            "ATA SMART attribute 199 (UDMA_CRC_Error_Count) raw value. Usually "
            "a cable or backplane fault rather than a failing drive.",
        )

        read_count = 0
        for name, dev_type in devices:
            payload = self._device_payload(name, dev_type)
            if payload is None:
                continue
            read_count += 1
            self._add_device(
                name,
                payload,
                info=info,
                healthy=healthy,
                temperature=temperature,
                power_on=power_on,
                power_cycles=power_cycles,
                spare_ratio=spare_ratio,
                wear_ratio=wear_ratio,
                media_errors=media_errors,
                realloc=realloc,
                pending=pending,
                uncorrectable=uncorrectable,
                crc_errors=crc_errors,
            )

        if devices and read_count == 0:
            # Almost always "not running as root": smartctl needs ATA_12/ATA_16
            # SCSI passthrough, and membership of the `disk` group is not enough.
            raise SubsystemUnavailable(
                "%s found %d device(s) but could read none of them; "
                "this collector needs root" % (self._smartctl, len(devices))
            )

        yield info
        yield healthy
        yield temperature
        yield power_on
        yield power_cycles
        yield spare_ratio
        yield wear_ratio
        yield media_errors
        yield realloc
        yield pending
        yield uncorrectable
        yield crc_errors

    @staticmethod
    def _add_device(name: str, payload: dict, **families: Any) -> None:
        labels = [name]

        families["info"].add_metric(
            labels,
            {
                "model": str(payload.get("model_name") or "unknown"),
                "serial": str(payload.get("serial_number") or "unknown"),
                "firmware": str(payload.get("firmware_version") or "unknown"),
                "protocol": str(payload.get("device", {}).get("protocol") or "unknown"),
            },
        )

        status = payload.get("smart_status")
        if isinstance(status, dict) and "passed" in status:
            families["healthy"].add_metric(labels, 1.0 if status["passed"] else 0.0)

        temp = payload.get("temperature")
        if isinstance(temp, dict):
            value = as_float(temp.get("current"))
            if value is not None:
                families["temperature"].add_metric(labels, value)

        hours = payload.get("power_on_time")
        if isinstance(hours, dict):
            value = as_float(hours.get("hours"))
            if value is not None:
                families["power_on"].add_metric(labels, value * 3600.0)

        value = as_float(payload.get("power_cycle_count"))
        if value is not None:
            families["power_cycles"].add_metric(labels, value)

        nvme = payload.get("nvme_smart_health_information_log")
        if isinstance(nvme, dict):
            value = as_float(nvme.get("available_spare"))
            if value is not None:
                families["spare_ratio"].add_metric(labels, value / 100.0)
            value = as_float(nvme.get("percentage_used"))
            if value is not None:
                families["wear_ratio"].add_metric(labels, value / 100.0)
            value = as_float(nvme.get("media_errors"))
            if value is not None:
                families["media_errors"].add_metric(labels, value)

        ata = payload.get("ata_smart_attributes")
        if isinstance(ata, dict):
            by_id = {
                5: "realloc",
                197: "pending",
                198: "uncorrectable",
                199: "crc_errors",
            }
            for attribute in ata.get("table") or []:
                if not isinstance(attribute, dict):
                    continue
                target = by_id.get(attribute.get("id"))
                if target is None:
                    continue
                raw = attribute.get("raw")
                value = as_float(raw.get("value") if isinstance(raw, dict) else raw)
                if value is not None:
                    families[target].add_metric(labels, value)


# --- GPU collector (NVML, falling back to nvidia-smi) -------------------------


class GpuCollector(Subsystem):
    """NVIDIA GPU telemetry.

    Prefers in-process NVML (the `pynvml` module, shipped by `nvidia-ml-py`) and
    falls back to parsing `nvidia-smi --query-gpu`. NVML initialisation is
    retried on every scrape rather than latched at construction: the old
    exporter initialised once in __init__, so a driver reload, a GPU reset, or
    an exporter that started before the driver was ready produced zero GPU
    series forever with no signal that anything was wrong.

    For datacentre GPUs, NVIDIA/dcgm-exporter is the better answer; this exists
    so a single-box host does not need a second daemon.
    """

    name = "gpu"

    _SMI_FIELDS = (
        "index",
        "uuid",
        "name",
        "utilization.gpu",
        "utilization.memory",
        "memory.total",
        "memory.used",
        "memory.free",
        "temperature.gpu",
        "fan.speed",
        "power.draw",
        "power.limit",
    )

    def __init__(self, timeout: float, nvidia_smi: str = DEFAULT_NVIDIA_SMI) -> None:
        super().__init__()
        self._timeout = timeout
        self._nvidia_smi = nvidia_smi
        self._nvml: Optional[Any] = None
        self._nvml_initialised = False

    def unavailable_reason(self) -> Optional[str]:
        if import_optional("pynvml") is None and shutil.which(self._nvidia_smi) is None:
            return (
                "neither the pynvml module nor %s is available"
                % self._nvidia_smi
            )
        return None

    def collect_families(self) -> Iterable[Metric]:
        readings = self._read_nvml()
        if readings is None:
            readings = self._read_nvidia_smi()
        if readings is None:
            raise SubsystemUnavailable(
                "neither NVML nor %s returned data; install nvidia-ml-py or the "
                "NVIDIA driver utilities, point --nvidia-smi at the binary, or "
                "disable this collector" % self._nvidia_smi
            )
        if not readings:
            # A working driver with zero GPUs is a successful, empty collection.
            LOG.debug("gpu collector: driver responded with no devices")
        return self._build(readings)

    # -- NVML path --

    def _ensure_nvml(self) -> Optional[Any]:
        """(Re-)initialise NVML. Retried every scrape, never latched."""
        if self._nvml is None:
            self._nvml = import_optional("pynvml")
        if self._nvml is None:
            return None
        if self._nvml_initialised:
            return self._nvml
        try:
            self._nvml.nvmlInit()
        except Exception as exc:  # noqa: BLE001 - NVMLError plus OSError on missing lib
            LOG.debug("NVML init failed, will retry next scrape: %s", exc)
            return None
        self._nvml_initialised = True
        LOG.info("NVML initialised")
        return self._nvml

    def _read_nvml(self) -> Optional[List[Dict[str, Any]]]:
        nvml = self._ensure_nvml()
        if nvml is None:
            return None
        try:
            count = nvml.nvmlDeviceGetCount()
        except Exception as exc:  # noqa: BLE001
            LOG.warning("NVML became unusable, resetting: %s", exc)
            self._nvml_initialised = False
            return None

        def text(value: Any) -> str:
            if isinstance(value, bytes):
                return value.decode("utf-8", "replace")
            return str(value)

        readings: List[Dict[str, Any]] = []
        for index in range(count):
            try:
                handle = nvml.nvmlDeviceGetHandleByIndex(index)
            except Exception as exc:  # noqa: BLE001
                LOG.debug("GPU %d handle unavailable: %s", index, exc)
                continue
            reading: Dict[str, Any] = {"index": str(index)}

            def probe(key: str, fn: Callable[[], Any]) -> None:
                try:
                    reading[key] = fn()
                except Exception as exc:  # noqa: BLE001 - per-field, per-card support varies
                    LOG.debug("GPU %d: %s unavailable: %s", index, key, exc)

            probe("uuid", lambda: text(nvml.nvmlDeviceGetUUID(handle)))
            probe("name", lambda: text(nvml.nvmlDeviceGetName(handle)))
            probe("temperature", lambda: nvml.nvmlDeviceGetTemperature(
                handle, nvml.NVML_TEMPERATURE_GPU))
            probe("fan_percent", lambda: nvml.nvmlDeviceGetFanSpeed(handle))
            probe("power_watts", lambda: nvml.nvmlDeviceGetPowerUsage(handle) / 1000.0)
            probe("power_limit_watts",
                  lambda: nvml.nvmlDeviceGetEnforcedPowerLimit(handle) / 1000.0)

            try:
                rates = nvml.nvmlDeviceGetUtilizationRates(handle)
                reading["gpu_percent"] = rates.gpu
                reading["memory_percent"] = rates.memory
            except Exception as exc:  # noqa: BLE001
                LOG.debug("GPU %d: utilisation unavailable: %s", index, exc)

            try:
                memory = nvml.nvmlDeviceGetMemoryInfo(handle)
                reading["memory_total"] = memory.total
                reading["memory_used"] = memory.used
                reading["memory_free"] = memory.free
            except Exception as exc:  # noqa: BLE001
                LOG.debug("GPU %d: memory unavailable: %s", index, exc)

            readings.append(reading)
        return readings

    # -- nvidia-smi path --

    def _read_nvidia_smi(self) -> Optional[List[Dict[str, Any]]]:
        result = run_command(
            [
                self._nvidia_smi,
                "--query-gpu=%s" % ",".join(self._SMI_FIELDS),
                "--format=csv,noheader,nounits",
            ],
            self._timeout,
        )
        if result is None:
            return None
        returncode, stdout = result
        if returncode != 0:
            LOG.warning("%s exited %d", self._nvidia_smi, returncode)
            return None

        readings: List[Dict[str, Any]] = []
        for line in stdout.splitlines():
            if not line.strip():
                continue
            cells = [cell.strip() for cell in line.split(",")]
            if len(cells) != len(self._SMI_FIELDS):
                LOG.warning("unexpected nvidia-smi row: %r", line)
                continue
            # Consumer cards emit '[N/A]' and '[Not Supported]' for fan speed and
            # power; as_float() turns those into None rather than raising.
            readings.append(
                {
                    "index": cells[0],
                    "uuid": cells[1],
                    "name": cells[2],
                    "gpu_percent": cells[3],
                    "memory_percent": cells[4],
                    # nvidia-smi reports MiB with --format=nounits.
                    "memory_total": self._mib(cells[5]),
                    "memory_used": self._mib(cells[6]),
                    "memory_free": self._mib(cells[7]),
                    "temperature": cells[8],
                    "fan_percent": cells[9],
                    "power_watts": cells[10],
                    "power_limit_watts": cells[11],
                }
            )
        return readings

    @staticmethod
    def _mib(cell: str) -> Optional[float]:
        value = as_float(cell)
        return None if value is None else value * 1024.0 * 1024.0

    # -- shared metric construction --

    @staticmethod
    def _build(readings: Sequence[Dict[str, Any]]) -> List[Metric]:
        info = InfoMetricFamily(
            "%s_gpu" % NS,
            "GPU identity. Join on `gpu` to attach the model name and UUID to "
            "the other GPU metrics.",
            labels=["gpu"],
        )
        specs: List[Tuple[str, str, str, Callable[[Any], Optional[float]]]] = [
            ("utilization_ratio", "gpu_percent",
             "Fraction of the last sampling period the GPU was busy, 0-1.",
             lambda v: None if as_float(v) is None else as_float(v) / 100.0),
            ("memory_utilization_ratio", "memory_percent",
             "Fraction of the last sampling period GPU memory was being read or "
             "written, 0-1. This is bandwidth activity, not occupancy.",
             lambda v: None if as_float(v) is None else as_float(v) / 100.0),
            ("memory_total_bytes", "memory_total", "Total GPU memory.", as_float),
            ("memory_used_bytes", "memory_used", "GPU memory in use.", as_float),
            ("memory_free_bytes", "memory_free", "GPU memory free.", as_float),
            ("temperature_celsius", "temperature", "GPU core temperature.", as_float),
            ("fan_speed_ratio", "fan_percent",
             "Fan speed as a fraction of maximum, 0-1. Absent on passively "
             "cooled cards.",
             lambda v: None if as_float(v) is None else as_float(v) / 100.0),
            ("power_watts", "power_watts", "Current board power draw.", as_float),
            ("power_limit_watts", "power_limit_watts",
             "Enforced board power limit.", as_float),
        ]
        families = {
            suffix: GaugeMetricFamily(
                "%s_gpu_%s" % (NS, suffix), help_text, labels=["gpu"]
            )
            for suffix, _key, help_text, _conv in specs
        }

        for reading in readings:
            gpu = str(reading.get("index", "unknown"))
            info.add_metric(
                [gpu],
                {
                    "uuid": str(reading.get("uuid") or "unknown"),
                    "name": str(reading.get("name") or "unknown"),
                },
            )
            for suffix, key, _help, convert in specs:
                value = convert(reading.get(key))
                if value is not None:
                    families[suffix].add_metric([gpu], value)

        return [info, *families.values()]


# --- HTTP serving -------------------------------------------------------------

LANDING_PAGE = (
    "<!doctype html><html><head><title>Unified host metrics exporter</title>"
    "</head><body><h1>Unified host metrics exporter</h1>"
    "<p><a href=\"/metrics\">Metrics</a></p></body></html>"
).encode("utf-8")


class QuietWSGIRequestHandler(wsgiref.simple_server.WSGIRequestHandler):
    """Route request logging through `logging` instead of stderr scribbling."""

    def log_message(self, format: str, *args: Any) -> None:  # noqa: A002
        LOG.debug("%s %s", self.address_string(), format % args)

    def get_environ(self) -> dict:
        environ = super().get_environ()
        environ["REMOTE_ADDR"] = self.client_address[0]
        return environ


class ThreadingWSGIServer(socketserver.ThreadingMixIn, wsgiref.simple_server.WSGIServer):
    """Threaded so one slow scrape cannot block a second, and daemonised so a
    stuck request thread cannot keep the process alive after shutdown."""

    daemon_threads = True
    address_family = socket.AF_INET

    def handle_error(self, request: Any, client_address: Any) -> None:
        exc = sys.exc_info()[1]
        # A scraper that hangs up mid-response is routine, not an incident.
        if isinstance(exc, (BrokenPipeError, ConnectionResetError)):
            LOG.debug("client %s disconnected early", client_address)
            return
        LOG.exception("error handling request from %s", client_address)


def build_wsgi_app(registry: CollectorRegistry) -> Callable:
    """A three-route app: landing page, /metrics, and a liveness probe.

    prometheus_client's make_wsgi_app serves metrics for every path, which makes
    a typo in a scrape config look like it works. Routing explicitly means a
    wrong path returns 404.
    """
    metrics_app = make_wsgi_app(registry)

    def app(environ: dict, start_response: Callable) -> Iterable[bytes]:
        path = environ.get("PATH_INFO", "/")
        if path in ("/metrics", "/metrics/"):
            return metrics_app(environ, start_response)
        if path in ("/", "/index.html"):
            start_response(
                "200 OK",
                [
                    ("Content-Type", "text/html; charset=utf-8"),
                    ("Content-Length", str(len(LANDING_PAGE))),
                ],
            )
            return [LANDING_PAGE]
        if path in ("/-/healthy", "/-/ready"):
            body = b"OK\n"
            start_response(
                "200 OK",
                [("Content-Type", "text/plain"), ("Content-Length", str(len(body)))],
            )
            return [body]
        body = b"404 Not Found: try /metrics\n"
        start_response(
            "404 Not Found",
            [("Content-Type", "text/plain"), ("Content-Length", str(len(body)))],
        )
        return [body]

    return app


def make_server(bind: str, port: int, registry: CollectorRegistry) -> ThreadingWSGIServer:
    """Bind the listening socket, choosing the address family from `bind`."""
    server_class = ThreadingWSGIServer
    try:
        infos = socket.getaddrinfo(bind, port, proto=socket.IPPROTO_TCP)
    except socket.gaierror as exc:
        usage_error("cannot resolve bind address %r: %s" % (bind, exc))
    family = infos[0][0] if infos else socket.AF_INET
    if family == socket.AF_INET6:
        server_class = type(
            "ThreadingWSGIServer6", (ThreadingWSGIServer,), {"address_family": socket.AF_INET6}
        )
    return wsgiref.simple_server.make_server(
        bind,
        port,
        build_wsgi_app(registry),
        server_class=server_class,
        handler_class=QuietWSGIRequestHandler,
    )


def serve(bind: str, port: int, registry: CollectorRegistry) -> int:
    """Serve until SIGTERM/SIGINT (and SIGHUP where it exists), then stop cleanly.

    systemd sends SIGTERM. The old exporter only handled KeyboardInterrupt, so a
    `systemctl stop` killed it mid-scrape and never called server_close().
    """
    try:
        server = make_server(bind, port, registry)
    except OSError as exc:
        if exc.errno in (errno.EADDRINUSE, errno.EACCES):
            LOG.error("cannot listen on %s:%d: %s", bind, port, exc.strerror)
        else:
            LOG.error("cannot listen on %s:%d: %s", bind, port, exc)
        return EXIT_FAILURE

    # A plain slot, not a threading.Event, and no logging inside the handler.
    # Two reasons, both load-bearing:
    #   * The handler runs in the main thread, which is also the thread doing the
    #     waiting, and Event.set() from a handler that interrupted Event.wait()
    #     on that same thread does not reliably wake the waiter (verified: the
    #     handler runs, the flag is set, and wait() still blocks for its full
    #     timeout).
    #   * logging acquires locks, so calling it from a handler that interrupted
    #     another logging call can deadlock.
    # Assigning to a list slot is atomic and async-signal-safe; the message is
    # logged by the main loop once it notices.
    stopping: List[Optional[int]] = [None]

    def on_signal(signum: int, _frame: Any) -> None:
        stopping[0] = signum

    for name in ("SIGTERM", "SIGINT", "SIGHUP"):
        signum = getattr(signal, name, None)
        if signum is not None:
            try:
                signal.signal(signum, on_signal)
            except (ValueError, OSError):  # not the main thread, or unsupported
                LOG.debug("cannot install handler for %s", name)

    thread = threading.Thread(target=server.serve_forever, name="hostwatch-http", daemon=True)
    thread.start()
    LOG.info("serving metrics on http://%s:%d/metrics", bind, port)
    if bind not in ("0.0.0.0", "::", ""):
        LOG.info(
            "bound to %s only; pass --bind 0.0.0.0 (or LZC_EXPORTER_BIND) to accept "
            "scrapes from other hosts",
            bind,
        )

    try:
        while stopping[0] is None:
            time.sleep(SHUTDOWN_POLL_SECONDS)
        LOG.info("received %s, shutting down", signal.Signals(stopping[0]).name)
    except KeyboardInterrupt:  # only if the SIGINT handler could not be installed
        LOG.info("interrupted, shutting down")

    server.shutdown()
    server.server_close()
    thread.join(timeout=SHUTDOWN_JOIN_SECONDS)
    if thread.is_alive():
        LOG.warning(
            "HTTP thread did not stop within %.0fs; exiting anyway",
            SHUTDOWN_JOIN_SECONDS,
        )
    LOG.info("stopped")
    # 130, not 0: the run was ended by a signal, and the repository-wide table
    # reserves 130 for exactly that. The shutdown itself was clean, which is why
    # the installed unit sets SuccessExitStatus=130 -- without it systemd would
    # record every `systemctl stop` as a failure.
    return EXIT_INTERRUPT


# --- Wiring -------------------------------------------------------------------

COLLECTOR_NAMES = ("host", "sensors", "smart", "gpu")


def build_registry(args: argparse.Namespace, selected: Sequence[str]) -> CollectorRegistry:
    """Build a private registry holding exactly the requested collectors.

    A private registry rather than the default one: no implicit GC, platform or
    process collectors, so what this exporter exposes is exactly what this file
    says it exposes.
    """
    registry = CollectorRegistry()

    build_info = Info(
        "%s_build" % NS, "Version of this exporter and its interpreter.", registry=registry
    )
    build_info.info(
        {
            "version": SCRIPT_VERSION,
            "python_version": platform.python_version(),
        }
    )

    mount_exclude = compile_pattern(args.mount_exclude, "--mount-exclude")
    netdev_exclude = compile_pattern(args.netdev_exclude, "--netdev-exclude")

    factories: Dict[str, Callable[[], Subsystem]] = {
        "host": lambda: HostCollector(mount_exclude, netdev_exclude),
        "sensors": SensorsCollector,
        "smart": lambda: SmartCollector(args.timeout, args.smart_interval, args.smartctl),
        "gpu": lambda: GpuCollector(args.timeout, args.nvidia_smi),
    }

    subsystems: List[Subsystem] = []
    for name in selected:
        subsystem = factories[name]()
        subsystems.append(subsystem)
        reason = subsystem.unavailable_reason()
        if reason:
            LOG.warning(
                "collector %s will report up=0: %s "
                "(disable it with --no-collector %s to stop the alert)",
                name,
                reason,
                name,
            )
        else:
            LOG.info("collector %s enabled", name)

    registry.register(ExporterCollector(subsystems))
    return registry


def select_collectors(args: argparse.Namespace) -> List[str]:
    """Resolve --collector / --no-collector into an ordered, validated list.

    The environment fallback is applied here rather than as an argparse
    `default=`, because `action="append"` appends to its default instead of
    replacing it: with a default list, LZC_EXPORTER_COLLECTORS=host plus
    --collector gpu would silently mean "both" rather than "the flag wins".
    """
    requested = args.collector if args.collector is not None else split_list(DEFAULT_COLLECTORS)
    disabled = args.no_collector if args.no_collector is not None else split_list(DEFAULT_DISABLED)
    requested = requested or list(COLLECTOR_NAMES)

    for name in set(requested) | set(disabled):
        if name not in COLLECTOR_NAMES:
            usage_error(
                "unknown collector %r (choose from: %s)"
                % (name, ", ".join(COLLECTOR_NAMES))
            )
    selected = [n for n in COLLECTOR_NAMES if n in requested and n not in disabled]
    if not selected:
        usage_error("every collector is disabled; there would be nothing to export")
    return selected


def split_list(value: str) -> List[str]:
    return [item.strip() for item in value.replace(",", " ").split() if item.strip()]


def resolve_textfile(args: argparse.Namespace) -> Optional[str]:
    """Decide whether this run writes a textfile, and where. Never guesses.

    `--textfile` is nargs="?", so the namespace distinguishes three cases that a
    plain `default=` would collapse into one:

      absent          -> None      -> serve
      bare flag       -> the value of LZC_EXPORTER_TEXTFILE
      flag with value -> that path

    The case this exists for is the fourth: LZC_EXPORTER_TEXTFILE set and
    --textfile absent. Reading the variable there would mean an environment file
    can change the mode of the process. That is not a theoretical objection --
    the installed unit loads /etc/default/<name>.local, the documentation invites
    operators to put LZC_EXPORTER_* settings in it, and the result is an exporter
    that writes a file, exits 0, is not restarted by Restart=on-failure, and
    leaves the port unserved with no unit in a failed state for an alert to find.
    A refusal is loud, and loud beats silent.
    """
    if args.textfile is None:
        if DEFAULT_TEXTFILE.strip():
            usage_error(
                "LZC_EXPORTER_TEXTFILE is set (%s) but --textfile was not given. "
                "The variable supplies the path; only the command line selects "
                "the mode, because letting an environment file do it turns a "
                "running exporter into a one-shot that exits 0 and stops serving "
                "without ever failing. Add --textfile to use that path, "
                "--textfile PATH to override it, or unset the variable to serve."
                % DEFAULT_TEXTFILE.strip()
            )
        return None

    path = args.textfile.strip()
    if not path:
        usage_error(
            "--textfile needs a path: give one, or set LZC_EXPORTER_TEXTFILE and "
            "pass --textfile with no value"
        )
    return path


def write_textfile(path: str, mode: int, registry: CollectorRegistry) -> bool:
    """Write the exposition to `path` atomically, then set its permissions.

    prometheus_client writes through a temporary file in the same directory and
    renames it, so node_exporter never reads a half-written file. What it does
    not do is set a mode: the file is created with the ambient umask, so under a
    unit carrying UMask=0077 -- or a root cron job -- the result is 0600 and
    node_exporter, running under its own account, reports
    node_textfile_scrape_error 1 instead of these metrics. The chmod makes
    readability a property of this script rather than of whatever umask happened
    to be in force.
    """
    try:
        write_to_textfile(path, registry)
    except Exception:  # noqa: BLE001 - OSError is expected; anything else is a bug
        # LOG.exception keeps the traceback, so nothing is hidden, while the
        # process still exits with the documented 1 rather than an unhandled
        # traceback's 1 plus a stack dump as the only explanation.
        LOG.exception("cannot write %s", path)
        return False
    try:
        os.chmod(path, mode)
    except OSError as exc:
        # The metrics are on disk and correct; only the mode is not what was
        # asked for. That is a warning, not a failed run.
        LOG.warning("wrote %s but could not set mode %04o: %s", path, mode, exc)
    else:
        LOG.info("wrote %s (mode %04o)", path, mode)
    return True


def write_exposition(registry: CollectorRegistry) -> None:
    """Write one exposition to stdout as bytes.

    generate_latest() already returns UTF-8. Decoding it so that the text layer
    can encode it again is how a drive model or GPU name with a non-ASCII byte
    becomes a UnicodeEncodeError on a host where stdout is not UTF-8 (LC_ALL=C
    with an interpreter old enough to honour it, a redirected pipe on Windows).
    """
    buffer = getattr(sys.stdout, "buffer", None)
    payload = generate_latest(registry)
    if buffer is None:  # stdout replaced by something text-only
        sys.stdout.write(payload.decode("utf-8"))
        sys.stdout.flush()
        return
    buffer.write(payload)
    buffer.flush()


def _finite(text: str) -> float:
    """float(), but 'nan' and 'inf' are rejected rather than accepted.

    float('nan') passes every ordering test, because every comparison against
    NaN is False: `nan <= 0` and `nan < 0` are both False, so a bare range check
    lets it straight through. A NaN reaching subprocess timeout= removes the one
    mechanism that stops a wedged disk stalling every scrape, and a NaN reaching
    the SMART cache interval silently disables caching. float('inf') is the
    mirror image: an infinite tool timeout never fires, and an infinite cache
    interval serves the first reading forever.
    """
    try:
        value = float(text)
    except ValueError:
        raise argparse.ArgumentTypeError("%r is not a number" % text)
    if not math.isfinite(value):
        raise argparse.ArgumentTypeError(
            "must be a finite number, got %r" % text
        )
    return value


def positive_number(text: str) -> float:
    value = _finite(text)
    if value <= 0:
        raise argparse.ArgumentTypeError("must be greater than 0, got %r" % text)
    return value


def non_negative_number(text: str) -> float:
    value = _finite(text)
    if value < 0:
        raise argparse.ArgumentTypeError("must be 0 or greater, got %r" % text)
    return value


def octal_mode(text: str) -> int:
    """Parse a file mode written the way chmod(1) is written, i.e. in octal.

    int(text, 8) rather than int(text): '0644' read as decimal is 644, which is
    0o1204 - group-writable, setuid-adjacent nonsense that nobody would have
    typed on purpose. Anything outside 0-0o777 is a usage error rather than
    something to silently mask.
    """
    try:
        value = int(text.strip(), 8)
    except (ValueError, AttributeError):
        raise argparse.ArgumentTypeError(
            "%r is not an octal file mode (for example 0644)" % text
        )
    if not 0 <= value <= 0o777:
        raise argparse.ArgumentTypeError(
            "must be between 0 and 0777, got %r" % text
        )
    return value


LOG_LEVELS = ("debug", "info", "warning", "error")


def log_level(text: str) -> str:
    """Validate a log level.

    A `type=` function rather than argparse's `choices=`, because `choices` is
    only checked for values that appear on the command line. A string `default=`
    -- which is exactly how LZC_EXPORTER_LOG_LEVEL arrives -- skips that check and
    goes straight through, so `LZC_EXPORTER_LOG_LEVEL=shouty` used to reach
    `getattr(logging, "SHOUTY")` and die with an AttributeError and exit 1. Bad
    input has to be a usage error, so it is validated here, where the default is
    converted too.
    """
    value = text.strip().lower()
    if value not in LOG_LEVELS:
        raise argparse.ArgumentTypeError(
            "%r is not a log level (choose from: %s)" % (text, ", ".join(LOG_LEVELS))
        )
    return value


def port_number(text: str) -> int:
    try:
        value = int(text)
    except ValueError:
        raise argparse.ArgumentTypeError("%r is not an integer" % text)
    if not 1 <= value <= 65535:
        raise argparse.ArgumentTypeError("must be between 1 and 65535, got %r" % text)
    return value


def parse_args(argv: Optional[Sequence[str]] = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        prog=SCRIPT_NAME,
        formatter_class=argparse.RawDescriptionHelpFormatter,
        description=(
            "Export host metrics for Prometheus: CPU, memory, filesystems and\n"
            "network from psutil; temperatures and fans from hwmon; drive health\n"
            "from smartctl; NVIDIA GPU telemetry from NVML or nvidia-smi.\n\n"
            "Every subsystem degrades on its own. A missing tool, a permission\n"
            "error or a wedged disk produces hostwatch_collector_up 0 for that\n"
            "collector and nothing else changes; the scrape still succeeds."
        ),
        epilog=(
            "Modes, chosen on the command line and nowhere else:\n"
            "  (default)          serve /metrics over HTTP until SIGTERM/SIGINT.\n"
            "  --once             print one exposition to stdout and exit.\n"
            "  --textfile PATH    write one exposition to PATH atomically and exit.\n"
            "  --textfile         same, using the path in LZC_EXPORTER_TEXTFILE.\n"
            "  --once and --textfile combine; giving either one suppresses the server.\n"
            "\n"
            "Setting LZC_EXPORTER_TEXTFILE without naming --textfile is a usage\n"
            "error (exit 2), not a mode change. An environment file is read by\n"
            "every unit that references it, so allowing it to select one-shot mode\n"
            "would let one line in /etc/default turn a running exporter into a\n"
            "process that writes a file, exits 0, and leaves nothing listening --\n"
            "which Restart=on-failure does not restart and no alert can see.\n"
            "\n"
            "Environment variables (flags win over them):\n"
            "  LZC_EXPORTER_BIND                 default for --bind\n"
            "  LZC_EXPORTER_PORT                 default for --port\n"
            "  LZC_EXPORTER_TIMEOUT              default for --timeout\n"
            "  LZC_EXPORTER_SMART_INTERVAL       default for --smart-interval\n"
            "  LZC_EXPORTER_TEXTFILE             path used by a bare --textfile\n"
            "  LZC_EXPORTER_TEXTFILE_MODE        default for --textfile-mode\n"
            "  LZC_EXPORTER_SMARTCTL             default for --smartctl\n"
            "  LZC_EXPORTER_NVIDIA_SMI           default for --nvidia-smi\n"
            "  LZC_EXPORTER_COLLECTORS           default for --collector (comma separated)\n"
            "  LZC_EXPORTER_DISABLE_COLLECTORS   default for --no-collector (comma separated)\n"
            "  LZC_EXPORTER_MOUNT_EXCLUDE        default for --mount-exclude\n"
            "  LZC_EXPORTER_NETDEV_EXCLUDE       default for --netdev-exclude\n"
            "  LZC_EXPORTER_LOG_LEVEL            default for --log-level\n"
            "  NO_COLOR                          any non-empty value disables colour\n"
            "\n"
            "LZC_EXPORTER_BIND and LZC_EXPORTER_PORT are the same two names that\n"
            "setup_prometheus_exporter.sh writes into the service environment\n"
            "file, so a hand-run copy and the installed unit take one spelling.\n"
            "\n"
            "Exit status:\n"
            "  0    a one-shot mode succeeded\n"
            "  1    the work ran but something in it failed: could not bind the\n"
            "       port, or could not write the textfile\n"
            "  2    usage error (unknown flag, missing or invalid argument value,\n"
            "       unknown collector, or LZC_EXPORTER_TEXTFILE set without\n"
            "       --textfile)\n"
            "  3    missing prerequisite: prometheus_client is not installed\n"
            "  130  interrupted (SIGINT/SIGTERM), after shutting down cleanly.\n"
            "       A systemd unit therefore needs SuccessExitStatus=130, which\n"
            "       the unit written by setup_prometheus_exporter.sh carries.\n"
            "\n"
            "Blast radius: this script reads sensors and runs smartctl and\n"
            "nvidia-smi read-only. It never installs packages, never loads kernel\n"
            "modules, and writes exactly one file - the --textfile path, when you\n"
            "ask for it. Requires root only for smartctl.\n"
            "\n"
            "Note on --port: 9105 is the default here and in the installer, but\n"
            "the Prometheus default-port-allocations wiki assigns it to the Mesos\n"
            "exporter. Change both sides with --port if you run one.\n"
            "\n"
            "License MIT. Origin https://github.com/Lazarev-Cloud/Scripts"
        ),
    )
    parser.add_argument(
        "-V",
        "--version",
        action="version",
        version="%s %s" % (SCRIPT_NAME, SCRIPT_VERSION),
    )
    parser.add_argument(
        "--bind",
        default=DEFAULT_BIND,
        metavar="ADDR",
        help="Address to listen on (default: %(default)s). Loopback by default "
        "because these metrics describe your hardware and the endpoint is "
        "unauthenticated; use 0.0.0.0 to accept remote scrapes.",
    )
    parser.add_argument(
        "--port",
        type=port_number,
        default=DEFAULT_PORT,
        metavar="PORT",
        help="TCP port to listen on (default: %(default)s).",
    )
    parser.add_argument(
        "--once",
        action="store_true",
        help="Print one exposition to stdout and exit instead of serving.",
    )
    parser.add_argument(
        "--textfile",
        nargs="?",
        default=None,
        const=DEFAULT_TEXTFILE,
        metavar="PATH",
        help="Write one exposition to PATH and exit instead of serving. The "
        "write is atomic (temporary file plus rename), so point it at a .prom "
        "file inside node_exporter's --collector.textfile.directory and run it "
        "from a systemd timer. Passing the flag with no value uses "
        "LZC_EXPORTER_TEXTFILE; setting only that variable is refused, because "
        "an environment file must not be able to turn a running service into a "
        "one-shot. Default: unset, i.e. serve.",
    )
    parser.add_argument(
        "--textfile-mode",
        type=octal_mode,
        default=DEFAULT_TEXTFILE_MODE,
        metavar="MODE",
        help="Octal permissions for the file --textfile writes (default: "
        "%(default)s). The default is world-readable because node_exporter "
        "usually runs under a different account and would otherwise report "
        "node_textfile_scrape_error rather than your metrics.",
    )
    parser.add_argument(
        "--collector",
        action="append",
        default=None,
        metavar="NAME",
        help="Enable only these collectors; repeatable. Choices: %s. "
        "Default: all of them (or LZC_EXPORTER_COLLECTORS)."
        % ", ".join(COLLECTOR_NAMES),
    )
    parser.add_argument(
        "--no-collector",
        action="append",
        default=None,
        metavar="NAME",
        help="Disable a collector; repeatable. Wins over --collector. On a Linux "
        "host already running node_exporter, --no-collector host removes the "
        "duplicated CPU/memory/filesystem/network series.",
    )
    parser.add_argument(
        "--smartctl",
        default=DEFAULT_SMARTCTL,
        metavar="PATH",
        help="Name or absolute path of the smartctl binary (default: "
        "%(default)s). A service PATH is not a login PATH, and smartctl lives "
        "in /usr/sbin or /usr/local/sbin depending on the distribution.",
    )
    parser.add_argument(
        "--nvidia-smi",
        default=DEFAULT_NVIDIA_SMI,
        metavar="PATH",
        help="Name or absolute path of the nvidia-smi binary (default: "
        "%(default)s). Only used when the in-process NVML bindings are absent.",
    )
    parser.add_argument(
        "--timeout",
        type=positive_number,
        default=DEFAULT_TIMEOUT,
        metavar="SECONDS",
        help="Hard timeout for each external tool invocation, in seconds "
        "(default: %(default)s). Keep it well below your Prometheus "
        "scrape_timeout.",
    )
    parser.add_argument(
        "--smart-interval",
        type=non_negative_number,
        default=DEFAULT_SMART_INTERVAL,
        metavar="SECONDS",
        help="Serve cached SMART data for this long so scrapes never sit in the "
        "disk spin-up path (default: %(default)s). 0 queries every scrape.",
    )
    parser.add_argument(
        "--mount-exclude",
        default=DEFAULT_MOUNT_EXCLUDE,
        metavar="REGEX",
        help="Skip filesystems whose mountpoint matches this regex. The default "
        "drops pseudo, container and snap mounts, which are otherwise "
        "unbounded on a container host. Empty string keeps everything.",
    )
    parser.add_argument(
        "--netdev-exclude",
        default=DEFAULT_NETDEV_EXCLUDE,
        metavar="REGEX",
        help="Skip network interfaces whose name matches this regex. The default "
        "drops per-guest virtual interfaces, which grow with the guest count. "
        "Empty string keeps everything.",
    )
    parser.add_argument(
        "--log-level",
        type=log_level,
        default=DEFAULT_LOG_LEVEL,
        metavar="LEVEL",
        help="Logging verbosity on stderr: %s (default: %%(default)s)."
        % ", ".join(LOG_LEVELS),
    )
    parser.add_argument(
        "--color",
        default="auto",
        choices=("auto", "always", "never"),
        help="Colour the log level on stderr (default: %(default)s). auto means "
        "only when stderr is a terminal and NO_COLOR is unset. The metrics "
        "exposition on stdout is never coloured. Flag only, no environment "
        "variable: NO_COLOR is the environment lever.",
    )
    return parser.parse_args(argv)


LEVEL_COLORS = {
    "DEBUG": "\033[36m",
    "INFO": "\033[36m",
    "WARNING": "\033[33m",
    "ERROR": "\033[01;31m",
    "CRITICAL": "\033[01;31m",
}
COLOR_RESET = "\033[m"


class LevelColorFormatter(logging.Formatter):
    """Colours the level name only. Everything else is left exactly as it was."""

    def format(self, record: logging.LogRecord) -> str:
        color = LEVEL_COLORS.get(record.levelname)
        if color:
            # A copy, because the same record object may be formatted again by
            # another handler and must not arrive there already escaped.
            record = logging.makeLogRecord(record.__dict__)
            record.levelname = "%s%s%s" % (color, record.levelname, COLOR_RESET)
        return super().format(record)


def want_color(when: str) -> bool:
    """Decide whether log lines carry colour.

    Gated on *stderr*, which is the stream the logger writes to. stdout carries
    the metrics exposition in --once mode and must never be touched: a scrape
    parser would choke on an escape sequence. Under systemd stderr is a pipe to
    journald rather than a terminal, so `auto` yields no colour there for free.

    NO_COLOR (https://no-color.org): any non-empty value disables colour. An
    explicit `--color always` still wins over it, because a flag the operator
    typed on this command line is a more specific instruction than an exported
    default. setup_prometheus_exporter.sh resolves the same conflict the same way.
    """
    if when == "never":
        return False
    if when == "always":
        return True
    if os.environ.get("NO_COLOR"):
        return False
    return bool(getattr(sys.stderr, "isatty", lambda: False)())


def configure_logging(level: str, color: str) -> None:
    # journald stamps its own timestamp on everything a unit writes, so the one
    # this script adds would be pure duplication under systemd. INVOCATION_ID is
    # set by systemd for every unit start and by nothing else.
    under_systemd = bool(os.environ.get("INVOCATION_ID"))
    fmt = "%(levelname)s %(message)s" if under_systemd else "%(asctime)s %(levelname)s %(message)s"
    handler = logging.StreamHandler(sys.stderr)
    formatter_class = LevelColorFormatter if want_color(color) else logging.Formatter
    # A literal Z, not %z. The converter below is time.gmtime, but strftime
    # renders %z from the *local* standard offset regardless of the struct_time
    # it is handed: on a UTC+2 host in summer this printed the correct UTC time
    # stamped "+0100", i.e. an instant an hour earlier than the one it names.
    # Verified, and the reason every log line was quietly misdated.
    formatter = formatter_class(fmt, datefmt="%Y-%m-%dT%H:%M:%SZ")
    formatter.converter = time.gmtime
    handler.setFormatter(formatter)
    LOG.handlers[:] = [handler]
    LOG.setLevel(getattr(logging, level.upper()))
    LOG.propagate = False


def main(argv: Optional[Sequence[str]] = None) -> int:
    args = parse_args(argv)
    configure_logging(args.log_level, args.color)

    # Resolve the mode before building anything. A usage error has to be the
    # first thing in the journal: construct the collectors first and an operator
    # sees four "will report up=0" warnings followed by a usage error, which
    # reads as though the warnings caused it.
    textfile = resolve_textfile(args)
    one_shot = bool(args.once or textfile)

    selected = select_collectors(args)
    registry = build_registry(args, selected)

    if not one_shot:
        # Process metrics are meaningful for a long-lived daemon and misleading
        # for a one-shot run, so they are registered only when serving.
        ProcessCollector(registry=registry)

    if textfile and not write_textfile(textfile, args.textfile_mode, registry):
        return EXIT_FAILURE

    if args.once:
        try:
            write_exposition(registry)
        except BrokenPipeError:
            # `--once | head` closes the pipe early. That is the reader's
            # choice, not a failure, and it must not print a traceback. stderr
            # is left alone so the shutdown flush cannot raise a second time.
            LOG.debug("stdout closed before the exposition finished")

    if one_shot:
        return EXIT_OK

    return serve(args.bind, args.port, registry)


if __name__ == "__main__":
    raise SystemExit(main())
