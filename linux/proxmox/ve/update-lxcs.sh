#!/usr/bin/env bash

# Enhanced Proxmox VE LXC Container Updater
# Author: Enhanced version based on tteck's original script
# License: MIT
# Version: 2.0

# Exit on any error, undefined variables, or pipe failures
set -eEuo pipefail

# Configuration
readonly SCRIPT_NAME="Proxmox VE LXC Updater"
readonly SCRIPT_VERSION="2.0"
readonly LOG_FILE="/var/log/lxc-updater.log"
readonly MAX_CONTAINER_WAIT=30
readonly SHUTDOWN_WAIT=10

# Color codes
readonly YW='\033[33m'    # Yellow
readonly BL='\033[36m'    # Blue
readonly RD='\033[01;31m' # Red
readonly GN='\033[1;92m'  # Green
readonly CL='\033[m'      # Clear

# Global arrays
declare -a EXCLUDED_CONTAINERS=()
declare -a CONTAINERS_NEEDING_REBOOT=()
declare -a FAILED_UPDATES=()

# Logging function
log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [$level] $message" >> "$LOG_FILE"
    
    case "$level" in
        "ERROR") echo -e "${RD}[Error]${CL} $message" ;;
        "WARN")  echo -e "${YW}[Warning]${CL} $message" ;;
        "INFO")  echo -e "${BL}[Info]${CL} $message" ;;
        "SUCCESS") echo -e "${GN}[Success]${CL} $message" ;;
        *) echo "$message" ;;
    esac
}

