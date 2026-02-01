#!/bin/bash
#
# setup-nvme-raid.sh
#
# Sets up NVMe instance store volumes as a single RAID-0 volume on Amazon EC2.
# Compatible with Deep Learning AMI (DLAMI) and other Ubuntu/Amazon Linux AMIs.
#
# Based on Amazon EKS AMI's setup-local-disks script:
# https://github.com/awslabs/amazon-eks-ami/blob/main/templates/shared/runtime/bin/setup-local-disks
#
# Usage:
#   sudo ./setup-nvme-raid.sh [OPTIONS]
#
# Options:
#   -d, --dir DIR       Mount point directory (default: /data)
#   -n, --name NAME     RAID array name (default: local_raid)
#   -h, --help          Show this help message
#
# Supported instances: p5.48xlarge, p5e.48xlarge, p5en.48xlarge, p4d.24xlarge,
#                      i3.*, i4i.*, c5d.*, c6id.*, g5.*, and other NVMe instance store types
#

set -o errexit
set -o pipefail
set -o nounset

readonly SCRIPT_NAME="$(basename "$0")"
readonly VERSION="1.0.0"

# Default configuration
MOUNT_POINT="/data"
RAID_NAME="local_raid"
MD_CONFIG_DIR="/.aws"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $*"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $*"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*" >&2
}

err_report() {
    log_error "Exited with error on line $1"
}

trap 'err_report $LINENO' ERR

print_help() {
    cat << EOF
${SCRIPT_NAME} v${VERSION}

Sets up NVMe instance store volumes as a single RAID-0 volume on Amazon EC2.

Usage:
    sudo ${SCRIPT_NAME} [OPTIONS]

Options:
    -d, --dir DIR       Mount point directory (default: ${MOUNT_POINT})
    -n, --name NAME     RAID array name (default: ${RAID_NAME})
    -h, --help          Show this help message

Examples:
    # Basic usage with defaults (mounts at /data)
    sudo ${SCRIPT_NAME}

    # Custom mount point
    sudo ${SCRIPT_NAME} --dir /mnt/nvme

    # Custom RAID name and mount point
    sudo ${SCRIPT_NAME} --name my_raid --dir /scratch

Supported Instances:
    - P5 family: p5.48xlarge, p5e.48xlarge, p5en.48xlarge
    - P4 family: p4d.24xlarge, p4de.24xlarge
    - I3/I4 family: i3.*, i4i.*
    - C5d/C6id family: c5d.*, c6id.*
    - G5 family: g5.*
    - And other instance types with NVMe instance store

Notes:
    - Instance store data is ephemeral and will be lost on stop/terminate
    - Script is idempotent and safe to run multiple times
    - Requires root privileges

EOF
}

check_root() {
    if [[ "$(id -u)" -ne 0 ]]; then
        log_error "This script must be run as root"
        exit 1
    fi
}

