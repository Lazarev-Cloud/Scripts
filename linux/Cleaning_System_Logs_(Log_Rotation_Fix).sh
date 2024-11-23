#!/bin/bash
echo "Cleaning old logs..."

sudo find /var/log -type f -name "*.log" -exec truncate -s 0 {} \;
sudo rm -f /var/log/*.gz

echo "Old logs cleaned."
