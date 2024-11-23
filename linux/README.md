# Comprehensive Debian/Ubuntu Maintenance Script

## Overview

The **Comprehensive Debian/Ubuntu Maintenance Script** is a powerful, all-in-one tool designed to automate and simplify a wide range of system administration tasks on Debian and Ubuntu systems. Whether you're a seasoned system administrator or a casual user looking to maintain your system's health, this script offers a robust set of features to ensure your system remains secure, efficient, and up-to-date.

## Features

### **1. Log Management**
- **Clean Old Logs**: Remove or truncate outdated log files to free up disk space.
- **Configure Log Rotation**: Set up custom log rotation policies.
- **Trigger Log Rotation**: Manually initiate log rotation.

### **2. Package Management**
- **Fix Broken APT Packages**: Resolve broken package dependencies.
- **Clean Disk Space**: Remove unused packages and temporary files.
- **System Update & Upgrade**: Update package lists and upgrade installed packages.
- **Unattended Upgrades**: Enable and configure automatic security updates.

### **3. APT Lock Management**
- **Resolve APT Lock Issues**: Remove stale APT lock files and reconfigure packages.

### **4. Backup and Restore**
- **Create Backups**: Backup specified directories.
- **Restore Backups**: Restore from existing backups.
- **Verify Backup Integrity**: Ensure backups are valid and not corrupted.
- **List Available Backups**: View all backups stored in `/var/backups/`.

### **5. System Information and Resource Usage**
- **Display System Information**: View detailed system specs.
- **Show Resource Usage**: Monitor CPU, memory, disk usage, and disk I/O.

### **6. Firewall Configuration**
- **Configure UFW Firewall**: Enable and set up UFW with default rules.

### **7. Security Scans**
- **Run Security Scans**: Perform security audits using `rkhunter` and Lynis.

### **8. User and Group Management**
- **Add/Remove Users and Groups**: Manage system users and groups efficiently.

### **9. Service Management**
- **Manage System Services**: Start, stop, restart, enable, or disable services.

### **10. Scheduling Tasks**
- **Schedule Maintenance Tasks**: Use `cron` to automate routine tasks.
- **List Scheduled Tasks**: View all scheduled maintenance tasks.

### **11. Reboot System**
- **Reboot Options**: Reboot immediately or after a specified delay.

### **12. Kernel Management**
- **List Installed Kernels**: View all installed kernel versions.
- **Remove Old Kernels**: Clean up outdated kernels.
- **Install Latest Kernel**: Upgrade to the latest available kernel.
- **Set Default Kernel**: Configure GRUB to boot a specific kernel by default.

### **13. Snap and Flatpak Package Management**
- **Manage Snap Packages**: List, install, refresh, and remove Snap packages.
- **Manage Flatpak Packages**: Install Flatpak, add repositories, and manage packages.

### **14. Swap Space Management**
- **Check Swap Usage**: Monitor current swap usage.
- **Create/Remove Swap Files**: Manage swap space as needed.

### **15. Time Synchronization Management**
- **Check Time Sync Status**: Verify NTP synchronization.
- **Enable/Disable NTP**: Control NTP settings.
- **Set Timezone**: Configure system timezone.

### **16. APT Repository Management**
- **Add/Remove APT Repositories**: Manage additional package sources.
- **List APT Repositories**: View all configured APT sources.

### **17. System Health Monitoring**
- **Check Uptime and Load**: Monitor system uptime and load averages.
- **Check Disk Inode Usage**: Ensure sufficient inodes are available.
- **Monitor Services**: Check the status of specific services.

### **18. Filesystem Integrity Check**
- **Run Filesystem Checks**: Schedule `fsck` operations.
- **Schedule Regular Checks**: Automate filesystem integrity checks via cron.

### **19. Docker Management**
- **Install Docker**: Set up Docker on your system.
- **Manage Docker Service**: Start, stop, enable, or disable Docker.
- **List/Remove Docker Containers**: View and manage Docker containers.

### **20. AppArmor Management**
- **Check AppArmor Status**: Verify AppArmor security module status.
- **Enable/Disable AppArmor**: Control AppArmor services.
- **Reload AppArmor Profiles**: Update security profiles.
- **Set AppArmor Profile Modes**: Switch profiles between enforce and complain modes.

### **21. Localization and Timezone Settings**
- **Set System Locale**: Configure system language settings.
- **Generate Locales**: Create missing locale configurations.

### **22. Essential Package Checks**
- **Ensure Essential Packages**: Verify and install essential system packages.
- **List Missing Packages**: Identify any missing critical packages.

### **23. System Log Analysis**
- **Search Logs**: Find specific keywords in system logs.
- **Display Recent Logs**: View the latest log entries.

### **24. Advanced Log Management**
- **Compress Old Logs**: Reduce log file sizes by compressing them.
- **Archive Logs**: Move logs to external storage destinations.
- **Delete Archived Logs**: Remove old archived logs based on retention policies.

### **25. Network Configuration Backup**
- **Backup Network Settings**: Save current network configurations.
- **Restore Network Settings**: Revert to previous network configurations from backups.

### **26. Custom Script Execution**
- **Execute Custom Scripts/Commands**: Run user-defined scripts or commands for additional customization.

### **27. Container-Specific Update Function (ProxmoxVE)**
- **Update ProxmoxVE Containers**: Modify `/usr/bin/update` scripts within ProxmoxVE containers.

## Prerequisites

