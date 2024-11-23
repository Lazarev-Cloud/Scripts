# Graphics Driver Restart Script

## Overview

The **Graphics Driver Restart Script** (`RestartGraphicsDriver.ps1`) is a simple PowerShell tool designed to restart the Windows graphics driver by restarting the `dwm` (Desktop Window Manager) process. This can help resolve certain graphical glitches or issues without requiring a full system reboot.

---

## Features

- **Quick Graphics Driver Restart**: Terminates and restarts the `dwm` process to refresh the graphics driver.
- **Error Resolution**: Addresses minor graphical issues, such as display glitches or freezes, with minimal disruption.
- **Safe Execution**: Relies on native PowerShell functionality and built-in processes.

---

## Prerequisites

1. **Administrator Permissions**: Run PowerShell as an administrator to allow process termination.
2. **PowerShell 5.1 or Later**: Confirm your version by running:
   ```powershell
   $PSVersionTable.PSVersion
   ```

---

## How to Use

1. **Download the Script**
   Save the `RestartGraphicsDriver.ps1` file to your computer.

2. **Run the Script**
   Open PowerShell as an administrator and execute the script:
   ```powershell
   .\RestartGraphicsDriver.ps1
   ```

3. **Output**
   - The script will display:
     - A message indicating the graphics driver is restarting.
     - A success message after the `dwm` process is terminated and restarted.

---

## Script Workflow

1. **Terminate `dwm` Process**:
   - The script uses the `Stop-Process` cmdlet to forcefully stop the `dwm` process.
2. **Driver Refresh**:
   - Upon termination, Windows automatically restarts the `dwm` process, refreshing the graphics driver.
3. **Feedback**:
   - Displays messages indicating the start and completion of the operation.

---

## Example Scenarios

- **Fixing Graphical Glitches**: Use this script to resolve minor display issues, such as frozen windows or unresponsive desktop environments.
- **Development Testing**: Restart the graphics driver during development or testing workflows for display-related applications.

---

## Notes

- **Caution**: Restarting the `dwm` process may temporarily disrupt the display. Ensure no critical tasks are active.
- **Recovery**: If the display does not restore properly, log out or restart the computer to recover.
