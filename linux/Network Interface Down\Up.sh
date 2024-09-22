#!/bin/bash
echo "Restarting network interface..."

# Replace 'eth0' with the name of your network interface
sudo ifconfig eth0 down
sudo ifconfig eth0 up

echo "Network interface restarted."
