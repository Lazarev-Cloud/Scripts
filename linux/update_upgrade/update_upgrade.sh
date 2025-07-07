#!/usr/bin/env bash

# Automated System Update and Upgrade
# Updates package lists and upgrades all installed packages on Debian/Ubuntu.

set -e

sudo apt update && sudo apt upgrade -y
