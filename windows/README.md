# Windows Maintenance Scripts Collection

## Overview

This repository contains a collection of PowerShell scripts designed to simplify and automate common Windows maintenance and troubleshooting tasks. Each script is located in its respective subfolder with a detailed README file explaining its purpose, features, and usage instructions.

---

## Contents

### 1. **Clear-WindowsUpdateCache**
- **Description**: Clears the Windows Update cache to resolve update-related errors and free up disk space.
- **Key Features**:
  - Stops the Windows Update service.
  - Deletes cached update files.
  - Restarts the Windows Update service.

### 2. **Clean-Disk**
- **Description**: Cleans up temporary files and system junk to free up disk space and improve system performance.
- **Key Features**:
  - Removes temporary files from system and user directories.
  - Clears the Windows Update cache.

### 3. **Winget Troubleshooting**
- **Description**: Fixes common issues with the Windows Package Manager (`winget`) and automates package upgrades.
- **Key Features**:
  - Validates and fixes `winget` paths and registry configurations.
  - Automates package upgrades for all installed applications.

### 4. **Windows Features Management**
- **Description**: Enables or disables optional Windows features.
- **Key Features**:
  - Uses PowerShell cmdlets to manage features.
  - Provides feedback and error handling for all operations.

### 5. **Graphics Driver Restart**
- **Description**: Restarts the Windows graphics driver by restarting the `dwm` (Desktop Window Manager) process.
- **Key Features**:
  - Resolves minor graphical issues without a full reboot.
  - Simple and quick to execute.

### 6. **Network Reset**
- **Description**: Resets the Winsock catalog and TCP/IP stack to their default settings to resolve network connectivity issues.
- **Key Features**:
  - Clears custom configurations in Winsock.
  - Restores the TCP/IP stack.

### 7. **Service Management**
- **Description**: Manages and restarts a specified Windows service.
- **Key Features**:
  - Checks service status.
  - Automatically restarts the service if needed.

### 8. **System File Repair**
- **Description**: Uses SFC (System File Checker) and DISM (Deployment Image Servicing and Management) tools to repair corrupted or missing system files.
- **Key Features**:
  - Automates both SFC and DISM scans.
  - Detects and attempts to repair issues with system integrity.

### 9. **Windows Store Apps Re-Registration**
- **Description**: Re-registers all Windows Store apps to resolve issues with app functionality or missing apps.
- **Key Features**:
  - Targets all users on the system.
  - Resolves corrupted app registrations.

### 10. **Windows Firewall Reset**
- **Description**: Resets the Windows Firewall to its default settings and enables it for all profiles.
- **Key Features**:
  - Clears custom firewall rules.
  - Ensures firewall protection is active for Domain, Private, and Public profiles.

---

## How to Use

1. Navigate to the subfolder containing the desired script.
2. Read the included `README.md` file for detailed instructions on how to execute the script.
3. Open PowerShell as an administrator and follow the steps outlined in the documentation.

---

## Notes

- **Administrative Privileges**: Most scripts require administrator permissions. Run PowerShell as an administrator to ensure proper execution.
- **Compatibility**: Scripts are designed for PowerShell 5.1 or later.
- **Caution**: Review each script's README for details on the changes it makes. Backup important data or configurations when necessary.

This collection is intended to simplify Windows maintenance tasks and provide tools for resolving common system issues.
