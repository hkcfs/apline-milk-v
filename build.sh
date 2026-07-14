#!/bin/bash
set -e
set -o pipefail

DEFAULT_BOARD=duo256m
DEFAULT_HNAME=milkv-alpine
DEFAULT_PASSWORD=milkv
ALPINE_MIRROR=https://dl-cdn.alpinelinux.org/alpine
ALPINE_VERSION=v3.24
ALPINE_RELEASE=3.24.1
OVERDRIVE=.od

ARCH_TARGET=""
FLAG=""
BOARD=""

while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help)
            cat <<EOF
build.sh - create an Alpine Linux image for Milk-V Duo boards

    build.sh [-c | --custom] [-h | --help] [--arch ARCH] [BOARD]

    -h | --help     show this help
    -c | --custom   prompt for settings
    --arch ARCH     target architecture: riscv (default) or arm64
    BOARD           one of duos, duos-wifi, duo256m

default hostname is "$DEFAULT_HNAME" and default root password is "$DEFAULT_PASSWORD"
default target board is "$DEFAULT_BOARD"
EOF
            exit
            ;;
        --arch)
            ARCH_TARGET="$2"
            shift 2
            ;;
        -c|--custom)
            FLAG="--custom"
            shift
            ;;
        *)
            BOARD="$1"
            shift
            ;;
    esac
done

if [ "$FLAG" = "--custom" ]; then
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

# Default to riscv if no arch specified
[ -z "$ARCH_TARGET" ] && ARCH_TARGET=riscv

if [ "$ARCH_TARGET" = "arm64" ]; then
    export ARCH=arm64
    export CROSS_COMPILE=aarch64-linux-gnu-
    ALPINE_ARCH=aarch64
    QEMU_BIN=qemu-aarch64-static
    echo "Architecture: aarch64 (ARM64/Cortex-A53)"
else
    export ARCH=riscv
    export CROSS_COMPILE=riscv64-linux-gnu-
    ALPINE_ARCH=riscv64
    QEMU_BIN=qemu-riscv64-static
    echo "Architecture: riscv64"
fi

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
    Architecture:   $ARCH_TARGET ($ALPINE_ARCH)
    Alpine Mirror:  $ALPINE_MIRROR
    Alpine Version: $ALPINE_VERSION
    Hostname:       $HNAME
    Password:       $DISPLAY_PASSWORD
    CPU Overdrive:  $DISPLAY_OD
============================================
EOF

if [ "$BOARD" = "duos-wifi" ]; then
    WIRELESS="true"
    BOARD="duos"
fi

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

# Select patches and defconfig based on architecture
if [ "$ARCH_TARGET" = "arm64" ]; then
    PATCHES_DIR="/project/kernel/patches-arm64"
    KERNEL_DEFCONFIG="defconfig"
else
    PATCHES_DIR="/project/kernel/patches"
    KERNEL_DEFCONFIG="milkv-${BOARD}_defconfig"
fi

# Determine if we can reuse existing source (use a version stamp; tarball has no git).
# KERNEL_DIR may be a persistent mount point, so we clear its CONTENTS rather than
# removing the directory itself.
NEED_DOWNLOAD=1
OLD_VERSION=$(cat "$KERNEL_DIR/.alpine-milkv-version" 2>/dev/null || echo "")
if [ -n "$OLD_VERSION" ] && [ "$OLD_VERSION" = "$LATEST_STABLE" ] && [ -f "$KERNEL_DIR/Makefile" ]; then
    echo "Reusing existing Linux $LATEST_STABLE source (incremental build)"
    NEED_DOWNLOAD=0
elif [ -n "$OLD_VERSION" ]; then
    echo "Kernel version changed ($OLD_VERSION -> $LATEST_STABLE), re-downloading..."
fi

if [ "$NEED_DOWNLOAD" = "1" ]; then
    echo "Downloading Linux $LATEST_STABLE..."
    KERN_SRC_URL="https://cdn.kernel.org/pub/linux/kernel/v${LATEST_MAJOR}.x/linux-${LATEST_STABLE}.tar.xz"
    wget -q -O /tmp/linux.tar.xz "$KERN_SRC_URL"
    mkdir -p "$KERNEL_DIR"
    # Clear any previous contents (works whether or not it is a mount point)
    find "$KERNEL_DIR" -mindepth 1 -delete 2>/dev/null || true
    tar -xf /tmp/linux.tar.xz -C /project/kernel/
    cp -a "/project/kernel/linux-${LATEST_STABLE}/." "$KERNEL_DIR/"
    rm -rf "/project/kernel/linux-${LATEST_STABLE}" /tmp/linux.tar.xz
    echo "$LATEST_STABLE" > "$KERNEL_DIR/.alpine-milkv-version"
