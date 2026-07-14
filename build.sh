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
build.sh - create an Alpine Linux image for the Milk-V Duo 256M (SG2002)

    build.sh [-c | --custom] [-h | --help] [--arch ARCH] [BOARD]

    -h | --help     show this help
    -c | --custom   prompt for settings
    --arch ARCH     target architecture: riscv (default) or arm64
    BOARD           duo256m (only supported board)

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
    while [ ! "$BOARD" = "duo256m" ]; do
        read -rp "target board (required, must be duo256m): " BOARD
    done
    [ -z "$HNAME" ] && read -rp "hostname (optional, default: $DEFAULT_HNAME): " HNAME
    [ -z "$PASSWORD" ] && { read -rsp "root password (optional, default: $DEFAULT_PASSWORD): " PASSWORD; echo; }
    read -rp 'enable CPU overdrive? y/n (y/n): ' OD
    [ "$OD" = "n" ] && OVERDRIVE=""
fi

[ -z "$BOARD" ] && BOARD=$DEFAULT_BOARD

# Only the Milk-V Duo 256M (SG2002) is supported.
if [ "$BOARD" != "duo256m" ]; then
    echo "ERROR: unsupported board '$BOARD'. Only 'duo256m' is supported." >&2
    exit 1
fi
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

# Never read from a terminal/stdin: when run detached (no controlling tty), a
# `make` that hits a missing .config symbol would block waiting for input and
# silently hang the build. Force stdin closed for the whole script.
exec < /dev/null

# ccache: cache compiled objects so kernel version bumps only recompile the
# files that actually changed. We wrap ONLY the compiler via CC=... (never
# CROSS_COMPILE, which is also used for ld/objcopy/etc that ccache can't wrap).
# CCACHE_DIR lives outside the kernel source tree so it survives the source
# wipe that happens on a kernel version change.
KMAKE_CC=""
if command -v ccache >/dev/null 2>&1; then
    export CCACHE_DIR="${CCACHE_DIR:-/project/.ccache}"
    export CCACHE_MAXSIZE="${CCACHE_MAXSIZE:-5G}"
    export CCACHE_COMPILERCHECK=content
    mkdir -p "$CCACHE_DIR"
    ccache -M "$CCACHE_MAXSIZE" >/dev/null 2>&1 || true
    # The CC/HOSTCC values must be single tokens (no spaces) so they survive
    # unquoted word-splitting on the make command line. Use tiny wrapper scripts
    # that exec "ccache <compiler>".
    CCACHE_BIN_DIR=/tmp/ccache-wrappers
    mkdir -p "$CCACHE_BIN_DIR"
    printf '#!/bin/sh\nexec ccache %sgcc "$@"\n' "$CROSS_COMPILE" > "$CCACHE_BIN_DIR/target-cc"
    printf '#!/bin/sh\nexec ccache gcc "$@"\n' > "$CCACHE_BIN_DIR/host-cc"
    chmod +x "$CCACHE_BIN_DIR/target-cc" "$CCACHE_BIN_DIR/host-cc"
    KMAKE_CC="CC=$CCACHE_BIN_DIR/target-cc HOSTCC=$CCACHE_BIN_DIR/host-cc"
    echo "ccache enabled: dir=$CCACHE_DIR max=$CCACHE_MAXSIZE"
    ccache -z >/dev/null 2>&1 || true
else
    echo "ccache not found - full compile (install 'ccache' for faster rebuilds)"
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

WIRELESS=""

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
echo "MARK1A: KERNEL_OUT=$KERNEL_OUT OUTDIR=$OUTDIR PATCHES_DIR=$PATCHES_DIR"

# Per-architecture output directories so a parallel matrix build (riscv + arm64)
# never clobbers each other's kernel / DTB / image. (Previously both arches
# wrote to images/kernel/Image, so the last build won the shared path.)
KERNEL_OUT="/project/images/kernel-${ARCH_TARGET}"
OUTDIR="/project/images/${ARCH_TARGET}"
ROOTFS_DIR="/project/rootfs-${ARCH_TARGET}"
mkdir -p "$KERNEL_OUT" "$OUTDIR"
PATCH_LOG="/project/images/${ARCH_TARGET}/patch-report.txt"
KBUILD_LOG="/project/images/${ARCH_TARGET}/kernel-build.log"

