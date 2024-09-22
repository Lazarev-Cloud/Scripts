function Restart-GraphicsDriver {
    Write-Host "Restarting graphics driver..."
    Stop-Process -Name dwm -Force
    Write-Host "Graphics driver restarted." -ForegroundColor Green
}

Restart-GraphicsDriver