- **Operating System**: Debian or Ubuntu-based distributions.
- **Root Privileges**: The script must be run as root to perform system-level operations.
- **Utilities**: Ensure the following utilities are installed:
  - `mail` (for email notifications)
  - `deborphan` (for package management)
  - `iostat` (part of `sysstat` for disk I/O monitoring)

```bash
sudo apt update
sudo apt install -y mailutils deborphan sysstat
```

- **Internet Connectivity**: Required for package installations and updates.

## Installation

1. **Clone the Repository**

   ```bash
   git clone https://github.com/yourusername/maintenance-script.git
   ```

2. **Navigate to the Script Directory**

   ```bash
   cd maintenance-script
   ```

3. **Make the Script Executable**

   ```bash
   chmod +x maintenance.sh
   ```

4. **Ensure Necessary Directories and Permissions**

   - **Backup Directory**

     ```bash
     sudo mkdir -p /var/backups/
     sudo chmod 700 /var/backups/
     ```

   - **Log File Permissions**

     ```bash
     sudo touch /var/log/maintenance_script.log
     sudo chmod 600 /var/log/maintenance_script.log
     ```

5. **Configure Log Rotation (Optional but Recommended)**

   ```bash
   sudo nano /etc/logrotate.d/maintenance_script
   ```

   Paste the following configuration:

   ```plaintext
   /var/log/maintenance_script.log {
       weekly
       rotate 4
       compress
       missingok
       notifempty
       create 600 root root
   }
   ```

   Save and exit (`Ctrl + O`, `Enter`, then `Ctrl + X`).

## Usage

### **1. Interactive Mode**

Simply run the script without any arguments to access the interactive menu:

```bash
sudo ./maintenance.sh
```

Navigate through the menu by entering the corresponding number for each task.

### **2. Command-Line Options**

Execute specific tasks directly via command-line arguments. This is useful for scripting or performing multiple tasks at once.

**General Syntax:**

```bash
sudo ./maintenance.sh [options]
```

**Examples:**

- **Clean Logs and Fix APT Packages**

  ```bash
  sudo ./maintenance.sh --clean-logs --fix-apt-packages
  ```

- **Create a Backup and Send Notification**

  ```bash
  sudo ./maintenance.sh --backup /home/user/data --send-notification admin@example.com
  ```

- **Manage a Specific Service**

  ```bash
  sudo ./maintenance.sh --manage-service restart apache2
  ```

### **3. Help Menu**

Display all available options and their descriptions:

```bash
sudo ./maintenance.sh --help
```

## Configuration

### **Email Notifications**

To enable email notifications after completing tasks:

1. **Install Mail Utilities**

   ```bash
   sudo apt install -y mailutils
   ```

2. **Configure SMTP Settings**

   Ensure that your system's mail transfer agent (MTA) is configured correctly to send emails.

3. **Use the `--send-notification` Option**

   Specify the email address where notifications should be sent:

   ```bash
   sudo ./maintenance.sh --send-notification admin@example.com
   ```

### **Log Rotation**

The script automatically configures log rotation for its own log file. Ensure that log rotation is set up correctly to prevent log files from growing indefinitely.

### **Scheduling Tasks**

Use the interactive menu or `--schedule-task` option to automate routine maintenance tasks via `cron`.

**Example: Schedule Daily Log Cleaning at 2 AM**

```bash
sudo ./maintenance.sh --schedule-task "--clean-logs" "0 2 * * *"
```

## Security and Best Practices

- **Run as Root**: Ensure you run the script with root privileges to execute system-level tasks.

- **Backup Before Major Changes**: Always create backups before performing significant system modifications.

- **Secure the Script**: Limit execution permissions to authorized users to prevent unauthorized system changes.

- **Test in Controlled Environments**: Before deploying on production systems, test the script in virtual machines or staging environments.

- **Regular Updates**: Keep the script updated to incorporate new features and security patches.

- **Input Validation**: The script includes basic input validation. For enhanced security, consider adding more robust validation mechanisms.

## Extensibility and Customization

The script is designed to be modular and extensible. You can easily add new features or modify existing ones by editing the script or adding new modules.

**Example: Adding a New Feature**

1. **Define the Function**

   ```bash
   new_feature() {
       # Your code here
   }
   ```

2. **Add to Interactive Menu**

   ```bash
   interactive_menu() {
       # ... existing options ...
       echo "84) New Feature Description"
       # ... existing options ...
   }
   
   # Add the case for the new option
   case "$option" in
       # ... existing cases ...
       84) new_feature ;;
       # ... existing cases ...
   esac
   ```

3. **Add to Command-Line Parsing**

   ```bash
   case "$1" in
       # ... existing options ...
       --new-feature)
           new_feature
           shift
           ;;
       # ... existing options ...
   esac
   ```

## Contribution

Contributions are welcome! Feel free to submit issues or pull requests to enhance the script's functionality.

1. **Fork the Repository**

2. **Create a New Branch**

   ```bash
   git checkout -b feature/your-feature-name
   ```

3. **Commit Your Changes**

   ```bash
   git commit -m "Add your feature description"
   ```

4. **Push to the Branch**

   ```bash
   git push origin feature/your-feature-name
   ```

5. **Submit a Pull Request**

## License

This project is licensed under the [MIT License](https://github.com/yourusername/maintenance-script/raw/main/LICENSE).

---

**Disclaimer**: Use this script at your own risk. Always ensure you have proper backups before performing system-level operations.
