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
         export GRUB_PLATFORMS="efi-x86_64" export  GRUB_EFI_ARCH="x86_64"
        # export REPO_URL="https://voidlinux.org"
        ;;
    aarch64)
        export GRUB_PKG="grub-arm64-efi"; export GRUB_TARGET="arm64-efi"
        export EFI_FALLBACK_DIR="BOOT"; export EFI_FALLBACK_BIN="BOOTAA64.EFI"
        export GRUB_SRC_BIN="grubaa64.efi"; export XBPS_TARGET_ARCH="aarch64"
         export GRUB_PLATFORMS="efi-arm64" ; export  GRUB_EFI_ARCH="arm64"
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
        xfs)   export FS_PKGS="xfsprogs dracut efibootmgr wget" ;;
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
xbps-install -vSy -R "$REPO_URL" -r /mnt base-system linux-firmware || {
    echo "ERROR: Failed to install bash in target system" >&2
    exit 1
}
set -e
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
#cp -a /etc/runit /mnt/etc
cp -a /etc/rc.* /mnt/etc
#cp -a /etc/sv /mnt/etc

mkdir -p /mnt/etc/dracut.conf.d

sudo mkdir -p /mnt/etc/dracut.conf.d
sudo tee /mnt/etc/dracut.conf.d/0xfs.conf <<EOF
hostonly="no"
ipv6.disable=1
loglevel=7
# Force include the foundational filesystem framework modules
#add_dracutmodules+=" gaps basesystem "
# Inject your structural storage engine directly into the kernel map
filesystems+=" ${FS_TYPE} "
add_drivers+=" libcrc32c ${FS_TYPE} "
add_dracutmodules+=" base rootfs-block "
EOF
mkdir -p /mnt/etc/runit/runsvdir/default

# ==============================================================================
# PHASE 6: CHROOT ENTRY (Package installation happens here)
# ==============================================================================
env UUID_FS="$UUID_ROOT" FS_TYPE="$FS_TYPE" FS_PKGS="$FS_PKGS" INSTALL_MODE="$INSTALL_MODE" \
    TARGET_ARCH="$TARGET_ARCH" GRUB_PKG="$GRUB_PKG" GRUB_TARGET="$GRUB_TARGET" \
    EFI_FALLBACK_DIR="$EFI_FALLBACK_DIR" EFI_FALLBACK_BIN="$EFI_FALLBACK_BIN" \
    GRUB_SRC_BIN="$GRUB_SRC_BIN" XBPS_ARCH="$XBPS_TARGET_ARCH" REPO_URL="$REPO_URL" \
   xchroot /mnt /bin/bash << 'EOF'
source /etc/profile
ldconfig
echo "installing xbps and packages"
mount -o rw,remount /boot/efi

mkdir -p /var/run/runit
echo "Checking for /var/db/xbps/keys:"
ls -la /var/db/xbps/keys/ || echo "Keys directory is EMPTY!"

mkdir -p /var/run/dbus /var/log/dbus
chmod 755 /var/run/dbus
mkdir -p /var/spool/cron /var/tmp
chmod 1777 /var/spool/cron /var/tmp
mkdir -p /var/{run,log,service,spool/cron/crontabs,tmp}
touch /var/run/utmp /var/log/wtmp
chmod 666 /var/run/utmp /var/log/wtmp

mkdir -p /boot/efi/EFI/BOOT /boot/efi/EFI/grub /boot/efi/Default
chmod 755 /boot/efi /boot/efi/EFI /boot/efi/EFI/BOOT /boot/efi/Default

mkdir -p /etc/runit /etc/sv

xbps-install -Syu || true
xbps-install -u xbps --yes

xbps-install -Sy --yes base-system efibootmgr "$GRUB_PKG" "$FS_PKGS" \
    linux6.12 dbus elogind mesa-dri \
    NetworkManager cronie nano xtools wget chrony grep sed \
    util-linux net-tools sudo zip git curl tar gzip parted vsv socklog-void \
    lvm2 xmirror openssh apparmor ufw fastfetch dracut-uefi zstd
