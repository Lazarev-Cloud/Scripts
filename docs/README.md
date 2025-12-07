# Using the Scripts

1. Choose your platform folder (`linux` or `windows`) or the cross-platform
   monitoring folder (`monitoring`).
2. Read the README inside the script's subfolder.
3. Follow the usage instructions. Most scripts require administrative
   privileges.

Example for Linux:
```bash
cd linux/update_upgrade
sudo ./update_upgrade.sh
```

Example for Windows (run from PowerShell as Administrator):
```powershell
cd windows\Winget
./WingetFix.ps1
```

Example for the Prometheus metrics exporter:
```bash
cd monitoring
python prometheus_unified_metrics.py --once
```

Provision a Linux host (installs dependencies, copies the exporter, and sets up
systemd). Run with root or sudo so sensor (CPU/board/SSD) and NVIDIA GPU tools
can be installed:
```bash
cd monitoring
sudo ./setup_prometheus_exporter.sh
```
