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
#set -e
export XBPS_ARCH="$XBPS_TARGET_ARCH"
export REPO_URL="https://repo-default.voidlinux.org/current"
#export XBPS_REPOSITORY="https://repo-default.voidlinux.org/current"
#"https://void.sakamoto.pl/current"

yes | xi -Syu nano curl parted

# ==============================================================================
# PHASE 0: PRE-FLIGHT SYSTEM VERIFICATIONS
# ==============================================================================
echo "=== Pre-flight Check: Verifying active internet connectivity ==="
if ! curl -s --connect-timeout 5 https://voidlinux.org > /dev/null; then
    echo "ERROR: Active internet link could not be verified!" >&2
    exit 1
fi

# ==============================================================================
# PHASE 1: CONFIGURATION & INPUT ARGUMENT HANDLING
# ==============================================================================
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FS_TYPE=""
INSTALL_MODE="wipe"
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
    echo "ERROR: Please specify --btrfs or --xfs" >&2
    exit 1
fi

MODULE_FILE="${SCRIPT_DIR}/storage_${FS_TYPE}.sh"
if [ ! -f "$MODULE_FILE" ]; then
    echo "ERROR: Storage module not found: $MODULE_FILE" >&2
    exit 1
fi

# ==============================================================================
# PHASE 2: HARDWARE ARCHITECTURE
# ==============================================================================
HOST_ARCH=$(uname -m)
TARGET_ARCH="$HOST_ARCH"
[ "$TARGET_ARCH" = "arm64" ] && TARGET_ARCH="aarch64"

case "$TARGET_ARCH" in
    x86_64)
        export GRUB_PKG="grub-x86_64-efi"; export GRUB_TARGET="x86_64-efi"
        export EFI_FALLBACK_DIR="BOOT"; export EFI_FALLBACK_BIN="BOOTX64.EFI"
        export GRUB_SRC_BIN="grubx64.efi"; export XBPS_TARGET_ARCH="x86_64"
        # export REPO_URL="https://voidlinux.org"
        ;;
    aarch64)
        export GRUB_PKG="grub-arm64-efi"; export GRUB_TARGET="arm64-efi"
        export EFI_FALLBACK_DIR="BOOT"; export EFI_FALLBACK_BIN="BOOTAA64.EFI"
        export GRUB_SRC_BIN="grubaa64.efi"; export XBPS_TARGET_ARCH="aarch64"
         export REPO_URL="${REPO_URL}/aarch64"
                ;;
    *)
        echo "ERROR: Unsupported architecture: $TARGET_ARCH" >&2
        exit 1
        ;;
esac

# ==============================================================================
# PHASE 3: STORAGE MODULE SOURCING
# ==============================================================================
. "$MODULE_FILE"

# Define FS_PKGS based on file system type (set by module or define here)
if [ -z "$FS_PKGS" ]; then
    case "$FS_TYPE" in
        btrfs) export FS_PKGS="btrfs-progs" ;;
        xfs)   export FS_PKGS="xfsprogs" ;;
    esac
fi

# ==============================================================================
# PHASE 4: TARGET DRIVE PARTITION & FILE SYSTEM INITIALIZATION
# ==============================================================================
if [ "$INSTALL_MODE" = "wipe" ]; then
    echo "=== 1. Locating target drive ==="
    TARGET_DISK=$(lsblk -dnro NAME,TYPE,MOUNTPOINTS | awk '$2=="disk" && $3=="" {print $1; exit}')
    if [ -z "$TARGET_DISK" ]; then
        echo "ERROR: No available destination drive found!" >&2; exit 1
    fi
    export DISK="/dev/$TARGET_DISK"

    # Correctly handle naming for NVMe vs SATA
    if echo "$DISK" | grep -q "nvme"; then
        export PART1="${DISK}p1"
        export PART2="${DISK}p2"
    else
        export PART1="${DISK}1"
        export PART2="${DISK}2"
    fi

    echo "Targeting: $DISK"
    wipefs -a "$DISK"
    parted -s "$DISK" mklabel gpt

    partition_and_format_wipe
