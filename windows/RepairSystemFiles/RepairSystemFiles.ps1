function Repair-SystemFiles {
    Write-Host "Starting System File Checker (SFC) scan..." -ForegroundColor Cyan
    sfc /scannow
    if ($LASTEXITCODE -eq 0) {
        Write-Host "SFC scan completed successfully. No issues found." -ForegroundColor Green
    } else {
        Write-Host "SFC scan found and attempted to repair issues." -ForegroundColor Yellow
    }

    Write-Host "Starting DISM scan..." -ForegroundColor Cyan
    DISM /Online /Cleanup-Image /RestoreHealth
    if ($LASTEXITCODE -eq 0) {
        Write-Host "DISM scan completed successfully. Image is healthy." -ForegroundColor Green
    } else {
        Write-Host "DISM scan encountered issues." -ForegroundColor Red
    }

    Write-Host "System file repair process completed." -ForegroundColor Cyan
}

# Execute the function
Repair-SystemFiles
