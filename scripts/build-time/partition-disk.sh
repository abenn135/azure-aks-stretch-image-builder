#!/bin/bash
#
# Partition and format unused space on secondary NVMe data disk.
# Creates three ext4 partitions: "blue" (resized original), "green", and "scratch".
#
# Must run as superuser (root).

set -euo pipefail
shopt -s extglob  # Enable extended globbing for +([0-9]) patterns

# --- Configuration ---
BLUE_PARTITION_NAME="blue"
GREEN_PARTITION_NAME="green"
SCRATCH_PARTITION_NAME="scratch"
# Percentage of unused space to allocate to "green" (remainder goes to "scratch")
GREEN_PERCENT=50
# Alignment boundary in sectors (1 MiB = 2048 * 512 bytes)
ALIGN=2048
# Mount point for chroot operations
TARGET_MOUNT="/mnt/target"

# --- Global variables (set during disk detection) ---
DATA_DISK=""
SECTOR_SIZE=""
TOTAL_SECTORS=""

# --- Helper functions ---
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

die() {
    echo "[ERROR] $*" >&2
    exit 1
}

# Check if a partition with a given label exists on DATA_DISK
partition_exists() {
    local label="$1"
    lsblk -ln -o PARTLABEL "$DATA_DISK" 2>/dev/null | grep -qx "$label"
}

# Get the device path for a partition by its label
get_partition_device() {
    local label="$1"
    local part_name
    part_name=$(lsblk -ln -o NAME,PARTLABEL "$DATA_DISK" | awk -v lbl="$label" '$2 == lbl {print $1}')
    if [[ -n "$part_name" ]]; then
        echo "/dev/$part_name"
    fi
}

# Find the secondary NVMe data disk (not the OS/boot disk)
detect_data_disk() {
    log "Detecting NVMe disks..."

    # Get the device that holds the root filesystem
    local root_dev
    root_dev=$(findmnt -n -o SOURCE / | sed 's/p\?[0-9]*$//' | xargs basename)
    log "Root filesystem is on: $root_dev"

    # Find all NVMe namespace block devices (nvme<controller>n<namespace>)
    # This matches both /dev/nvme1n1 (second controller) and /dev/nvme0n2 (second namespace)
    for disk in /dev/nvme+([0-9])n+([0-9]); do
        [[ -b "$disk" ]] || continue
        local disk_name
        disk_name=$(basename "$disk")
        if [[ "$disk_name" != "$root_dev" ]]; then
            DATA_DISK="$disk"
            break
        fi
    done

    if [[ -z "$DATA_DISK" ]]; then
        die "Could not find a secondary NVMe data disk."
    fi

    log "Selected secondary NVMe data disk: $DATA_DISK"

    # Verify the disk has a GPT partition table
    if ! parted -s "$DATA_DISK" print 2>/dev/null | grep -q "Partition Table: gpt"; then
        die "Disk $DATA_DISK does not have a GPT partition table."
    fi

    # Get disk geometry
    SECTOR_SIZE=$(cat /sys/block/"$(basename "$DATA_DISK")"/queue/hw_sector_size)
    TOTAL_SECTORS=$(cat /sys/block/"$(basename "$DATA_DISK")"/size)
    log "Disk has $TOTAL_SECTORS sectors of $SECTOR_SIZE bytes each."
}