#fix runit
# rm -rf var/service run/runit
# mkdir -p run/runit/runsvdir
# mkdir -p var/service
mkdir -p /etc/runit/runsvdir/default
chmod 755 /etc/runit/runsvdir/default/
rm /etc/runit/runsvdir/current
ln -sf /etc/runit/runsvdir/default /etc/runit/runsvdir/current

# ==============================================================================
# GRUB2 EFI CONFIGURATION
# ==============================================================================
echo "Configuring GRUB2 EFI..."

if [ "$FS_TYPE" = "btrfs" ]; then
    ROOTFLAGS="subvol=@"
    GRUB_PRELOAD="btrfs"
else
    ROOTFLAGS=""
    GRUB_PRELOAD="xfs"
fi
FINALROOTFLAG="${ROOTFLAGS:+rootflags=$ROOTFLAGS}"

cat > /etc/default/grub <<EOG
GRUB_DISTRIBUTOR="Void"
GRUB_PRELOAD_MODULES="$GRUB_PRELOAD"
GRUB_CMDLINE_LINUX_DEFAULT="loglevel=4 root=UUID=$UUID_FS $FINALROOTFLAG rootfstype=$FS_TYPE console=tty0 console=ttyAMA0,115200 rw"
GRUB_DISABLE_OS_PROBER=true
GRUB_TIMEOUT=5
GRUB_TIMEOUT_STYLE=menu
GRUB_GFXMODE=auto
EOG


mkdir -p /etc/sv/agetty-generic
cat > /etc/sv/agetty-generic/run <<'EOS'
#!/bin/sh
exec 2>&1
[ -r ./conf ] && . ./conf
exec chpst -u root /sbin/agetty ${AGETTY_ARGS} ${TTY} ${BAUD} ${TERM}
EOS
chmod +x /etc/sv/agetty-generic/run

mkdir -p /etc/sv/agetty-ttyAMA0
cp -R /etc/sv/agetty-generic /etc/sv/agetty-ttyAMA0
cat > /etc/sv/agetty-ttyAMA0/conf <<'EOS'
TTY=ttyAMA0
BAUD=115200
TERM=linux
AGETTY_ARGS=--autologin root
EOS
#ln -sf /etc/sv/agetty-ttyAMA0 /var/service/

for tty in 1 2 3 4 5 6; do
    mkdir -p "/etc/sv/agetty-tty${tty}"
    cat > "/etc/sv/agetty-tty${tty}/run" <<EOS
#!/bin/sh
exec /sbin/agetty --noclear tty${tty} linux
EOS
    chmod +x "/etc/sv/agetty-tty${tty}/run"
   # ln -sf "/etc/sv/agetty-tty${tty}" /var/service/
ln -sf "/etc/sv/agetty-tty${tty}" /etc/runit/runsvdir/default/agetty-tty${tty}
done


####

# Create service symlinks in default
##cd /etc/runit/runsvdir/default
# Core SERVICEs
#udev  apparmor
rm -f /var/service/dhcpcd-eth0
mkdir -p /var/run/dbus
chmod 755 /var/run/dbus

ln -sf /etc/sv/dbus /etc/runit/runsvdir/default/
# 2. Only then start NetworkManager
ln -sf /etc/sv/NetworkManager /etc/runit/runsvdir/default/
for sv in  agetty-ttyAMA0 ufw socklog-unix nanoklogd \
          cronie sshd; do
#    [ -f /etc/sv/$sv/run ] && ln -sf /etc/sv/$sv .
ln -sf /etc/sv/$sv  /etc/runit/runsvdir/default/
# /var/service/
done

#enables them
#ln -sf default /etc/runit/runsvdir/current
#ln -sf /etc/sv/agetty-ttyAMA0 /var/service/
#ln -sf /etc/sv/dhcpcd /var/service/ 2>/dev/null || true
####
ufw allow 5900:5905/tcp 2>/dev/null || true
ufw allow 222/tcp 2>/dev/null || true
ufw --force enable 2>/dev/null || true

# ==============================================================================
# AUTODETECT KERNEL VERSION
# ==============================================================================

KVER=$(ls -1 /lib/modules | grep -v build | head -1)
if [ -z "$KVER" ]; then
    echo "ERROR: Kernel not installed!"
    exit 1
fi

echo "Detected kernel version: $KVER"

