#!/bin/sh
set -e

# --- Configuration & Input Handling ---
FS_TYPE=""
INSTALL_MODE="wipe" # Options: wipe, manual
TARGET_EFI=""
TARGET_ROOT=""

while [ "$#" -gt 0 ]; do
    case "$1" in
        --btrfs) FS_TYPE="btrfs"; shift ;;
        --xfs)   FS_TYPE="xfs"; shift ;;
        --parts) 
            INSTALL_MODE="manual"
            TARGET_EFI="$2"
            TARGET_ROOT="$3"
            shift 3
            ;;
        *) echo "Unknown parameter: $1" >&2; exit 1 ;;
    esac
done

if [ -z "$FS_TYPE" ]; then
    echo "ERROR: Please specify a storage architecture choice: --btrfs or --xfs" >&2
    exit 1
fi

if [ "$INSTALL_MODE" = "manual" ] && { [ -z "$TARGET_EFI" ] || [ -z "$TARGET_ROOT" ]; }; then
    echo "ERROR: --parts requires exactly two arguments: <efi_partition> <root_partition>" >&2
    echo "Example: ./setup.sh --btrfs --parts /dev/sda1 /dev/sda4" >&2
    exit 1
fi

MODULE_FILE="./storage_${FS_TYPE}.sh"
if [ ! -f "$MODULE_FILE" ]; then
    echo "ERROR: Storage definitions module script not found: $MODULE_FILE" >&2
    exit 1
fi

chmod +x "$MODULE_FILE"

# --- System Preparation ---
sudo xbps-install -Syu
sudo xbps-install -uy xbps
sudo xbps-install parted -y

# --- Mode-Specific Partition Management ---
if [ "$INSTALL_MODE" = "wipe" ]; then
    echo "=== 1. Dynamically locating installation target drive ==="
    TARGET_DISK=$(lsblk -dnro NAME,TYPE,MOUNTPOINTS | awk '$2=="disk" && $3=="" {print $1; exit}')

    if [ -z "$TARGET_DISK" ]; then
        echo "ERROR: Could not automatically find an available destination drive!" >&2
        exit 1
    fi

    export DISK="/dev/$TARGET_DISK"
    export PART1="${DISK}1"
    export PART2="${DISK}2"
    echo "Target drive identified for full wipe: $DISK"

    echo "=== 2. Wiping target disk headers ==="
    wipefs -a "$DISK"

    echo "=== 3. Creating GPT Table ==="
    parted -s "$DISK" mklabel gpt

    # Execute original partitioning/formatting from selected file system module
    partition_and_format_wipe

else
    echo "=== 1. Manual Coexistence Mode Activated ==="
    if [ ! -b "$TARGET_EFI" ] || [ ! -b "$TARGET_ROOT" ]; then
        echo "ERROR: Specified partitions do not exist or are not valid block devices!" >&2
        exit 1
    fi
    
    export PART1="$TARGET_EFI"
    export PART2="$TARGET_ROOT"
    echo "Using existing EFI partition: $PART1"
    echo "Targeting root partition for clean installation: $PART2"
    echo "WARNING: Existing data on $PART2 will be wiped. $PART1 will be preserved."

    # Execute manual formatting/mounting from selected file system module
    format_and_mount_manual
fi

echo "=== 8. Cloning Live OS structures directly to Target ==="
cp -ax / /mnt

# --- Executing Dynamic FSTAB Setup ---
generate_fstab

echo "=== 10. Mounting runtime components for chroot wrapper ==="
mount --rbind /sys /mnt/sys && mount --make-rslave /mnt/sys
mount --rbind /dev /mnt/dev && mount --make-rslave /mnt/dev
mount --rbind /proc /mnt/proc && mount --make-rslave /mnt/proc
mount --bind /run /mnt/run && mount --make-slave /mnt/run

# --- Unified Multi-System Chroot Deploy Pipeline ---
echo "=== 11. Generating permanent self-sustained UEFI boot tracks ==="
UUID_FS=$(blkid -o value -s UUID "$PART2")

