#!/bin/sh
chmod +x ./setup.sh

sudo xbps-install -Syu
sudo xbps-install -uy xbps
sudo xbps-install parted -y

set -e

echo "=== 1. Dynamically locating installation target drive ==="
# Automatically finds the largest unmounted internal cloud storage disk (e.g., vda, sda)
TARGET_DISK=$(lsblk -dnro NAME,TYPE,MOUNTPOINTS | awk '$2=="disk" && $3=="" {print $1; exit}')

if [ -z "$TARGET_DISK" ]; then
    echo "ERROR: Could not automatically find an available destination drive!" >&2
    exit 1
fi

DISK="/dev/$TARGET_DISK"
echo "Target drive identified as: $DISK"

# Strictly keeps the plain 1 and 2 naming convention 
PART1="${DISK}1"
PART2="${DISK}2"

echo "=== 2. Wiping target disk headers ==="
wipefs -a "$DISK"
sudo xbps-install parted -y

echo "=== 3. Creating GPT Table ==="
parted -s "$DISK" mklabel gpt

echo "=== 4. Creating 100MB EFI Partition & Btrfs Data Partition ==="
parted -s "$DISK" mkpart primary fat32 1MiB 100MiB
parted -s "$DISK" set 1 esp on
parted -s "$DISK" mkpart primary btrfs 100MiB 100%

# Allow kernel time to safely map out the new partition tables
udevadm settle

echo "=== 5. Formatting filesystems ==="
mkfs.vfat -F 32 "$PART1"
mkfs.btrfs -f -d single -m single "$PART2"

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

echo "=== 8. Cloning Live OS structures directly to Btrfs ==="
cp -ax / /mnt

echo "=== 9. Inverting explicit storage mounts mapping table using persistent UUIDs ==="
# Capture system device IDs dynamically to prevent drive letter shift errors on boot
UUID_BTRFS=$(blkid -o value -s UUID "$PART2")
UUID_EFI=$(blkid -o value -s UUID "$PART1")

cat << FSTAB > /mnt/etc/fstab
UUID=$UUID_BTRFS / btrfs noatime,compress=zstd,subvol=@ 0 1,space_cache=v2,autodefrag 0 1
UUID=$UUID_BTRFS /home btrfs noatime,compress=zstd,subvol=@home 0 2,space_cache=v2,autodefrag 0 1
UUID=$UUID_EFI /boot/efi vfat defaults 0 2

FSTAB

echo "=== 10. Mounting runtime components for chroot wrapper ==="
mount --rbind /sys /mnt/sys && mount --make-rslave /mnt/sys
mount --rbind /dev /mnt/dev && mount --make-rslave /mnt/dev
mount --rbind /proc /mnt/proc && mount --make-rslave /mnt/proc
mount --bind /run /mnt/run && mount --make-slave /mnt/run

echo "=== 11. Generating permanent self-sustained UEFI boot tracks ==="
UUID_BTRFS=$(blkid -o value -s UUID "$PART2")
env UUID_BTRFS="$UUID_BTRFS" chroot /mnt /bin/bash << 'EOF'
  # Synchronize and download core system management packages
  xbps-install -Syu || true
  xbps-install -u xbps --yes
  xbps-install -Sy --yes grub-arm64-efi btrfs-progs dhcpcd cronie nano xtools wget 7zip git
  xbps-install -Sy --yes curl tar parted vsv openssh socklog-void linux-lts linux-lts-headers
  xbps-install -y apparmor ufw fastfetch
   
  echo "Port 222" > /etc/ssh/sshd_config.d/ssh.conf
  sudo ln -sf /etc/sv/cronie /var/service/
# Enable serial console (essential for cloud platforms like OCI)
  cp -R /etc/sv/agetty-generic /etc/sv/agetty-ttyAMA0
