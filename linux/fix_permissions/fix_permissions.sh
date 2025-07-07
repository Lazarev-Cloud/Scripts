#!/bin/bash
echo "Fixing ownership and permission issues in home directory..."

# Change ownership of all files in the user's home directory to the current user
sudo chown -R $USER:$USER /home/$USER

# Fix common permission issues
sudo find /home/$USER -type d -exec chmod 755 {} \;
sudo find /home/$USER -type f -exec chmod 644 {} \;

echo "Permissions and ownership fixed."
