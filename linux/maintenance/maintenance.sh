#!/usr/bin/env bash

# Comprehensive Maintenance Script for Debian/Ubuntu
# Author: YourName
# License: MIT
# Repository: https://github.com/yourusername/maintenance-script

function header_info {
  clear
  cat <<"EOF"
   __  __          __      __          ____                 
  / / / /___  ____/ /___ _/ /____     / __ \___  ____  ____ 
 / / / / __ \/ __  / __ `/ __/ _ \   / /_/ / _ \/ __ \/ __ \
/ /_/ / /_/ / /_/ / /_/ / /_/  __/  / _, _/  __/ /_/ / /_/ /
\____/ .___/\__,_/\__,_/\__/\___/  /_/ |_|\___/ .___/\____/ 
    /_/                                      /_/            
EOF
}

set -eEuo pipefail
BL=$(echo "\033[36m")  # Blue
RD=$(echo "\033[01;31m") # Red
GN=$(echo "\033[1;92m")  # Green
CL=$(echo "\033[m")      # Clear

header_info
echo "Loading..."
LOG_FILE="/var/log/maintenance_script.log"
NODE=$(hostname)

# Ensure the script is run as root.
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root. Please use sudo."
   exit 1
fi

# Initialize log file
touch "$LOG_FILE"
chmod 600 "$LOG_FILE"

# Variables
NOTIFY_EMAIL=""

# Function to display the help message.
show_help() {
    cat << EOF
Usage: sudo $0 [options]

Options:
  --clean-logs                       Clean old log files.
  --fix-apt-packages                 Fix broken APT packages and update system.
  --fix-apt-lock                     Resolve APT lock issues.
  --clean-disk                       Perform disk cleanup and remove unused packages.
  --update-system                    Update and upgrade the entire system.
  --backup [directory]               Create a backup of the specified directory.
  --restore [backup_file] [restore_directory]  Restore from a backup.
  --system-info                      Display system information.
  --resource-usage                   Show CPU, memory, and disk usage.
  --configure-firewall               Enable and configure the UFW firewall.
  --security-scan                    Perform a security scan for rootkits and malware.
  --add-user [username]              Add a new user.
  --remove-user [username]           Remove an existing user.
  --add-group [groupname]            Add a new group.
  --remove-group [groupname]         Remove an existing group.
  --manage-service [action] [service_name] Manage a specified service.
  --schedule-task [task] [schedule]  Schedule a maintenance task with cron.
  --list-scheduled-tasks             List all scheduled maintenance tasks.
  --reboot [delay]                   Reboot the system immediately or after a specified delay in minutes.
  --logrotate-configure              Set up custom log rotation.
  --logrotate-trigger                Manually trigger log rotation.
  --send-notification [email]        Send a notification after tasks.
  --list-kernels                     List all installed kernels.
  --remove-old-kernels               Remove old kernels, keeping the current and one previous.
  --install-latest-kernel            Install the latest available kernel.
  --set-default-kernel               Update GRUB with the current kernel as default.
  --enable-unattended-upgrades       Enable automatic unattended upgrades.
  --configure-auto-updates           Configure automatic update intervals.
  --check-unattended-status          Check status of unattended upgrades.
  --list-snap-packages               List all installed snap packages.
  --remove-snap-package [pkg]        Remove a specified snap package.
  --refresh-snap-packages            Refresh (update) all snap packages.
  --install-snap-package [pkg]       Install a specified snap package.
  --install-flatpak                   Install Flatpak.
  --add-flatpak-repo [URL]            Add a Flatpak repository.
  --list-flatpak-packages             List all installed Flatpak packages.
  --remove-flatpak-package [pkg]       Remove a specified Flatpak package.
  --refresh-flatpak-packages          Refresh (update) all Flatpak packages.
  --check-swap                        Check current swap usage.
  --create-swap [size]                Create a swap file of specified size (e.g., 2G, 512M).
  --remove-swap                       Disable and remove the swap file.
  --check-time-sync                   Check time synchronization status.
  --enable-ntp                        Enable NTP time synchronization.
  --disable-ntp                       Disable NTP time synchronization.
  --set-timezone [timezone]           Set system timezone (e.g., 'Europe/London').
  --add-apt-repo [repo] [key_url]     Add an APT repository with optional GPG key URL.
  --remove-apt-repo [repo]            Remove a specified APT repository.
  --list-apt-repos                    List all APT repositories.
  --check-uptime                      Check system uptime.
  --check-load                        Check system load averages.
  --check-inodes                      Check disk inode usage.
  --monitor-service [service]         Monitor the status of a specific service.
  --run-fsck                          Schedule a filesystem check on next reboot.
  --schedule-fsck                     Schedule regular filesystem checks weekly.
  --install-docker                    Install Docker.
  --start-docker                      Start and enable Docker service.
  --stop-docker                       Stop and disable Docker service.
  --list-docker-containers            List all running Docker containers.
  --remove-docker-container [id]       Remove a specified Docker container.
  --check-apparmor-status             Check AppArmor status.
  --enable-apparmor                   Enable and start AppArmor.
  --disable-apparmor                  Disable and stop AppArmor.
  --reload-apparmor-profiles          Reload all AppArmor profiles.
  --set-apparmor-mode [profile] [mode] Set AppArmor profile to 'enforce' or 'complain'.
  --set-locale [locale]                Set system locale (e.g., 'en_US.UTF-8').
  --generate-locales                   Generate missing locales.
  --verify-backup [backup_file]        Verify the integrity of a specified backup file.
  --list-backups                       List all available backups in /var/backups/.
  --ensure-essential-packages          Check and install missing essential packages.
  --list-missing-packages              List missing essential packages.
  --search-logs [keyword]              Search system logs for a specific keyword.
  --recent-logs [number]               Display the last [number] lines of /var/log/syslog (default: 100).
  --compress-logs                      Compress old log files older than 7 days.
  --archive-logs [destination]         Archive compressed logs to a specified destination.
  --delete-archived-logs [dir] [days]  Delete archived logs older than specified days.
  --install-lynis                      Install Lynis for system auditing.
  --run-lynis-audit                    Run Lynis security audit.
  --backup-network-config              Backup network configuration files.
  --restore-network-config [file]       Restore network configuration from a backup file.
  --exec-script [script_path]           Execute a custom script.
  --exec-command [command]              Execute a custom command.
  -h, --help                           Display this help message.

Examples:
  sudo $0 --clean-logs --fix-apt-packages
  sudo $0 --backup /home/user/data --send-notification admin@example.com
  sudo $0 --manage-service restart apache2
EOF
}

# Function to log messages
log_message() {
    local message="$1"
    echo "$(date +"%Y-%m-%d %H:%M:%S") : $message" | tee -a "$LOG_FILE"
}

# Function to send email notifications
send_notification() {
    local subject="$1"
    local body="$2"
    local email="$3"

    if [[ -z "$email" ]]; then
        echo "No notification email provided."
        return
    fi

    if command -v mail >/dev/null 2>&1; then
        echo "$body" | mail -s "$subject" "$email"
    else
        echo "Mail utility not found. Cannot send notification."
    fi
}

# ====== Maintenance Functions ======

# 1. Log Management
clean_logs() {
    log_message "Cleaning old logs started."
    echo "Cleaning old logs..."
    find /var/log -type f -name "*.log" -exec truncate -s 0 {} \;
    find /var/log -type f -name "*.gz" -exec rm -f {} \;
    log_message "Old logs cleaned."
    echo "Old logs cleaned."
}

# 2. Package Management
fix_apt_packages() {
    log_message "Fixing broken APT packages started."
    echo "Fixing broken APT packages..."
    apt --fix-broken install -y
    dpkg --configure -a
    apt update
    apt upgrade -y
    log_message "APT packages fixed and system updated."
    echo "APT package issues fixed and system updated."
}

# 3. APT Lock Management
fix_apt_lock() {
    log_message "Fixing APT lock issues started."
    echo "Fixing APT lock issues..."
    rm -f /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock
    dpkg --configure -a
    apt update
    log_message "APT lock issues resolved."
    echo "APT lock issues resolved."
}

# 4. Disk Cleanup
clean_disk() {
    log_message "Disk cleanup started."
    echo "Cleaning disk space..."

    # Remove unused packages
    apt autoremove -y
    apt clean
    apt autoclean

    # Remove temporary files
    rm -rf /tmp/*

    log_message "Disk cleanup completed."
    echo "Disk cleanup completed."
}

# 5. System Update
update_system() {
    log_message "System update and upgrade started."
    echo "Updating and upgrading the system..."
    apt update
    apt upgrade -y
    apt dist-upgrade -y
    log_message "System update and upgrade completed."
    echo "System update and upgrade completed."
}

# 6. Backup and Restore
backup_system() {
    local backup_dir="$1"
    local timestamp
    timestamp=$(date +"%Y%m%d_%H%M%S")
    local backup_file="/var/backups/backup_${timestamp}.tar.gz"

    if [[ -z "$backup_dir" ]]; then
        echo "Please specify a directory to back up."
        log_message "Backup failed: No directory specified."
        return 1
    fi

    if [[ ! -d "$backup_dir" ]]; then
        echo "Directory $backup_dir does not exist."
        log_message "Backup failed: Directory $backup_dir does not exist."
        return 1
    fi

    echo "Creating backup of $backup_dir..."
    tar -czvf "$backup_file" "$backup_dir" &>> "$LOG_FILE"
    if [[ $? -eq 0 ]]; then
        log_message "Backup created: $backup_file"
        echo "Backup created: $backup_file"
    else
        log_message "Backup failed for directory: $backup_dir"
        echo "Backup failed."
    fi
}

restore_backup() {
    local backup_file="$1"
    local restore_dir="$2"

    if [[ -z "$backup_file" || -z "$restore_dir" ]]; then
        echo "Please specify both backup file and restore directory."
        log_message "Restore failed: Missing backup file or restore directory."
        return 1
    fi

    if [[ ! -f "$backup_file" ]]; then
        echo "Backup file $backup_file does not exist."
        log_message "Restore failed: Backup file $backup_file does not exist."
        return 1
    fi

    if [[ ! -d "$restore_dir" ]]; then
        echo "Restore directory $restore_dir does not exist. Creating it."
        mkdir -p "$restore_dir"
    fi

    echo "Restoring backup from $backup_file to $restore_dir..."
    tar -xzvf "$backup_file" -C "$restore_dir" &>> "$LOG_FILE"
    if [[ $? -eq 0 ]]; then
        log_message "Backup restored from $backup_file to $restore_dir."
        echo "Backup restored successfully."
    else
        log_message "Restore failed from $backup_file to $restore_dir."
        echo "Restore failed."
    fi
}

# 7. System Information
system_info() {
    echo "System Information:"
    uname -a
    lsb_release -a 2>/dev/null
    echo ""
    echo "CPU Information:"
    lscpu
    echo ""
    echo "Memory Usage:"
    free -h
    echo ""
    echo "Disk Usage:"
    df -h
    echo ""
    echo "Network Interfaces:"
    ip addr show
    log_message "Displayed system information."
}

# 8. Resource Usage
resource_usage() {
    echo "CPU and Memory Usage:"
    top -b -n1 | head -15
    echo ""
    echo "Disk I/O:"
    iostat
    log_message "Displayed resource usage."
}

# 9. Firewall Configuration
configure_firewall() {
    log_message "Configuring UFW firewall started."
    echo "Configuring UFW firewall..."

    if command -v ufw >/dev/null 2>&1; then
        ufw enable
        ufw allow ssh
        ufw allow http
        ufw allow https
        ufw status verbose
        log_message "UFW firewall configured."
        echo "UFW firewall configured."
    else
        echo "UFW is not installed. Installing UFW..."
        apt install ufw -y &>> "$LOG_FILE"
        if [[ $? -eq 0 ]]; then
            ufw enable
            ufw allow ssh
            ufw allow http
            ufw allow https
            ufw status verbose
            log_message "UFW firewall installed and configured."
            echo "UFW firewall installed and configured."
        else
            echo "Failed to install UFW."
            log_message "Failed to install UFW."
        fi
    fi
}

# 10. Security Scan
security_scan() {
    log_message "Security scan started."
    echo "Performing security scan..."

    if command -v rkhunter >/dev/null 2>&1; then
        rkhunter --update
        rkhunter --check --sk
    else
        echo "rkhunter is not installed. Installing rkhunter..."
        apt install rkhunter -y &>> "$LOG_FILE"
        if [[ $? -eq 0 ]]; then
            rkhunter --update
            rkhunter --check --sk
            log_message "rkhunter installed and security scan completed."
            echo "rkhunter installed and security scan completed."
        else
            echo "Failed to install rkhunter."
            log_message "Failed to install rkhunter."
        fi
    fi
}

# 11. User and Group Management
add_user() {
    local username="$1"

    if [[ -z "$username" ]]; then
        echo "Please provide a username to add."
        log_message "Add user failed: No username provided."
        return 1
    fi

    if id "$username" &>/dev/null; then
        echo "User $username already exists."
        log_message "Add user failed: User $username already exists."
        return 1
    fi

    useradd -m "$username"
    if [[ $? -eq 0 ]]; then
        passwd "$username"
        log_message "User $username added successfully."
        echo "User $username added successfully."
    else
        log_message "Failed to add user $username."
        echo "Failed to add user."
    fi
}

remove_user() {
    local username="$1"

    if [[ -z "$username" ]]; then
        echo "Please provide a username to remove."
        log_message "Remove user failed: No username provided."
        return 1
    fi

    if ! id "$username" &>/dev/null; then
        echo "User $username does not exist."
        log_message "Remove user failed: User $username does not exist."
        return 1
    fi

    userdel -r "$username"
    if [[ $? -eq 0 ]]; then
        log_message "User $username removed successfully."
        echo "User $username removed successfully."
    else
        log_message "Failed to remove user $username."
        echo "Failed to remove user."
    fi
}

add_group() {
    local group="$1"

    if [[ -z "$group" ]]; then
        echo "Please provide a group name to add."
        log_message "Add group failed: No group name provided."
        return 1
    fi

    if getent group "$group" >/dev/null; then
        echo "Group $group already exists."
        log_message "Add group failed: Group $group already exists."
        return 1
    fi

    groupadd "$group"
    if [[ $? -eq 0 ]]; then
        log_message "Group $group added successfully."
        echo "Group $group added successfully."
    else
        log_message "Failed to add group $group."
        echo "Failed to add group."
    fi
}

remove_group() {
    local group="$1"

    if [[ -z "$group" ]]; then
        echo "Please provide a group name to remove."
        log_message "Remove group failed: No group name provided."
        return 1
    fi

    if ! getent group "$group" >/dev/null; then
        echo "Group $group does not exist."
        log_message "Remove group failed: Group $group does not exist."
        return 1
    fi

    groupdel "$group"
    if [[ $? -eq 0 ]]; then
        log_message "Group $group removed successfully."
        echo "Group $group removed successfully."
    else
        log_message "Failed to remove group $group."
        echo "Failed to remove group."
    fi
}

# 12. Service Management
manage_service() {
    local action="$1"
    local service="$2"

    if [[ -z "$action" || -z "$service" ]]; then
        echo "Please specify both action and service name."
        log_message "Manage service failed: Missing action or service name."
        return 1
    fi

    if ! systemctl list-unit-files | grep -qw "$service"; then
        echo "Service $service does not exist."
        log_message "Manage service failed: Service $service does not exist."
        return 1
    fi

    systemctl "$action" "$service" &>> "$LOG_FILE"
    if [[ $? -eq 0 ]]; then
        log_message "Service $service $action successfully."
        echo "Service $service $action successfully."
    else
        log_message "Failed to $action service $service."
        echo "Failed to $action service."
    fi
}

# 13. Scheduling Tasks
schedule_task() {
    local task="$1"
    local schedule="$2"

    if [[ -z "$task" || -z "$schedule" ]]; then
        echo "Please provide both a task and a schedule."
        echo "Example schedule: '0 2 * * *' for daily at 2 AM."
        log_message "Schedule task failed: Missing task or schedule."
        return 1
    fi

    # Basic cron schedule validation
    if ! [[ "$schedule" =~ ^([0-5]?[0-9]|[0-5][0-9])\ ([0-9]|1[0-9]|2[0-3])\ ([1-9]|[12][0-9]|3[01])\ ([1-9]|1[0-2])\ ([0-6])$ ]]; then
        echo "Invalid cron schedule format."
        log_message "Schedule task failed: Invalid cron schedule format."
        return 1
    fi

    (crontab -l 2>/dev/null; echo "$schedule $0 $task") | crontab -
    if [[ $? -eq 0 ]]; then
        log_message "Task '$task' scheduled with cron at '$schedule'."
        echo "Task '$task' scheduled successfully."
    else
        log_message "Failed to schedule task '$task' with cron."
        echo "Failed to schedule task."
    fi
}

list_scheduled_tasks() {
    echo "Scheduled Maintenance Tasks (crontab):"
    crontab -l
    log_message "Listed scheduled maintenance tasks."
}

# 14. Reboot System
reboot_system() {
    local delay="$1"
    if [[ -n "$delay" ]]; then
        echo "System will reboot in $delay minutes."
        shutdown -r +"$delay" "Reboot initiated by maintenance script."
        log_message "System scheduled to reboot in $delay minutes."
    else
        echo "Rebooting the system now..."
        shutdown -r now "Reboot initiated by maintenance script."
        log_message "System reboot initiated."
    fi
}

# 15. Log Rotation
configure_logrotate() {
    log_message "Configuring log rotation started."
    echo "Configuring log rotation..."

    local logrotate_conf="/etc/logrotate.d/custom"

    if [[ ! -f "$logrotate_conf" ]]; then
        cat << EOF > "$logrotate_conf"
/var/log/*.log {
    daily
    missingok
    rotate 7
    compress
    delaycompress
    notifempty
    create 0640 root adm
    sharedscripts
    postrotate
        systemctl reload rsyslog > /dev/null 2>&1 || true
    endscript
}
EOF
        log_message "Custom logrotate configuration created at $logrotate_conf."
        echo "Custom logrotate configuration created."
    else
        log_message "Custom logrotate configuration already exists at $logrotate_conf."
        echo "Custom logrotate configuration already exists."
    fi

    log_message "Log rotation configured."
}

trigger_logrotate() {
    log_message "Triggering log rotation."
    echo "Triggering log rotation..."
    logrotate -f /etc/logrotate.conf
    if [[ $? -eq 0 ]]; then
        log_message "Log rotation triggered successfully."
        echo "Log rotation triggered successfully."
    else
        log_message "Log rotation failed."
        echo "Log rotation failed."
    fi
}

# 16. Notifications
notify_after_task() {
    if [[ -n "$NOTIFY_EMAIL" ]]; then
        local subject="Maintenance Script Notification"
        local body="The maintenance script has completed its tasks successfully."
        send_notification "$subject" "$body" "$NOTIFY_EMAIL"
    fi
}

# 17. Kernel Management
list_kernels() {
    echo "Installed Kernels:"
    dpkg --list | grep linux-image | awk '{print $2}'
    log_message "Listed installed kernels."
}

remove_old_kernels() {
    echo "Removing old kernels..."
    current_kernel=$(uname -r | sed 's/-generic//')
    dpkg --list | grep linux-image | awk '{print $2}' | grep -v "$current_kernel" | grep -v "$(apt-cache showpkg linux-image-$(uname -r | awk -F'-' '{print $1"-"$2}'))" | xargs sudo apt-get -y purge
    apt autoremove -y
    log_message "Old kernels removed."
    echo "Old kernels removed."
}

install_latest_kernel() {
    echo "Installing the latest kernel..."
    apt update
    apt install -y linux-generic
    log_message "Latest kernel installed."
    echo "Latest kernel installed."
}

set_default_kernel() {
    echo "Setting default kernel in GRUB..."
    update-grub
    log_message "GRUB updated with the default kernel."
    echo "Default kernel set."
}

# 18. Unattended Upgrades
enable_unattended_upgrades() {
    echo "Enabling unattended upgrades..."
    apt install -y unattended-upgrades
    dpkg-reconfigure --priority=low unattended-upgrades
    log_message "Unattended upgrades enabled."
    echo "Unattended upgrades enabled."
}

configure_automatic_updates() {
    echo "Configuring automatic updates..."
    cat << EOF > /etc/apt/apt.conf.d/20auto-upgrades
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
APT::Periodic::Unattended-Upgrade "1";
EOF
    log_message "Automatic updates configured."
    echo "Automatic updates configured."
}

check_unattended_upgrades() {
    systemctl status unattended-upgrades
    log_message "Checked unattended upgrades status."
}

# 19. Snap Package Management
list_snap_packages() {
    echo "Installed Snap Packages:"
    snap list
    log_message "Listed installed snap packages."
}

remove_snap_package() {
    local package="$1"
    if [[ -z "$package" ]]; then
        echo "Please provide a snap package name to remove."
        log_message "Remove snap package failed: No package name provided."
        return 1
    fi
    snap remove "$package"
    if [[ $? -eq 0 ]]; then
        log_message "Snap package $package removed successfully."
        echo "Snap package $package removed successfully."
    else
        log_message "Failed to remove snap package $package."
        echo "Failed to remove snap package."
    fi
}

refresh_snap_packages() {
    echo "Refreshing (updating) snap packages..."
    snap refresh
    log_message "Snap packages refreshed."
    echo "Snap packages refreshed."
}

install_snap_package() {
    local package="$1"
    if [[ -z "$package" ]]; then
        echo "Please provide a snap package name to install."
        log_message "Install snap package failed: No package name provided."
        return 1
    fi
    snap install "$package"
    if [[ $? -eq 0 ]]; then
        log_message "Snap package $package installed successfully."
        echo "Snap package $package installed successfully."
    else
        log_message "Failed to install snap package $package."
        echo "Failed to install snap package."
    fi
}

# 20. Flatpak Package Management
install_flatpak() {
    echo "Installing Flatpak..."
    apt update
    apt install -y flatpak
    if [[ $? -eq 0 ]]; then
        log_message "Flatpak installed successfully."
        echo "Flatpak installed successfully."
    else
        log_message "Failed to install Flatpak."
        echo "Failed to install Flatpak."
    fi
}

add_flatpak_repo() {
    local repo_url="$1"
    if [[ -z "$repo_url" ]]; then
        echo "Please provide a Flatpak repository URL."
        log_message "Add Flatpak repo failed: No repository URL provided."
        return 1
    fi
    flatpak remote-add --if-not-exists flathub "$repo_url"
    if [[ $? -eq 0 ]]; then
        log_message "Flatpak repository $repo_url added successfully."
        echo "Flatpak repository added successfully."
    else
        log_message "Failed to add Flatpak repository $repo_url."
        echo "Failed to add Flatpak repository."
    fi
}

list_flatpak_packages() {
    echo "Installed Flatpak Packages:"
    flatpak list
    log_message "Listed installed Flatpak packages."
}

remove_flatpak_package() {
    local package="$1"
    if [[ -z "$package" ]]; then
        echo "Please provide a Flatpak package name to remove."
        log_message "Remove Flatpak package failed: No package name provided."
        return 1
    fi
    flatpak uninstall -y "$package"
    if [[ $? -eq 0 ]]; then
        log_message "Flatpak package $package removed successfully."
        echo "Flatpak package $package removed successfully."
    else
        log_message "Failed to remove Flatpak package $package."
        echo "Failed to remove Flatpak package."
    fi
}

refresh_flatpak_packages() {
    echo "Refreshing (updating) Flatpak packages..."
    flatpak update -y
    if [[ $? -eq 0 ]]; then
        log_message "Flatpak packages refreshed."
        echo "Flatpak packages refreshed."
    else
        log_message "Failed to refresh Flatpak packages."
        echo "Failed to refresh Flatpak packages."
    fi
}

# 21. Swap Space Management
check_swap() {
    echo "Swap Usage:"
    swapon --show
    free -h
    log_message "Checked swap usage."
}

create_swap() {
    local swap_size="$1"
    if [[ -z "$swap_size" ]]; then
        echo "Please provide swap size (e.g., 2G, 512M)."
        log_message "Create swap failed: No swap size provided."
        return 1
    fi
    fallocate -l "$swap_size" /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    echo '/swapfile none swap sw 0 0' | tee -a /etc/fstab
    log_message "Swap file of size $swap_size created and enabled."
    echo "Swap file created and enabled."
}

remove_swap() {
    echo "Disabling and removing swap file..."
    swapoff /swapfile
    rm /swapfile
    sed -i '/\/swapfile/d' /etc/fstab
    log_message "Swap file disabled and removed."
    echo "Swap file disabled and removed."
}

# 22. Time Synchronization Management
check_time_sync() {
    timedatectl status
    log_message "Checked time synchronization status."
}

enable_ntp() {
    echo "Enabling NTP time synchronization..."
    timedatectl set-ntp true
    log_message "NTP time synchronization enabled."
    echo "NTP time synchronization enabled."
}

disable_ntp() {
    echo "Disabling NTP time synchronization..."
    timedatectl set-ntp false
    log_message "NTP time synchronization disabled."
    echo "NTP time synchronization disabled."
}

set_timezone() {
    local timezone="$1"
    if [[ -z "$timezone" ]]; then
        echo "Please provide a timezone (e.g., 'Europe/London')."
        log_message "Set timezone failed: No timezone provided."
        return 1
    fi
    timedatectl set-timezone "$timezone"
    if [[ $? -eq 0 ]]; then
        log_message "Timezone set to $timezone."
        echo "Timezone set to $timezone."
    else
        log_message "Failed to set timezone to $timezone."
        echo "Failed to set timezone."
    fi
}

# 23. APT Repository Management
add_apt_repo() {
    local repo="$1"
    local key_url="$2"

    if [[ -z "$repo" ]]; then
        echo "Please provide an APT repository string."
        log_message "Add APT repo failed: No repository string provided."
        return 1
    fi

    echo "Adding APT repository: $repo"
    add-apt-repository -y "$repo"
    if [[ -n "$key_url" ]]; then
        wget -qO - "$key_url" | apt-key add -
        if [[ $? -eq 0 ]]; then
            log_message "GPG key added from $key_url."
            echo "GPG key added."
        else
            log_message "Failed to add GPG key from $key_url."
            echo "Failed to add GPG key."
        fi
    fi
    apt update
    log_message "APT repository $repo added."
    echo "APT repository added successfully."
}

remove_apt_repo() {
    local repo="$1"

    if [[ -z "$repo" ]]; then
        echo "Please provide an APT repository string to remove."
        log_message "Remove APT repo failed: No repository string provided."
        return 1
    fi

    echo "Removing APT repository: $repo"
    add-apt-repository --remove -y "$repo"
    apt update
    log_message "APT repository $repo removed."
    echo "APT repository removed successfully."
}

list_apt_repos() {
    echo "Current APT Repositories:"
    grep -r ^deb /etc/apt/sources.list /etc/apt/sources.list.d/
    log_message "Listed APT repositories."
}

# 24. System Health Monitoring
check_uptime() {
    echo "System Uptime:"
    uptime
    log_message "Checked system uptime."
}

check_load() {
    echo "Load Averages:"
    uptime | awk -F 'load average:' '{ print $2 }'
    log_message "Checked load averages."
}

check_disk_inodes() {
    echo "Disk Inode Usage:"
    df -i
    log_message "Checked disk inode usage."
}

monitor_service() {
    local service="$1"
    if [[ -z "$service" ]]; then
        echo "Please provide a service name to monitor."
        log_message "Monitor service failed: No service name provided."
        return 1
    fi

    if systemctl is-active --quiet "$service"; then
        echo "Service $service is running."
    else
        echo "Service $service is NOT running."
    fi
    log_message "Monitored service $service."
}

# 25. Filesystem Integrity Check
run_fsck() {
    echo "Running filesystem check..."
    touch /forcefsck
    log_message "Filesystem check scheduled on next reboot."
    echo "Filesystem check scheduled on next reboot."
}

schedule_fsck() {
    echo "Scheduling regular filesystem checks..."
    echo "0 3 * * 1 root /sbin/fsck -Af -M" >> /etc/crontab
    log_message "Regular filesystem checks scheduled."
    echo "Regular filesystem checks scheduled."
}

# 26. Docker Management
install_docker() {
    echo "Installing Docker..."
    apt update
    apt install -y apt-transport-https ca-certificates curl gnupg lsb-release
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu \
      $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
    apt update
    apt install -y docker-ce docker-ce-cli containerd.io
    log_message "Docker installed successfully."
    echo "Docker installed successfully."
}

start_docker() {
    systemctl start docker
    systemctl enable docker
    log_message "Docker service started and enabled."
    echo "Docker service started and enabled."
}

stop_docker() {
    systemctl stop docker
    systemctl disable docker
    log_message "Docker service stopped and disabled."
    echo "Docker service stopped and disabled."
}

list_docker_containers() {
    echo "Running Docker Containers:"
    docker ps
    log_message "Listed Docker containers."
}

remove_docker_container() {
    local container_id="$1"
    if [[ -z "$container_id" ]]; then
        echo "Please provide a Docker container ID to remove."
        log_message "Remove Docker container failed: No container ID provided."
        return 1
    fi
    docker rm -f "$container_id"
    if [[ $? -eq 0 ]]; then
        log_message "Docker container $container_id removed successfully."
        echo "Docker container $container_id removed successfully."
    else
        log_message "Failed to remove Docker container $container_id."
        echo "Failed to remove Docker container."
    fi
}

# 27. AppArmor Management
check_apparmor_status() {
    apparmor_status
    log_message "Checked AppArmor status."
}

enable_apparmor() {
    echo "Enabling AppArmor..."
    systemctl enable apparmor
    systemctl start apparmor
    log_message "AppArmor enabled."
    echo "AppArmor enabled."
}

disable_apparmor() {
    echo "Disabling AppArmor..."
    systemctl stop apparmor
    systemctl disable apparmor
    log_message "AppArmor disabled."
    echo "AppArmor disabled."
}

reload_apparmor_profiles() {
    echo "Reloading AppArmor profiles..."
    apparmor_parser -r /etc/apparmor.d/*
    log_message "AppArmor profiles reloaded."
    echo "AppArmor profiles reloaded."
}

set_apparmor_mode() {
    local profile="$1"
    local mode="$2"

    if [[ -z "$profile" || -z "$mode" ]]; then
        echo "Please provide both profile name and mode (enforce/complain)."
        log_message "Set AppArmor mode failed: Missing profile name or mode."
        return 1
    fi

    if [[ "$mode" == "enforce" ]]; then
        aa-enforce "$profile"
    elif [[ "$mode" == "complain" ]]; then
        aa-complain "$profile"
    else
        echo "Invalid mode. Use 'enforce' or 'complain'."
        log_message "Set AppArmor mode failed: Invalid mode."
        return 1
    fi

    if [[ $? -eq 0 ]]; then
        log_message "AppArmor profile $profile set to $mode mode."
        echo "AppArmor profile $profile set to $mode mode."
    else
        log_message "Failed to set AppArmor profile $profile to $mode mode."
        echo "Failed to set AppArmor profile."
    fi
}

# 28. Localization and Timezone Settings
set_system_locale() {
    local locale="$1"
    if [[ -z "$locale" ]]; then
        echo "Please provide a locale (e.g., 'en_US.UTF-8')."
        log_message "Set locale failed: No locale provided."
        return 1
    fi
    echo "Setting system locale to $locale..."
    locale-gen "$locale"
    update-locale LANG="$locale"
    log_message "System locale set to $locale."
    echo "System locale set to $locale."
}

generate_locales() {
    echo "Generating missing locales..."
    dpkg-reconfigure locales
    log_message "Locales generated."
    echo "Locales generated."
}

# 29. Backup Verification
verify_backup() {
    local backup_file="$1"

    if [[ -z "$backup_file" ]]; then
        echo "Please provide a backup file to verify."
        log_message "Verify backup failed: No backup file provided."
        return 1
    fi

    if [[ ! -f "$backup_file" ]]; then
        echo "Backup file $backup_file does not exist."
        log_message "Verify backup failed: Backup file $backup_file does not exist."
        return 1
    fi

    echo "Verifying backup integrity..."
    tar -tzf "$backup_file" &>/dev/null
    if [[ $? -eq 0 ]]; then
        log_message "Backup $backup_file is valid."
        echo "Backup $backup_file is valid."
    else
        log_message "Backup $backup_file is corrupted or invalid."
        echo "Backup $backup_file is corrupted or invalid."
    fi
}

list_backups() {
    echo "Available Backups in /var/backups/:"
    ls /var/backups/backup_*.tar.gz
    log_message "Listed available backups."
}

# 30. Essential Package Checks
ensure_essential_packages() {
    local packages=("curl" "wget" "git" "vim" "htop" "tmux" "net-tools" "gnupg" "software-properties-common" "iostat")
    local missing=()

    for pkg in "${packages[@]}"; do
        if ! dpkg -s "$pkg" &>/dev/null; then
            missing+=("$pkg")
        fi
    done

    if [[ ${#missing[@]} -eq 0 ]]; then
        echo "All essential packages are installed."
        log_message "All essential packages are installed."
    else
        echo "Installing missing essential packages: ${missing[*]}"
        apt install -y "${missing[@]}"
        if [[ $? -eq 0 ]]; then
            log_message "Essential packages installed: ${missing[*]}"
            echo "Essential packages installed successfully."
        else
            log_message "Failed to install essential packages: ${missing[*]}"
            echo "Failed to install some essential packages."
        fi
    fi
}

list_missing_packages() {
    local packages=("curl" "wget" "git" "vim" "htop" "tmux" "net-tools" "gnupg" "software-properties-common" "iostat")
    local missing=()

    for pkg in "${packages[@]}"; do
        if ! dpkg -s "$pkg" &>/dev/null; then
            missing+=("$pkg")
        fi
    done

    if [[ ${#missing[@]} -eq 0 ]]; then
        echo "All essential packages are installed."
    else
        echo "Missing essential packages: ${missing[*]}"
    fi
    log_message "Listed missing essential packages."
}

# 31. System Log Analysis
search_logs() {
    local keyword="$1"
    if [[ -z "$keyword" ]]; then
        echo "Please provide a keyword to search in logs."
        log_message "Search logs failed: No keyword provided."
        return 1
    fi

    echo "Searching /var/log for keyword: $keyword"
    grep -i "$keyword" /var/log/*.log
    log_message "Searched logs for keyword: $keyword."
}

recent_logs() {
    local num="$1"
    if [[ -z "$num" ]]; then
        num=100
    fi

    echo "Displaying the last $num lines of /var/log/syslog:"
    tail -n "$num" /var/log/syslog
    log_message "Displayed the last $num lines of /var/log/syslog."
}

# 32. Advanced Log Management
compress_old_logs() {
    echo "Compressing old logs..."
    find /var/log -type f -name "*.log" -mtime +7 -exec gzip {} \;
    log_message "Old logs compressed."
    echo "Old logs compressed."
}

archive_logs() {
    local destination="$1"
    if [[ -z "$destination" ]]; then
        echo "Please provide a destination path for archiving logs."
        log_message "Archive logs failed: No destination provided."
        return 1
    fi

    echo "Archiving logs to $destination..."
    tar -czvf "$destination/logs_archive_$(date +"%Y%m%d_%H%M%S").tar.gz" /var/log/*.gz /var/log/*.log.gz &>> "$LOG_FILE"
    if [[ $? -eq 0 ]]; then
        log_message "Logs archived to $destination."
        echo "Logs archived successfully."
    else
        log_message "Failed to archive logs to $destination."
        echo "Failed to archive logs."
    fi
}

delete_archived_logs() {
    local archive_dir="$1"
    local retention_days="$2"

    if [[ -z "$archive_dir" || -z "$retention_days" ]]; then
        echo "Please provide both archive directory and retention days."
        log_message "Delete archived logs failed: Missing archive directory or retention days."
        return 1
    fi

    echo "Deleting archived logs older than $retention_days days from $archive_dir..."
    find "$archive_dir" -type f -name "logs_archive_*.tar.gz" -mtime +"$retention_days" -exec rm -f {} \;
    log_message "Archived logs older than $retention_days days deleted from $archive_dir."
    echo "Archived logs deleted successfully."
}

# 33. Lynis Security Audit
install_lynis() {
    echo "Installing Lynis for system auditing..."
    apt install -y lynis
    if [[ $? -eq 0 ]]; then
        log_message "Lynis installed successfully."
        echo "Lynis installed successfully."
    else
        log_message "Failed to install Lynis."
        echo "Failed to install Lynis."
    fi
}

run_lynis_audit() {
    if ! command -v lynis >/dev/null 2>&1; then
        echo "Lynis is not installed. Installing now..."
        install_lynis
    fi

    echo "Running Lynis security audit..."
    lynis audit system
    log_message "Lynis security audit completed."
}

# 34. Network Configuration Backup
backup_network_config() {
    local backup_file="/var/backups/network_config_backup_$(date +"%Y%m%d_%H%M%S").tar.gz"
    echo "Backing up network configuration..."
    tar -czvf "$backup_file" /etc/network /etc/netplan /etc/NetworkManager &>> "$LOG_FILE"
    if [[ $? -eq 0 ]]; then
        log_message "Network configuration backed up to $backup_file."
        echo "Network configuration backed up to $backup_file."
    else
        log_message "Failed to backup network configuration."
        echo "Failed to backup network configuration."
    fi
}

restore_network_config() {
    local backup_file="$1"

    if [[ -z "$backup_file" ]]; then
        echo "Please provide a backup file to restore."
        log_message "Restore network config failed: No backup file provided."
        return 1
    fi

    if [[ ! -f "$backup_file" ]]; then
        echo "Backup file $backup_file does not exist."
        log_message "Restore network config failed: Backup file $backup_file does not exist."
        return 1
    fi

    echo "Restoring network configuration from $backup_file..."
    tar -xzvf "$backup_file" -C / &>> "$LOG_FILE"
    if [[ $? -eq 0 ]]; then
        log_message "Network configuration restored from $backup_file."
        echo "Network configuration restored successfully."
    else
        log_message "Failed to restore network configuration from $backup_file."
        echo "Failed to restore network configuration."
    fi
}

# 35. Custom Script Execution
execute_custom_script() {
    local script_path="$1"

    if [[ -z "$script_path" ]]; then
        echo "Please provide the path to the script to execute."
        log_message "Execute custom script failed: No script path provided."
        return 1
    fi

    if [[ ! -f "$script_path" ]]; then
        echo "Script file $script_path does not exist."
        log_message "Execute custom script failed: Script file $script_path does not exist."
        return 1
    fi

    chmod +x "$script_path"
    "$script_path"
    if [[ $? -eq 0 ]]; then
        log_message "Custom script $script_path executed successfully."
        echo "Custom script executed successfully."
    else
        log_message "Failed to execute custom script $script_path."
        echo "Failed to execute custom script."
    fi
}

execute_custom_command() {
    local command="$1"

    if [[ -z "$command" ]]; then
        echo "Please provide the command to execute."
        log_message "Execute custom command failed: No command provided."
        return 1
    fi

    echo "Executing custom command: $command"
    eval "$command"
    if [[ $? -eq 0 ]]; then
        log_message "Custom command '$command' executed successfully."
        echo "Custom command executed successfully."
    else
        log_message "Failed to execute custom command '$command'."
        echo "Failed to execute custom command."
    fi
}

# 36. Container-Specific Update Function (as per your example)
update_container() {
    container=$1
    os=$(pct config "$container" | awk '/^ostype/ {print $2}')

    if [[ "$os" == "ubuntu" || "$os" == "debian" ]]; then
        echo -e "${BL}[Info]${GN} Checking /usr/bin/update in ${BL}$container${CL} (OS: ${GN}$os${CL})"

        if pct exec "$container" -- [ -e /usr/bin/update ]; then
            if pct exec "$container" -- grep -q "community-scripts/ProxmoxVE" /usr/bin/update; then
                echo -e "${RD}[No Change]${CL} /usr/bin/update is already up to date in ${BL}$container${CL}.\n"
            elif pct exec "$container" -- grep -q -v "tteck" /usr/bin/update; then
                echo -e "${RD}[Warning]${CL} /usr/bin/update in ${BL}$container${CL} contains a different entry (${RD}tteck${CL}). No changes made.\n"
            else
                pct exec "$container" -- bash -c "sed -i 's/tteck\\/Proxmox/community-scripts\\/ProxmoxVE/g' /usr/bin/update"

                if pct exec "$container" -- grep -q "community-scripts/ProxmoxVE" /usr/bin/update; then
                    echo -e "${GN}[Success]${CL} /usr/bin/update updated in ${BL}$container${CL}.\n"
                else
                    echo -e "${RD}[Error]${CL} /usr/bin/update in ${BL}$container${CL} could not be updated properly.\n"
                fi
            fi
        else
            echo -e "${RD}[Error]${CL} /usr/bin/update not found in container ${BL}$container${CL}.\n"
        fi
    else
        echo -e "${BL}[Info]${GN} Skipping ${BL}$container${CL} (not Debian/Ubuntu)\n"
    fi
}

# 37. Essential Package Installation in Containers (Optional)
# Add here if needed.

# ====== Interactive Menu Function ======

interactive_menu() {
    echo "===== Debian/Ubuntu Maintenance Menu ====="
    echo "1) Clean Old Logs"
    echo "2) Fix APT Packages"
    echo "3) Fix APT Locks"
    echo "4) Clean Disk"
    echo "5) Update System"
    echo "6) Backup System"
    echo "7) Restore Backup"
    echo "8) System Info"
    echo "9) Resource Usage"
    echo "10) Configure Firewall"
    echo "11) Security Scan"
    echo "12) Add User"
    echo "13) Remove User"
    echo "14) Add Group"
    echo "15) Remove Group"
    echo "16) Manage Service"
    echo "17) Schedule Task"
    echo "18) List Scheduled Tasks"
    echo "19) Reboot System"
    echo "20) Configure Log Rotation"
    echo "21) Trigger Log Rotation"
    echo "22) Send Notification"
    echo "23) List Installed Kernels"
    echo "24) Remove Old Kernels"
    echo "25) Install Latest Kernel"
    echo "26) Set Default Kernel"
    echo "27) Enable Unattended Upgrades"
    echo "28) Configure Automatic Updates"
    echo "29) Check Unattended Upgrades Status"
    echo "30) List Snap Packages"
    echo "31) Remove Snap Package"
    echo "32) Refresh Snap Packages"
    echo "33) Install Snap Package"
    echo "34) Install Flatpak"
    echo "35) Add Flatpak Repository"
    echo "36) List Flatpak Packages"
    echo "37) Remove Flatpak Package"
    echo "38) Refresh Flatpak Packages"
    echo "39) Check Swap Usage"
    echo "40) Create Swap File"
    echo "41) Remove Swap File"
    echo "42) Check Time Synchronization Status"
    echo "43) Enable NTP"
    echo "44) Disable NTP"
    echo "45) Set Timezone"
    echo "46) Add APT Repository"
    echo "47) Remove APT Repository"
    echo "48) List APT Repositories"
    echo "49) Check System Uptime"
    echo "50) Check Load Averages"
    echo "51) Check Disk Inode Usage"
    echo "52) Monitor Service Status"
    echo "53) Run Filesystem Check (fsck)"
    echo "54) Schedule Filesystem Check"
    echo "55) Install Docker"
    echo "56) Start Docker Service"
    echo "57) Stop Docker Service"
    echo "58) List Docker Containers"
    echo "59) Remove Docker Container"
    echo "60) Check AppArmor Status"
    echo "61) Enable AppArmor"
    echo "62) Disable AppArmor"
    echo "63) Reload AppArmor Profiles"
    echo "64) Set AppArmor Profile Mode"
    echo "65) Set System Locale"
    echo "66) Generate Locales"
    echo "67) Verify Backup Integrity"
    echo "68) List Available Backups"
    echo "69) Ensure Essential Packages Installed"
    echo "70) List Missing Essential Packages"
    echo "71) Search Logs for Keyword"
    echo "72) Display Recent Log Entries"
    echo "73) Compress Old Logs"
    echo "74) Archive Logs to Destination"
    echo "75) Delete Archived Logs"
    echo "76) Install Lynis"
    echo "77) Run Lynis Security Audit"
    echo "78) Backup Network Configuration"
    echo "79) Restore Network Configuration"
    echo "80) Execute Custom Script"
    echo "81) Execute Custom Command"
    echo "82) Update Containers (ProxmoxVE)"
    echo "83) Exit"
    echo "=========================================="

    read -p "Select an option [1-83]: " option

    case "$option" in
        1) clean_logs ;;
        2) fix_apt_packages ;;
        3) fix_apt_lock ;;
        4) clean_disk ;;
        5) update_system ;;
        6)
            read -p "Enter directory to backup: " backup_dir
            backup_system "$backup_dir"
            ;;
        7)
            read -p "Enter backup file path: " backup_file
            read -p "Enter restore directory: " restore_dir
            restore_backup "$backup_file" "$restore_dir"
            ;;
        8) system_info ;;
        9) resource_usage ;;
        10) configure_firewall ;;
        11) security_scan ;;
        12)
            read -p "Enter username to add: " username
            add_user "$username"
            ;;
        13)
            read -p "Enter username to remove: " username
            remove_user "$username"
            ;;
        14)
            read -p "Enter group name to add: " group
            add_group "$group"
            ;;
        15)
            read -p "Enter group name to remove: " group
            remove_group "$group"
            ;;
        16)
            read -p "Enter action [start|stop|restart|status|enable|disable]: " action
            read -p "Enter service name: " service
            manage_service "$action" "$service"
            ;;
        17)
            read -p "Enter task (e.g., --clean-logs): " task
            read -p "Enter cron schedule (e.g., '0 2 * * *'): " schedule
            schedule_task "$task" "$schedule"
            ;;
        18) list_scheduled_tasks ;;
        19)
            read -p "Do you want to reboot now or after a delay? [now/delay]: " rb_option
            case "$rb_option" in
                now) reboot_system ;;
                delay)
                    read -p "Enter delay in minutes: " delay
                    reboot_system "$delay"
                    ;;
                *) echo "Invalid option." ;;
            esac
            ;;
        20) configure_logrotate ;;
        21) trigger_logrotate ;;
        22)
            read -p "Enter email address for notifications: " email
            NOTIFY_EMAIL="$email"
            echo "Notifications will be sent to $email."
            ;;
        23) list_kernels ;;
        24) remove_old_kernels ;;
        25) install_latest_kernel ;;
        26) set_default_kernel ;;
        27) enable_unattended_upgrades ;;
        28) configure_automatic_updates ;;
        29) check_unattended_upgrades ;;
        30) list_snap_packages ;;
        31)
            read -p "Enter snap package name to remove: " snap_pkg
            remove_snap_package "$snap_pkg"
            ;;
        32) refresh_snap_packages ;;
        33)
            read -p "Enter snap package name to install: " snap_pkg
            install_snap_package "$snap_pkg"
            ;;
        34) install_flatpak ;;
        35)
            read -p "Enter Flatpak repository URL: " flatpak_repo
            add_flatpak_repo "$flatpak_repo"
            ;;
        36) list_flatpak_packages ;;
        37)
            read -p "Enter Flatpak package name to remove: " flatpak_pkg
            remove_flatpak_package "$flatpak_pkg"
            ;;
        38) refresh_flatpak_packages ;;
        39) check_swap ;;
        40)
            read -p "Enter swap size (e.g., 2G, 512M): " swap_size
            create_swap "$swap_size"
            ;;
        41) remove_swap ;;
        42) check_time_sync ;;
        43) enable_ntp ;;
        44) disable_ntp ;;
        45)
            read -p "Enter timezone (e.g., 'Europe/London'): " timezone
            set_timezone "$timezone"
            ;;
        46)
            read -p "Enter APT repository string: " apt_repo
            read -p "Enter GPG key URL (optional): " gpg_url
            add_apt_repo "$apt_repo" "$gpg_url"
            ;;
        47)
            read -p "Enter APT repository string to remove: " apt_repo
            remove_apt_repo "$apt_repo"
            ;;
        48) list_apt_repos ;;
        49) check_uptime ;;
        50) check_load ;;
        51) check_disk_inodes ;;
        52)
            read -p "Enter service name to monitor: " service
            monitor_service "$service"
            ;;
        53) run_fsck ;;
        54) schedule_fsck ;;
        55) install_docker ;;
        56) start_docker ;;
        57) stop_docker ;;
        58) list_docker_containers ;;
        59)
            read -p "Enter Docker container ID to remove: " docker_id
            remove_docker_container "$docker_id"
            ;;
        60) check_apparmor_status ;;
        61) enable_apparmor ;;
        62) disable_apparmor ;;
        63) reload_apparmor_profiles ;;
        64)
            read -p "Enter AppArmor profile name: " profile
            read -p "Enter mode [enforce|complain]: " mode
            set_apparmor_mode "$profile" "$mode"
            ;;
        65)
            read -p "Enter locale (e.g., 'en_US.UTF-8'): " locale
            set_system_locale "$locale"
            ;;
        66) generate_locales ;;
        67)
            read -p "Enter backup file to verify: " backup_file
            verify_backup "$backup_file"
            ;;
        68) list_backups ;;
        69) ensure_essential_packages ;;
        70) list_missing_packages ;;
        71)
            read -p "Enter keyword to search in logs: " keyword
            search_logs "$keyword"
            ;;
        72)
            read -p "Enter number of recent log lines to display (default 100): " num
            recent_logs "${num:-100}"
            ;;
        73) compress_old_logs ;;
        74)
            read -p "Enter destination path for archiving logs: " dest
            archive_logs "$dest"
            ;;
        75)
            read -p "Enter archive directory: " arch_dir
            read -p "Enter retention days: " ret_days
            delete_archived_logs "$arch_dir" "$ret_days"
            ;;
        76) install_lynis ;;
        77) run_lynis_audit ;;
        78) backup_network_config ;;
        79)
            read -p "Enter backup file to restore network config: " net_backup
            restore_network_config "$net_backup"
            ;;
        80)
            read -p "Enter path to custom script: " custom_script
            execute_custom_script "$custom_script"
            ;;
        81)
            read -p "Enter custom command to execute: " custom_cmd
            execute_custom_command "$custom_cmd"
            ;;
        82)
            # Update containers (ProxmoxVE specific)
            header_info
            for container in $(pct list | awk '{if(NR>1) print $1}'); do
                update_container "$container"
            done
            header_info
            echo -e "${GN}The process is complete. The repositories have been switched to community-scripts/ProxmoxVE.${CL}\n"
            ;;
        83) echo "Exiting."; exit 0 ;;
        *) echo "Invalid option."; ;;
    esac
}

# ====== Command-Line Argument Parsing ======

while [[ $# -gt 0 ]]; do
    case "$1" in
        --clean-logs)
            clean_logs
            shift
            ;;
        --fix-apt-packages)
            fix_apt_packages
            shift
            ;;
        --fix-apt-lock)
            fix_apt_lock
            shift
            ;;
        --clean-disk)
            clean_disk
            shift
            ;;
        --update-system)
            update_system
            shift
            ;;
        --backup)
            if [[ -n "$2" && ! "$2" =~ ^-- ]]; then
                backup_system "$2"
                shift 2
            else
                echo "Please provide a directory to back up."
                log_message "Backup failed: No directory provided."
                exit 1
            fi
            ;;
        --restore)
            if [[ -n "$2" && -n "$3" && ! "$2" =~ ^-- && ! "$3" =~ ^-- ]]; then
                restore_backup "$2" "$3"
                shift 3
            else
                echo "Please provide both backup file and restore directory."
                log_message "Restore failed: Missing backup file or restore directory."
                exit 1
            fi
            ;;
        --system-info)
            system_info
            shift
            ;;
        --resource-usage)
            resource_usage
            shift
            ;;
        --configure-firewall)
            configure_firewall
            shift
            ;;
        --security-scan)
            security_scan
            shift
            ;;
        --add-user)
            if [[ -n "$2" && ! "$2" =~ ^-- ]]; then
                add_user "$2"
                shift 2
            else
                echo "Please provide a username to add."
                log_message "Add user failed: No username provided."
                exit 1
            fi
            ;;
        --remove-user)
            if [[ -n "$2" && ! "$2" =~ ^-- ]]; then
                remove_user "$2"
                shift 2
            else
                echo "Please provide a username to remove."
                log_message "Remove user failed: No username provided."
                exit 1
            fi
            ;;
        --add-group)
            if [[ -n "$2" && ! "$2" =~ ^-- ]]; then
                add_group "$2"
                shift 2
            else
                echo "Please provide a group name to add."
                log_message "Add group failed: No group name provided."
                exit 1
            fi
            ;;
        --remove-group)
            if [[ -n "$2" && ! "$2" =~ ^-- ]]; then
                remove_group "$2"
                shift 2
            else
                echo "Please provide a group name to remove."
                log_message "Remove group failed: No group name provided."
                exit 1
            fi
            ;;
        --manage-service)
            if [[ -n "$2" && -n "$3" && ! "$2" =~ ^-- && ! "$3" =~ ^-- ]]; then
                manage_service "$2" "$3"
                shift 3
            else
                echo "Please provide both action and service name."
                log_message "Manage service failed: Missing action or service name."
                exit 1
            fi
            ;;
        --schedule-task)
            if [[ -n "$2" && -n "$3" && ! "$2" =~ ^-- && ! "$3" =~ ^-- ]]; then
                schedule_task "$2" "$3"
                shift 3
            else
                echo "Please provide both task and schedule."
                echo "Example: --schedule-task '--clean-logs' '0 2 * * *'"
                log_message "Schedule task failed: Missing task or schedule."
                exit 1
            fi
            ;;
        --list-scheduled-tasks)
            list_scheduled_tasks
            shift
            ;;
        --reboot)
            if [[ -n "$2" && ! "$2" =~ ^-- ]]; then
                reboot_system "$2"
                shift 2
            else
                reboot_system
                shift
            fi
            ;;
        --logrotate-configure)
            configure_logrotate
            shift
            ;;
        --logrotate-trigger)
            trigger_logrotate
            shift
            ;;
        --send-notification)
            if [[ -n "$2" && ! "$2" =~ ^-- ]]; then
                NOTIFY_EMAIL="$2"
                shift 2
            else
                echo "Please provide an email address to send notifications."
                log_message "Send notification failed: No email provided."
                exit 1
            fi
            ;;
        --list-kernels)
            list_kernels
            shift
            ;;
        --remove-old-kernels)
            remove_old_kernels
            shift
            ;;
        --install-latest-kernel)
            install_latest_kernel
            shift
            ;;
        --set-default-kernel)
            set_default_kernel
            shift
            ;;
        --enable-unattended-upgrades)
            enable_unattended_upgrades
            shift
            ;;
        --configure-auto-updates)
            configure_automatic_updates
            shift
            ;;
        --check-unattended-status)
            check_unattended_upgrades
            shift
            ;;
        --list-snap-packages)
            list_snap_packages
            shift
            ;;
        --remove-snap-package)
            if [[ -n "$2" && ! "$2" =~ ^-- ]]; then
                remove_snap_package "$2"
                shift 2
            else
                echo "Please provide a snap package name to remove."
                log_message "Remove snap package failed: No package name provided."
                exit 1
            fi
            ;;
        --refresh-snap-packages)
            refresh_snap_packages
            shift
            ;;
        --install-snap-package)
            if [[ -n "$2" && ! "$2" =~ ^-- ]]; then
                install_snap_package "$2"
                shift 2
            else
                echo "Please provide a snap package name to install."
                log_message "Install snap package failed: No package name provided."
                exit 1
            fi
            ;;
        --install-flatpak)
            install_flatpak
            shift
            ;;
        --add-flatpak-repo)
            if [[ -n "$2" && ! "$2" =~ ^-- ]]; then
                add_flatpak_repo "$2"
                shift 2
            else
                echo "Please provide a Flatpak repository URL."
                log_message "Add Flatpak repo failed: No repository URL provided."
                exit 1
            fi
            ;;
        --list-flatpak-packages)
            list_flatpak_packages
            shift
            ;;
        --remove-flatpak-package)
            if [[ -n "$2" && ! "$2" =~ ^-- ]]; then
                remove_flatpak_package "$2"
                shift 2
            else
                echo "Please provide a Flatpak package name to remove."
                log_message "Remove Flatpak package failed: No package name provided."
                exit 1
            fi
            ;;
        --refresh-flatpak-packages)
            refresh_flatpak_packages
            shift
            ;;
        --check-swap)
            check_swap
            shift
            ;;
        --create-swap)
            if [[ -n "$2" && ! "$2" =~ ^-- ]]; then
                create_swap "$2"
                shift 2
            else
                echo "Please provide swap size (e.g., 2G, 512M)."
                log_message "Create swap failed: No swap size provided."
                exit 1
            fi
            ;;
        --remove-swap)
            remove_swap
            shift
            ;;
        --check-time-sync)
            check_time_sync
            shift
            ;;
        --enable-ntp)
            enable_ntp
            shift
            ;;
        --disable-ntp)
            disable_ntp
            shift
            ;;
        --set-timezone)
            if [[ -n "$2" && ! "$2" =~ ^-- ]]; then
                set_timezone "$2"
                shift 2
            else
                echo "Please provide a timezone (e.g., 'Europe/London')."
                log_message "Set timezone failed: No timezone provided."
                exit 1
            fi
            ;;
        --add-apt-repo)
            if [[ -n "$2" && ! "$2" =~ ^-- ]]; then
                local repo="$2"
                local key_url="$3"
                if [[ -n "$3" && ! "$3" =~ ^-- ]]; then
                    add_apt_repo "$repo" "$key_url"
                    shift 3
                else
                    add_apt_repo "$repo"
                    shift 2
                fi
            else
                echo "Please provide an APT repository string."
                log_message "Add APT repo failed: No repository string provided."
                exit 1
            fi
            ;;
        --remove-apt-repo)
            if [[ -n "$2" && ! "$2" =~ ^-- ]]; then
                remove_apt_repo "$2"
                shift 2
            else
                echo "Please provide an APT repository string to remove."
                log_message "Remove APT repo failed: No repository string provided."
                exit 1
            fi
            ;;
        --list-apt-repos)
            list_apt_repos
            shift
            ;;
        --check-uptime)
            check_uptime
            shift
            ;;
        --check-load)
            check_load
            shift
            ;;
        --check-inodes)
            check_disk_inodes
            shift
            ;;
        --monitor-service)
            if [[ -n "$2" && ! "$2" =~ ^-- ]]; then
                monitor_service "$2"
                shift 2
            else
                echo "Please provide a service name to monitor."
                log_message "Monitor service failed: No service name provided."
                exit 1
            fi
            ;;
        --run-fsck)
            run_fsck
            shift
            ;;
        --schedule-fsck)
            schedule_fsck
            shift
            ;;
        --install-docker)
            install_docker
            shift
            ;;
        --start-docker)
            start_docker
            shift
            ;;
        --stop-docker)
            stop_docker
            shift
            ;;
        --list-docker-containers)
            list_docker_containers
            shift
            ;;
        --remove-docker-container)
            if [[ -n "$2" && ! "$2" =~ ^-- ]]; then
                remove_docker_container "$2"
                shift 2
            else
                echo "Please provide a Docker container ID to remove."
                log_message "Remove Docker container failed: No container ID provided."
                exit 1
            fi
            ;;
        --check-apparmor-status)
            check_apparmor_status
            shift
            ;;
        --enable-apparmor)
            enable_apparmor
            shift
            ;;
        --disable-apparmor)
            disable_apparmor
            shift
            ;;
        --reload-apparmor-profiles)
            reload_apparmor_profiles
            shift
            ;;
        --set-apparmor-mode)
            if [[ -n "$2" && -n "$3" && ! "$2" =~ ^-- && ! "$3" =~ ^-- ]]; then
                set_apparmor_mode "$2" "$3"
                shift 3
            else
                echo "Please provide both profile name and mode ('enforce' or 'complain')."
                log_message "Set AppArmor mode failed: Missing profile name or mode."
                exit 1
            fi
            ;;
        --set-locale)
            if [[ -n "$2" && ! "$2" =~ ^-- ]]; then
                set_system_locale "$2"
                shift 2
            else
                echo "Please provide a locale (e.g., 'en_US.UTF-8')."
                log_message "Set locale failed: No locale provided."
                exit 1
            fi
            ;;
        --generate-locales)
            generate_locales
            shift
            ;;
        --verify-backup)
            if [[ -n "$2" && ! "$2" =~ ^-- ]]; then
                verify_backup "$2"
                shift 2
            else
                echo "Please provide a backup file to verify."
                log_message "Verify backup failed: No backup file provided."
                exit 1
            fi
            ;;
        --list-backups)
            list_backups
            shift
            ;;
        --ensure-essential-packages)
            ensure_essential_packages
            shift
            ;;
        --list-missing-packages)
            list_missing_packages
            shift
            ;;
        --search-logs)
            if [[ -n "$2" && ! "$2" =~ ^-- ]]; then
                search_logs "$2"
                shift 2
            else
                echo "Please provide a keyword to search in logs."
                log_message "Search logs failed: No keyword provided."
                exit 1
            fi
            ;;
        --recent-logs)
            if [[ -n "$2" && ! "$2" =~ ^-- ]]; then
                recent_logs "$2"
                shift 2
            else
                recent_logs
                shift
            fi
            ;;
        --compress-logs)
            compress_old_logs
            shift
            ;;
        --archive-logs)
            if [[ -n "$2" && ! "$2" =~ ^-- ]]; then
                archive_logs "$2"
                shift 2
            else
                echo "Please provide a destination path for archiving logs."
                log_message "Archive logs failed: No destination provided."
                exit 1
            fi
            ;;
        --delete-archived-logs)
            if [[ -n "$2" && -n "$3" && ! "$2" =~ ^-- && ! "$3" =~ ^-- ]]; then
                delete_archived_logs "$2" "$3"
                shift 3
            else
                echo "Please provide both archive directory and retention days."
                log_message "Delete archived logs failed: Missing archive directory or retention days."
                exit 1
            fi
            ;;
        --install-lynis)
            install_lynis
            shift
            ;;
        --run-lynis-audit)
            run_lynis_audit
            shift
            ;;
        --backup-network-config)
            backup_network_config
            shift
            ;;
        --restore-network-config)
            if [[ -n "$2" && ! "$2" =~ ^-- ]]; then
                restore_network_config "$2"
                shift 2
            else
                echo "Please provide a backup file to restore network config."
                log_message "Restore network config failed: No backup file provided."
                exit 1
            fi
            ;;
        --exec-script)
            if [[ -n "$2" && ! "$2" =~ ^-- ]]; then
                execute_custom_script "$2"
                shift 2
            else
                echo "Please provide the path to the script to execute."
                log_message "Execute custom script failed: No script path provided."
                exit 1
            fi
            ;;
        --exec-command)
            if [[ -n "$2" && ! "$2" =~ ^-- ]]; then
                execute_custom_command "$2"
                shift 2
            else
                echo "Please provide the command to execute."
                log_message "Execute custom command failed: No command provided."
                exit 1
            fi
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            show_help
            exit 1
            ;;
    esac
done

# If no arguments are provided, display the interactive menu.
if [[ $# -eq 0 ]]; then
    while true; do
        interactive_menu
        echo ""
        read -p "Do you want to perform another task? [y/N]: " cont
        case "$cont" in
            y|Y) continue ;;
            *) 
                header_info
                echo -e "${GN}The process is complete. All selected maintenance tasks have been executed.${CL}\n"
                notify_after_task
                exit 0 
                ;;
        esac
    done
fi

# Send notification if email is set
notify_after_task