else
    export PART1="$TARGET_EFI"
    export PART2="$TARGET_ROOT"
    format_and_mount_manual
fi

# ==============================================================================
# PHASE 5: MOUNT & CHROOT ENTRY
# ==============================================================================
#mkdir -p /mnt/etc/xbps.d
#echo "ignorepkg=linux" > /mnt/etc/xbps.d/00-block-kernel.conf
# BOOTSTRAP: Install pristine base system files directly into the target mount
# This safely creates a minimal, flawless /etc with no host programs installed!
echo "Bootstrapping minimal base layout..."

# Setup target structure
mkdir -p /mnt/var/cache/xbps /mnt/dev /mnt/proc /mnt/sys /mnt/run /mnt/tmp /mnt/usr/bin /mnt/root /mnt/etc

# Cross-arch fix: Copy qemu static if needed
if [ "$HOST_ARCH" != "$TARGET_ARCH" ]; then
    cp "/usr/bin/qemu-${TARGET_ARCH}-static" /mnt/usr/bin/ 2>/dev/null || true
fi

mkdir -p /mnt/var/db/xbps/keys /mnt/etc /mnt/boot/efi

# 2. Copy validation keys and network DNS so xbps can reach the internet
cp -r /var/db/xbps/keys/* /mnt/var/db/xbps/keys/ 2>/dev/null || true
cp /etc/resolv.conf /mnt/etc/resolv.conf

# 3. Mount all host virtual environments needed for construction
mount --rbind /sys /mnt/sys && mount --make-rslave /mnt/sys
mount --rbind /dev /mnt/dev && mount --make-rslave /mnt/dev
mount --rbind /proc /mnt/proc && mount --make-rslave /mnt/proc
mount --bind /run /mnt/run && mount --make-slave /mnt/run
mount -t efivarfs efivarfs /mnt/sys/firmware/efi/efivars || true
# 4. Bootstrap the absolute baseline files directly from the repository
echo "Bootstrapping minimal base layout from $REPO_URL..."
# Without this 0-byte file, xbps-install -r will fail on empty targets!
touch /mnt/var/db/xbps/.pkgdb-0.plist
cp -a /var/db/xbps/keys/. /mnt/var/db/xbps/keys/ 2>/dev/null || true
cp -r /etc/ssl /mnt/etc/
cp -r /etc/ca-certificates /mnt/etc/
if [ -d "/host/binpkgs" ]; then
    LOCAL_REPO="/host/binpkgs"
else
    # Fallback search path if your live ISO mounts partitions differently
    LOCAL_REPO=$(find /run /pkgs /usr / -maxdepth 3 -type d -name "current" -print -quit 2>/dev/null)
fi

rm -rf /mnt/var/cache/xbps/*
xbps-install -S -R "$REPO_URL" -r /mnt
xbps-install -vSy -R "$REPO_URL" -r /mnt base-system base-files bash linux-firmware grub || {
    echo "ERROR: Failed to install bash in target system" >&2
    exit 1
}
#xbps-install -vSy -R "$REPO_URL" -r /mnt base-files

echo 'after'
#xbps-install -C /etc/xbps.d -S -y -r /mnt base-files || true
# Check if the essential files were actually written to your disk
if [ -f "/mnt/etc/passwd" ] && [ -d "/mnt/usr/lib" ]; then
    echo "Verification passed: Core directory structure exists."
else
    echo "ERROR: Directories are empty. base-files install did not execute correctly." >&2
    exit 1
fi
echo "DEBUG: TARGET_ARCH=$TARGET_ARCH"
echo "DEBUG: XBPS_TARGET_ARCH=$XBPS_TARGET_ARCH"
echo "DEBUG: XBPS_ARCH=$XBPS_ARCH"
echo "DEBUG: REPO_URL=$REPO_URL"

sync
generate_fstab
mkdir -p /mnt/sys/firmware/efi/efivars
mount -t efivarfs efivarfs /mnt/sys/firmware/efi/efivars || true
cp /etc/resolv.conf /mnt/etc/resolv.conf

mkdir -p /mnt/etc/ssl/certs          # <- create the path
mkdir -p /mnt/etc/ca-certificates
cp -a /etc/ssl /mnt/etc

mkdir -p /mnt/etc/dracut.conf.d

cat > /mnt/etc/dracut.conf <<EOF
hostonly="no"
compress="xz"
EOF

sudo mkdir -p /mnt/etc/dracut.conf.d
sudo tee /mnt/etc/dracut.conf.d/10-xfs.conf <<EOF
hostonly="yes"
add_drivers+=" ${FS_TYPE} "
omit_dracutmodules+=" systemd systemd-initrd systemd-networkd "
EOF
# ==============================================================================
# PHASE 6: CHROOT ENTRY (Package installation happens here)
# ==============================================================================
env UUID_FS="$UUID_FS" FS_TYPE="$FS_TYPE" FS_PKGS="$FS_PKGS" INSTALL_MODE="$INSTALL_MODE" \
    TARGET_ARCH="$TARGET_ARCH" GRUB_PKG="$GRUB_PKG" GRUB_TARGET="$GRUB_TARGET" \
    EFI_FALLBACK_DIR="$EFI_FALLBACK_DIR" EFI_FALLBACK_BIN="$EFI_FALLBACK_BIN" \
    GRUB_SRC_BIN="$GRUB_SRC_BIN" XBPS_ARCH="$XBPS_TARGET_ARCH" REPO_URL="$REPO_URL" \
   xchroot /mnt /bin/bash << 'EOF'
source /etc/profile
ldconfig
echo "installing xbps and packages"

#critical for xbps to work
echo "Checking for /var/db/xbps/keys:"
ls -la /var/db/xbps/keys/ || echo "Keys directory is EMPTY!"
# Test DNS
mkdir -p /var/spool/cron
chmod 1777 /var/spool/cron
mkdir -p /var/tmp
chmod 1777 /var/tmp
mkdir -p /var/run /var/log
chmod 755 /var/run /var/log
#mkdir -p /dev /dev/pts /proc /sys
#mount -t proc proc /proc
#mount -t sysfs sysfs /sys
#mount -t devtmpfs dev /dev
#mount -t devpts devpts /dev/pts -o gid=5,mode=620

# Create EFI directory structure
mkdir -p /boot/efi/EFI/BOOT /boot/efi/EFI/grub
chmod 755 /boot/efi /boot/efi/EFI /boot/efi/EFI/BOOT

#chmod 755 /boot/efi /boot/efi/Default 2>/dev/null || true

mount -o rw,remount /boot/efi          # make sure EFI is writable
mkdir -p /boot/efi/Default
chmod 755 /boot/efi/Default

xbps-install -Syu || true
xbps-install -u xbps --yes

xbps-install -Sy --yes  \
base-files "$GRUB_PKG" "$FS_PKGS" \
linux-lts linux-lts-headers mesa-dri linux-firmware \
dhcpcd cronie nano xtools wget \
p7zip git curl tar parted vsv \
openssh socklog-void apparmor ufw fastfetch dracut

# ==============================================================================
# FIX RUNIT STRUCTURE WITH PROPER PERMISSIONS
# ==============================================================================
echo "🔧 Setting up runit supervision with proper permissions..."

# Create runit directories
mkdir -p /etc/runit /etc/sv
chmod 755 /etc/runit /etc/sv

# Create runit runsvdir structure
mkdir -p /etc/runit/runsvdir/default
chmod 755 /etc/runit/runsvdir/default

# Remove any existing broken symlinks
rm -f /etc/runit/runsvdir/current
rm -rf /var/service

# Create /var/service as symlink to runsvdir/default
mkdir -p /var/run/runit
chmod 755 /var/run/runit
ln -sf /etc/runit/runsvdir/default /var/service
chmod 755 /var/service

# Create runsvdir/current symlink
ln -sf default /etc/runit/runsvdir/current
chmod 755 /etc/runit/runsvdir/current

# Fix permissions on all /etc/sv/ service directories
chmod -R 755 /etc/sv/*/
find /etc/sv -type f -name "run" -exec chmod 755 {} \;
find /etc/sv -type f -name "finish" -exec chmod 755 {} \;
find /etc/sv -type f -name "check" -exec chmod 755 {} \;

