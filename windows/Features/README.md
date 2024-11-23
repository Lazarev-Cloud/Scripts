# Windows Features Management Script

## Overview

The **Windows Features Management Script** (`WindowsFeatures.ps1`) is a PowerShell tool designed to simplify enabling or disabling specific Windows features. This script uses built-in PowerShell cmdlets to manage optional Windows components, allowing administrators to configure systems efficiently.

---

## Features

- **Enable Windows Features**: Quickly turn on optional Windows features.
- **Disable Windows Features**: Easily turn off unnecessary features to optimize system performance.
- **Error Handling**: Provides clear feedback and error messages during operations.
- **Batch Execution**: Can be integrated into larger automation workflows.

---

## Parameters

| Parameter      | Description                                         | Values                       | Mandatory |
| -------------- | --------------------------------------------------- | ---------------------------- | --------- |
| `-Action`      | Specifies the action to perform.                    | `Enable`, `Disable`          | Yes       |
| `-FeatureName` | The name of the Windows feature to manage.          | Any valid feature name.      | Yes       |

---

## Prerequisites

1. **Administrator Permissions**: Run PowerShell as an administrator.
2. **PowerShell 5.1 or Later**: Confirm your version by running:
   ```powershell
   $PSVersionTable.PSVersion
   ```
3. **Windows Optional Features**: Ensure the system supports the feature being managed.

---

## How to Use

1. **Download the Script**
   Save the `WindowsFeatures.ps1` file to your computer.

2. **Run the Script**
   Open PowerShell as an administrator and execute the script with required parameters:
   ```powershell
   .\WindowsFeatures.ps1 -Action <Enable|Disable> -FeatureName <FeatureName>
   ```

3. **Example Commands**
   - Enable the `NetFx3` feature:
     ```powershell
     .\WindowsFeatures.ps1 -Action Enable -FeatureName NetFx3
     ```
   - Disable the `Internet-Explorer-Optional-amd64` feature:
     ```powershell
     .\WindowsFeatures.ps1 -Action Disable -FeatureName Internet-Explorer-Optional-amd64
     ```

---

## Supported Features

To view all optional Windows features available on your system, run:
```powershell
Get-WindowsOptionalFeature -Online
```

---

## Script Workflow

1. **Action Validation**:
   - Ensures the provided action (`Enable` or `Disable`) is valid.
2. **Feature Management**:
   - Uses `Enable-WindowsOptionalFeature` or `Disable-WindowsOptionalFeature` cmdlets.
3. **Feedback**:
   - Displays success or error messages to guide the user.
