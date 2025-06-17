#!/bin/bash

# ==============================================================================
# Script to update the hostname on Debian/Ubuntu systems.
# Author: Gemini
# Usage: sudo ./update_hostname.sh <new-hostname>
# ==============================================================================

# --- Color Definitions ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
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

# 2. Check for hostname argument
if [ $# -ne 1 ]; then
  log_error "Usage: sudo $0 <new-hostname>"
fi

NEW_HOSTNAME="$1"
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
if grep -q "\b$OLD_HOSTNAME\b" /etc/hosts; then
    sed -i "s/\b$OLD_HOSTNAME\b/$NEW_HOSTNAME/g" /etc/hosts
    if [ $? -ne 0 ]; then
        log_error "Failed to update /etc/hosts."
    fi
    log_success "/etc/hosts file updated."
else
    log_warn "Old hostname '$OLD_HOSTNAME' not found in /etc/hosts. Skipping this step."
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
