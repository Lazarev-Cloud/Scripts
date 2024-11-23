function ReRegister-WindowsApps {
    Write-Host "Re-registering all Windows Store apps..."
    Get-AppxPackage -AllUsers | Foreach {Add-AppxPackage -DisableDevelopmentMode -Register "$($_.InstallLocation)\AppXManifest.xml"}
    Write-Host "Windows Store apps re-registered successfully." -ForegroundColor Green
}

ReRegister-WindowsApps
