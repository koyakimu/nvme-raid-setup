#!/bin/bash
#
# EC2 User Data example for NVMe RAID setup
#
# This script can be used as EC2 User Data to automatically configure
# NVMe instance store volumes when launching an instance.
#
# Usage:
#   1. Copy this script content to EC2 User Data field when launching an instance
#   2. Or encode as base64 and use in CloudFormation/Terraform
#
# Supported AMIs:
#   - AWS Deep Learning AMI (Ubuntu/Amazon Linux)
#   - Amazon Linux 2 / 2023
#   - Ubuntu 20.04 / 22.04 / 24.04
#

set -o errexit
set -o pipefail
set -o nounset

# Configuration
MOUNT_POINT="/data"
SCRIPT_URL="https://raw.githubusercontent.com/koyakimu/nvme-raid-setup/main/setup-nvme-raid.sh"

# Logging
exec > >(tee /var/log/user-data.log | logger -t user-data -s 2>/dev/console) 2>&1

echo "=========================================="
echo "Starting NVMe RAID setup via User Data"
echo "Timestamp: $(date)"
echo "Instance ID: $(curl -s http://169.254.169.254/latest/meta-data/instance-id)"
echo "Instance Type: $(curl -s http://169.254.169.254/latest/meta-data/instance-type)"
echo "=========================================="

# Wait for cloud-init to complete (optional, for complex setups)
# cloud-init status --wait

# Download and run the setup script
cd /tmp
curl -fsSL -o setup-nvme-raid.sh "${SCRIPT_URL}"
chmod +x setup-nvme-raid.sh
./setup-nvme-raid.sh --dir "${MOUNT_POINT}"

# Verify setup
echo ""
echo "=========================================="
echo "Setup completed!"
echo "Mount point: ${MOUNT_POINT}"
df -h "${MOUNT_POINT}"
echo "=========================================="

# Optional: Set permissions for non-root users
# chmod 777 "${MOUNT_POINT}"

# Optional: Create subdirectories for specific use cases
# mkdir -p "${MOUNT_POINT}/checkpoints"
# mkdir -p "${MOUNT_POINT}/datasets"
# mkdir -p "${MOUNT_POINT}/cache"
