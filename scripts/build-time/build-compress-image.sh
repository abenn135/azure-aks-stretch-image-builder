#!/bin/bash

set -euo pipefail

STORAGE_ACCOUNT_NAME=`jq -r .storageAccountName config.json`
STORAGE_CONTAINER_NAME=`jq -r .storageContainerName config.json`
BUILD_VERSION=`jq -r .buildVersion config.json`

TARGET_MOUNT="/mnt/target"
if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root. Please run with sudo."
    exit 1
fi

DATA_DISK_LINK="/dev/disk/azure/data/by-lun/0"

detect_root_partition() {
    if [ -b "${DATA_DISK_LINK}-part1" ]; then
        echo "${DATA_DISK_LINK}-part1"
    else
        echo "Error: Could not find data disk at ${DATA_DISK_LINK}-part1" >&2
        exit 1
    fi
}

# Detect a partition by parted flag or GPT type GUID.
# Usage: detect_partition <label> <parted_flag> <gpt_type_guid>
detect_partition() {
    local label="$1"
    local parted_flag="$2"
    local type_guid="$3"
    local base_disk
    base_disk=$(readlink -f "$DATA_DISK_LINK")

    # Method 1: Use parted to find a partition with the given flag
    local part_num
    part_num=$(parted -s "$base_disk" print 2>/dev/null \
        | awk -v flag="$parted_flag" '$0 ~ flag { print $1 }')

    if [ -n "$part_num" ]; then
        local dev="${DATA_DISK_LINK}-part${part_num}"
        if [ -b "$dev" ]; then
            echo "$dev"
            return 0
        fi
    fi

    # Method 2: Check for the GPT partition type GUID via lsblk
    local name parttype
    while read -r name parttype; do
        if [ "$parttype" = "$type_guid" ]; then
            echo "/dev/$name"
            return 0
        fi
    done < <(lsblk -ln -o NAME,PARTTYPE "$base_disk" 2>/dev/null)

    echo "Error: Could not find $label partition (flag '$parted_flag' or type GUID '$type_guid') on $base_disk" >&2
    exit 1
}

DATA_ROOT_PARTITION=$(detect_root_partition)
echo "Root partition detected at $DATA_ROOT_PARTITION"

DATA_BOOT_PARTITION=$(detect_partition "boot" "bls_boot" "bc13c2ff-59e6-4262-a352-b275fd6f7172")
echo "Boot partition detected at $DATA_BOOT_PARTITION"

DATA_EFI_PARTITION=$(detect_partition "EFI" "boot, esp" "c12a7328-f81f-11d2-ba4b-00a0c93ec93b")
echo "EFI partition detected at $DATA_EFI_PARTITION"

# Unmount the partition if it's already mounted
if findmnt $DATA_ROOT_PARTITION; then
    echo "Unmounting $TARGET_MOUNT..."
    umount `findmnt -n -o TARGET $DATA_ROOT_PARTITION`
fi

# Mount it in the desired place
echo "Mounting $DATA_ROOT_PARTITION to $TARGET_MOUNT..."
mkdir -p $TARGET_MOUNT
mount $DATA_ROOT_PARTITION $TARGET_MOUNT

# Bind-mount pseudo-filesystems and DNS config needed for chroot
mount --bind /proc $TARGET_MOUNT/proc
mount --bind /sys $TARGET_MOUNT/sys
mount --bind /dev $TARGET_MOUNT/dev
mount --bind /dev/pts $TARGET_MOUNT/dev/pts
# Remove dangling symlink (e.g. -> /run/systemd/resolve/stub-resolv.conf) and copy host DNS config
rm -f $TARGET_MOUNT/etc/resolv.conf
cp /etc/resolv.conf $TARGET_MOUNT/etc/resolv.conf

cp chroot-run.sh $TARGET_MOUNT/
chroot $TARGET_MOUNT /bin/bash /chroot-run.sh

# Unmount bind mounts in reverse order, then the partition
echo "Unmounting bind mounts and $TARGET_MOUNT..."
umount $TARGET_MOUNT/dev/pts
umount $TARGET_MOUNT/dev
umount $TARGET_MOUNT/sys
umount $TARGET_MOUNT/proc
umount $TARGET_MOUNT

# Compress the root partition as a raw disk using dd and gzip
echo "Compressing root partition $DATA_ROOT_PARTITION to /tmp/compressed-root-partition.img.gz..."
dd if=$DATA_ROOT_PARTITION bs=4M | gzip > /tmp/compressed-root-partition.img.gz
echo "Root partition compression complete."

# Compress the boot partition
echo "Compressing boot partition $DATA_BOOT_PARTITION to /tmp/compressed-boot-partition.tgz..."
tar -czf /tmp/compressed-boot-partition.tgz -C /boot .
echo "Boot partition compression complete."

# Compress the EFI partition
echo "Compressing EFI partition $DATA_EFI_PARTITION to /tmp/compressed-efi-partition.tgz..."
tar -czf /tmp/compressed-efi-partition.tgz -C /boot .
echo "EFI partition compression complete."

echo "Getting az CLI..."
apt-get update
apt-get install -y apt-transport-https ca-certificates curl gnupg lsb-release
mkdir -p /etc/apt/keyrings
curl -sLS https://packages.microsoft.com/keys/microsoft.asc |
  gpg --dearmor | tee /etc/apt/keyrings/microsoft.gpg > /dev/null
chmod go+r /etc/apt/keyrings/microsoft.gpg
AZ_DIST=$(lsb_release -cs)
echo "Types: deb
URIs: https://packages.microsoft.com/repos/azure-cli/
Suites: ${AZ_DIST}
Components: main
Architectures: $(dpkg --print-architecture)
Signed-by: /etc/apt/keyrings/microsoft.gpg" | tee /etc/apt/sources.list.d/azure-cli.sources
apt-get update
apt-get install -y azure-cli

# Copy image to storage account. This VM should have a system-assigned managed identity with Contributor role on the resource group containing the storage account.
az login --identity
az storage blob upload --account-name $STORAGE_ACCOUNT_NAME --container-name $STORAGE_CONTAINER_NAME --name ${BUILD_VERSION}_root.img.gz --file /tmp/compressed-root-partition.img.gz
echo "Root partition image uploaded."
az storage blob upload --account-name $STORAGE_ACCOUNT_NAME --container-name $STORAGE_CONTAINER_NAME --name ${BUILD_VERSION}_boot.tgz --file /tmp/compressed-boot-partition.tgz
echo "Boot partition image uploaded."
az storage blob upload --account-name $STORAGE_ACCOUNT_NAME --container-name $STORAGE_CONTAINER_NAME --name ${BUILD_VERSION}_efi.tgz --file /tmp/compressed-efi-partition.tgz
echo "EFI partition image uploaded."
az storage blob upload --account-name $STORAGE_ACCOUNT_NAME --container-name $STORAGE_CONTAINER_NAME --name ${BUILD_VERSION}_config.json --file config.json
echo "Config file uploaded."
az storage blob upload --account-name $STORAGE_ACCOUNT_NAME --container-name $STORAGE_CONTAINER_NAME --name latest_config.json --file config.json
echo "Latest config file set to current build."
echo "All images uploaded to Azure Storage container $STORAGE_CONTAINER_NAME in account $STORAGE_ACCOUNT_NAME"