fi

cd "$KERNEL_DIR"
echo "Kernel version: $(make kernelrelease 2>/dev/null || echo 'unknown')"

# Patches must ONLY be applied on a pristine tree. Re-applying on an already
# patched tree corrupts source files. Use a stamp keyed to version/board/arch
# so an existing prepared tree is reused for a fast incremental rebuild.
PREPARE_STAMP="$KERNEL_DIR/.alpine-milkv-prepared"
WANT_PREPARE="${LATEST_STABLE}:${BOARD}:${ARCH_TARGET}"
if [ "$(cat "$PREPARE_STAMP" 2>/dev/null)" = "$WANT_PREPARE" ]; then
    echo ""
    echo "=== Source already patched & configured for $WANT_PREPARE (incremental) ==="
    APPLIED=0
    SKIPPED=0
    SKIP_PREPARE=1
else
    SKIP_PREPARE=0
fi

if [ "$SKIP_PREPARE" = "0" ]; then
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
        # Determine appliability by EXIT CODE (not by grepping output, which
        # matches even when hunks fail). --forward skips already-applied hunks,
        # --fuzz=3 tolerates context drift against newer vanilla trees.
        if patch -p1 --forward --fuzz=3 --dry-run < "$patch" >/dev/null 2>&1; then
            patch -p1 --forward --fuzz=3 < "$patch" >/dev/null 2>&1
            echo "  APPLIED: $name"
            echo "APPLIED: $name" >> "$PATCH_LOG"
            APPLIED=$((APPLIED + 1))
        else
            echo "  SKIPPED: $name (already upstream or does not apply)"
            echo "SKIPPED: $name" >> "$PATCH_LOG"
            SKIPPED=$((SKIPPED + 1))
        fi
    done
else
    echo "No patches found in $PATCHES_DIR"
fi

echo ""
echo "Patch summary: $APPLIED applied, $SKIPPED skipped"

# Ensure our arm64 board DTB is registered in the sophgo Makefile
# (the patch's Makefile hunk may fail to apply across kernel versions)
if [ "$ARCH_TARGET" = "arm64" ]; then
    SOPHGO_MK="arch/arm64/boot/dts/sophgo/Makefile"
    rm -f "${SOPHGO_MK}.rej"
    if [ -f "$SOPHGO_MK" ] && ! grep -q "sg2002-milkv-duo-256m.dtb" "$SOPHGO_MK"; then
        echo 'dtb-$(CONFIG_ARCH_SOPHGO) += sg2002-milkv-duo-256m.dtb' >> "$SOPHGO_MK"
        echo "  Registered sg2002-milkv-duo-256m.dtb in $SOPHGO_MK"
    fi
fi
echo "" >> "$PATCH_LOG"
echo "Summary: $APPLIED applied, $SKIPPED skipped" >> "$PATCH_LOG"

# Use our defconfig
echo ""
echo "Configuring kernel..."
if [ "$ARCH_TARGET" = "arm64" ]; then
    # For arm64, use the upstream defconfig which already has Sophgo support
    make "$KERNEL_DEFCONFIG" 2>/dev/null
else
    cp /project/kernel/"$KERNEL_DEFCONFIG" .config
    make olddefconfig 2>/dev/null
fi

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

echo "$WANT_PREPARE" > "$PREPARE_STAMP"
fi  # end SKIP_PREPARE guard

echo "Building kernel with $JOBS jobs..."
mkdir -p /project/images
KBUILD_LOG=/project/images/kernel-build.log
# Build the kernel Image and modules first (these are required).
make -j"$JOBS" Image modules > "$KBUILD_LOG" 2>&1 || {
    echo "!!! Kernel Image/modules build FAILED. Last 40 lines:"
    tail -40 "$KBUILD_LOG"
    exit 1
}
# Build device trees. A single out-of-tree board DTS that doesn't apply cleanly
# against the latest vanilla kernel must NOT abort the whole build: QEMU 'virt'
# supplies its own DTB, so a boot test still works. Failures are logged.
if ! make -j"$JOBS" dtbs >> "$KBUILD_LOG" 2>&1; then
    echo "  WARNING: 'make dtbs' reported errors (some board DTBs may be missing)."
    echo "  WARNING: dtbs build had errors" >> "$PATCH_LOG"
