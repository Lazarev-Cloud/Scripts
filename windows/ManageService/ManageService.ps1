param (
    [Parameter(Mandatory=$true)]
    [string]$ServiceName
)

function Restart-ServiceIfNeeded {
    $service = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if ($null -eq $service) {
        Write-Host "Service '$ServiceName' not found." -ForegroundColor Red
        return
    }

    Write-Host "Checking status of service '$ServiceName'..." -ForegroundColor Cyan
    if ($service.Status -ne 'Running') {
        Write-Host "Service '$ServiceName' is not running. Attempting to start..." -ForegroundColor Yellow
        try {
            Start-Service -Name $ServiceName -ErrorAction Stop
            Write-Host "Service '$ServiceName' started successfully." -ForegroundColor Green
        } catch {
            Write-Host "Failed to start service '$ServiceName'. Error: $_" -ForegroundColor Red
        }
    } else {
        Write-Host "Service '$ServiceName' is already running." -ForegroundColor Green
    }
}

# Execute the function with the provided service name
Restart-ServiceIfNeeded -ServiceName $ServiceName
