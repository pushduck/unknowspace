#!/bin/bash

# ==============================================================================
# Script to update the hostname on Debian/Ubuntu systems.
# Now with interactive prompt if no hostname is provided.
#
# Author: Gemini
# Usage:
#   sudo ./update_hostname.sh <new-hostname>  (Directly)
#   sudo ./update_hostname.sh               (Interactive mode)
# ==============================================================================

# --- Color Definitions ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# --- Logging Functions ---
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
    exit 1
}

log_warn() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

# --- Main Script ---

# 1. Check for root privileges
if [ "$EUID" -ne 0 ]; then
  log_error "This script must be run as root. Please use 'sudo'."
fi

# 2. Get the new hostname (either from argument or interactive prompt)
if [ $# -eq 0 ]; then
    # No arguments provided, switch to interactive mode
    log_info "No hostname provided as an argument. Entering interactive mode."
    echo -n -e "➡️  ${CYAN}Please enter the new hostname:${NC} "
    read NEW_HOSTNAME
    if [ -z "$NEW_HOSTNAME" ]; then
        log_error "Hostname cannot be empty. Aborting."
    fi
elif [ $# -eq 1 ]; then
    # Argument provided
    NEW_HOSTNAME="$1"
else
    # Too many arguments
    log_error "Too many arguments. Usage: sudo $0 [new-hostname]"
fi


OLD_HOSTNAME=$(hostname)

# 3. Validate hostname format
HOSTNAME_REGEX="^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$"
if [[ ! "$NEW_HOSTNAME" =~ $HOSTNAME_REGEX ]]; then
    log_error "Invalid hostname format: '$NEW_HOSTNAME'.\nIt must contain only letters, numbers, and hyphens, and cannot start or end with a hyphen."
fi

# Check if hostname is already set to the new name
if [ "$OLD_HOSTNAME" == "$NEW_HOSTNAME" ]; then
    log_warn "Hostname is already set to '$NEW_HOSTNAME'. No changes needed."
    hostnamectl
    exit 0
fi

log_info "Starting hostname update from '$OLD_HOSTNAME' to '$NEW_HOSTNAME'..."

# 4. Set the new hostname
log_info "Step 1/3: Setting new hostname with hostnamectl..."
hostnamectl set-hostname "$NEW_HOSTNAME"
if [ $? -ne 0 ]; then
    log_error "Failed to set hostname using hostnamectl."
fi
log_success "Hostname set to '$NEW_HOSTNAME'."

# 5. Update /etc/hosts
log_info "Step 2/3: Updating /etc/hosts file..."
# Use sed to replace the old hostname with the new one. The \b ensures whole-word matching.
# We also handle the case where the old hostname might not exist (e.g., fresh server).
# We search for 127.0.1.1 and replace the name on that line.
if grep -q "127.0.1.1" /etc/hosts; then
    sed -i "s/^\(127\.0\.1\.1\s\+\).*/\1$NEW_HOSTNAME/" /etc/hosts
    if [ $? -ne 0 ]; then
        log_error "Failed to update /etc/hosts."
    fi
    log_success "/etc/hosts file updated."
else
    log_warn "Line with '127.0.1.1' not found in /etc/hosts. You may need to update it manually if needed."
fi


# 6. Configure cloud-init (if it exists)
log_info "Step 3/3: Checking for cloud-init configuration..."
CLOUD_CFG="/etc/cloud/cloud.cfg"
if [ -f "$CLOUD_CFG" ]; then
    # Check if preserve_hostname is already set to true
    if grep -q "^preserve_hostname: *true" "$CLOUD_CFG"; then
        log_success "cloud-init is already configured to preserve hostname."
    # Check if the setting exists but is false or commented out, and replace it
    elif grep -q "^#* *preserve_hostname:" "$CLOUD_CFG"; then
        sed -i 's/^#* *preserve_hostname:.*/preserve_hostname: true/' "$CLOUD_CFG"
        log_success "Updated cloud-init config to preserve hostname."
    # If the setting doesn't exist at all, append it
    else
        echo "" >> "$CLOUD_CFG" # Add a newline for better formatting
        echo "preserve_hostname: true" >> "$CLOUD_CFG"
        log_success "Added 'preserve_hostname: true' to cloud-init config."
    fi
else
    log_info "cloud-init config not found. Skipping."
fi

echo -e "\n--------------------------------------------------"
log_success "Hostname change complete!"
log_info "Please log out and log back in for the new hostname to appear in your shell prompt."
echo "Current system hostname status:"
echo "--------------------------------------------------"
# Print the final status with color highlighting
hostnamectl | sed "s/$NEW_HOSTNAME/\\o033[1;32m&\o033[0m/"

exit 0