fi
tail -5 "$KBUILD_LOG"

echo "Copying kernel artifacts..."
rm -rf /project/images/kernel/dtb
mkdir -p /project/images/kernel
mkdir -p /project/images/kernel/dtb/sophgo
# Only copy the Sophgo board DTBs (not every vendor's DTBs - that overflows
# the 128M boot partition with 1700+ unrelated device trees).
if [ "$ARCH_TARGET" = "arm64" ]; then
    cp arch/arm64/boot/Image /project/images/kernel/
    find arch/arm64/boot/dts/sophgo -name "*.dtb" -exec cp {} /project/images/kernel/dtb/sophgo/ \; 2>/dev/null || true
else
    cp arch/riscv/boot/Image /project/images/kernel/
    find arch/riscv/boot/dts/sophgo -name "*.dtb" -exec cp {} /project/images/kernel/dtb/sophgo/ \; 2>/dev/null || true
fi

echo "Kernel built: $(ls -lh /project/images/kernel/Image | awk '{print $5}')"
cd /project

# ============================================
# STEP 2: Build rootfs
# ============================================
echo ""
echo "=== Step 2: Building Alpine rootfs ==="

echo "Downloading Alpine minirootfs for $ALPINE_ARCH..."
rm -rf rootfs
mkdir -p rootfs
mkdir -p images

wget -q -O /tmp/alpine-minirootfs.tar.gz \
    "$ALPINE_MIRROR/$ALPINE_VERSION/releases/$ALPINE_ARCH/alpine-minirootfs-$ALPINE_RELEASE-$ALPINE_ARCH.tar.gz"

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

# Copy QEMU static into chroot for cross-arch emulation
QEMU_STATIC_PATH=$(which "$QEMU_BIN" 2>/dev/null || echo "")
if [ -n "$QEMU_STATIC_PATH" ]; then
    cp "$QEMU_STATIC_PATH" rootfs/usr/bin/ 2>/dev/null || true
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
if [ "$ARCH_TARGET" = "arm64" ]; then
    BOOTLOADER_DIR="milkv-bootloader/$BOARD-arm64"
else
    BOOTLOADER_DIR="milkv-bootloader/$BOARD"
fi
cp $BOOTLOADER_DIR/fip.bin$OVERDRIVE images/fip.bin 2>/dev/null || \
    cp $BOOTLOADER_DIR/fip.bin images/fip.bin
echo "OK."

# Copy kernel to boot partition for genimage
rm -rf images/boot
mkdir -p images/boot
cp images/kernel/Image images/boot/
cp -r images/kernel/dtb images/boot/ 2>/dev/null || true

echo "Setting root password"
sed -i "s|^root:[^:]*:|root:$PASSWORD_HASH:|" ./rootfs/etc/shadow

echo "Generating SD Card Image..."
[ -n "$WIRELESS" ] && BOARD="duos-wifi"
IMG_NAME="alpine-milkv-$BOARD-$ARCH_TARGET"
dd if=/dev/zero of=images/swap.img bs=1M count=256 2>/dev/null
mkswap images/swap.img >/dev/null
fakeroot genimage --rootpath ./rootfs --config ./genimage.cfg --inputpath ./images
mv images/alpine-milkv.img images/$IMG_NAME.img

echo ""
echo "============================================"
echo " BUILD COMPLETE!"
echo "============================================"
echo "Kernel: Linux $LATEST_STABLE"
echo "Arch:   $ARCH_TARGET ($ALPINE_ARCH)"
echo "Patches: $APPLIED applied, $SKIPPED skipped"
echo "Image: images/$IMG_NAME.img"
echo "Size:  $(ls -lh images/$IMG_NAME.img | awk '{print $5}')"
echo ""
echo "Patch report: images/patch-report.txt"
echo ""
echo "Flash with:"
echo "  sudo dd if=images/$IMG_NAME.img of=/dev/sdX bs=4M status=progress"
echo "============================================"
