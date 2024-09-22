# Lazarev Cloud Scripts

Welcome to the **Lazarev Cloud Scripts** repository! This collection of automation scripts is designed to help system administrators and IT professionals efficiently troubleshoot and resolve common errors in both **Windows** and **Linux** environments. By automating routine maintenance tasks, these scripts save time and reduce the potential for human error.

## Table of Contents

- [Lazarev Cloud Scripts](#lazarev-cloud-scripts)
  - [Table of Contents](#table-of-contents)
  - [Features](#features)
  - [Repository Structure](#repository-structure)
  - [Windows Scripts](#windows-scripts)
    - [Repairing System Files Using SFC and DISM](#repairing-system-files-using-sfc-and-dism)
    - [Resetting Windows Firewall to Default Settings](#resetting-windows-firewall-to-default-settings)
    - [Managing and Restarting a Problematic Service](#managing-and-restarting-a-problematic-service)
    - [Enabling/Disabling Windows Features](#enablingdisabling-windows-features)
    - [Cleaning Up Windows Update Cache](#cleaning-up-windows-update-cache)
    - [Disk Cleanup with PowerShell](#disk-cleanup-with-powershell)
    - [Re-registering Windows Store Apps](#re-registering-windows-store-apps)
    - [Resetting Winsock and TCP/IP Stack](#resetting-winsock-and-tcpip-stack)
    - [Restarting Graphics Driver](#restarting-graphics-driver)
    - [Winget Troubleshooter](#winget-troubleshooter)
  - [Linux Scripts](#linux-scripts)
    - [Automated System Update and Upgrade](#automated-system-update-and-upgrade)
    - [Fixing Package Manager Lock (APT)](#fixing-package-manager-lock-apt)
    - [Fixing Package Manager Lock (DNF)](#fixing-package-manager-lock-dnf)
    - [Fixing "Broken Packages" in APT](#fixing-broken-packages-in-apt)
    - [Fixing "Permission Denied" Errors by Correcting Ownership](#fixing-permission-denied-errors-by-correcting-ownership)
    - [Cleaning System Logs (Log Rotation Fix)](#cleaning-system-logs-log-rotation-fix)
    - [Network Interface Down/Up](#network-interface-downup)
  - [Universal Scripts](#universal-scripts)
  - [Installation](#installation)
  - [Usage](#usage)
    - [Windows Scripts](#windows-scripts-1)
    - [Linux Scripts](#linux-scripts-1)
  - [Contributing](#contributing)
  - [License](#license)
  - [Contact](#contact)

## Features

- **Automated Troubleshooting**: Quickly resolve common system errors without manual intervention.
- **Cross-Platform Support**: Scripts available for both Windows and Linux environments.
- **Modular Design**: Each script addresses a specific issue, making it easy to use and maintain.
- **User-Friendly**: Clear descriptions and usage instructions for each script.
- **Open Source**: Free to use, modify, and distribute.

## Repository Structure

```
.
├── linux
│   ├── Automated System Update and Upgrade.sh
│   ├── Cleaning System Logs (Log Rotation Fix).sh
│   ├── Fixing "Broken Packages" in APT.sh
│   ├── Fixing "Permission Denied" Errors by Correcting Ownership.sh
│   ├── Fixing Package Manager Lock (APT).sh
│   ├── Fixing Package Manager Lock (DNF).sh
│   └── Network Interface Down Up.sh
├── universal scripts
│   └── (Add universal scripts will be here)
└── windows
    ├── Cleaning Up Windows Update Cache.ps1
    ├── Disk Cleanup with PowerShell.ps1
    ├── Enabling Disabling Windows Features.ps1
    ├── Managing and Restarting a Problematic Service.ps1
    ├── Re-registering Windows Store Apps.ps1
    ├── Repairing System Files Using SFC and DISM.ps1
    ├── Resetting Windows Firewall to Default Settings.ps1
    ├── Resetting Winsock and TCP/IP Stack.ps1
    ├── Restarting Graphics Driver.ps1
    └── winget.ps1
```

---

*Happy Troubleshooting!*

---

## Windows Scripts

### Repairing System Files Using SFC and DISM

**Script:** `windows/Repairing System Files Using SFC and DISM.ps1`

**Description:**  
Automates the process of scanning and repairing corrupted system files using the System File Checker (SFC) and Deployment Image Servicing and Management (DISM) tools. Essential for maintaining system stability and performance.

**Usage:**  
Run the script with administrative privileges to initiate the repair process.

```powershell
.\Repairing\ System\ Files\ Using\ SFC\ and\ DISM.ps1
```

---

### Resetting Windows Firewall to Default Settings

**Script:** `windows/Resetting Windows Firewall to Default Settings.ps1`

**Description:**  
Resets Windows Firewall to its default settings, ensuring that all firewall rules are restored and the firewall is enabled for all network profiles. Useful for resolving firewall-related connectivity issues.

**Usage:**  
Execute the script as an administrator.

```powershell
.\Resetting\ Windows\ Firewall\ to\ Default\ Settings.ps1
```

---

### Managing and Restarting a Problematic Service

**Script:** `windows/Managing and Restarting a Problematic Service.ps1`

**Description:**  
Checks the status of a specified Windows service and restarts it if it's not running. Helps in maintaining essential services without manual intervention.

**Usage:**  
Provide the service name as a parameter when running the script.

```powershell
.\Managing\ and\ Restarting\ a\ Problematic\ Service.ps1 -ServiceName "Spooler"
```

---

### Enabling/Disabling Windows Features

**Script:** `windows/Enabling Disabling Windows Features.ps1`

**Description:**  
Enables or disables specific Windows features based on user input. Facilitates the management of optional Windows components for troubleshooting or customization.

**Usage:**  
Specify the action (`Enable` or `Disable`) and the feature name when executing the script.

```powershell
.\Enabling\ Disabling\ Windows\ Features.ps1 -Action "Enable" -FeatureName "TelnetClient"
```

---

### Cleaning Up Windows Update Cache

**Script:** `windows/Cleaning Up Windows Update Cache.ps1`

**Description:**  
Clears the Windows Update cache to resolve update-related issues caused by corrupted or incomplete downloads.

**Usage:**  
Run the script with administrative rights.

```powershell
.\Cleaning\ Up\ Windows\ Update\ Cache.ps1
```

---

### Disk Cleanup with PowerShell

**Script:** `windows/Disk Cleanup with PowerShell.ps1`

**Description:**  
Deletes unnecessary temporary files and system junk to free up disk space and improve system performance.

**Usage:**  
Execute the script as an administrator.

```powershell
.\Disk\ Cleanup\ with\ PowerShell.ps1
```

---

### Re-registering Windows Store Apps

**Script:** `windows/Re-registering Windows Store Apps.ps1`

**Description:**  
Re-registers all Windows Store apps to fix issues related to app functionality and installation problems.

**Usage:**  
Run the script with elevated privileges.

```powershell
.\Re-registering\ Windows\ Store\ Apps.ps1
```

---

### Resetting Winsock and TCP/IP Stack

**Script:** `windows/Resetting Winsock and TCP/IP Stack.ps1`

**Description:**  
Resets the Winsock catalog and TCP/IP stack to resolve network connectivity issues such as "Limited Connectivity" or frequent disconnections.

**Usage:**  
Execute the script as an administrator.

```powershell
.\Resetting\ Winsock\ and\ TCP\IP\ Stack.ps1
```

---

### Restarting Graphics Driver

**Script:** `windows/Restarting Graphics Driver.ps1`

**Description:**  
Restarts the Windows graphics driver to fix graphical issues like screen freezing, flickering, or resolution problems without needing a full system reboot.

**Usage:**  
Run the script with administrative privileges.

```powershell
.\Restarting\ Graphics\ Driver.ps1
```

---

### Winget Troubleshooter

**Script:** `windows/winget.ps1`

**Description:**  
Fixes common issues related to the Windows Package Manager (WinGet) by ensuring its path is correctly set in both the current session and system-wide environment variables. Additionally, it upgrades all installed packages automatically.

**Usage:**  
Execute the script with administrative rights to fix WinGet path issues and upgrade packages.

```powershell
.\winget.ps1
```

---

## Linux Scripts

### Automated System Update and Upgrade

**Script:** `linux/Automated System Update and Upgrade.sh`

**Description:**  
Automates the process of updating package lists and upgrading installed packages to ensure the system is up-to-date with the latest security patches and features.

**Usage:**  
Make the script executable and run it.

```bash
chmod +x Automated\ System\ Update\ and\ Upgrade.sh
./Automated\ System\ Update\ and\ Upgrade.sh
```

---

### Fixing Package Manager Lock (APT)

**Script:** `linux/Fixing Package Manager Lock (APT).sh`

**Description:**  
Resolves issues where the APT package manager is locked by removing lock files and reconfiguring packages, allowing for smooth package installations and updates.

**Usage:**  
Run the script with root privileges.

```bash
sudo ./Fixing\ Package\ Manager\ Lock\ \(APT\).sh
```

---

### Fixing Package Manager Lock (DNF)

**Script:** `linux/Fixing Package Manager Lock (DNF).sh`

**Description:**  
Addresses lock issues with the DNF package manager by removing lock files, enabling uninterrupted package management operations.

**Usage:**  
Execute the script as a superuser.

```bash
sudo ./Fixing\ Package\ Manager\ Lock\ \(DNF\).sh
```

---

### Fixing "Broken Packages" in APT

**Script:** `linux/Fixing "Broken Packages" in APT.sh`

**Description:**  
Automates the process of fixing broken dependencies and package issues in Debian/Ubuntu-based systems using APT commands.

**Usage:**  
Run the script with administrative privileges.

```bash
sudo ./Fixing\ \"Broken\ Packages\"\ in\ APT.sh
```

---

### Fixing "Permission Denied" Errors by Correcting Ownership

**Script:** `linux/Fixing "Permission Denied" Errors by Correcting Ownership.sh`

**Description:**  
Corrects file and directory ownership and permissions to resolve "Permission Denied" errors, ensuring users have the appropriate access rights.

**Usage:**  
Execute the script with superuser permissions.

```bash
sudo ./Fixing\ \"Permission\ Denied\"\ Errors\ by\ Correcting\ Ownership.sh
```

---

### Cleaning System Logs (Log Rotation Fix)

**Script:** `linux/Cleaning System Logs (Log Rotation Fix).sh`

**Description:**  
Cleans up old system logs and ensures proper log rotation, freeing up disk space and maintaining system performance.

**Usage:**  
Run the script with root access.

```bash
sudo ./Cleaning\ System\ Logs\ \(Log\ Rotation\ Fix\).sh
```

---

### Network Interface Down/Up

**Script:** `linux/Network Interface Down Up.sh`

**Description:**  
Restarts a specified network interface to resolve connectivity issues without requiring a full system reboot.

**Usage:**  
Provide the network interface name as a parameter when running the script.

```bash
sudo ./Network\ Interface\ Down\ Up.sh eth0
```

---

## Universal Scripts

*Currently, there are no universal scripts. Future updates may include scripts that work across both Windows and Linux platforms.*

## Installation

1. **Clone the Repository**

   ```bash
   git clone https://github.com/Lazarev-Cloud/Scripts.git
   ```

2. **Navigate to the Repository Directory**

   ```bash
   cd Scripts
   ```

3. **Review Scripts**

   Explore the `windows` and `linux` directories to find scripts relevant to your operating system.

## Usage

### Windows Scripts

1. **Open PowerShell as Administrator**

2. **Navigate to the Windows Scripts Directory**

   ```powershell
   cd .\windows\
   ```

3. **Execute the Desired Script**

   For example, to reset the Windows Firewall:

   ```powershell
   .\Resetting\ Windows\ Firewall\ to\ Default\ Settings.ps1
   ```

### Linux Scripts

1. **Open Terminal**

2. **Navigate to the Linux Scripts Directory**

   ```bash
   cd ./linux/
   ```

3. **Make the Script Executable (if not already)**

   ```bash
   chmod +x Fixing\ Package\ Manager\ Lock\ \(APT\).sh
   ```

4. **Run the Script with Appropriate Permissions**

   For example, to fix APT lock issues:

   ```bash
   sudo ./Fixing\ Package\ Manager\ Lock\ \(APT\).sh
   ```

## Contributing

We welcome contributions from the community! To contribute:

1. **Fork the Repository**

2. **Create a Feature Branch**

   ```bash
   git checkout -b feature/YourFeature
   ```

3. **Commit Your Changes**

   ```bash
   git commit -m "Add Your Feature"
   ```

4. **Push to the Branch**

   ```bash
   git push origin feature/YourFeature
   ```

5. **Open a Pull Request**

   Describe your changes and submit the pull request for review.

## License

This project is licensed under the [MIT License](LICENSE).


## Contact

For questions, suggestions, or support, please reach out to us:

- **Email:** support@lazarev.cloud
- **GitHub Issues:** [Open an Issue](https://github.com/Lazarev-Cloud/Scripts/issues)

---

*© 2024 Lazarev Cloud. All rights reserved.*