echo "ttyAMA0" > /etc/sv/agetty-ttyAMA0/conf
echo "115200" >> /etc/sv/agetty-ttyAMA0/conf
echo "linux" >> /etc/sv/agetty-ttyAMA0/conf
echo "--autologin root" >> /etc/sv/agetty-ttyAMA0/conf
ln -sf /etc/sv/agetty-ttyAMA0 /var/service/

 # 2. Lock down the tracking table so general updates don't break this pinning
  echo 'ignorepkg=linux' >> /etc/xbps.d/10-ignore.conf
  echo 'ignorepkg=linux-headers' >> /etc/xbps.d/10-ignore.conf

  # 3. PURGE THE OLD KERNEL FIRST: Completely strip out the live ISO's 6.12 kernel
  # This deletes the old modules, leaving ONLY the LTS kernel folders on the disk.
  xbps-remove -R linux linux-headers --yes || true
  vkpurge rm all
  # Install GRUB for EFI
   # Clean out default grub paths and inject the correct root configurations
  echo 'GRUB_DISTRIBUTOR="Void"' > /etc/default/grub
  echo "GRUB_CMDLINE_LINUX_DEFAULT=\"loglevel=4 root=UUID=$UUID_BTRFS rootflags=subvol=@ rootfstype=btrfs console=tty0 console=ttyAMA0,115200\"" >> /etc/default/grub
  echo 'GRUB_DISABLE_OS_PROBER=true' >> /etc/default/grub

  grub-install --target=arm64-efi --efi-directory=/boot/efi --bootloader-id=grub --recheck 
  # Generate GRUB config with btrfs support
  grub-mkconfig -o /boot/grub/grub.cfg
  

    
  # Verify EFI boot entry tracks
  efibootmgr -v || echo 'EFI boot entry mapped'

  # Enable the logging system services under runit framework
  ln -sf /etc/sv/socklog-unix /var/service/
  ln -sf /etc/sv/nanoklogd /var/service/
    ln -sf /etc/sv/sshd /var/service/
     ln -sf /etc/sv/ufw /var/service/
  ufw allow 5900:5905/tcp
  ufw allow 22

  # Schedule automatic routine system packages upgrades via crontab
  (crontab -l 2>/dev/null; echo '#update every 1st  every month') | crontab -
  (crontab -l 2>/dev/null; echo '0 2 1 * * xbps-install -Syu --yes && shutdown -r +1'; echo '@reboot vkpurge rm all') | crontab -
(crontab -l 2>/dev/null; echo '#docleanup every hour') | crontab -
(crontab -l 2>/dev/null; echo '0 * * * * find /var/cache/xbps -type f -mmin +60 -exec rm -f {} +') | crontab -
(crontab -l 2>/dev/null; echo '05 * * * * /usr/sbin/fstrim -a') | crontab -


 # 1. Kill the inherited, broken interface-locked service
  rm -f /var/service/dhcpcd-eth0
  # 2. Enable the universal network manager that dynamically scans all interfaces
  ln -sf /etc/sv/dhcpcd /var/service/
  
  # Force fallback compliance layout paths for UEFI auto-detection setups
  mkdir -p /boot/efi/EFI/BOOT
  cp /boot/efi/EFI/grub/grubaa64.efi /boot/efi/EFI/BOOT/BOOTAA64.EFI

    # Force dracut to rebuild the initramfs with btrfs storage support! if new kernel critical
 dracut --force --regenerate-all
  xbps-remove -O --yes
  # 2. Purge orphan dependencies that were pulled in but are no longer needed
  xbps-remove -o --yes
  # 3. Clear out inherited cache directories from the Live ISO clone operation
  rm -rf /var/cache/xbps/*
  fstrim -av / || echo "Fstrim skipped during installation context"
  btrfs balance start -dusage=50 -musage=50 / || true
EOF

echo "=== 12. Cleaning locks and sync mappings ==="
umount -R /mnt
sync
echo "SUCCESS! Machine is configured for OCI with EFI boot. Powering off now."
poweroff -f