# Shrink the last partition to 1/3 its size if it fills the disk
# This is idempotent: skips if green/scratch already exist (meaning resize was done)
shrink_last_partition_if_needed() {
    # If green and scratch exist, the resize has already been done
    if partition_exists "$GREEN_PARTITION_NAME" && partition_exists "$SCRATCH_PARTITION_NAME"; then
        log "Partitions '$GREEN_PARTITION_NAME' and '$SCRATCH_PARTITION_NAME' already exist; skipping resize."
        return 0
    fi

    # Find the end of the last existing partition (in sectors)
    # parted output gives sizes in various units; use 'unit s' for sectors
    local last_partition_end
    last_partition_end=$(parted -s "$DATA_DISK" unit s print | \
        awk '/^ [0-9]+/ {gsub(/s$/,"",$3); end=$3} END {print end}')

    if [[ -z "$last_partition_end" || "$last_partition_end" -eq 0 ]]; then
        die "Could not determine the end of the last partition on $DATA_DISK."
    fi

    log "Last partition ends at sector: $last_partition_end"

    # Calculate available space
    local start_sector usable_end available_sectors
    start_sector=$(( (last_partition_end + ALIGN) / ALIGN * ALIGN ))
    usable_end=$(( TOTAL_SECTORS - 34 ))  # Reserve 34 sectors for backup GPT
    available_sectors=$(( usable_end - start_sector ))

    if [[ $available_sectors -gt 0 ]]; then
        log "Free space available ($available_sectors sectors); no resize needed."
        return 0
    fi

    log "No free space available. Azure may have auto-expanded the last partition."
    log "Will shrink the last partition to 1/3 its size to make room for green and scratch."

    # Find the last partition number and its details
    # Note: parted lists partitions in order by start sector, so the last row
    # in the output is the partition that extends furthest on the disk.
    local last_part_info last_part_num last_part_start last_part_end last_part_dev
    last_part_info=$(parted -s "$DATA_DISK" unit s print | awk '/^ [0-9]+/ {num=$1; start=$2; end=$3} END {print num, start, end}')
    last_part_num=$(echo "$last_part_info" | awk '{print $1}')
    last_part_start=$(echo "$last_part_info" | awk '{gsub(/s$/,"",$2); print $2}')
    last_part_end=$(echo "$last_part_info" | awk '{gsub(/s$/,"",$3); print $3}')
    last_part_dev="${DATA_DISK}p${last_part_num}"

    log "Last partition: #$last_part_num ($last_part_dev), sectors ${last_part_start}s - ${last_part_end}s"

    local last_part_sectors target_sectors new_last_part_end target_bytes target_kb
    last_part_sectors=$(( last_part_end - last_part_start + 1 ))
    # Target size is 1/3 of current size, aligned
    target_sectors=$(( last_part_sectors / 3 ))
    target_sectors=$(( target_sectors / ALIGN * ALIGN ))
    new_last_part_end=$(( last_part_start + target_sectors - 1 ))

    # Calculate target size in bytes for resize2fs (it needs size, not sectors)
    target_bytes=$(( target_sectors * SECTOR_SIZE ))
    target_kb=$(( target_bytes / 1024 ))

    log "Shrinking partition #$last_part_num from $last_part_sectors sectors to $target_sectors sectors ($target_kb KB)"

    # Ensure partition is not mounted
    if mountpoint -q "$last_part_dev" 2>/dev/null || mount | grep -q "^$last_part_dev "; then
        log "Unmounting $last_part_dev..."
        umount "$last_part_dev" || die "Failed to unmount $last_part_dev"
    fi

    # Check filesystem before resizing
    log "Checking filesystem integrity before resize..."
    e2fsck -f -y "$last_part_dev" || die "Filesystem check failed on $last_part_dev before resize"

    # Shrink the filesystem first (must be done before shrinking partition)
    log "Shrinking filesystem on $last_part_dev to ${target_kb}K..."
    resize2fs "$last_part_dev" "${target_kb}K" || die "Failed to shrink filesystem on $last_part_dev"

    # Now shrink the partition using parted
    # Delete and recreate the partition at the new size (safe since filesystem is already shrunk)
    log "Resizing partition #$last_part_num..."

    # Get partition name/label, defaulting to "blue" if none exists
    local last_part_name
    last_part_name=$(lsblk -ln -o PARTLABEL "$last_part_dev" 2>/dev/null | head -1)
    last_part_name="${last_part_name:-$BLUE_PARTITION_NAME}"

    # Delete and recreate (preserves data since filesystem is already shrunk)
    parted -s "$DATA_DISK" rm "$last_part_num" || die "Failed to remove partition #$last_part_num"
    parted -s -a optimal "$DATA_DISK" mkpart "$last_part_name" ext4 "${last_part_start}s" "${new_last_part_end}s" || \
        die "Failed to recreate partition #$last_part_num"

    # Wait for udev
    udevadm settle --timeout=10

    # Verify filesystem integrity after partition resize
    log "Verifying filesystem integrity after resize..."
    e2fsck -f -y "$last_part_dev" || die "Filesystem check failed on $last_part_dev after resize - DATA MAY BE CORRUPTED"

    log "Partition #$last_part_num successfully resized and verified."
}

# Create a partition and format it with ext4 (if it doesn't already exist)
# Arguments: $1=label_name
# Returns: 0 if created or already exists, 1 on failure
create_partition_if_needed() {
    local label="$1"

    if partition_exists "$label"; then
        log "Partition '$label' already exists; skipping creation."
        return 0
    fi

    # Find the end of the last existing partition
    local last_partition_end
    last_partition_end=$(parted -s "$DATA_DISK" unit s print | \
        awk '/^ [0-9]+/ {gsub(/s$/,"",$3); end=$3} END {print end}')

    local start_sector usable_end available_sectors
    start_sector=$(( (last_partition_end + ALIGN) / ALIGN * ALIGN ))
    usable_end=$(( TOTAL_SECTORS - 34 ))
    available_sectors=$(( usable_end - start_sector ))

    if [[ $available_sectors -le 0 ]]; then
        die "No space available to create partition '$label'."
    fi

    # Determine partition size based on label
    local end_sector
    if [[ "$label" == "$GREEN_PARTITION_NAME" ]]; then
        # Green gets GREEN_PERCENT of available space
        local green_sectors
        green_sectors=$(( available_sectors * GREEN_PERCENT / 100 ))
        end_sector=$(( start_sector + green_sectors ))
        end_sector=$(( end_sector / ALIGN * ALIGN - 1 ))
    else
        # Scratch gets the remainder
        end_sector=$(( usable_end - 1 ))
    fi

    log "Creating partition '$label' (sectors ${start_sector}s - ${end_sector}s)..."
    parted -s -a optimal "$DATA_DISK" mkpart "$label" ext4 "${start_sector}s" "${end_sector}s"

    # Wait for udev to create device node
    udevadm settle --timeout=10

    # Find the newly created partition device
    local part_dev dev_path
    part_dev=$(lsblk -ln -o NAME,PARTLABEL "$DATA_DISK" | awk -v lbl="$label" '$2 == lbl {print $1}')

    if [[ -z "$part_dev" ]]; then
        die "Failed to detect partition device for '$label'."
    fi

    dev_path="/dev/$part_dev"
    log "Formatting $dev_path as ext4 (label: $label)..."
    mkfs.ext4 -L "$label" "$dev_path"

    log "Partition '$label' created and formatted."
}

