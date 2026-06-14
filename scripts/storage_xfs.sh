#!/bin/sh
# XFS Storage Module
export FS_PKGS="xfsprogs"

partition_and_format_wipe() {
    echo "=== 4. Creating 100MB EFI Partition & XFS Data Partition ==="
    parted -s "$DISK" mkpart primary fat32 1MiB 100MiB
    parted -s "$DISK" set 1 esp on
    parted -s "$DISK" mkpart primary xfs 100MiB 100%
    udevadm settle

    echo "=== 5. Formatting filesystems ==="
    mkfs.vfat -F 32 "$PART1"
    mkfs.xfs -f "$PART2"
    
    setup_mounts
}

format_and_mount_manual() {
    echo "=== 5. Formatting target root partition only (Preserving EFI) ==="
    # Do not touch the existing EFI system partition layout ($PART1)
    mkfs.xfs -f "$PART2"
    
    setup_mounts
}

setup_mounts() {
    echo "=== 6. Setting up XFS runtime workspace ==="
    mkdir -p /mnt
    mount "$PART2" /mnt

    echo "=== 7. Re-mounting storage layout structural tree ==="
    mkdir -p /mnt/boot/efi
    mount "$PART1" /mnt/boot/efi
}

generate_fstab() {
    echo "=== 9. Inverting explicit storage mounts mapping table ==="
    UUID_XFS=$(blkid -o value -s UUID "$PART2")
    UUID_EFI=$(blkid -o value -s UUID "$PART1")

    cat << FSTAB > /mnt/etc/fstab
UUID=$UUID_XFS / xfs defaults,noatime 0 1
UUID=$UUID_EFI /boot/efi vfat defaults 0 2
FSTAB
}

# XFS layout does not need custom engine balances
rm -f /mnt/tmp/fs_optimize.sh
