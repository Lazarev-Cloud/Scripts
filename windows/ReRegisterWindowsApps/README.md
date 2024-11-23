
# Windows Store Apps Re-Registration Script

## Overview

The **Windows Store Apps Re-Registration Script** (`ReRegisterWindowsApps.ps1`) is a PowerShell tool designed to re-register all Windows Store apps. This process can resolve issues such as:
- Apps failing to launch.
- Corrupted or missing app registrations.
- Problems with the Microsoft Store or built-in Windows applications.

---

## Features

- **Re-register All Apps**: Reinstalls the app manifest for all installed Windows Store apps.
- **System-Wide Fix**: Targets apps for all users on the system.
- **Automated Process**: Runs in a single command with minimal user intervention.
- **Error Resolution**: Addresses issues caused by corrupted app registrations or missing components.

---

## Prerequisites

1. **Administrator Permissions**: Run PowerShell as an administrator to execute the required commands.
2. **Windows Store Apps**: Ensure the Windows Store and related apps are installed on your system.

---

## How to Use

1. **Download the Script**
   Save the `ReRegisterWindowsApps.ps1` file to your computer.

2. **Run the Script**
   Open PowerShell as an administrator and execute the script:
   ```powershell
   .\ReRegisterWindowsApps.ps1
   ```

3. **Monitor the Output**
   - The script will display messages indicating the progress and completion of the re-registration process.

---

## Script Workflow

1. **Enumerate Installed Apps**:
   - Uses `Get-AppxPackage -AllUsers` to list all installed Windows Store apps.
2. **Re-register App Manifests**:
   - Executes `Add-AppxPackage -DisableDevelopmentMode -Register` for each app, re-registering its manifest file.
3. **Completion Message**:
   - Displays a confirmation message upon successful re-registration.

---

## Example Scenarios

- **Fixing Launch Issues**:
  Use this script if Windows Store apps or built-in applications (e.g., Calculator, Photos) fail to open or crash on launch.
- **Resolving Microsoft Store Problems**:
  Address issues where the Microsoft Store itself fails to open or display available apps.
- **Restoring Missing Apps**:
  Re-register apps that are present on the system but do not appear in the Start Menu.

---

## Notes

- **Execution Time**: The script may take several minutes to complete, depending on the number of apps installed.
- **Reboot Recommended**: Restart the system after running the script to ensure all changes take effect.
- **Backup Recommended**: If custom app configurations are critical, consider backing up user data before running the script.
