function Reset-WindowsFirewall {
    Write-Host "Resetting Windows Firewall to default settings..." -ForegroundColor Cyan
    # Reset firewall rules
    netsh advfirewall reset

    # Enable firewall for all profiles
    netsh advfirewall set allprofiles state on

    Write-Host "Windows Firewall has been reset to default settings and enabled for all profiles." -ForegroundColor Green
}

# Execute the function
Reset-WindowsFirewall
