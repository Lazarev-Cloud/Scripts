function Clean-Disk {
    Write-Host "Cleaning up temporary files and system junk..." -ForegroundColor Cyan
    Remove-Item -Path "$env:SystemRoot\Temp\*" -Force -Recurse
    Remove-Item -Path "$env:SystemRoot\SoftwareDistribution\Download\*" -Force -Recurse
    Remove-Item -Path "$env:USERPROFILE\AppData\Local\Temp\*" -Force -Recurse
    Write-Host "Disk cleanup completed." -ForegroundColor Green
}

Clean-Disk
