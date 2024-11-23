# Network Reset Script: Winsock and TCP/IP Stack

## Overview

The **Network Reset Script** (`ResetNetwork.ps1`) is a PowerShell tool that resets the Winsock catalog and TCP/IP stack to their default configurations. This script is useful for resolving various networking issues, such as connectivity problems, misconfigured network settings, or issues caused by third-party software.

---

## Features

- **Winsock Reset**: Clears the Winsock catalog, removing custom configurations or corrupted entries.
- **TCP/IP Stack Reset**: Restores the TCP/IP stack to its default state, addressing common network issues.
- **Easy Execution**: Automates the process using a single command.
- **Post-Execution Guidance**: Provides instructions to reboot the system after resetting.

---

## Prerequisites

1. **Administrator Permissions**: Run PowerShell as an administrator to execute network-related commands.
2. **Windows System Tools**: Ensure `netsh` is available (built into most Windows versions).

---

## How to Use

1. **Download the Script**
   Save the `ResetNetwork.ps1` file to your computer.

2. **Run the Script**
   Open PowerShell as an administrator and execute the script:
   ```powershell
   .\ResetNetwork.ps1
   ```

3. **Reboot Your System**
   After running the script, restart your computer for the changes to take effect.

---

## Script Workflow

1. **Reset Winsock Catalog**:
   - Executes `netsh winsock reset` to clear custom Winsock configurations.
2. **Reset TCP/IP Stack**:
   - Executes `netsh int ip reset` to restore default IP stack settings.
3. **Provide Feedback**:
   - Displays messages indicating progress and completion.
   - Advises the user to reboot the system.

---

## Example Scenarios

- **Resolving Network Connectivity Issues**:
  Use this script when experiencing:
  - Inability to connect to the internet.
  - DNS resolution issues.
  - Problems caused by malware or misconfigured networking tools.
- **Restoring Default Network Settings**:
  Quickly reset configurations after uninstalling third-party network tools or VPNs.

---

## Notes

- **Caution**: This script resets all custom network settings. Backup any necessary configurations before running.
- **Post-Script Reboot**: A system reboot is mandatory to apply the changes fully.
