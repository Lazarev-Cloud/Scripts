# Clean-Disk Script

## Overview

The `Clean-Disk` PowerShell script is designed to clean up temporary files and system junk from key locations in a Windows system. This can help free up disk space and improve overall system performance.

---

## Features

- Cleans system temporary files.
- Removes Windows Update cache files from `SoftwareDistribution\Download`.
- Clears user-specific temporary files from `AppData\Local\Temp`.
- Provides real-time progress updates with messages.

---

## Usage Instructions

### 1. Run PowerShell as Administrator
   - Press `Win + S`, type **PowerShell**, right-click on it, and select **Run as Administrator**.

### 2. Execute the Script
   - Copy and paste the script directly into your PowerShell window and press **Enter**.
   - Alternatively, save the script as a `.ps1` file (e.g., `Clean-Disk.ps1`) and run it using the following command:
     ```powershell
     .\Clean-Disk.ps1
     ```

---

## Prerequisites

- **Administrative Privileges**: Required for deleting files from system directories.
- **PowerShell Version**: Compatible with PowerShell 5.1 or later.

---

## Code Explanation

```powershell
param(
    [switch]$Confirm
)

function Clean-Disk {
    Write-Host "Cleaning up temporary files and system junk..." -ForegroundColor Cyan

    $paths = @(
        "$env:SystemRoot\Temp",
        "$env:SystemRoot\SoftwareDistribution\Download",
        "$env:USERPROFILE\AppData\Local\Temp"
    )

    foreach ($p in $paths) {
        if (Test-Path $p) {
            try {
                Remove-Item -Path "$p\*" -Force -Recurse -ErrorAction Stop
            } catch {
                Write-Host "Failed to clean $p : $_" -ForegroundColor Red
            }
        }
    }

    Write-Host "Disk cleanup completed." -ForegroundColor Green
}

if ($Confirm) {
    Clean-Disk
} else {
    Write-Host "Run with -Confirm to perform disk cleanup." -ForegroundColor Yellow
}
```

- **Key Directories Cleaned**:
  - `$env:SystemRoot\Temp`: Removes system temporary files.
  - `$env:SystemRoot\SoftwareDistribution\Download`: Clears cached files from Windows Update.
  - `$env:USERPROFILE\AppData\Local\Temp`: Deletes user-specific temporary files.

- **Messages**:
  - Displays progress updates to inform the user about ongoing tasks and completion.

---

## Important Notes

1. **Irreversible Deletion**: The script permanently deletes files in the specified directories. Ensure there are no important files in these locations before running the script.
2. **Targeted Cleanup**: The script is limited to standard temporary and cache directories, minimizing the risk of affecting critical system files.
3. **Recommended Usage**: Use this script periodically to maintain system cleanliness and performance.
Logs are stored in `$env:TEMP\Clean-Disk.log`.
