# Service Management Script: Managing and Restarting a Problematic Service

## Overview

The **Service Management Script** (`ManageService.ps1`) is a PowerShell tool designed to check the status of a specified Windows service and restart it if it is not running. This script is helpful for resolving issues with critical services that may occasionally stop or fail.

---

## Features

- **Service Status Check**: Verifies whether the specified service is running.
- **Automatic Restart**: Attempts to restart the service if it is not running.
- **Error Handling**: Provides clear feedback if the service is not found or cannot be restarted.
- **Customizable Input**: Allows specifying the service name as a parameter for flexibility.

---

## Parameters

| Parameter      | Description                          | Mandatory |
| -------------- | ------------------------------------ | --------- |
| `-ServiceName` | The name of the Windows service to manage. | Yes       |

---

## Prerequisites

1. **Administrator Permissions**: Run PowerShell as an administrator to manage services.
2. **Valid Service Name**: Ensure the service name provided matches an existing Windows service.

---

## How to Use

1. **Download the Script**
   Save the `ManageService.ps1` file to your computer.

2. **Run the Script**
   Open PowerShell as an administrator and execute the script with the service name:
   ```powershell
   .\ManageService.ps1 -ServiceName "<ServiceName>"
   ```

3. **Example Commands**
   - Check and restart the `wuauserv` service (Windows Update Service):
     ```powershell
     .\ManageService.ps1 -ServiceName "wuauserv"
     ```

---

## Script Workflow

1. **Service Validation**:
   - Checks if the specified service exists.
   - Displays an error if the service is not found.
2. **Status Check**:
   - Verifies whether the service is running.
3. **Restart Service**:
   - Attempts to restart the service if it is stopped or not running.
4. **Feedback**:
   - Displays messages indicating the status and outcome of the operation.

---

## Example Scenarios

- **Resolving Service Issues**:
  Use this script to restart services that may stop unexpectedly, such as:
  - `Spooler` (Print Spooler)
  - `wuauserv` (Windows Update Service)
  - `MpsSvc` (Windows Firewall Service)
- **Monitoring Critical Services**:
  Automate the script to periodically check and restart essential services.

---

## Notes

- **Service Dependencies**: Restarting a service may also restart its dependent services.
- **Error Handling**: If the service cannot be restarted, review the PowerShell output for details.
