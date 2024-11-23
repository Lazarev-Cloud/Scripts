function Reset-NetworkSettings {
    Write-Host "Resetting Winsock and TCP/IP stack..." -ForegroundColor Cyan
    netsh winsock reset
    netsh int ip reset
    Write-Host "Network settings reset completed. Please reboot your system for changes to take effect." -ForegroundColor Green
}
Reset-NetworkSettings
