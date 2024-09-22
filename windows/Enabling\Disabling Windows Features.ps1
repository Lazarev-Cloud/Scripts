param (
    [Parameter(Mandatory=$true)]
    [ValidateSet("Enable", "Disable")]
    [string]$Action,

    [Parameter(Mandatory=$true)]
    [string]$FeatureName
)

function Manage-WindowsFeature {
    param (
        [string]$Action,
        [string]$Feature
    )

    Write-Host "$Action-ing Windows feature '$Feature'..." -ForegroundColor Cyan
    try {
        if ($Action -eq "Enable") {
            Enable-WindowsOptionalFeature -Online -FeatureName $Feature -All -NoRestart
        } elseif ($Action -eq "Disable") {
            Disable-WindowsOptionalFeature -Online -FeatureName $Feature -Remove -NoRestart
        }
        Write-Host "Feature '$Feature' has been $($Action.ToLower())d successfully." -ForegroundColor Green
    } catch {
        Write-Host "Failed to $($Action.ToLower()) feature '$Feature'. Error: $_" -ForegroundColor Red
    }
}

# Execute the function with provided parameters
Manage-WindowsFeature -Action $Action -Feature $FeatureName
