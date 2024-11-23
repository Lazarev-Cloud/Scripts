# System File Repair Script: Using SFC and DISM

## Overview

The **System File Repair Script** (`RepairSystemFiles.ps1`) automates the process of checking and repairing corrupted or missing system files on a Windows system. It leverages two powerful tools:
- **SFC (System File Checker)**: Scans for and repairs corrupted system files.
- **DISM (Deployment Image Servicing and Management)**: Repairs the Windows image used for updates and system operations.

---

## Features

- **Automated SFC and DISM Execution**: Runs both tools sequentially for comprehensive system repair.
- **Error Detection**: Identifies and reports any issues found during the scans.
- **Repair Attempts**: Automatically attempts to repair corrupted files or restore missing components.
- **Progress Feedback**: Displays detailed status messages during each stage of the process.

---

## Prerequisites

1. **Administrator Permissions**: Run PowerShell as an administrator to execute system-level commands.
2. **Windows Built-in Tools**: Ensure both `sfc` and `DISM` are available on your system (included in most Windows versions).

---

## How to Use

1. **Download the Script**
   Save the `RepairSystemFiles.ps1` file to your computer.

2. **Run the Script**
   Open PowerShell as an administrator and execute the script:
   ```powershell
   .\RepairSystemFiles.ps1
   ```

3. **Follow On-Screen Instructions**
   - The script will run the SFC and DISM scans automatically.
   - Monitor the output for details on issues found and repairs attempted.

---

## Script Workflow

1. **SFC Scan**:
   - Runs `sfc /scannow` to detect and repair corrupted system files.
   - Reports the results:
     - **Success**: No issues found.
     - **Partial Repair**: Issues found and attempted to repair.

2. **DISM Scan**:
   - Executes `DISM /Online /Cleanup-Image /RestoreHealth` to repair the Windows image.
   - Reports the results of the operation:
     - **Success**: The image was successfully repaired.
     - **Failure**: Informs the user of any unresolved issues.

3. **Completion Message**:
   - Advises the user on any further actions, such as restarting the system.

---

## Example Scenarios

- **Fixing System Corruption**:
  Use this script if you experience:
  - Slow performance or frequent crashes.
  - Errors related to missing or corrupted system files.
- **Preparing for Updates**:
  Run the script before major Windows updates to ensure system integrity.
- **Resolving Installation Issues**:
  Use it to fix problems with installing software or updates caused by corrupted system components.

---

## Notes

- **Time Required**: The script may take several minutes to complete, depending on the system state.
- **Reboot Recommended**: Restart the system after running the script to apply repairs fully.
- **Backup Recommended**: Back up important data before using repair tools.
