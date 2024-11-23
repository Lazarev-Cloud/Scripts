
# Windows Firewall Reset Script

## Overview

The **Windows Firewall Reset Script** (`ResetFirewall.ps1`) is a PowerShell tool designed to restore the Windows Firewall to its default configuration. It resets all custom firewall rules and ensures the firewall is enabled for all profiles, providing a secure baseline for network protection.

---

## Features

- **Firewall Reset**: Clears all custom firewall rules and policies, restoring the default settings.
- **Enable Firewall**: Ensures the firewall is turned on for all profiles (Domain, Private, and Public).
- **Automated Execution**: Runs in a single command with clear feedback on progress and results.
- **System Security**: Provides a secure default configuration for the firewall.

---

## Prerequisites

1. **Administrator Permissions**: Run PowerShell as an administrator to execute the required commands.
2. **Windows Firewall**: Ensure the Windows Firewall service is installed and operational.

---

## How to Use

1. **Download the Script**
   Save the `ResetFirewall.ps1` file to your computer.

2. **Run the Script**
   Open PowerShell as an administrator and execute the script:
   ```powershell
   .\ResetFirewall.ps1
   ```

3. **Monitor the Output**
   - The script will display messages indicating the progress and completion of the reset and enable operations.

---

## Script Workflow

1. **Reset Firewall Rules**:
   - Executes `netsh advfirewall reset` to remove all custom firewall rules and configurations.
2. **Enable Firewall for All Profiles**:
   - Runs `netsh advfirewall set allprofiles state on` to ensure the firewall is active for Domain, Private, and Public profiles.
3. **Feedback**:
   - Displays messages confirming the reset and enabling of the firewall.

---

## Example Scenarios

- **Restoring Default Security Settings**:
  Use this script to revert any changes made to the firewall configuration, ensuring a secure baseline.
- **Troubleshooting Network Issues**:
  Resolve issues caused by misconfigured or conflicting firewall rules.
- **Preparing for New Rules**:
  Clear existing rules to set up a clean slate before applying new firewall policies.

---

## Notes

- **Impact on Custom Rules**: This script will remove all custom firewall rules. Backup important configurations if necessary.
- **Reboot Recommended**: A system restart may be required for all changes to take effect.
- **Applies to All Profiles**: The reset and enabling operations affect Domain, Private, and Public network profiles.
