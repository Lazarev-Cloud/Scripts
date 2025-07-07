#!/usr/bin/env bash
# Safe network interface restart script
set -euo pipefail

LOG_FILE="/var/log/network_restart.log"
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') : $1" | tee -a "$LOG_FILE"
}

if [[ $# -ne 1 ]]; then
    echo "Usage: $0 <interface>" >&2
    exit 1
fi

iface="$1"
if ! ip link show "$iface" &>/dev/null; then
    echo "Error: interface '$iface' not found" >&2
    exit 1
fi

log "Restarting network interface '$iface'"
if sudo ip link set "$iface" down && sudo ip link set "$iface" up; then
    log "Interface '$iface' restarted"
else
    log "Failed to restart '$iface'"
    exit 1
fi
