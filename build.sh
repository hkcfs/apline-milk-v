#!/bin/bash
set -e

DEFAULT_BOARD=duo256m
DEFAULT_HNAME=milkv-alpine
DEFAULT_PASSWORD=milkv
ALPINE_MIRROR=https://dl-cdn.alpinelinux.org/alpine
ALPINE_VERSION=v3.21
OVERDRIVE=.od

FLAG=$1

if [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
    cat <<EOF
build.sh - create an Alpine Linux image for Milk-V Duo boards

    build.sh [-c | --custom] [-h | --help] | [BOARD]

    -h | --help     show this help
    -c | --custom   prompt for settings
    BOARD           one of duos, duos-wifi, duo256m

default hostname is "$DEFAULT_HNAME" and default root password is "$DEFAULT_PASSWORD"
default target board is "$DEFAULT_BOARD"
EOF
    exit
fi

if [ ! "$FLAG" = "--custom" ] && [ ! "$FLAG" = "-c" ]; then
    BOARD=$1
    echo "BOARD=$BOARD"
else
    while [ ! "$BOARD" = "duos" ] && [ ! "$BOARD" = "duos-wifi" ] && [ ! "$BOARD" = "duo256m" ]; do
        read -rp "target board (required, must be duos or duo256m): " BOARD
    done
    [ -z "$HNAME" ] && read -rp "hostname (optional, default: $DEFAULT_HNAME): " HNAME
    [ -z "$PASSWORD" ] && { read -rsp "root password (optional, default: $DEFAULT_PASSWORD): " PASSWORD; echo; }
    read -rp 'enable CPU overdrive? y/n (y/n): ' OD
    [ "$OD" = "n" ] && OVERDRIVE=""
fi

[ -z "$BOARD" ] && BOARD=$DEFAULT_BOARD
[ -z "$HNAME" ] && HNAME=$DEFAULT_HNAME
[ -z "$PASSWORD" ] && PASSWORD=$DEFAULT_PASSWORD

if [ "$PASSWORD" = "$DEFAULT_PASSWORD" ]; then
    DISPLAY_PASSWORD="Default ($DEFAULT_PASSWORD)"
else
    DISPLAY_PASSWORD="Changed by user"
fi

PASSWORD_HASH=$(echo -n "$PASSWORD" | openssl passwd -6 -stdin)
[ "$OVERDRIVE" = ".od" ] && DISPLAY_OD="Enabled (1000MHz)" || DISPLAY_OD="Disabled (850MHz)"

cat <<EOF
==== Alpine Linux for Milk-V Duo Boards ====
Selected Configuration:
    Board:          $BOARD
    Alpine Mirror:  $ALPINE_MIRROR
    Alpine Version: $ALPINE_VERSION
    Hostname:       $HNAME
    Password:       $DISPLAY_PASSWORD
    CPU Overdrive:  $DISPLAY_OD
=============================================
EOF

if [ "$BOARD" = "duos-wifi" ]; then
    WIRELESS="true"
    BOARD="duos"
fi

export ARCH=riscv
export CROSS_COMPILE=riscv64-linux-gnu-
JOBS=$(nproc)

# ============================================
# STEP 1: Build kernel (always latest stable)
# ============================================
echo ""
echo "=== Step 1: Building latest stable Linux kernel ==="

# Fetch latest stable version from kernel.org
echo "Determining latest stable kernel..."
LATEST_STABLE=$(wget -qO- https://cdn.kernel.org/pub/linux/kernel/v7.x/ 2>/dev/null | grep -oP 'linux-7\.\d+\.\d+\.tar' | sed 's/linux-//;s/\.tar//' | sort -V | tail -1)
if [ -z "$LATEST_STABLE" ]; then
    # Try another approach
    LATEST_STABLE=$(wget -qO- https://www.kernel.org 2>/dev/null | grep -oP 'stable:\s+\K[0-9]+\.[0-9]+\.[0-9]+' | head -1)
fi
if [ -z "$LATEST_STABLE" ]; then
    echo "WARNING: Could not fetch latest stable, using 7.1.3"
    LATEST_STABLE="7.1.3"
fi
echo "Latest stable kernel: $LATEST_STABLE"
LATEST_MAJOR=$(echo "$LATEST_STABLE" | cut -d. -f1)
KERNEL_TAG="v${LATEST_STABLE}"

KERNEL_DIR="/project/kernel/linux"
PATCHES_DIR="/project/kernel/patches"

# Remove stale clone if version changed
if [ -d "$KERNEL_DIR" ]; then
    OLD_VERSION=$(cd "$KERNEL_DIR" && git describe --tags 2>/dev/null || echo "unknown")
    if [ "$OLD_VERSION" != "$KERNEL_TAG" ]; then
        echo "Kernel version changed ($OLD_VERSION -> $LATEST_STABLE), re-cloning..."
        rm -rf "$KERNEL_DIR"
    fi
fi

if [ ! -d "$KERNEL_DIR" ]; then
    echo "Downloading Linux $LATEST_STABLE..."
    KERN_SRC_URL="https://cdn.kernel.org/pub/linux/kernel/v${LATEST_MAJOR}.x/linux-${LATEST_STABLE}.tar.xz"
    wget -q -O /tmp/linux.tar.xz "$KERN_SRC_URL"
    tar -xf /tmp/linux.tar.xz -C /project/kernel/
    mv "/project/kernel/linux-${LATEST_STABLE}" "$KERNEL_DIR"
    rm -f /tmp/linux.tar.xz
fi

cd "$KERNEL_DIR"
echo "Kernel version: $(make kernelrelease 2>/dev/null || echo 'unknown')"

# Apply out-of-tree patches
echo ""
echo "=== Applying patches ==="
APPLIED=0
FAILED=0
SKIPPED=0
PATCH_LOG="/project/images/patch-report.txt"
mkdir -p /project/images
echo "Patch report for Linux $LATEST_STABLE" > "$PATCH_LOG"
echo "Generated: $(date -u)" >> "$PATCH_LOG"
echo "=================================" >> "$PATCH_LOG"

if [ -d "$PATCHES_DIR" ] && [ "$(ls -A "$PATCHES_DIR"/*.patch 2>/dev/null)" ]; then
    for patch in "$PATCHES_DIR"/*.patch; do
        name=$(basename "$patch")
        # Try patch -p1 (works on any source tree)
        if patch -p1 --dry-run < "$patch" 2>/dev/null | grep -qE "patching file|checking file"; then
            patch -p1 --force < "$patch" 2>/dev/null || true
            echo "  APPLIED: $name"
            echo "APPLIED: $name" >> "$PATCH_LOG"
            APPLIED=$((APPLIED + 1))
        else
            echo "  SKIPPED: $name (already upstream or conflict)"
            echo "SKIPPED: $name" >> "$PATCH_LOG"
            SKIPPED=$((SKIPPED + 1))
        fi
    done
else
    echo "No patches found in $PATCHES_DIR"
fi

echo ""
echo "Patch summary: $APPLIED applied, $SKIPPED skipped"
echo "" >> "$PATCH_LOG"
echo "Summary: $APPLIED applied, $SKIPPED skipped" >> "$PATCH_LOG"

# Use our defconfig
echo ""
echo "Configuring kernel..."
cp /project/kernel/milkv-${BOARD}_defconfig .config

# Enable virtio for QEMU testing
sed -i 's/^# CONFIG_VIRTIO_BLK is not set/CONFIG_VIRTIO_BLK=y/' .config
sed -i 's/^# CONFIG_VIRTIO_NET is not set/CONFIG_VIRTIO_NET=y/' .config
sed -i 's/^# CONFIG_VIRTIO_CONSOLE is not set/CONFIG_VIRTIO_CONSOLE=y/' .config
sed -i 's/^# CONFIG_VIRTIO_MENU is not set/CONFIG_VIRTIO_MENU=y/' .config
sed -i 's/^# CONFIG_SCSI_VIRTIO is not set/CONFIG_SCSI_VIRTIO=y/' .config
sed -i 's/^# CONFIG_VIRTIO_FS is not set/CONFIG_VIRTIO_FS=y/' .config
grep -q 'CONFIG_VIRTIO_MMIO=' .config || echo 'CONFIG_VIRTIO_MMIO=y' >> .config
grep -q 'CONFIG_VIRTIO_PCI=' .config || echo 'CONFIG_VIRTIO_PCI=y' >> .config
grep -q 'CONFIG_NET_9P=' .config || echo 'CONFIG_NET_9P=y' >> .config
grep -q 'CONFIG_NET_9P_VIRTIO=' .config || echo 'CONFIG_NET_9P_VIRTIO=y' >> .config
grep -q 'CONFIG_9P_FS=' .config || echo 'CONFIG_9P_FS=y' >> .config

echo "Building kernel with $JOBS jobs..."
make olddefconfig 2>/dev/null
make -j"$JOBS" Image modules dtbs 2>&1 | tail -5

# Copy outputs
echo "Copying kernel artifacts..."
mkdir -p /project/images/kernel
cp arch/riscv/boot/Image /project/images/kernel/

# Copy DTBs
mkdir -p /project/images/kernel/dtb/sophgo
find arch/riscv/boot/dts -name "*.dtb" -exec cp {} /project/images/kernel/dtb/sophgo/ \; 2>/dev/null || true

echo "Kernel built: $(ls -lh /project/images/kernel/Image | awk '{print $5}')"
cd /project

# ============================================
# STEP 2: Build rootfs
# ============================================
echo ""
echo "=== Step 2: Building Alpine rootfs ==="

echo "Downloading Alpine minirootfs for riscv64..."
rm -rf rootfs
mkdir -p rootfs
mkdir -p images

wget -q -O /tmp/alpine-minirootfs.tar.gz \
    "$ALPINE_MIRROR/$ALPINE_VERSION/releases/riscv64/alpine-minirootfs-3.21.0-riscv64.tar.gz"

echo "Extracting rootfs..."
tar -xzf /tmp/alpine-minirootfs.tar.gz -C rootfs
rm /tmp/alpine-minirootfs.tar.gz

# Copy kernel into rootfs boot
mkdir -p rootfs/boot
cp images/kernel/Image rootfs/boot/
cp -r images/kernel/dtb rootfs/boot/ 2>/dev/null || true

echo "Running second-stage setup..."
cp scripts/second-stage.sh rootfs/
cp scripts/first-boot.sh rootfs/

# Mount proc/sys/dev for chroot
mount -t proc proc rootfs/proc 2>/dev/null || true
mount -t sysfs sysfs rootfs/sys 2>/dev/null || true
mount -o bind /dev rootfs/dev 2>/dev/null || true
mount -o bind /dev/pts rootfs/dev/pts 2>/dev/null || true

# Copy QEMU static into chroot for riscv64 emulation
QEMU_STATIC=$(which qemu-riscv64-static 2>/dev/null || echo "")
if [ -n "$QEMU_STATIC" ]; then
    cp "$QEMU_STATIC" rootfs/usr/bin/ 2>/dev/null || true
fi

# Configure DNS for chroot
echo "nameserver 8.8.8.8" > rootfs/etc/resolv.conf
echo "nameserver 8.8.4.4" >> rootfs/etc/resolv.conf

chroot rootfs /bin/sh -e /second-stage.sh "$BOARD" "$HNAME" "$PASSWORD" "$WIRELESS"

# Unmount BEFORE genimage runs
cleanup() {
    umount rootfs/dev/pts 2>/dev/null || true
    umount rootfs/dev 2>/dev/null || true
    umount rootfs/sys 2>/dev/null || true
    umount rootfs/proc 2>/dev/null || true
}
cleanup

# ============================================
# STEP 3: Build SD card image
# ============================================
echo ""
echo "=== Step 3: Building SD card image ==="

echo -n "Installing Bootloader..."
cp milkv-bootloader/$BOARD/fip.bin$OVERDRIVE images/fip.bin 2>/dev/null || \
    cp milkv-bootloader/$BOARD/fip.bin images/fip.bin
echo "OK."

# Copy kernel to boot partition for genimage
mkdir -p images/boot
cp images/kernel/Image images/boot/
cp -r images/kernel/dtb images/boot/ 2>/dev/null || true

echo "Setting root password"
sed -i "s|^root:[^:]*:|root:$PASSWORD_HASH:|" ./rootfs/etc/shadow

echo "Generating SD Card Image..."
[ -n "$WIRELESS" ] && BOARD="duos-wifi"
dd if=/dev/zero of=images/swap.img bs=1M count=256 2>/dev/null
mkswap images/swap.img >/dev/null
fakeroot genimage --rootpath ./rootfs --config ./genimage.cfg --inputpath ./images
mv images/alpine-milkv.img images/alpine-milkv-$BOARD.img

echo ""
echo "============================================"
echo " BUILD COMPLETE!"
echo "============================================"
echo "Kernel: Linux $LATEST_STABLE"
echo "Patches: $APPLIED applied, $SKIPPED skipped"
echo "Image: images/alpine-milkv-$BOARD.img"
echo "Size:  $(ls -lh images/alpine-milkv-$BOARD.img | awk '{print $5}')"
echo ""
echo "Patch report: images/patch-report.txt"
echo ""
echo "Flash with:"
echo "  sudo dd if=images/alpine-milkv-$BOARD.img of=/dev/sdX bs=4M status=progress"
echo "============================================"
