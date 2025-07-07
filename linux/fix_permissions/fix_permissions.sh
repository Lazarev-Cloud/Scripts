#!/usr/bin/env bash
set -euo pipefail

LOG_FILE="/var/log/fix_permissions.log"
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') : $1" | tee -a "$LOG_FILE"
}

HOME_DIR="/home/$USER"
if [[ ! -d "$HOME_DIR" ]]; then
    echo "Home directory $HOME_DIR not found" >&2
    exit 1
fi

log "Fixing permissions in $HOME_DIR"
sudo chown -R "$USER":"$USER" "$HOME_DIR"
sudo find "$HOME_DIR" -type d -exec chmod 755 {} \;
sudo find "$HOME_DIR" -type f -exec chmod 644 {} \;
log "Permissions fixed"
