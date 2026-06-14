#!/bin/sh
: '
supports architecture autodetect buildmachine - if run on arm or intel
two storage options xfs or btrfs
Original Full Disk Wipe Mode (Destructive):
./setup.sh --btrfs
# OR
./setup.sh --xfs

DUAL BOOT / Safe Coexistence Mode (Preserves existing OS and EFI partition) :
bash# Syntax: ./setup.sh --<filesystem> --parts <efi_partition> <target_clean_partition>
./setup.sh --btrfs --parts /dev/nvme0n1p1 /dev/nvme0n1p4
# OR
./setup.sh --xfs --parts /dev/sda1 /dev/sda3

Building an Intel/AMD (x86_64) Target Image on an ARM64/Ampere machine :
./setup.sh --btrfs --arch x86_64
Building an Intel Target safely into specific partitions attached to your ARM machine:
./setup.sh --xfs --arch x86_64 --parts /dev/sdb1 /dev/sdb2
Standard Host Native Installation (Default) autodetects build machine:
./setup.sh --xfs

'

set -e

# --- Pre-Flight Internet Connectivity Check ---
echo "=== Pre-flight Check: Verifying active internet connectivity ==="
if ! curl -s --connect-timeout 5 https://voidlinux.org > /dev/null; then
    echo "ERROR: Active internet link could not be verified!" >&2
    exit 1
fi

# --- Configuration & Input Handling ---
FS_TYPE=""
INSTALL_MODE="wipe" 
TARGET_EFI=""
TARGET_ROOT=""
FORCE_ARCH="" # Captures cross-architecture target overrides

while [ "$#" -gt 0 ]; do
    case "$1" in
        --btrfs) FS_TYPE="btrfs"; shift ;;
        --xfs)   FS_TYPE="xfs"; shift ;;
        --arch)  FORCE_ARCH="$2"; shift 2 ;; # Allow passing '--arch x86_64' explicitly
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

# Determine Target vs Host Architecture
HOST_ARCH=$(uname -m)
if [ -n "$FORCE_ARCH" ]; then
    TARGET_ARCH="$FORCE_ARCH"
else
    TARGET_ARCH="$HOST_ARCH"
fi
# Standardize naming syntax maps
[ "$TARGET_ARCH" = "arm64" ] && TARGET_ARCH="aarch64"

echo "Host System Architecture: $HOST_ARCH"
echo "Target Image Architecture: $TARGET_ARCH"

# Host Prerequisites: If cross-building, the host MUST have emulation packages ready
if [ "$HOST_ARCH" != "$TARGET_ARCH" ]; then
    echo "=== Cross-Architecture Build Detected! Installing Host Emulation Layer ==="
    # Installs the static QEMU user space engines and kernel binary interpreters on host
    sudo xbps-install -Sy qemu-user-static-binfmt binfmt-support -y || true
fi

# --- Configure Target Architecture Profile Properties ---
case "$TARGET_ARCH" in
    x86_64)
        export GRUB_PKG="grub-x86_64-efi"
        export GRUB_TARGET="x86_64-efi"
        export EFI_FALLBACK_DIR="BOOT"
        export EFI_FALLBACK_BIN="BOOTX64.EFI"
        export GRUB_SRC_BIN="grubx64.efi"
        export QEMU_ARCH="x86_64"
        export XBPS_TARGET_ARCH="x86_64" # Crucial environment value for cross-xbps
        ;;
    aarch64)
        export GRUB_PKG="grub-arm64-efi"
        export GRUB_TARGET="arm64-efi"
        export EFI_FALLBACK_DIR="BOOT"
        export EFI_FALLBACK_BIN="BOOTAA64.EFI"
        export GRUB_SRC_BIN="grubaa64.efi"
        export QEMU_ARCH="aarch64"
        export XBPS_TARGET_ARCH="aarch64"
        ;;
    *)
        echo "ERROR: Unsupported target architecture: $TARGET_ARCH" >&2
        exit 1
        ;;
esac

# --- System Preparation ---
sudo xbps-install -Syu
sudo xbps-install -uy xbps
sudo xbps-install parted curl -y

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
    echo "=== 2. Wiping target disk headers ==="
    wipefs -a "$DISK"
    echo "=== 3. Creating GPT Table ==="
    parted -s "$DISK" mklabel gpt
    partition_and_format_wipe
else
    echo "=== 1. Manual Coexistence Mode Activated ==="
    export PART1="$TARGET_EFI"
    export PART2="$TARGET_ROOT"
    format_and_mount_manual
