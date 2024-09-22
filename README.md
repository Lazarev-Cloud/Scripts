# Lazarev Cloud Scripts

Welcome to the **Lazarev Cloud Scripts** repository! This collection contains a variety of automation scripts designed to fix common errors in both **Windows** and **Linux** environments. These scripts aim to streamline troubleshooting processes, saving you time and effort.

## Table of Contents

- [Lazarev Cloud Scripts](#lazarev-cloud-scripts)
  - [Table of Contents](#table-of-contents)
  - [Repository Structure](#repository-structure)
  - [Windows Scripts](#windows-scripts)
    - [winget.ps1](#wingetps1)
    - [Cleaning Up Windows Update Cache.ps1](#cleaning-up-windows-update-cacheps1)
    - [Disk Cleanup with PowerShell.ps1](#disk-cleanup-with-powershellps1)
    - [Enabling/Disabling Windows Features.ps1](#enablingdisabling-windows-featuresps1)
    - [Managing and Restarting a Problematic Service.ps1](#managing-and-restarting-a-problematic-serviceps1)
    - [Re-registering Windows Store Apps.ps1](#re-registering-windows-store-appsps1)
    - [Repairing System Files Using SFC and DISM.ps1](#repairing-system-files-using-sfc-and-dismps1)
    - [Resetting Windows Firewall to Default Settings.ps1](#resetting-windows-firewall-to-default-settingsps1)
    - [Resetting Winsock and TCP/IP Stack.ps1](#resetting-winsock-and-tcpip-stackps1)
    - [Restarting Graphics Driver.ps1](#restarting-graphics-driverps1)
  - [Linux Scripts](#linux-scripts)
    - [Automated System Update and Upgrade.sh](#automated-system-update-and-upgradesh)
    - [Cleaning System Logs (Log Rotation Fix).sh](#cleaning-system-logs-log-rotation-fixsh)
    - [Fixing "Broken Packages" in APT.sh](#fixing-broken-packages-in-aptsh)
    - [Fixing "Permission Denied" Errors by Correcting Ownership.sh](#fixing-permission-denied-errors-by-correcting-ownershipsh)
    - [Fixing Package Manager Lock (APT).sh](#fixing-package-manager-lock-aptsh)
    - [Fixing Package Manager Lock (DNF).sh](#fixing-package-manager-lock-dnfsh)
    - [Network Interface Down/Up.sh](#network-interface-downupsh)
  - [Universal Scripts](#universal-scripts)
  - [Installation](#installation)
  - [Usage](#usage)
    - [Windows Scripts](#windows-scripts-1)
    - [Linux Scripts](#linux-scripts-1)
  - [Contributing](#contributing)
  - [License](#license)
  - [Support](#support)

---

## Repository Structure

```
.
├── .git
├── .gitignore
├── README.md
├── linux
│   ├── Automated System Update and Upgrade.sh
│   ├── Cleaning System Logs (Log Rotation Fix).sh
│   ├── Fixing "Broken Packages" in APT.sh
│   ├── Fixing "Permission Denied" Errors by Correcting Ownership.sh
│   ├── Fixing Package Manager Lock (APT).sh
│   ├── Fixing Package Manager Lock (DNF).sh
│   └── Network Interface Down\Up.sh
├── universal scripts
│   └── [Add universal scripts here]
└── windows
    ├── Cleaning Up Windows Update Cache.ps1
    ├── Disk Cleanup with PowerShell.ps1
    ├── Enabling\Disabling Windows Features.ps1
    ├── Managing and Restarting a Problematic Service.ps1
    ├── Re-registering Windows Store Apps.ps1
    ├── Repairing System Files Using SFC and DISM.ps1
    ├── Resetting Windows Firewall to Default Settings.ps1
    ├── Resetting Winsock and TCP\IP Stack.ps1
    ├── Restarting Graphics Driver.ps1
    └── winget.ps1
```

---

## Windows Scripts

### winget.ps1

**Description:**

This script fixes common issues related to the Windows Package Manager (**winget**) by ensuring that its path is correctly added to the system's environment variables and registry. After fixing the path issues, it automatically upgrades all installed packages using winget.

**Key Features:**

- Adds the winget path to the current session environment variable if missing.
- Updates the system-wide PATH in the registry to include the winget path.
- Runs `winget upgrade --all` to update all packages silently.

**Usage:**

Run the script with administrative privileges:

```powershell
.\winget.ps1
```

---

### Cleaning Up Windows Update Cache.ps1

**Description:**

This script clears the Windows Update cache to resolve issues related to corrupted or incomplete updates. By deleting the contents of the `SoftwareDistribution\Download` folder, it forces Windows Update to download fresh files.

**Key Features:**

- Stops the Windows Update service.
- Deletes cached update files.
- Restarts the Windows Update service.

**Usage:**

Execute the script as an administrator:

```powershell
.\Cleaning Up Windows Update Cache.ps1
```

---

### Disk Cleanup with PowerShell.ps1

**Description:**

Automates the process of cleaning up unnecessary files to free up disk space. The script removes temporary files, system junk, and other non-essential data.

**Key Features:**

- Deletes files from the Windows Temp directory.
- Cleans up user-specific temporary files.
- Removes leftover files from software distribution.

**Usage:**

Run with elevated permissions:

```powershell
.\Disk Cleanup with PowerShell.ps1
```

---

### Enabling/Disabling Windows Features.ps1

**Description:**

Allows users to enable or disable specific Windows features using PowerShell commands. Useful for troubleshooting or customizing the system's functionality.

**Key Features:**

- Enables features using `Enable-WindowsOptionalFeature`.
- Disables features using `Disable-WindowsOptionalFeature`.
- Accepts parameters for action (`Enable` or `Disable`) and feature name.

**Usage:**

Provide the action and feature name when running the script:

```powershell
.\EnablingDisabling Windows Features.ps1 -Action Enable -FeatureName "TelnetClient"
```

---

### Managing and Restarting a Problematic Service.ps1

**Description:**

Checks the status of a specified Windows service and restarts it if it's not running. This script helps in maintaining the health of critical services without manual intervention.

**Key Features:**

- Accepts the service name as a parameter.
- Checks if the service exists and its current status.
- Attempts to start the service if it's stopped.

**Usage:**

Run the script with the service name:

```powershell
.\Managing and Restarting a Problematic Service.ps1 -ServiceName "Spooler"
```

---

### Re-registering Windows Store Apps.ps1

**Description:**

Fixes issues with Windows Store apps by re-registering them. This can resolve problems where apps fail to start or update.

**Key Features:**

- Re-registers all installed Windows Store apps.
- Uses `Get-AppxPackage` and `Add-AppxPackage` cmdlets.

**Usage:**

Execute as administrator:

```powershell
.\Re-registering Windows Store Apps.ps1
```

---

### Repairing System Files Using SFC and DISM.ps1

**Description:**

Automates the process of scanning and repairing corrupted system files using the System File Checker (SFC) and Deployment Image Servicing and Management (DISM) tools.

**Key Features:**

- Runs `sfc /scannow` to check and repair system files.
- Uses `DISM /Online /Cleanup-Image /RestoreHealth` to repair the system image.
- Provides status messages indicating the progress and results.

**Usage:**

Run with administrative privileges:

```powershell
.\Repairing System Files Using SFC and DISM.ps1
```

---

### Resetting Windows Firewall to Default Settings.ps1

**Description:**

Resets the Windows Firewall to its default settings, which can resolve issues caused by misconfigured firewall rules.

**Key Features:**

- Resets firewall rules using `netsh advfirewall reset`.
- Enables the firewall for all profiles (Domain, Private, Public).

**Usage:**

Execute as administrator:

```powershell
.\Resetting Windows Firewall to Default Settings.ps1
```

---

### Resetting Winsock and TCP/IP Stack.ps1

**Description:**

Resets the network settings to fix connectivity issues such as "Limited Connectivity" or "No Internet Access."

**Key Features:**

- Uses `netsh winsock reset` to reset Winsock entries.
- Runs `netsh int ip reset` to reset TCP/IP stack.

**Usage:**

Run the script with elevated permissions:

```powershell
.\Resetting Winsock and TCPIP Stack.ps1
```

---

### Restarting Graphics Driver.ps1

**Description:**

Restarts the graphics driver to resolve display issues like freezing, flickering, or black screens without rebooting the system.

**Key Features:**

- Stops and restarts the Desktop Window Manager (`dwm.exe`).
- Minimal disruption to the user session.

**Usage:**

Execute as administrator:

```powershell
.\Restarting Graphics Driver.ps1
```

---

## Linux Scripts

### Automated System Update and Upgrade.sh

**Description:**

Automates the process of updating the package lists and upgrading all installed packages on Debian/Ubuntu systems.

**Key Features:**

- Runs `sudo apt update` to refresh package lists.
- Executes `sudo apt upgrade -y` to upgrade packages without prompts.

**Usage:**

Make the script executable and run it:

```bash
chmod +x Automated System Update and Upgrade.sh
sudo ./Automated System Update and Upgrade.sh
```

---

### Cleaning System Logs (Log Rotation Fix).sh

**Description:**

Cleans up old system logs and fixes issues with log rotation, which can consume excessive disk space.

**Key Features:**

- Truncates log files in `/var/log/`.
- Removes compressed log files (`*.gz`).

**Usage:**

Run the script with root privileges:

```bash
sudo ./Cleaning System Logs (Log Rotation Fix).sh
```

---

### Fixing "Broken Packages" in APT.sh

**Description:**

Resolves issues with broken dependencies or packages in Debian/Ubuntu systems.

**Key Features:**

- Runs `sudo apt --fix-broken install`.
- Executes `sudo dpkg --configure -a`.
- Updates and upgrades packages.

**Usage:**

Execute with administrative rights:

```bash
sudo ./Fixing "Broken Packages" in APT.sh
```

---

### Fixing "Permission Denied" Errors by Correcting Ownership.sh

**Description:**

Fixes permission issues by correcting ownership and permissions of files and directories, especially in the user's home directory.

**Key Features:**

- Changes ownership to the current user using `sudo chown`.
- Adjusts directory permissions to `755` and file permissions to `644`.

**Usage:**

Run as root or with sudo:

```bash
sudo ./Fixing "Permission Denied" Errors by Correcting Ownership.sh
```

---

### Fixing Package Manager Lock (APT).sh

**Description:**

Removes lock files that prevent the APT package manager from functioning properly.

**Key Features:**

- Deletes lock files: `/var/lib/dpkg/lock-frontend` and `/var/lib/dpkg/lock`.
- Runs `sudo dpkg --configure -a` to reconfigure packages.
- Updates package lists with `sudo apt update`.

**Usage:**

Execute with sudo:

```bash
sudo ./Fixing Package Manager Lock (APT).sh
```

---

### Fixing Package Manager Lock (DNF).sh

**Description:**

Removes lock files for the DNF package manager on Fedora/RHEL-based systems.

**Key Features:**

- Deletes DNF lock files: `/var/run/yum.pid` and `/var/run/dnf.pid`.

**Usage:**

Run with root permissions:

```bash
sudo ./Fixing Package Manager Lock (DNF).sh
```

---

### Network Interface Down/Up.sh

**Description:**

Restarts a network interface to resolve connectivity issues.

**Key Features:**

- Uses `sudo ifconfig` to bring the interface down and up.
- Replace `eth0` with your actual network interface name.

**Usage:**

Provide the network interface name when running the script:

```bash
sudo ./Network Interface Down\Up.sh eth0
```

---

## Universal Scripts

*Currently, there are no universal scripts in the repository. Future updates may include cross-platform scripts.*

---

## Installation

1. **Clone the Repository:**

   ```bash
   git clone https://github.com/Lazarev-Cloud/Scripts.git
   ```

2. **Navigate to the Repository Directory:**

   ```bash
   cd Scripts
   ```

---

## Usage

### Windows Scripts

1. **Open PowerShell as Administrator.**

2. **Navigate to the Windows Scripts Directory:**

   ```powershell
   cd .\windows\
   ```

3. **Run the Desired Script:**

   For example, to repair system files:

   ```powershell
   .\Repairing System Files Using SFC and DISM.ps1
   ```

### Linux Scripts

1. **Open Terminal.**

2. **Navigate to the Linux Scripts Directory:**

   ```bash
   cd ./linux/
   ```

3. **Make the Script Executable:**

   ```bash
   chmod +x scriptname.sh
   ```

4. **Run the Script with Appropriate Permissions:**

   ```bash
   sudo ./scriptname.sh
   ```

---

## Contributing

We welcome contributions! Please follow these steps:

1. **Fork the Repository.**

2. **Create a New Branch:**

   ```bash
   git checkout -b feature/YourFeature
   ```

3. **Make Your Changes and Commit:**

   ```bash
   git commit -am "Add new feature"
   ```

4. **Push to Your Fork:**

   ```bash
   git push origin feature/YourFeature
   ```

5. **Create a Pull Request.**

---

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

---

## Support

For issues or questions, please open an issue on the GitHub repository or contact us at [support@lazarev.cloud](mailto:support@lazarev.cloud).

---

**Visit our GitHub repository for more information and access to all scripts: [Lazarev-Cloud/Scripts](https://github.com/Lazarev-Cloud/Scripts)**

---

*Happy scripting!*