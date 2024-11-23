# Winget Cheat-Sheet

## Overview
Winget (Windows Package Manager) simplifies the management of software on Windows by providing commands to search, install, upgrade, remove, and configure applications.

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

## Search and Installation Examples

| Example | Description |
| --- | --- |
| `winget search vscode` | Search for Visual Studio Code in the repository |
| `winget install vscode` | Install Visual Studio Code |
| `winget install --id Microsoft.VisualStudioCode -e` | Install a specific app by its ID (exact match) |

---

## Package Management

| Command | Description |
| --- | --- |
| `winget source list` | List available repositories |
| `winget source add <name> <URL>` | Add a new repository |
| `winget source remove <name>` | Remove a repository |
| `winget settings` | Open the configuration settings file |
| `winget validate <manifest>` | Validate a package manifest |

---

## Advanced Usage

| Command | Description |
| --- | --- |
| `winget export -o <file>` | Export the list of installed applications to a file |
| `winget import -i <file>` | Install applications from an exported file |
| `winget features` | Show experimental features |
| `winget hash <file>` | Generate a SHA256 hash for a file |
| `winget install <name> --silent` | Perform a silent installation |
| `winget install <name> --scope <scope>` | Specify a scope (e.g., `user` or `machine`) for installation |
| `winget install <name> --locale <locale>` | Install a package with a specific locale |
| `winget install <name> --override "<custom-options>"` | Pass custom installer options |

---

## Windows Store Integration

| Command | Description |
| --- | --- |
| `winget search --source msstore` | Search for apps in the Microsoft Store |
| `winget install <name> --source msstore` | Install a Microsoft Store app |

---

## Example Workflow

1. **Export installed apps:**
   ```
   winget export -o apps-list.json
   ```
2. **Import and reinstall:**
   ```
   winget import -i apps-list.json
   ```
3. **Upgrade all apps:**
   ```
   winget upgrade --all
   ```

---

This cheat-sheet summarizes common Winget commands and examples for quick reference. Use `winget -?` for more details on available options and syntax.