fi

echo "=== 8. Cloning Live OS structures directly to Target ==="
# Note: If cloning a running system to an alternative architecture image, we do NOT 
# want to inherit the host architectures binaries, or it causes severe library chaos.
cp -ax / /mnt

# --- CROSS ARCHITECTURE EMULATION JUMP HOOK ---
if [ "$HOST_ARCH" != "$TARGET_ARCH" ]; then
    echo "=== Injecting QEMU User Static Binary into Target Space ==="
    sudo mkdir -p /mnt/usr/bin
    sudo cp -f "/usr/bin/qemu-${QEMU_ARCH}-static" /mnt/usr/bin/
    
    # Ensure binary format execution rules are fully registered on the host machine
    if [ -f /etc/init.d/binfmt-support ]; then sudo /etc/init.d/binfmt-support restart; fi
    
    # Force initialize a clean native target package database to prevent host arch bleed
    echo "ARCH=$XBPS_TARGET_ARCH" > /mnt/etc/xbps.d/00-arch.conf
fi

# --- Executing Dynamic FSTAB Setup ---
generate_fstab

echo "=== 10. Mounting runtime components for chroot wrapper ==="
mount --rbind /sys /mnt/sys && mount --make-rslave /mnt/sys
mount --rbind /dev /mnt/dev && mount --make-rslave /mnt/dev
mount --rbind /proc /mnt/proc && mount --make-rslave /mnt/proc
mount --bind /run /mnt/run && mount --make-slave /mnt/run

echo "=== 11. Generating permanent self-sustained UEFI boot tracks ==="
UUID_FS=$(blkid -o value -s UUID "$PART2")