env UUID_FS="$UUID_FS" FS_TYPE="$FS_TYPE" FS_PKGS="$FS_PKGS" INSTALL_MODE="$INSTALL_MODE" chroot /mnt /bin/bash << 'EOF'
  set -e
  # Synchronize and download core system management packages
  xbps-install -Syu || true
  xbps-install -u xbps --yes
  
  # Install standard common tools combined with the custom filesystem packages
  xbps-install -Sy --yes grub-arm64-efi $FS_PKGS dhcpcd cronie nano xtools wget 7zip git
  xbps-install -Sy --yes curl tar parted vsv openssh socklog-void linux-lts linux-lts-headers
  xbps-install -y apparmor ufw fastfetch
   
  # Secure customized SSH tracking mapping 
  echo "Port 222" > /etc/ssh/sshd_config.d/ssh.conf
  ln -sf /etc/sv/cronie /var/service/

  # Enable serial console (essential for cloud platforms like OCI)
  cp -R /etc/sv/agetty-generic /etc/sv/agetty-ttyAMA0
  echo "ttyAMA0" > /etc/sv/agetty-ttyAMA0/conf
  echo "115200" >> /etc/sv/agetty-ttyAMA0/conf
  echo "linux" >> /etc/sv/agetty-ttyAMA0/conf
  echo "--autologin root" >> /etc/sv/agetty-ttyAMA0/conf
  ln -sf /etc/sv/agetty-ttyAMA0 /var/service/

  # Lock down the tracking table so general updates don't break kernel pinning
  echo 'ignorepkg=linux' >> /etc/xbps.d/10-ignore.conf
  echo 'ignorepkg=linux-headers' >> /etc/xbps.d/10-ignore.conf

  # PURGE THE OLD KERNEL FIRST: Completely strip out the live ISO's running kernel
  xbps-remove -R linux linux-headers --yes || true
  vkpurge rm all
  
  # Configure and build common GRUB settings with modern AppArmor protections active
  echo 'GRUB_DISTRIBUTOR="Void"' > /etc/default/grub
  
  if [ "$FS_TYPE" = "btrfs" ]; then
      echo "GRUB_CMDLINE_LINUX_DEFAULT=\"loglevel=4 root=UUID=$UUID_FS rootflags=subvol=@ rootfstype=btrfs console=tty0 console=ttyAMA0,115200 apparmor=1 security=apparmor\"" >> /etc/default/grub
  else
      echo "GRUB_CMDLINE_LINUX_DEFAULT=\"loglevel=4 root=UUID=$UUID_FS rootfstype=xfs console=tty0 console=ttyAMA0,115200 apparmor=1 security=apparmor\"" >> /etc/default/grub
  fi
  
  # Keep OS Prober enabled for side-by-side configurations to auto-detect Windows/Linux environments
  if [ "$INSTALL_MODE" = "manual" ]; then
      echo 'GRUB_DISABLE_OS_PROBER=false' >> /etc/default/grub
  else
      echo 'GRUB_DISABLE_OS_PROBER=true' >> /etc/default/grub
  fi

  grub-install --target=arm64-efi --efi-directory=/boot/efi --bootloader-id=grub --recheck 
  grub-mkconfig -o /boot/grub/grub.cfg
  
  efibootmgr -v || echo 'EFI boot entry mapped'

  # Enable core system services under runit framework
  ln -sf /etc/sv/socklog-unix /var/service/
  ln -sf /etc/sv/nanoklogd /var/service/
  ln -sf /etc/sv/sshd /var/service/
  ln -sf /etc/sv/ufw /var/service/
 
  # Schedule automatic routine system packages upgrades via crontab
  (crontab -l 2>/dev/null; echo '#update every 1st every month') | crontab -
  (crontab -l 2>/dev/null; echo '0 2 1 * * xbps-install -Syu --yes && shutdown -r +1'; echo '@reboot vkpurge rm all') | crontab -
  (crontab -l 2>/dev/null; echo '#docleanup every hour') | crontab -
  (crontab -l 2>/dev/null; echo '0 * * * * find /var/cache/xbps -type f -mmin +60 -exec rm -f {} +') | crontab -
  (crontab -l 2>/dev/null; echo '05 * * * * /usr/sbin/fstrim -a') | crontab -

  # Kill the inherited, broken interface-locked network service and set universal manager
  rm -f /var/service/dhcpcd-eth0
  ln -sf /etc/sv/dhcpcd /var/service/
  
  # Force fallback compliance layout paths for UEFI auto-detection setups
  mkdir -p /boot/efi/EFI/BOOT
  cp /boot/efi/EFI/grub/grubaa64.efi /boot/efi/EFI/BOOT/BOOTAA64.EFI

  # Force dracut to rebuild the initramfs with new storage drivers
  dracut --force --regenerate-all
  
  # Run structural system cleanup optimization commands
  xbps-remove -O --yes
  xbps-remove -o --yes
  rm -rf /var/cache/xbps/*
  fstrim -av / || echo "Fstrim skipped during installation context"

  # Source custom system optimizations if provided by the filesystem script
  if [ -f /tmp/fs_optimize.sh ]; then
      sh /tmp/fs_optimize.sh
      rm -f /tmp/fs_optimize.sh
  fi

  # Firewall rules adjusted to secure your modified Port 222 configuration
  ufw allow 5900:5905/tcp
  ufw allow 222/tcp
  ufw enable
EOF

echo "=== 12. Cleaning locks and sync mappings ==="
umount -R /mnt
sync
echo "SUCCESS! Machine is configured with EFI boot. Powering off now."
poweroff -f
