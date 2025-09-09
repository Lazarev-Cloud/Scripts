param(
    [string]$LogPath = "$env:TEMP\registry_cleanup.log",
    [string]$BackupPath = "$env:TEMP\registry_backup.reg",
    [switch]$Confirm
)

Start-Transcript -Path $LogPath -Append | Out-Null

if ($Confirm) {
    reg export HKCU "$BackupPath" /y | Out-Null
    $runPaths = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run",
                "HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce"

    foreach ($path in $runPaths) {
        Get-ItemProperty $path | ForEach-Object {
            $value = $_.PSChildName
            $cmd = $_.$value
            if ($cmd -and !(Test-Path ($cmd -split ' ')[0])) {
                Write-Host "Removing invalid entry $value from $path" -ForegroundColor Yellow
                Remove-ItemProperty -Path $path -Name $value
            }
        }
    }
    Write-Host "Registry cleanup completed. Backup stored at $BackupPath" -ForegroundColor Green
} else {
    Write-Host "Run with -Confirm to perform registry cleanup." -ForegroundColor Yellow
}

Stop-Transcript | Out-Null