# Display header
header_info() {
    clear
    cat << 'EOF'
   __  __          __      __          __   _  ________
  / / / /___  ____/ /___ _/ /____     / /  | |/ / ____/
 / / / / __ \/ __  / __ `/ __/ _ \   / /   |   / /
/ /_/ / /_/ / /_/ / /_/ / /_/  __/  / /___/   / /___
\____/ .___/\__,_/\__,_/\__/\___/  /_____/_/|_\____/
    /_/

EOF
    echo -e "${GN}Enhanced Proxmox VE LXC Container Updater v${SCRIPT_VERSION}${CL}\n"
}

# Validate prerequisites
check_prerequisites() {
    log "INFO" "Checking prerequisites..."
    
    # Check if running on Proxmox
    if ! command -v pct >/dev/null 2>&1; then
        log "ERROR" "pct command not found. This script must run on Proxmox VE."
        exit 1
    fi
    
    # Check if running as root
    if [[ $EUID -ne 0 ]]; then
        log "ERROR" "This script must be run as root."
        exit 1
    fi
    
    # Check if whiptail is available
    if ! command -v whiptail >/dev/null 2>&1; then
        log "ERROR" "whiptail not found. Please install: apt-get install whiptail"
        exit 1
    fi
    
    # Create log file if it doesn't exist
    touch "$LOG_FILE" || {
        log "ERROR" "Cannot create log file: $LOG_FILE"
        exit 1
    }
    
    log "SUCCESS" "Prerequisites check passed"
}

# Sanitize container ID input
sanitize_container_id() {
    local container_id="$1"
    # Only allow digits
    if [[ "$container_id" =~ ^[0-9]+$ ]]; then
        echo "$container_id"
    else
        log "WARN" "Invalid container ID format: $container_id"
        return 1
    fi
}

# Validate container exists
validate_container() {
    local container="$1"
    
    # Sanitize input
    container=$(sanitize_container_id "$container") || return 1
    
    if ! pct config "$container" >/dev/null 2>&1; then
        log "ERROR" "Container $container does not exist or is not accessible"
        return 1
    fi
    
    return 0
}

# Get container information
get_container_info() {
    local container="$1"
    local info_type="$2"
    
    case "$info_type" in
        "hostname")
            pct exec "$container" -- hostname 2>/dev/null || echo "unknown"
            ;;
        "ostype")
            pct config "$container" 2>/dev/null | awk '/^ostype:/ {print $2}' || echo "unknown"
            ;;
        "status")
            pct status "$container" 2>/dev/null || echo "status: unknown"
            ;;
        "template")
            if pct config "$container" 2>/dev/null | grep -q "template: 1"; then
                echo "true"
            else
                echo "false"
            fi
            ;;
    esac
}

# Get disk usage information
get_disk_info() {
    local container="$1"
    local os="$2"
    
    if [[ "$os" == "ubuntu" || "$os" == "debian" || "$os" == "fedora" ]]; then
        local disk_info
        if disk_info=$(pct exec "$container" -- df /boot 2>/dev/null | awk 'NR==2{gsub("%","",$5); printf "%s %.1fG %.1fG %.1fG", $5, $3/1024/1024, $2/1024/1024, $4/1024/1024}'); then
            echo "$disk_info"
        else
            echo "N/A N/A N/A N/A"
        fi
    else
        echo "N/A N/A N/A N/A"
    fi
}

# Wait for container to be ready
wait_for_container() {
    local container="$1"
    local max_wait="$2"
    local count=0
    
    while [[ $count -lt $max_wait ]]; do
        if pct exec "$container" -- true 2>/dev/null; then
            log "INFO" "Container $container is ready"
            return 0
        fi
        sleep 1
        ((count++))
    done
    
    log "ERROR" "Container $container not ready after ${max_wait}s"
    return 1
}

# Check if container needs reboot
needs_reboot() {
    local container="$1"
    local os="$2"
    
    # Check for reboot-required flag (Ubuntu/Debian)
    if [[ "$os" == "ubuntu" || "$os" == "debian" ]]; then
        if pct exec "$container" -- test -f /var/run/reboot-required 2>/dev/null; then
            return 0
        fi
    fi
    
    # Check for other OS-specific reboot indicators
    case "$os" in
        "fedora"|"centos"|"rocky"|"alma")
            # Check if kernel was updated
            if pct exec "$container" -- needs-restarting -r 2>/dev/null; then
                return 1
            else
                return 0
            fi
            ;;
        "archlinux")
            # Check for .pacnew files or kernel updates
            if pct exec "$container" -- find /boot -name "*.pacnew" 2>/dev/null | grep -q .; then
                return 0
            fi
            ;;
    esac
    
    return 1
}

# Update container based on OS type
update_container() {
    local container="$1"
    local retries=3
    local retry_count=0
    
    # Validate container
    if ! validate_container "$container"; then
        FAILED_UPDATES+=("$container: Invalid container")
        return 1
    fi
    
    # Get container information
    local name hostname os status template
    hostname=$(get_container_info "$container" "hostname")
    os=$(get_container_info "$container" "ostype")
    status=$(get_container_info "$container" "status")
    template=$(get_container_info "$container" "template")
    
    log "INFO" "Processing container $container ($hostname) - OS: $os, Status: $status"
    
    # Skip templates
    if [[ "$template" == "true" ]]; then
        log "INFO" "Skipping template container $container"
        return 0
    fi
    
    # Get disk information
    local disk_info_array
    read -ra disk_info_array <<< "$(get_disk_info "$container" "$os")"
    
    # Display container info
    header_info
    if [[ "${disk_info_array[0]}" != "N/A" ]]; then
        log "INFO" "Updating $container : $hostname - Boot Disk: ${disk_info_array[0]}% full [${disk_info_array[1]}/${disk_info_array[2]} used, ${disk_info_array[3]} free]"
    else
        log "INFO" "Updating $container : $hostname - [No disk info available for $os]"
    fi
    
    # Start container if stopped
    local was_stopped=false
    if [[ "$status" == "status: stopped" ]]; then
        log "INFO" "Starting container $container"
        if ! pct start "$container"; then
            log "ERROR" "Failed to start container $container"
            FAILED_UPDATES+=("$container: Failed to start")
            return 1
        fi
        
        if ! wait_for_container "$container" "$MAX_CONTAINER_WAIT"; then
            log "ERROR" "Container $container failed to become ready"
            FAILED_UPDATES+=("$container: Not ready after start")
            return 1
        fi
        was_stopped=true
    elif [[ "$status" != "status: running" ]]; then
        log "WARN" "Container $container is in unexpected state: $status"
        FAILED_UPDATES+=("$container: Unexpected state - $status")
        return 1
    fi
    
    # Perform update with retries
    local update_success=false
    while [[ $retry_count -lt $retries && "$update_success" == false ]]; do
        ((retry_count++))
        log "INFO" "Update attempt $retry_count for container $container"
        
        case "$os" in
            "alpine")
                if pct exec "$container" -- ash -c "apk update && apk upgrade" 2>/dev/null; then
                    update_success=true
                fi
                ;;
            "archlinux")
                if pct exec "$container" -- bash -c "pacman -Syyu --noconfirm" 2>/dev/null; then
                    update_success=true
                fi
                ;;
            "fedora"|"rocky"|"centos"|"alma")
                if pct exec "$container" -- bash -c "dnf -y update" 2>/dev/null; then
                    update_success=true
                fi
                ;;
            "ubuntu"|"debian"|"devuan")
                # Safer update command without removing EXTERNALLY-MANAGED
                if pct exec "$container" -- bash -c "DEBIAN_FRONTEND=noninteractive apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get -y dist-upgrade -qq" 2>/dev/null; then
                    update_success=true
                fi
                ;;
            "opensuse")
                if pct exec "$container" -- bash -c "zypper ref && zypper --non-interactive dup" 2>/dev/null; then
                    update_success=true
                fi
                ;;
            *)
                log "WARN" "Unsupported OS type: $os for container $container"
                FAILED_UPDATES+=("$container: Unsupported OS - $os")
                return 1
                ;;
        esac
        
        if [[ "$update_success" == false ]]; then
            log "WARN" "Update attempt $retry_count failed for container $container"
            if [[ $retry_count -lt $retries ]]; then
                sleep 5
            fi
        fi
    done
    
    if [[ "$update_success" == false ]]; then
        log "ERROR" "All update attempts failed for container $container"
        FAILED_UPDATES+=("$container: All update attempts failed")
        
        # Don't shutdown if update failed and container was originally stopped
        if [[ "$was_stopped" == true ]]; then
            log "INFO" "Stopping container $container due to failed update"
            pct stop "$container" 2>/dev/null || true
        fi
        return 1
    fi
    
    log "SUCCESS" "Successfully updated container $container"
    
    # Check if reboot is needed
    if needs_reboot "$container" "$os"; then
        CONTAINERS_NEEDING_REBOOT+=("$container ($hostname)")
        log "INFO" "Container $container requires a reboot"
    fi
    
    # Shutdown if it was originally stopped
    if [[ "$was_stopped" == true ]]; then
        log "INFO" "Shutting down container $container"
        if pct shutdown "$container"; then
            # Wait for graceful shutdown
            local shutdown_count=0
            while [[ $shutdown_count -lt $SHUTDOWN_WAIT ]]; do
                if [[ "$(get_container_info "$container" "status")" == "status: stopped" ]]; then
                    break
                fi
                sleep 1
                ((shutdown_count++))
            done
            
            if [[ $shutdown_count -ge $SHUTDOWN_WAIT ]]; then
                log "WARN" "Graceful shutdown timeout for container $container, forcing stop"
                pct stop "$container" 2>/dev/null || true
            fi
        else
            log "WARN" "Failed to shutdown container $container gracefully, forcing stop"
            pct stop "$container" 2>/dev/null || true
        fi
    fi
    
    return 0
}

# Get list of containers to exclude
get_excluded_containers() {
    local node
    node=$(hostname)
    
    # Build menu array safely
    local exclude_menu=()
    local msg_max_length=0
    
    while IFS= read -r line; do
        # Skip header line and parse container info
        if [[ "$line" =~ ^[0-9] ]]; then
            local container_id container_name
            container_id=$(echo "$line" | awk '{print $1}')
            container_name=$(echo "$line" | awk '{for(i=3;i<=NF;i++) printf "%s ", $i; print ""}' | sed 's/[[:space:]]*$//')
            
            # Sanitize inputs
            if container_id=$(sanitize_container_id "$container_id") 2>/dev/null; then
                local offset=2
                local item_length=$((${#container_name} + offset))
                [[ $item_length -gt $msg_max_length ]] && msg_max_length=$item_length
                
                exclude_menu+=("$container_id" "$container_name " "OFF")
            fi
        fi
    done < <(pct list 2>/dev/null)
    
    if [[ ${#exclude_menu[@]} -eq 0 ]]; then
        log "WARN" "No containers found"
        return 0
    fi
    
    # Show selection dialog
    local excluded_raw
    if excluded_raw=$(whiptail --backtitle "Proxmox VE Helper Scripts" \
                               --title "Containers on $node" \
                               --checklist "\nSelect containers to skip from updates:\n" \
                               16 $((msg_max_length + 23)) 6 \
                               "${exclude_menu[@]}" \
                               3>&1 1>&2 2>&3 2>/dev/null); then
        
        # Parse selected containers safely
        while IFS= read -r container_id; do
            # Remove quotes and validate
            container_id=$(echo "$container_id" | tr -d '"')
            if container_id=$(sanitize_container_id "$container_id") 2>/dev/null; then
                EXCLUDED_CONTAINERS+=("$container_id")
            fi
        done <<< "$excluded_raw"
        
        if [[ ${#EXCLUDED_CONTAINERS[@]} -gt 0 ]]; then
            log "INFO" "Excluding containers: ${EXCLUDED_CONTAINERS[*]}"
        fi
    else
        log "INFO" "No containers excluded"
    fi
}

# Check if container should be excluded
is_excluded() {
    local container="$1"
    local excluded_container
    
    for excluded_container in "${EXCLUDED_CONTAINERS[@]}"; do
        if [[ "$excluded_container" == "$container" ]]; then
            return 0
        fi
    done
    return 1
}

# Generate summary report
generate_summary() {
    header_info
    
    local total_containers=0
    local updated_containers=0
    local excluded_count=${#EXCLUDED_CONTAINERS[@]}
    local failed_count=${#FAILED_UPDATES[@]}
    local reboot_count=${#CONTAINERS_NEEDING_REBOOT[@]}
    
    # Count total containers
    while IFS= read -r line; do
        if [[ "$line" =~ ^[0-9] ]]; then
            ((total_containers++))
        fi
    done < <(pct list 2>/dev/null)
    
    updated_containers=$((total_containers - excluded_count - failed_count))
    
    log "SUCCESS" "Update process completed!"
    echo ""
    log "INFO" "Summary:"
    echo "  Total containers: $total_containers"
    echo "  Successfully updated: $updated_containers"
    echo "  Excluded: $excluded_count"
    echo "  Failed updates: $failed_count"
    echo "  Requiring reboot: $reboot_count"
    echo ""
    
    if [[ $failed_count -gt 0 ]]; then
        log "ERROR" "Failed updates:"
        local failed_update
        for failed_update in "${FAILED_UPDATES[@]}"; do
            echo "  $failed_update"
        done
        echo ""
    fi
    
    if [[ $reboot_count -gt 0 ]]; then
        log "WARN" "Containers requiring reboot:"
        local container_name
        for container_name in "${CONTAINERS_NEEDING_REBOOT[@]}"; do
            echo "  $container_name"
        done
        echo ""
    fi
    
    log "INFO" "Detailed logs available at: $LOG_FILE"
}

# Main execution function
main() {
    # Initialize
    header_info
    log "INFO" "Starting $SCRIPT_NAME v$SCRIPT_VERSION"
    
    # Check prerequisites
    check_prerequisites
    
    # Confirm execution
    if ! whiptail --backtitle "Proxmox VE Helper Scripts" \
                  --title "$SCRIPT_NAME" \
                  --yesno "This will update LXC containers. Proceed?" \
                  10 58; then
        log "INFO" "Update cancelled by user"
        exit 0
    fi
    
    # Get containers to exclude
    get_excluded_containers
    
    # Process all containers
    log "INFO" "Starting container updates..."
    
    while IFS= read -r line; do
        if [[ "$line" =~ ^[0-9] ]]; then
            local container_id
            container_id=$(echo "$line" | awk '{print $1}')
            
            # Sanitize and validate
            if ! container_id=$(sanitize_container_id "$container_id") 2>/dev/null; then
                continue
            fi
            
            if is_excluded "$container_id"; then
                log "INFO" "Skipping excluded container $container_id"
                continue
            fi
            
            # Update container
            update_container "$container_id" || true
        fi
    done < <(pct list 2>/dev/null)
    
    # Generate summary
    generate_summary
    
    log "INFO" "$SCRIPT_NAME completed"
}

# Trap for cleanup
cleanup() {
    log "INFO" "Script interrupted, cleaning up..."
    exit 130
}

# Set up signal handling
trap cleanup INT TERM

# Execute main function
main "$@"
