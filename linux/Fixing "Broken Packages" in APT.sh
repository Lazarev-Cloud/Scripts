#!/bin/bash
echo "Fixing broken APT packages..."

sudo apt --fix-broken install
sudo dpkg --configure -a
sudo apt update
sudo apt upgrade -y

echo "APT package issues fixed."
