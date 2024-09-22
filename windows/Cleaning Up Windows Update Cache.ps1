function Clear-WindowsUpdateCache {
    Write-Host "Stopping Windows Update Service..."
    Stop-Service -Name wuauserv -Force
    Write-Host "Deleting Windows Update cache..."
    Remove-Item -Path "C:\Windows\SoftwareDistribution\Download\*" -Force -Recurse
    Write-Host "Starting Windows Update Service..."
    Start-Service -Name wuauserv
    Write-Host "Windows Update cache cleared successfully!" -ForegroundColor Green
}

Clear-WindowsUpdateCache