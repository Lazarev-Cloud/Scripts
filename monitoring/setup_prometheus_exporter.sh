#!/usr/bin/env bash
set -euo pipefail

SCRIPT_PATH="${BASH_SOURCE[0]:-}"
if [[ -z "$SCRIPT_PATH" || "$SCRIPT_PATH" == "bash" ]]; then
  SCRIPT_DIR="$PWD"
else
  SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
fi
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
INSTALL_DIR="/opt/prometheus-unified-exporter"
SERVICE_NAME="prometheus-unified-exporter"
PYTHON_PACKAGES=(psutil pynvml)

if [[ $(id -u) -ne 0 ]]; then
  SUDO="$(command -v sudo 2>/dev/null || true)"
  if [[ -z "$SUDO" ]]; then
    echo "[error] Please run as root or install sudo." >&2
    exit 1
  fi
  if ! $SUDO -n true 2>/dev/null; then
    echo "[error] sudo is required for package installation and sensor access." >&2
    echo "        Re-run as root or configure passwordless sudo for this user." >&2
    exit 1
  fi
else
  SUDO=""
fi

log() {
  echo "[setup] $*"
}

fail() {
  echo "[error] $*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1
}

identify_pkg_manager() {
  if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    case "$ID" in
      ubuntu|debian)
        echo "apt"; return 0 ;;
      rhel|centos|fedora|rocky|almalinux)
        if require_command dnf; then echo "dnf"; else echo "yum"; fi; return 0 ;;
      opensuse*|sles)
        echo "zypper"; return 0 ;;
      arch|manjaro)
        echo "pacman"; return 0 ;;
    esac
  fi
  if require_command apt-get; then echo "apt"; return 0; fi
  if require_command dnf; then echo "dnf"; return 0; fi
  if require_command yum; then echo "yum"; return 0; fi
  if require_command pacman; then echo "pacman"; return 0; fi
  if require_command zypper; then echo "zypper"; return 0; fi
  fail "Unsupported distribution: no known package manager detected."
}

install_packages() {
  local pkg_mgr="$1"; shift
  local packages=("$@")
  case "$pkg_mgr" in
    apt)
      $SUDO apt-get update
      $SUDO apt-get install -y "${packages[@]}"
      ;;
    dnf)
      $SUDO dnf install -y "${packages[@]}"
      ;;
    yum)
      $SUDO yum install -y "${packages[@]}"
      ;;
    pacman)
      $SUDO pacman -Sy --noconfirm "${packages[@]}"
      ;;
    zypper)
      $SUDO zypper install -y --no-confirm "${packages[@]}"
      ;;
    *)
      fail "Package manager $pkg_mgr is not supported by this script."
      ;;
  esac
}

ensure_system_dependencies() {
  local pkg_mgr
  pkg_mgr=$(identify_pkg_manager)
  log "Detected package manager: $pkg_mgr"

  local base_packages=()
  local sensor_packages=()
  local gpu_packages=()

  case "$pkg_mgr" in
    apt)
      base_packages=(python3 python3-venv python3-pip curl)
      sensor_packages=(lm-sensors nvme-cli smartmontools)
      gpu_packages=(pciutils)
      ;;
    dnf|yum)
      base_packages=(python3 python3-pip python3-virtualenv curl)
      sensor_packages=(lm_sensors nvme-cli smartmontools)
      gpu_packages=(pciutils)
      ;;
    pacman)
      base_packages=(python python-pip curl)
      sensor_packages=(lm_sensors nvme-cli smartmontools)
      gpu_packages=(pciutils)
      ;;
    zypper)
      base_packages=(python3 python3-pip curl)
      sensor_packages=(lm_sensors nvme-cli smartmontools)
      gpu_packages=(pciutils)
      ;;
  esac

  install_packages "$pkg_mgr" "${base_packages[@]}" "${sensor_packages[@]}" "${gpu_packages[@]}"

  if require_command sensors-detect; then
    log "Running sensors-detect non-interactively to enable CPU/board temperature readings"
    yes "" | $SUDO sensors-detect --auto || true
  fi

  if require_command modprobe; then
    log "Attempting to load common sensor modules (coretemp, nct6775)"
    $SUDO modprobe coretemp 2>/dev/null || true
    $SUDO modprobe nct6775 2>/dev/null || true
  fi

  if require_command lspci && lspci | grep -qi nvidia; then
    if ! require_command nvidia-smi; then
      log "NVIDIA GPU detected but nvidia-smi missing; attempting to install utilities"
      case "$pkg_mgr" in
        apt)
          install_packages "$pkg_mgr" nvidia-utils-535 || install_packages "$pkg_mgr" nvidia-utils-530 || true
          ;;
        dnf|yum)
          install_packages "$pkg_mgr" nvidia-driver || true
          ;;
        zypper)
          install_packages "$pkg_mgr" nvidia-utils-G06 || true
          ;;
        pacman)
          install_packages "$pkg_mgr" nvidia-utils || true
          ;;
      esac
    fi
  fi
}

