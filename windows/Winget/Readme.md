# Winget Troubleshooting and Optimization Script

## Overview

The **Winget Troubleshooting and Optimization Script** (`WingetFix.ps1`) is a PowerShell tool designed to fix common issues with the Windows Package Manager (`winget`). It ensures `winget` is properly installed, configured, and operational. Additionally, it provides functionality to streamline upgrades of all installed packages.

---

## Features

| Feature | Description |
| --- | --- |
| **Path Validation** | Checks for the `winget` executable and ensures its directory is added to the system and session `PATH`. |
| **Registry Configuration** | Fixes registry issues related to the `winget` installation path. |
| **Package Upgrades** | Automates the upgrade process for all installed packages, handling unknown versions and accepting agreements. |
| **User-Friendly Diagnostics** | Provides clear messages about the status and results of each operation. |

---

## Script Functions

### 1. `Add-WinGetPath-Registry`
- Locates the `winget` installation directory.
- Adds the directory to the system’s registry to ensure persistent access.

### 2. `Fix-WinGetPath`
- Verifies the availability of `winget` in the system and session paths.
- Calls `Add-WinGetPath` and `Add-WinGetPath-Registry` to resolve path-related issues.
- Ensures `winget` is correctly configured for immediate use.

### 3. `Upgrade-WinGetPackages`
- Executes the `winget upgrade --all` command to update all installed packages.
- Includes advanced options to:
  - Handle unknown package versions.
  - Accept package agreements automatically.
  - Run non-interactively for batch operations.
- Confirms successful completion of upgrades.

---

## Prerequisites

1. **PowerShell 5.1 or Later**: Confirm your version by running:
   ```powershell
   $PSVersionTable.PSVersion
   ```
2. **Winget Installed**: Ensure `winget` is installed. If not, install it from [Microsoft's Winget Documentation](https://learn.microsoft.com/en-us/windows/package-manager/).

---

## How to Use

### Download and Run the Script

1. Save `WingetFix.ps1` to your computer.
2. Open PowerShell as an administrator.
3. Execute the script:
   ```powershell
   .\WingetFix.ps1
   ```

### Script Workflow

1. **Fix Path Issues**:
   The script checks and resolves path or registry problems with `winget`, ensuring it works as expected.

2. **Upgrade Packages**:
   Use the automated upgrade function to update all installed applications seamlessly.

---

## Example Workflow

### Fixing `winget` Path Issues

1. **Run the Script**:
   ```powershell
   .\WingetFix.ps1
   ```
2. The script will:
   - Check for the `winget` executable.
   - Add its directory to the system and session paths.
   - Update the registry if needed.

### Upgrading All Packages

1. **Run the Upgrade Function**:
   ```powershell
   .\WingetFix.ps1
   ```
2. The script will:
   - Identify all installed packages.
   - Upgrade them with `winget upgrade --all`.

---

## Manual Winget Commands (For Reference)

| Command | Description |
| --- | --- |
| `winget list` | List all installed packages. |
| `winget upgrade --all` | Upgrade all installed packages. |
| `winget source reset` | Reset repositories to default. |
| `winget validate <manifest>` | Validate a package manifest. |


P.S.

**Export Installed Apps**
   ```powershell
   winget export -o apps-list.json
   ```
**Import and Install Apps**
   ```powershell
   winget import -i apps-list.json
   ```
**Upgrade All Apps**
   ```powershell
   winget upgrade --all
   ```
