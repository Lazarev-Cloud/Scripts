# Winget Manager Script

## Overview

The **Winget Manager Script** simplifies software management on Windows by leveraging the capabilities of the Windows Package Manager (`winget`). This script automates tasks such as searching, installing, upgrading, and removing applications, making it an essential tool for efficient system management.

---

## Basic Commands

| Command | Description |
| --- | --- |
| `winget -?` | Show the Winget help menu |
| `winget list` | List all installed applications |
| `winget search <name>` | Search for a package in the repository |
| `winget install <name>` | Install a package |
| `winget upgrade <name>` | Upgrade a specific package |
| `winget upgrade --all` | Upgrade all installed packages |
| `winget uninstall <name>` | Uninstall a package |
| `winget show <name>` | Show details of a package |

---

## Workflow Examples

### Batch Installation

1. **Export Installed Apps**
   ```powershell
   winget export -o apps-list.json
   ```

2. **Import and Install Apps**
   ```powershell
   winget import -i apps-list.json
   ```

3. **Upgrade All Apps**
   ```powershell
   winget upgrade --all
   ```

---

## Advanced Usage

| Command | Description |
| --- | --- |
| `winget source list` | List available repositories |
| `winget source add <name> <URL>` | Add a new repository |
| `winget source remove <name>` | Remove a repository |
| `winget settings` | Open the configuration settings file |
| `winget validate <manifest>` | Validate a package manifest |
| `winget export -o <file>` | Export the list of installed applications to a file |
| `winget import -i <file>` | Install applications from an exported file |
| `winget hash <file>` | Generate a SHA256 hash for a file |
| `winget install <name> --silent` | Perform a silent installation |
| `winget install <name> --scope <scope>` | Specify a scope (e.g., `user` or `machine`) for installation |
| `winget install <name> --locale <locale>` | Install a package with a specific locale |
| `winget install <name> --override "<custom-options>"` | Pass custom installer options |

---

## Microsoft Store Integration

| Command | Description |
| --- | --- |
| `winget search --source msstore` | Search for apps in the Microsoft Store |
| `winget install <name> --source msstore` | Install a Microsoft Store app |

---

## Script Usage

To run the script:

1. **Download the Script**
   Save `WingetManager.ps1` to your local system.

2. **Execute the Script**
   Open PowerShell and run:
   ```powershell
   .\WingetManager.ps1
   ```

3. **Modify Parameters**
   Adjust script settings to specify custom applications, use silent installs, or apply additional options.