setup_virtualenv() {
  local exporter_src=""
  for candidate in "$SCRIPT_DIR/prometheus_unified_metrics.py" "$REPO_ROOT/monitoring/prometheus_unified_metrics.py"; do
    if [[ -f "$candidate" ]]; then
      exporter_src="$candidate"
      break
    fi
  done

  if [[ -z "$exporter_src" ]]; then
    local exporter_url="${EXPORTER_URL:-https://raw.githubusercontent.com/Lazarev-Cloud/Scripts/refs/heads/main/monitoring/prometheus_unified_metrics.py}"
    log "Exporter not found locally; attempting to download from $exporter_url"
    exporter_src="$SCRIPT_DIR/prometheus_unified_metrics.py"
    if ! curl -fsSL "$exporter_url" -o "$exporter_src"; then
      fail "Unable to download prometheus_unified_metrics.py; set EXPORTER_URL or place it next to this script."
    fi
  fi

  log "Creating installation directory at $INSTALL_DIR"
  $SUDO mkdir -p "$INSTALL_DIR"
  $SUDO cp "$exporter_src" "$INSTALL_DIR/"
  $SUDO chown -R "$(id -u):$(id -g)" "$INSTALL_DIR"

  if [[ ! -d "$INSTALL_DIR/venv" ]]; then
    log "Initializing Python virtual environment"
    python3 -m venv "$INSTALL_DIR/venv"
  fi

  log "Installing Python dependencies: ${PYTHON_PACKAGES[*]}"
  "$INSTALL_DIR/venv/bin/pip" install --upgrade pip
  "$INSTALL_DIR/venv/bin/pip" install "${PYTHON_PACKAGES[@]}"
}

configure_systemd() {
  if ! require_command systemctl; then
    log "systemctl not found; skipping service setup. You can run the exporter manually:"
    echo "  $INSTALL_DIR/venv/bin/python $INSTALL_DIR/prometheus_unified_metrics.py"
    return
  fi

  local service_file="/etc/systemd/system/${SERVICE_NAME}.service"
  log "Writing systemd unit to $service_file"
  cat <<SERVICE | ${SUDO:+$SUDO }tee "$service_file" >/dev/null
[Unit]
Description=Unified Prometheus Host Exporter
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$INSTALL_DIR/venv/bin/python $INSTALL_DIR/prometheus_unified_metrics.py --port 9105
Restart=on-failure
RestartSec=5
User=root

[Install]
WantedBy=multi-user.target
SERVICE

  log "Reloading systemd and starting service"
  $SUDO systemctl daemon-reload
  $SUDO systemctl enable --now "$SERVICE_NAME"
  $SUDO systemctl status "$SERVICE_NAME" --no-pager --full || true
}

main() {
  log "Preparing host for Prometheus exporter (OS, sensors, GPU, Python)"
  ensure_system_dependencies
  setup_virtualenv
  configure_systemd
  log "Done. Exporter should be available on port 9105."
}

main "$@"