# We pass down XBPS_ARCH directly to force the chroot xbps system to operate inside target architecture mode
env UUID_FS="$UUID_FS" FS_TYPE="$FS_TYPE" FS_PKGS="$FS_PKGS" INSTALL_MODE="$INSTALL_MODE" \
    TARGET_ARCH="$TARGET_ARCH" GRUB_PKG="$GRUB_PKG" GRUB_TARGET="$GRUB_TARGET" \
    EFI_FALLBACK_DIR="$EFI_FALLBACK_DIR" EFI_FALLBACK_BIN="$EFI_FALLBACK_BIN" \
    GRUB_SRC_BIN="$GRUB_SRC_BIN" XBPS_ARCH="$XBPS_TARGET_ARCH" chroot /mnt /bin/bash << 'EOF'
  set -e
  
  # Synchronize packages forcing target repository profiles
  xbps-install -Syu || true
  xbps-install -u xbps --yes
  
  # Install tools matching target environment configurations
  xbps-install -Sy --yes $GRUB_PKG $FS_PKGS dhcpcd cronie nano xtools wget 7zip git
  xbps-install -Sy --yes curl tar parted vsv openssh socklog-void linux-lts linux-lts-headers
  xbps-install -y apparmor ufw fastfetch
   
  echo "Port 222" > /etc/ssh/sshd_config.d/ssh.conf
  ln -sf /etc/sv/cronie /var/service/

  if [ "$TARGET_ARCH" = "x86_64" ]; then
      ln -sf /etc/sv/agetty-tty1 /var/service/
  else
      cp -R /etc/sv/agetty-generic /etc/sv/agetty-ttyAMA0
      echo "ttyAMA0" > /etc/sv/agetty-ttyAMA0/conf
      echo "115200" >> /etc/sv/agetty-ttyAMA0/conf
      echo "linux" >> /etc/sv/agetty-ttyAMA0/conf
      echo "--autologin root" >> /etc/sv/agetty-ttyAMA0/conf
      ln -sf /etc/sv/agetty-ttyAMA0 /var/service/
  fi

  echo 'ignorepkg=linux' >> /etc/xbps.d/10-ignore.conf
  echo 'ignorepkg=linux-headers' >> /etc/xbps.d/10-ignore.conf

  xbps-remove -R linux linux-headers --yes || true
  vkpurge rm all
  
  echo 'GRUB_DISTRIBUTOR="Void"' > /etc/default/grub
  
  if [ "$TARGET_ARCH" = "x86_64" ]; then
      CMDLINE_CONSOLES="console=tty0"
  else
      CMDLINE_CONSOLES="console=tty0 console=ttyAMA0,115200"
  fi

  if [ "$FS_TYPE" = "btrfs" ]; then
      echo "GRUB_CMDLINE_LINUX_DEFAULT=\"loglevel=4 root=UUID=$UUID_FS rootflags=subvol=@ rootfstype=btrfs $CMDLINE_CONSOLES apparmor=1 security=apparmor\"" >> /etc/default/grub
  else
      echo "GRUB_CMDLINE_LINUX_DEFAULT=\"loglevel=4 root=UUID=$UUID_FS rootfstype=xfs $CMDLINE_CONSOLES apparmor=1 security=apparmor\"" >> /etc/default/grub
  fi
  
  if [ "$INSTALL_MODE" = "manual" ]; then
      echo 'GRUB_DISABLE_OS_PROBER=false' >> /etc/default/grub
  else
      echo 'GRUB_DISABLE_OS_PROBER=true' >> /etc/default/grub
  fi

  # Forces grub-install to output structural architecture profiles mapping target requirements
  grub-install --target=$GRUB_TARGET --efi-directory=/boot/efi --bootloader-id=grub --recheck --no-nvram
  grub-mkconfig -o /boot/grub/grub.cfg
  
  # Skip real efibootmgr hardware mapping calls if running in a simulated target space
  if [ "$(uname -m)" = "$TARGET_ARCH" ]; then
      efibootmgr -v || echo 'EFI boot entry mapped'
  else
      echo "Cross-compiling environment: NVRAM variable synchronization skipped."
  fi

  ln -sf /etc/sv/socklog-unix /var/service/
  ln -sf /etc/sv/nanoklogd /var/service/
  ln -sf /etc/sv/sshd /var/service/
  ln -sf /etc/sv/ufw /var/service/
 
  (crontab -l 2>/dev/null; echo '#update every 1st every month') | crontab -
  (crontab -l 2>/dev/null; echo '0 2 1 * * xbps-install -Syu --yes && shutdown -r +1'; echo '@reboot vkpurge rm all') | crontab -
  (crontab -l 2>/dev/null; echo '#docleanup every hour') | crontab -
  (crontab -l 2>/dev/null; echo '0 * * * * find /var/cache/xbps -type f -mmin +60 -exec rm -f {} +') | crontab -
  (crontab -l 2>/dev/null; echo '05 * * * * /usr/sbin/fstrim -a') | crontab -

  rm -f /var/service/dhcpcd-eth0
  ln -sf /etc/sv/dhcpcd /var/service/
  
  mkdir -p /boot/efi/EFI/$EFI_FALLBACK_DIR
  cp /boot/efi/EFI/grub/$GRUB_SRC_BIN /boot/efi/EFI/$EFI_FALLBACK_DIR/$EFI_FALLBACK_BIN

  # CRITICAL X86 CROSS-COMPILATION DRACUT INJECTION TWEAK:
  # Dracut running inside QEMU emulation fails auto-detecting core storage modules. 
  # We force find the newly installed LTS kernel directory name inside /lib/modules dynamically.
  TARGET_KERNEL_VERSION=$(ls -1 /lib/modules | head -n 1)
  echo "Building Initramfs Storage Track Drivers for Kernel version: $TARGET_KERNEL_VERSION"
  dracut --force --kver "$TARGET_KERNEL_VERSION" --regenerate-all
  
  xbps-remove -O --yes
  xbps-remove -o --yes
  rm -rf /var/cache/xbps/*
  
  if [ "$(uname -m)" = "$TARGET_ARCH" ]; then
      fstrim -av / || echo "Fstrim skipped"
  fi

  if [ -f /tmp/fs_optimize.sh ]; then
      sh /tmp/fs_optimize.sh
      rm -f /tmp/fs_optimize.sh
  fi

  ufw allow 5900:5905/tcp
  ufw allow 222/tcp
  ufw enable
EOF

# --- Post-Chroot Cleanup of Emulation Hooks ---
if [ "$HOST_ARCH" != "$TARGET_ARCH" ]; then
    rm -f "/mnt/usr/bin/qemu-${QEMU_ARCH}-static"
fi

echo "=== 12. Cleaning locks and sync mappings ==="
umount -R /mnt
sync
echo "SUCCESS! Target Cross-Architecture Image Build Complete."

# Never force-poweroff a host if preparing a target image loop disk 
if [ "$HOST_ARCH" != "$TARGET_ARCH" ] || [ "$INSTALL_MODE" = "manual" ]; then
    echo "Image preparation wrapper completed successfully. Exiting clean."
else
    poweroff -f
fi
