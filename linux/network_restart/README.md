# Restart Network Interface

Brings a specified network interface down and back up.

## Usage

```bash
sudo ./network_restart.sh <interface>
```

Replace `<interface>` with the actual network interface name (e.g., `eth0`, `enp0s3`). The script validates that the interface exists before attempting the restart.

Logs are written to `/var/log/network_restart.log`.