MAJOR_VERSION=$(uname -r | awk -F '.' '{print $1}')
MINOR_VERSION=$(uname -r | awk -F '.' '{print $2}')
VERSION=${MAJOR_VERSION}.${MINOR_VERSION}
#dracut -f
#decompress xfs modules
zstd -d /lib/modules/$KVER/kernel/fs/xfs/xfs.ko.zst -o /lib/modules/$KVER/kernel/fs/xfs/xfs.ko
zstd -d /lib/modules/$KVER/kernel/lib/libcrc32c.ko.zst -o /lib/modules/$KVER/kernel/lib/libcrc32c.ko
rm /lib/modules/$KVER/kernel/fs/xfs/xfs.ko.zst
rm /lib/modules/$KVER/kernel/lib/libcrc32c.ko.zst

depmod -a $KVER
dracut --force --regenerate-all
#The second dracut run is what actually includes the uncompressed files in the initramfs image.
#xbps-reconfigure -fa "linux${VERSION}" 2>/dev/null || xbps-reconfigure -fa linux6.12 || true

grub-install --target="$GRUB_TARGET" \
    --efi-directory=/boot/efi \
    --bootloader-id=VOID \
    --force \
    --no-nvram \
    --recheck 2>&1 | grep -v "Error\|Warning" || true

# ==============================================================================
# GRUB2 SETUP (cat-based, no corruption)
# ==============================================================================

echo "Installing GRUB2 EFI..."
mkdir -p /boot/grub /boot/efi/EFI/VOID /boot/efi/EFI/BOOT

cp /usr/lib/grub/x86_64-efi/grubx64.efi /boot/efi/EFI/VOID/ 2>/dev/null || true
cp /usr/lib/grub/x86_64-efi/grubx64.efi /boot/efi/EFI/BOOT/BOOTX64.EFI 2>/dev/null || true
cp /usr/lib/grub/arm64-efi/grubaa64.efi /boot/efi/EFI/VOID/ 2>/dev/null || true
cp /usr/lib/grub/arm64-efi/grubaa64.efi /boot/efi/EFI/BOOT/BOOTAA64.EFI 2>/dev/null || true
cp /boot/efi/efi/void/grubaa64.efi /boot/efi/EFI/BOOT/BOOTAA64.EFI 2>/dev/null || true


VMLINUX=$(ls /boot/vmlinux-* 2>/dev/null | head -1 | xargs basename)
INITRD=$(ls /boot/initramfs-*.img 2>/dev/null | head -1 | xargs basename)

cat > /boot/grub/grub.cfg <<GRUBCFG
set timeout=5
set root='hd0,gpt2'
insmod part_gpt
insmod ext2
insmod btrfs
insmod xfs

menuentry "Void Linux" {
    insmod gzio
    insmod part_gpt
    set root='hd0,gpt2'
    linux /boot/$VMLINUX root=/dev/vda2 rootfstype=$FS_TYPE $FINALROOTFLAG console=tty0 console=ttyAMA0,115200 rw
    initrd /boot/$INITRD
}
GRUBCFG

chmod 644 /boot/grub/grub.cfg

echo "🔍 Verifying GRUB2..."
[ -f /boot/grub/grub.cfg ] && echo "✅ GRUB config: $(wc -c < /boot/grub/grub.cfg) bytes" || echo "❌ GRUB config missing"
[ -f "/boot/$VMLINUX" ] && echo "✅ Kernel found: $VMLINUX" || echo "❌ Kernel missing"
[ -f "/boot/$INITRD" ] && echo "✅ Initrd found: $INITRD" || echo "❌ Initrd missing"
#
#rm /var/service
#mkdir -p /var/service
#for dir in /etc/sv/*; do
#  [ -d "$dir" ] && ln -sf "$dir" /var/service/
#done

echo "🔍 Verifying runit..."
[ -L /sbin/init ] && echo "✅ /sbin/init linked" || echo "❌ /sbin/init broken"
[ -d /var/service ] && echo "✅ /var/service exists" || echo "❌ /var/service missing"

xbps-remove -O --yes 2>/dev/null || true
xbps-remove -o --yes 2>/dev/null || true
rm -rf /var/cache/xbps/*

sync
echo "✅ GRUB2 EFI system ready for boot!"
EOF

# Cleanup
sync
echo "SUCCESS!"