echo "✅ Runit structure ready"

# Configure GRUB using echo instead of sed
echo "Configuring GRUB..."
cat > /etc/default/grub <<EOG
GRUB_DISTRIBUTOR="Void"
GRUB_PRELOAD_MODULES="$([ "$FS_TYPE" = "btrfs" ] && echo "btrfs" || echo "xfs")"
GRUB_CMDLINE_LINUX_DEFAULT="loglevel=4 root=UUID=${FS_TYPE:+"$([ "$FS_TYPE" = "btrfs" ] && echo "$UUID_BTRFS" || echo "$UUID_FS")"} rootflags=${FS_TYPE:+"$([ "$FS_TYPE" = "btrfs" ] && echo "subvol=@" [...]
GRUB_DISABLE_OS_PROBER=true
EOG

echo 'Installing GRUB...'
mkdir -p /boot/efi/EFI/BOOT
/usr/sbin/grub-install --target="$GRUB_TARGET" --efi-directory=/boot/efi --bootloader-id=VOID --recheck
echo 'Generating GRUB config...'
grub-mkconfig -o /boot/grub/grub.cfg 2>&1 | tee /tmp/grub-mkconfig.log

echo 'grub install'
mkdir -p /boot/efi/EFI/BOOT
/usr/sbin/grub-install --target="$GRUB_TARGET" --efi-directory=/boot/efi --bootloader-id=VOID --recheck
#echo 'grub mkconfig'
#grub-mkconfig -o /boot/grub/grub.cfg 2>&1 | tee /tmp/grub-mkconfig.log

# Core runtime services initialization
ln -sf /etc/sv/apparmor /var/service/ 2>/dev/null || true
ln -sf /etc/sv/cronie /var/service/ 2>/dev/null || true
ln -sf /etc/sv/socklog-unix /var/service/ 2>/dev/null || true
ln -sf /etc/sv/nanoklogd /var/service/ 2>/dev/null || true
ln -sf /etc/sv/sshd /var/service/ 2>/dev/null || true
ln -sf /etc/sv/ufw /var/service/ 2>/dev/null || true

cp -R /etc/sv/agetty-generic /etc/sv/agetty-ttyAMA0
chmod 755 /etc/sv/agetty-ttyAMA0
echo "ttyAMA0" > /etc/sv/agetty-ttyAMA0/conf
echo "115200" >> /etc/sv/agetty-ttyAMA0/conf
echo "linux" >> /etc/sv/agetty-ttyAMA0/conf
echo "--autologin root" >> /etc/sv/agetty-ttyAMA0/conf
ln -sf /etc/sv/agetty-ttyAMA0 /var/service/

# Scheduled maintenance tasks via cron
# Monthly system update and reboot
(crontab -l 2>/dev/null; echo '# Update every 1st of the month') | crontab -
(crontab -l 2>/dev/null; echo '0 2 1 * * xbps-install -Syu --yes && shutdown -r +1') | crontab -

# Hourly cache cleanup
(crontab -l 2>/dev/null; echo '# Cleanup cache every hour') | crontab -
(crontab -l 2>/dev/null; echo '0 * * * * find /var/cache/xbps -type f -mmin +60 -exec rm -f {} +') | crontab -

# Hourly SSD trim
(crontab -l 2>/dev/null; echo '05 * * * * /usr/sbin/fstrim -a') | crontab -

# Network configuration
rm -f /var/service/dhcpcd-eth0
ln -sf /etc/sv/dhcpcd /var/service/ 2>/dev/null || true

# Firewall configuration
ufw allow 5900:5905/tcp
ufw allow 222/tcp
ufw --force enable || echo "Firewall state configured for first boot"

echo "== mounts =="
mount | grep -E ' /boot/efi | /boot/efi '

echo "== type/space =="
df -hT /boot/efi

echo "== dirs =="
ls -ld /boot/efi /boot/efi/Default || true
findmnt -n -o SOURCE /boot/efi || true

echo "== write test =="
mkdir -p /boot/efi/Default && touch /boot/efi/Default/write_test_$$ && rm -f /boot/efi/Default/write_test_$$ && echo OK || echo FAIL
# Initramfs generation
TARGET_KERNEL_VERSION=$(ls -1 /lib/modules | head -n 1)
echo "Building Initramfs Storage Track Drivers for Kernel version: $TARGET_KERNEL_VERSION"
#dracut --force --hostonly --add "xfs"

 mkdir -p /boot/efi/EFI/BOOT
 dracut --force --regenerate-all
#xbps-reconfigure -fa linux-lts

xbps-reconfigure -f linux-lts
update-grub
grub-mkconfig -o /boot/grub/grub.cfg
#dracut --force /boot/initramfs-$(uname -r).img $(uname -r) --add 'xfs'
#£ dracut --force --regenerate-all --add 'xfs efi-vars'
# --add 'efi-vars'
# Cleanup orphaned packages and cache
xbps-remove -O --yes
xbps-remove -o --yes
rm -rf /var/cache/xbps/*

# Skip NVRAM operations in cross-compilation environments
if [ "$(uname -m)" = "$TARGET_ARCH" ]; then
    efibootmgr -v || echo 'EFI boot entry mapped'
else
    echo "Cross-compiling environment: NVRAM variable synchronization skipped."
fi

#prints
#grub-mkconfig -T -o /boot/grub/grub.cfg   # -T = test mode, prints errors only
echo 'boot folder:'
ls /boot
# 2️⃣  Confirm XFS driver is inside the initramfs
#lsinitrd /boot/initramfs-$(uname -r).img | grep xfs

# 3️⃣  Look at the generated menuentry (should contain the UUID you passed)
#grep -A2 '^menuentry' /boot/grub/grub.cfg | head -n 6
cat /boot/grub/grub.cfg

# Create fallback EFI boot file
if [ "$INSTALL_MODE" = "wipe" ]; then
    echo 'Creating fallback EFI boot file'
    cp "/boot/efi/EFI/grub/$GRUB_SRC_BIN" "/boot/efi/EFI/BOOT/$EFI_FALLBACK_BIN"
fi

# Trim filesystem if native architecture
if [ "$(uname -m)" = "$TARGET_ARCH" ]; then
    fstrim -a  || echo "Fstrim skipped"
fi

# Call file system-specific optimizations if available
if [ -f /tmp/fs_optimize.sh ]; then
    sh /tmp/fs_optimize.sh
    rm -f /tmp/fs_optimize.sh
fi
EOF
####END
mkdir -p /etc/kernel/post-install.d
cat > /etc/kernel/post-install.d/99-update-boot <<'EFF'
mount -o remount,rw /boot/efi
touch /boot/efi/Default/test_write_$$ 2>&1 | cat
ls -ld /boot/efi /boot/efi/Default || true
KVER="$1"
if command -v dracut >/dev/null 2>&1; then
  dracut --force --kver "$KVER" --hostonly --add "xfs"
fi
grub-mkconfig -o /boot/grub/grub.cfg || true


EFF
chmod +x /etc/kernel/post-install.d/99-update-boot

# Cleanup
umount -flR /mnt || true
sync
echo "SUCCESS!"
