function Add-WinGetPath {
    $WinGetPath = (Get-ChildItem -Path "$env:ProgramFiles\WindowsApps\Microsoft.DesktopAppInstaller*_x64*\winget.exe").DirectoryName
    If (-Not($WinGetPath)) {
        Write-Host "Winget installation not found. Please ensure it's installed." -ForegroundColor Red
        return
    }

    # Check if the WinGet path is in the current session environment variable
    If (-Not(($Env:Path -split ';') -contains $WinGetPath)) {
        If ($env:path -match ";$") {
            $env:path +=  $WinGetPath + ";"
        } else {
            $env:path +=  ";" + $WinGetPath + ";"
        }
        Write-Host "Winget path $WinGetPath added to the current session environment variable." -ForegroundColor Green
    } else {
        Write-Host "Winget path already exists in the current session environment variable." -ForegroundColor Yellow
    }
}

function Add-WinGetPath-Registry {
    $WinGetPath = (Get-ChildItem -Path "$env:ProgramFiles\WindowsApps\Microsoft.DesktopAppInstaller*_x64*\winget.exe").DirectoryName
    If (-Not($WinGetPath)) {
        Write-Host "Winget installation not found. Please ensure it's installed." -ForegroundColor Red
        return
    }

    # Get the current PATH from the system registry
    $registryPath = 'Registry::HKEY_LOCAL_MACHINE\System\CurrentControlSet\Control\Session Manager\Environment'
    $oldPath = (Get-ItemProperty -Path $registryPath -Name 'Path').Path

    # Check if the WinGet path is already in the registry
    If (-Not(($oldPath -split ';') -contains $WinGetPath)) {
        $newPath = $oldPath + ';' + $WinGetPath
        Set-ItemProperty -Path $registryPath -Name 'Path' -Value $newPath
        [Environment]::SetEnvironmentVariable('Path', $newPath, [EnvironmentVariableTarget]::Machine)
        Write-Host "Winget path $WinGetPath added to the registry and system-wide environment variable." -ForegroundColor Green
    } else {
        Write-Host "Winget path already exists in the registry." -ForegroundColor Yellow
    }
}

# Main function to add WinGet path to both session and registry
function Fix-WinGetPath {
    Write-Host "Checking and fixing WinGet path issues..."
    Add-WinGetPath
    Add-WinGetPath-Registry
    Write-Host "Winget path check and update completed." -ForegroundColor Cyan
}

# Function to upgrade all packages using WinGet
function Upgrade-WinGetPackages {
    Write-Host "Upgrading all WinGet packages..."
    winget upgrade --all --include-unknown --accept-package-agreements --disable-interactivity
    If ($?) {
        Write-Host "All packages upgraded successfully." -ForegroundColor Green
    } else {
        Write-Host "Failed to upgrade some packages." -ForegroundColor Red
    }
}

# Run the main functions
Fix-WinGetPath
Upgrade-WinGetPackages