# Patches must ONLY be applied on a pristine tree. Re-applying on an already
# patched tree corrupts source files. Key the stamp on a hash of the patch set
# AND the defconfig, so changing either one forces a clean re-prepare (and a
# `make mrproper` to drop any build artifacts left over from a previous set,
# e.g. a board DTB that was removed). This keeps the persistent kernel-source
# volume correct across patch edits instead of leaving stale incremental state.
PREPARE_STAMP="$KERNEL_DIR/.alpine-milkv-prepared"
if [ "${ARCH_TARGET}" = "riscv" ]; then
    DEFCONFIG_SRC="/project/kernel/${KERNEL_DEFCONFIG}"
else
    DEFCONFIG_SRC="/project/kernel/configs/arm64-slim.config"
fi
PREPARE_HASH=$( ( ls -1 "$PATCHES_DIR"/*.patch 2>/dev/null; cat "$PATCHES_DIR"/*.patch 2>/dev/null; \
                  cat "$DEFCONFIG_SRC" 2>/dev/null ) | md5sum | cut -d' ' -f1 )
echo "MARK1B: PATCHES_DIR=$PATCHES_DIR DEFCONFIG_SRC=$DEFCONFIG_SRC HASH=$PREPARE_HASH"
WANT_PREPARE="${LATEST_STABLE}:${BOARD}:${ARCH_TARGET}:${PREPARE_HASH}"
if [ "$(cat "$PREPARE_STAMP" 2>/dev/null)" = "$WANT_PREPARE" ]; then
    echo ""
    echo "=== Source already patched & configured for $WANT_PREPARE (incremental) ==="
    APPLIED=0
    SKIPPED=0
    SKIP_PREPARE=1
else
    SKIP_PREPARE=0
fi
echo "MARK1C: SKIP_PREPARE=$SKIP_PREPARE"

if [ "$SKIP_PREPARE" = "0" ]; then
# Clean any build artifacts left from a previous (different) patch set so a
# removed board DTB or symbol doesn't break the incremental build.
make mrproper </dev/null >/dev/null 2>&1 || true
# Apply out-of-tree patches
echo ""
echo "=== Applying patches ==="
APPLIED=0
FAILED=0
 SKIPPED=0
 mkdir -p /project/images
echo "Patch report for Linux $LATEST_STABLE" > "$PATCH_LOG"
echo "Generated: $(date -u)" >> "$PATCH_LOG"
echo "=================================" >> "$PATCH_LOG"

if [ -d "$PATCHES_DIR" ] && [ "$(ls -A "$PATCHES_DIR"/*.patch 2>/dev/null)" ]; then
    for patch in "$PATCHES_DIR"/*.patch; do
        name=$(basename "$patch")
        # New-file patches: a stale copy left by a previous build makes `patch`
        # skip re-applying (and keep the OLD content), so an edited patch would
        # never take effect on incremental rebuilds. Remove the target first so
        # the current patch content is always used. (The kernel source volume is
        # persistent across builds.)
        if grep -q "new file mode" "$patch"; then
            newfile=$(grep -m1 '^+++ b/' "$patch" | sed 's|^+++ b/||')
            [ -n "$newfile" ] && rm -f "$newfile"
        fi
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

# Ensure our board DTB is registered in the sophgo Makefile for this arch
# (the patch's Makefile hunk may fail to apply across kernel versions). This runs
# for both riscv and arm64 so the Duo 256M DTB is always built.
SOPHGO_MK="arch/${ARCH_TARGET}/boot/dts/sophgo/Makefile"
rm -f "${SOPHGO_MK}.rej"
if [ -f "$SOPHGO_MK" ] && ! grep -q "sg2002-milkv-duo-256m.dtb" "$SOPHGO_MK"; then
    echo 'dtb-$(CONFIG_ARCH_SOPHGO) += sg2002-milkv-duo-256m.dtb' >> "$SOPHGO_MK"
    echo "  Registered sg2002-milkv-duo-256m.dtb in $SOPHGO_MK"
fi
echo "" >> "$PATCH_LOG"
echo "Summary: $APPLIED applied, $SKIPPED skipped" >> "$PATCH_LOG"

# Use our defconfig
echo ""
echo "Configuring kernel..."
if [ "$ARCH_TARGET" = "arm64" ]; then
    # For arm64, start from the upstream defconfig (has Sophgo support) then
    # slim it down: the stock defconfig builds EVERY arm64 SoC vendor's drivers
    # and DTBs (thousands of files). We keep only the Sophgo family and drop the
    # heavy subsystems a headless SBC never uses. This is the single biggest
    # kernel compile-time win. (Inspired by scpcom/sophgo-sg200x, which builds
    # only one SoC family.)
    make "$KERNEL_DEFCONFIG" 2>/dev/null
    echo "Slimming arm64 config (keep Sophgo, drop other SoC vendors)..."
    if [ -f arch/arm64/Kconfig.platforms ]; then
        for sym in $(grep -oP '^config \K[A-Z0-9_]+' arch/arm64/Kconfig.platforms); do
            case "$sym" in
                ARCH_SOPHGO) ./scripts/config -e "$sym" ;;
                ARCH_*)      ./scripts/config -d "$sym" ;;
            esac
        done
    fi
    SLIM_FRAG=/project/kernel/configs/arm64-slim.config
    if [ -f "$SLIM_FRAG" ]; then
        echo "Applying slim fragment: $SLIM_FRAG"
        ./scripts/kconfig/merge_config.sh -m .config "$SLIM_FRAG" >/dev/null 2>&1 \
            || cat "$SLIM_FRAG" >> .config
    fi
    make olddefconfig 2>/dev/null
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
# Build the kernel Image and modules first (these are required).
make -j"$JOBS" $KMAKE_CC Image modules </dev/null > "$KBUILD_LOG" 2>&1 || {
    echo "!!! Kernel Image/modules build FAILED. Last 40 lines:"
    tail -40 "$KBUILD_LOG"
    exit 1
}
# Build the board device tree. We build ONLY the target board DTB (not the full
# `make dtbs`, which compiles every Sophgo board and aborts on any single broken
# sibling DTS against newer kernels). The board DTB is what ships in the image's
# boot partition; QEMU 'virt' supplies its own DTB for the boot test. The DTB
# make target is the path relative to arch/<arch>/boot/dts/ (e.g. sophgo/...).
BOARD_DTB="sophgo/sg2002-milkv-duo-256m.dtb"
if ! make -j"$JOBS" $KMAKE_CC "$BOARD_DTB" </dev/null >> "$KBUILD_LOG" 2>&1; then
    echo "  WARNING: board DTB build reported errors."
    echo "  WARNING: board DTB build had errors" >> "$PATCH_LOG"
fi
tail -5 "$KBUILD_LOG"

if command -v ccache >/dev/null 2>&1; then
    echo "--- ccache stats ---"
    ccache -s 2>/dev/null | grep -iE 'hit|miss|cache size' || true
fi

echo "Copying kernel artifacts..."
rm -rf "$KERNEL_OUT/dtb"
mkdir -p "$KERNEL_OUT/dtb/sophgo"
# Only copy the Sophgo board DTBs (not every vendor's DTBs - that overflows
# the 128M boot partition with 1700+ unrelated device trees).
if [ "$ARCH_TARGET" = "arm64" ]; then
    cp arch/arm64/boot/Image "$KERNEL_OUT/"
    find arch/arm64/boot/dts/sophgo -name "*.dtb" -exec cp {} "$KERNEL_OUT/dtb/sophgo/" \; 2>/dev/null || true
else
    cp arch/riscv/boot/Image "$KERNEL_OUT/"
    find arch/riscv/boot/dts/sophgo -name "*.dtb" -exec cp {} "$KERNEL_OUT/dtb/sophgo/" \; 2>/dev/null || true
fi

echo "Kernel built: $(ls -lh "$KERNEL_OUT/Image" | awk '{print $5}')"
cd /project

# ============================================
# STEP 2: Build $ROOTFS_DIR
# ============================================
echo ""
echo "=== Step 2: Building Alpine $ROOTFS_DIR ==="

echo "Downloading Alpine minirootfs for $ALPINE_ARCH..."
rm -rf $ROOTFS_DIR
mkdir -p $ROOTFS_DIR
mkdir -p images

wget -q -O /tmp/alpine-minirootfs.tar.gz \
    "$ALPINE_MIRROR/$ALPINE_VERSION/releases/$ALPINE_ARCH/alpine-minirootfs-$ALPINE_RELEASE-$ALPINE_ARCH.tar.gz"

echo "Extracting $ROOTFS_DIR..."
tar -xzf /tmp/alpine-minirootfs.tar.gz -C $ROOTFS_DIR
rm /tmp/alpine-minirootfs.tar.gz

# Copy kernel into $ROOTFS_DIR boot
mkdir -p $ROOTFS_DIR/boot
cp "$KERNEL_OUT/Image" $ROOTFS_DIR/boot/
cp -r "$KERNEL_OUT/dtb" $ROOTFS_DIR/boot/ 2>/dev/null || true

echo "Running second-stage setup..."
cp scripts/second-stage.sh $ROOTFS_DIR/
cp -r packages $ROOTFS_DIR/packages 2>/dev/null || true

# Mount proc/sys/dev for chroot
mount -t proc proc $ROOTFS_DIR/proc 2>/dev/null || true
mount -t sysfs sysfs $ROOTFS_DIR/sys 2>/dev/null || true
mount -o bind /dev $ROOTFS_DIR/dev 2>/dev/null || true
mount -o bind /dev/pts $ROOTFS_DIR/dev/pts 2>/dev/null || true

# Copy QEMU static into chroot for cross-arch emulation
QEMU_STATIC_PATH=$(which "$QEMU_BIN" 2>/dev/null || echo "")
if [ -n "$QEMU_STATIC_PATH" ]; then
    cp "$QEMU_STATIC_PATH" $ROOTFS_DIR/usr/bin/ 2>/dev/null || true
fi

# Configure DNS for chroot
echo "nameserver 8.8.8.8" > $ROOTFS_DIR/etc/resolv.conf
echo "nameserver 8.8.4.4" >> $ROOTFS_DIR/etc/resolv.conf

chroot $ROOTFS_DIR /bin/sh -e /second-stage.sh "$BOARD" "$HNAME" "$PASSWORD" "$WIRELESS"

# Unmount BEFORE genimage runs
cleanup() {
    umount $ROOTFS_DIR/dev/pts 2>/dev/null || true
    umount $ROOTFS_DIR/dev 2>/dev/null || true
    umount $ROOTFS_DIR/sys 2>/dev/null || true
    umount $ROOTFS_DIR/proc 2>/dev/null || true
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
cp $BOOTLOADER_DIR/fip.bin$OVERDRIVE "$OUTDIR/fip.bin" 2>/dev/null || \
    cp $BOOTLOADER_DIR/fip.bin "$OUTDIR/fip.bin"
echo "OK."

# Copy kernel to boot partition for genimage
rm -rf "$OUTDIR/boot"
mkdir -p "$OUTDIR/boot"
cp "$KERNEL_OUT/Image" "$OUTDIR/boot/"
cp -r "$KERNEL_OUT/dtb" "$OUTDIR/boot/" 2>/dev/null || true

echo "Setting root password"
sed -i "s|^root:[^:]*:|root:$PASSWORD_HASH:|" "$ROOTFS_DIR/etc/shadow"

echo "Generating SD Card Image..."
IMG_NAME="alpine-milkv-$BOARD-$ARCH_TARGET"
dd if=/dev/zero of="$OUTDIR/swap.img" bs=1M count=256 2>/dev/null
mkswap "$OUTDIR/swap.img" >/dev/null
fakeroot genimage --rootpath "$ROOTFS_DIR" --config ./genimage.cfg --inputpath "$OUTDIR" --outputpath "$OUTDIR"
mv "$OUTDIR/alpine-milkv.img" "$OUTDIR/$IMG_NAME.img"

echo ""
echo "============================================"
echo " BUILD COMPLETE!"
echo "============================================"
echo "Kernel: Linux $LATEST_STABLE"
echo "Arch:   $ARCH_TARGET ($ALPINE_ARCH)"
echo "Patches: $APPLIED applied, $SKIPPED skipped"
echo "Image: $IMG_NAME.img (in outputs/ as alpine-milkv-duo256m-$ARCH_TARGET.img)"
echo "Size:  $(ls -lh "$OUTDIR/$IMG_NAME.img" | awk '{print $5}')"
echo ""
echo "Patch report: $ARCH_TARGET/patch-report.txt"
echo ""
echo "Flash with:"
echo "  sudo dd if=outputs/alpine-milkv-duo256m-$ARCH_TARGET.img of=/dev/sdX bs=4M status=progress"
echo "============================================"
