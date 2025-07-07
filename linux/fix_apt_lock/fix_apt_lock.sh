#!/bin/bash
echo "Fixing APT lock issues..."

sudo rm /var/lib/dpkg/lock-frontend
sudo rm /var/lib/dpkg/lock
sudo dpkg --configure -a
sudo apt update

echo "APT lock issue resolved."
