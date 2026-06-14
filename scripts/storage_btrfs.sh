#!/bin/sh
# Btrfs Storage Module
export FS_PKGS="btrfs-progs"

partition_and_format_wipe() {
    echo "=== 4. Creating 100MB EFI Partition & Btrfs Data Partition ==="
    parted -s "$DISK" mkpart primary fat32 1MiB 100MiB
    parted -s "$DISK" set 1 esp on
    parted -s "$DISK" mkpart primary btrfs 100MiB 100%
    udevadm settle

    echo "=== 5. Formatting filesystems ==="
    mkfs.vfat -F 32 "$PART1"
    mkfs.btrfs -f -d single -m single "$PART2"
    
    setup_subvolumes
}

format_and_mount_manual() {
    echo "=== 5. Formatting target root partition only (Preserving EFI) ==="
    # Do not touch the existing EFI system partition layout ($PART1)
    mkfs.btrfs -f -d single -m single "$PART2"
    
    setup_subvolumes
}

setup_subvolumes() {
    echo "=== 6. Setting up Btrfs subvolumes ==="
    mkdir -p /mnt
    mount "$PART2" /mnt
    btrfs subvolume create /mnt/@
    btrfs subvolume create /mnt/@home
    umount /mnt

    echo "=== 7. Re-mounting subvolume layout structural tree ==="
    mount -o noatime,compress=zstd,subvol=@ "$PART2" /mnt
    mkdir -p /mnt/home /mnt/boot/efi
    mount -o noatime,compress=zstd,subvol=@home "$PART2" /mnt/home
    mount "$PART1" /mnt/boot/efi
}

generate_fstab() {
    echo "=== 9. Inverting explicit storage mounts mapping table ==="
    UUID_BTRFS=$(blkid -o value -s UUID "$PART2")
    UUID_EFI=$(blkid -o value -s UUID "$PART1")

    cat << FSTAB > /mnt/etc/fstab
UUID=$UUID_BTRFS / btrfs noatime,compress=zstd,subvol=@,space_cache=v2,autodefrag 0 1
UUID=$UUID_BTRFS /home btrfs noatime,compress=zstd,subvol=@home,space_cache=v2,autodefrag 0 2
UUID=$UUID_EFI /boot/efi vfat defaults 0 2
FSTAB
}

# Write dynamic background balancing tasks directly into the target execution space
cat << 'OPT' > /mnt/tmp/fs_optimize.sh
btrfs balance start -dusage=50 -musage=50 / || true
OPT
