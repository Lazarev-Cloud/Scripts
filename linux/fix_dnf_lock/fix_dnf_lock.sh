#!/bin/bash
echo "Fixing DNF lock issues..."

sudo rm -f /var/run/yum.pid
sudo rm -f /var/run/dnf.pid

echo "DNF lock issue resolved."