# Mount the target filesystem and update GRUB/initramfs
# This is idempotent: checks mount status and always runs grub/initramfs updates
update_bootloader() {
    log "Updating bootloader configuration..."

    local root_part="${DATA_DISK}p1"
    local efi_part="${DATA_DISK}p15"
    local need_unmount_root=false
    local need_unmount_efi=false
    local need_unmount_dev=false
    local need_unmount_pts=false
    local need_unmount_proc=false
    local need_unmount_sys=false

    # Create mount point
    mkdir -p "$TARGET_MOUNT"

    # Mount root partition if not already mounted
    if ! mountpoint -q "$TARGET_MOUNT"; then
        log "Mounting $root_part at $TARGET_MOUNT..."
        mount "$root_part" "$TARGET_MOUNT"
        need_unmount_root=true
    else
        log "$TARGET_MOUNT is already mounted."
    fi

    # Mount virtual filesystems if not already mounted
    if ! mountpoint -q "$TARGET_MOUNT/dev"; then
        mount --bind /dev "$TARGET_MOUNT/dev"
        need_unmount_dev=true
    fi
    if ! mountpoint -q "$TARGET_MOUNT/dev/pts"; then
        mount --bind /dev/pts "$TARGET_MOUNT/dev/pts"
        need_unmount_pts=true
    fi
    if ! mountpoint -q "$TARGET_MOUNT/proc"; then
        mount --bind /proc "$TARGET_MOUNT/proc"
        need_unmount_proc=true
    fi
    if ! mountpoint -q "$TARGET_MOUNT/sys"; then
        mount --bind /sys "$TARGET_MOUNT/sys"
        need_unmount_sys=true
    fi

    # Mount EFI partition
    mkdir -p "$TARGET_MOUNT/boot/efi"
    if ! mountpoint -q "$TARGET_MOUNT/boot/efi"; then
        log "Mounting $efi_part at $TARGET_MOUNT/boot/efi..."
        mount "$efi_part" "$TARGET_MOUNT/boot/efi"
        need_unmount_efi=true
    else
        log "$TARGET_MOUNT/boot/efi is already mounted."
    fi

    # Run GRUB and initramfs updates in chroot
    log "Running grub-install, update-grub, and update-initramfs..."
    chroot "$TARGET_MOUNT" /bin/bash -c '
        grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=ubuntu
        update-grub
        update-initramfs -u -k all
    '

    log "Bootloader update complete."

    # Unmount in reverse order (only what we mounted)
    log "Cleaning up mounts..."
    if $need_unmount_efi; then
        umount "$TARGET_MOUNT/boot/efi"
    fi
    if $need_unmount_sys; then
        umount "$TARGET_MOUNT/sys"
    fi
    if $need_unmount_proc; then
        umount "$TARGET_MOUNT/proc"
    fi
    if $need_unmount_pts; then
        umount "$TARGET_MOUNT/dev/pts"
    fi
    if $need_unmount_dev; then
        umount "$TARGET_MOUNT/dev"
    fi
    if $need_unmount_root; then
        umount "$TARGET_MOUNT"
    fi

    log "Mounts cleaned up."
}

# --- Main execution ---

# Pre-flight checks
if [[ $EUID -ne 0 ]]; then
    die "This script must be run as root (use sudo)."
fi

# Step 1: Detect the data disk
detect_data_disk

# Step 2: Shrink the last partition if needed to make room
shrink_last_partition_if_needed

# Step 3: Create green and scratch partitions if they don't exist
create_partition_if_needed "$GREEN_PARTITION_NAME"
create_partition_if_needed "$SCRATCH_PARTITION_NAME"

# Step 4: Print final partition table
log "Final partition layout:"
parted -s "$DATA_DISK" unit s print
lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT "$DATA_DISK"

# Step 5: Update bootloader (mount, update grub/initramfs, unmount)
update_bootloader

log "Done. All partitions are created, formatted, and bootloader is configured."
