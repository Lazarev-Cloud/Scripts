param(
    [string]$LogPath = "$env:TEMP\system_health.log"
)

Start-Transcript -Path $LogPath -Append | Out-Null

Write-Host "CPU Usage:" (Get-CimInstance -ClassName Win32_Processor | measure -Property LoadPercentage -Average | select -ExpandProperty Average) "%"
Write-Host "Memory Usage:" (Get-CimInstance -ClassName Win32_OperatingSystem | select -ExpandProperty FreePhysicalMemory) "KB free"
Write-Host "Disk Usage:" (Get-PSDrive -Name C | select -ExpandProperty Used) "bytes used"

Stop-Transcript | Out-Null
