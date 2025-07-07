#!/usr/bin/env bash
# Basic system health monitoring script
set -euo pipefail

LOG_FILE="/var/log/system_health.log"

log_message() {
    local msg="$1"
    echo "$(date '+%Y-%m-%d %H:%M:%S') : $msg" | tee -a "$LOG_FILE"
}

cpu_usage() {
    top -bn1 | awk '/^%?Cpu/{print $2+$4}'
}

mem_usage() {
    free -m | awk '/Mem:/ {printf("%.2f", $3/$2*100)}'
}

disk_usage() {
    df -h / | awk 'NR==2 {print $5}'
}

log_message "CPU usage: $(cpu_usage)%"
log_message "Memory usage: $(mem_usage)%"
log_message "Disk usage: $(disk_usage)"
