param(
    [string]$LogPath = "$env:TEMP\Clean-Disk.log",
    [switch]$Confirm
)

Start-Transcript -Path $LogPath -Append | Out-Null
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
Stop-Transcript | Out-Null