install_dependencies() {
    local packages_needed=()

    if ! command -v mdadm &> /dev/null; then
        packages_needed+=(mdadm)
    fi

    if ! command -v mkfs.xfs &> /dev/null; then
        packages_needed+=(xfsprogs)
    fi

    if [[ ${#packages_needed[@]} -eq 0 ]]; then
        return 0
    fi

    log_info "Installing required packages: ${packages_needed[*]}"

    # Detect package manager
    if command -v apt-get &> /dev/null; then
        apt-get update -qq
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${packages_needed[@]}"
    elif command -v yum &> /dev/null; then
        yum install -y -q "${packages_needed[@]}"
    elif command -v dnf &> /dev/null; then
        dnf install -y -q "${packages_needed[@]}"
    else
        log_error "Unable to detect package manager. Please install manually: ${packages_needed[*]}"
        exit 1
    fi
}

discover_nvme_devices() {
    local disks=()

    # Method 1: Use /dev/disk/by-id (most reliable)
    if [[ -d /dev/disk/by-id ]]; then
        while IFS= read -r -d '' disk; do
            disks+=("$disk")
        done < <(find -L /dev/disk/by-id/ -xtype l -name '*NVMe_Instance_Storage_*' -print0 2>/dev/null || true)
    fi

    # Method 2: Fallback to nvme list if by-id doesn't work
    if [[ ${#disks[@]} -eq 0 ]] && command -v nvme &> /dev/null; then
        log_warn "Falling back to nvme list for device discovery"
        while IFS= read -r dev; do
            if [[ -n "$dev" ]]; then
                disks+=("$dev")
            fi
        done < <(nvme list 2>/dev/null | grep "Amazon EC2 NVMe Instance Storage" | awk '{print $1}')
    fi

    if [[ ${#disks[@]} -eq 0 ]]; then
        return 1
    fi

    # Resolve to real device paths and deduplicate
    local resolved_disks=()
    for disk in "${disks[@]}"; do
        resolved_disks+=("$(realpath "$disk")")
    done

    # Sort and deduplicate
    printf '%s\n' "${resolved_disks[@]}" | sort -u
}

create_raid() {
    local -a devices=("$@")
    local device_count=${#devices[@]}
    local md_device="/dev/md/${RAID_NAME}"
    local md_config="${MD_CONFIG_DIR}/mdadm.conf"

    mkdir -p "${MD_CONFIG_DIR}"

    # Check if RAID already exists
    if [[ -b "${md_device}" ]]; then
        log_info "RAID device ${md_device} already exists"
        echo "${md_device}"
        return 0
    fi

    # Check for existing md device with different name (homehost suffix)
    local existing_md
    existing_md=$(find /dev/md/ -type l -regex ".*/${RAID_NAME}_?[0-9a-z]*$" 2>/dev/null | tail -n1 || true)
    if [[ -n "${existing_md}" ]]; then
        log_info "Found existing RAID device: ${existing_md}"
        echo "${existing_md}"
        return 0
    fi

    log_info "Creating RAID-0 array with ${device_count} device(s)"
    log_info "Devices: ${devices[*]}"

    mdadm --create --force --verbose \
        "${md_device}" \
        --level=0 \
        --name="${RAID_NAME}" \
        --raid-devices="${device_count}" \
        "${devices[@]}"

    # Wait for RAID initialization
    log_info "Waiting for RAID initialization..."
    local timeout=60
    local elapsed=0
    while [[ -n "$(mdadm --detail "${md_device}" 2>/dev/null | grep -ioE 'State :.*resyncing')" ]]; do
        if [[ $elapsed -ge $timeout ]]; then
            log_warn "RAID initialization taking longer than expected, continuing anyway"
            break
        fi
        sleep 1
        ((elapsed++))
    done

    # Save RAID configuration
    mdadm --detail --scan > "${md_config}"
    log_info "RAID configuration saved to ${md_config}"

    echo "${md_device}"
}

format_device() {
    local device="$1"

    # Check if already formatted
    local fstype
    fstype=$(lsblk "${device}" -o fstype --noheadings 2>/dev/null | tr -d '[:space:]')

    if [[ -n "${fstype}" ]]; then
        log_info "Device ${device} already formatted as ${fstype}"
        return 0
    fi

    log_info "Formatting ${device} with XFS"

    # Use -l su=8b to avoid log stripe unit warnings with RAID
    # Default RAID stripe unit (512k) exceeds max log stripe unit (256k)
    mkfs.xfs -f -l su=8b "${device}"
}

mount_device() {
    local device="$1"
    local mount_point="$2"

    mkdir -p "${mount_point}"

    # Check if already mounted
    if mountpoint -q "${mount_point}"; then
        log_info "${mount_point} is already mounted"
        return 0
    fi

    # Check if device is mounted elsewhere
    local current_mount
    current_mount=$(lsblk "${device}" -o MOUNTPOINT --noheadings 2>/dev/null | tr -d '[:space:]')
    if [[ -n "${current_mount}" ]]; then
        log_warn "Device ${device} is already mounted at ${current_mount}"
        return 0
    fi

    log_info "Mounting ${device} at ${mount_point}"
    mount -o defaults,noatime "${device}" "${mount_point}"

    # Add to fstab if not already present
    local dev_uuid
    dev_uuid=$(blkid -s UUID -o value "${device}")
    if [[ -n "${dev_uuid}" ]] && ! grep -q "${dev_uuid}" /etc/fstab; then
        log_info "Adding mount to /etc/fstab"
        echo "UUID=${dev_uuid} ${mount_point} xfs defaults,noatime,nofail 0 2" >> /etc/fstab
    fi
}

main() {
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                print_help
                exit 0
                ;;
            -d|--dir)
                MOUNT_POINT="$2"
                shift 2
                ;;
            -n|--name)
                RAID_NAME="$2"
                shift 2
                ;;
            *)
                log_error "Unknown option: $1"
                print_help
                exit 1
                ;;
        esac
    done

    log_info "Starting NVMe RAID setup (v${VERSION})"
    log_info "Mount point: ${MOUNT_POINT}"
    log_info "RAID name: ${RAID_NAME}"

    check_root
    install_dependencies

    # Discover NVMe instance store devices
    local devices_str
    if ! devices_str=$(discover_nvme_devices); then
        log_warn "No NVMe instance store devices found, skipping setup"
        exit 0
    fi

    # Convert to array
    local -a devices
    mapfile -t devices <<< "${devices_str}"
    local device_count=${#devices[@]}

    log_info "Found ${device_count} NVMe instance store device(s)"

    local target_device
    if [[ ${device_count} -gt 1 ]]; then
        # Multiple devices: create RAID-0
        target_device=$(create_raid "${devices[@]}")
    else
        # Single device: use directly
        target_device="${devices[0]}"
        log_info "Single device found, using directly: ${target_device}"
    fi

    format_device "${target_device}"
    mount_device "${target_device}" "${MOUNT_POINT}"

    log_info "Setup complete!"
    echo ""
    df -h "${MOUNT_POINT}"
}

main "$@"
