# Registry-Cleanup.ps1

Cleans invalid startup entries from the Windows registry.

## Usage

```powershell
./Registry-Cleanup.ps1 -Confirm
```

A backup of the HKCU hive is saved to `$env:TEMP\registry_backup.reg` before any changes are made.
Logs are written to `$env:TEMP\registry_cleanup.log`.
