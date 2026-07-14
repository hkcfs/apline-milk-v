#!/bin/sh
# capture-boot.sh - Boot a built Milk-V Duo 256M image in QEMU and capture the
# full boot log + a few diagnostics over SSH, so a GitHub Release can prove the
# auto-built image actually boots. Output is a fenced code block ready to paste
# into release notes (mirrors the daily-build proof used by nuttx-sg2000).
#
# Usage: capture-boot.sh <arch:riscv|arm64> <image.img> [kernel/Image]
#
# Requires: qemu-system-riscv64 / qemu-system-aarch64, sshpass, mtools (mcopy).
set -u

ARCH="${1:?arch required (riscv|arm64)}"
IMG="${2:?image path required}"
KERNEL="${3:-}"
BUILD_LOG="${4:-}"

if [ "$ARCH" = "riscv" ]; then
    QEMU=$(command -v qemu-system-riscv64)
    MACHINE="virt"
    CPU=""
    APPEND="console=ttyS0 root=/dev/vda3 rootwait rw"
    PORT=2222
elif [ "$ARCH" = "arm64" ]; then
    QEMU=$(command -v qemu-system-aarch64)
    MACHINE="virt"
    CPU="-cpu cortex-a53"
    APPEND="console=ttyAMA0 root=/dev/vda3 rootwait rw"
    PORT=2223
else
    echo "unknown arch: $ARCH" >&2
    exit 1
fi

WORK=$(mktemp -d)
KERNEL_OUT="$WORK/Image"
if [ -n "$KERNEL" ] && [ -f "$KERNEL" ]; then
    cp "$KERNEL" "$KERNEL_OUT"
else
    # Extract the kernel from the image's boot partition (vfat, partition 1).
    # genimage places the first partition at sector 1 (512 bytes), so detect
    # the real offset instead of assuming 1MiB. genimage flattens the boot
    # vfat, so the kernel ends up at /Image (not /boot/Image) in the vfat.
    BOOT_START=$(partx -o START -n 1 "$IMG" 2>/dev/null | tail -1 | tr -d ' ')
    BOOT_OFF=$(( ${BOOT_START:-1} * 512 ))
    if mcopy -i "$IMG"@@"$BOOT_OFF" ::/Image "$KERNEL_OUT" 2>/dev/null; then
        :
    elif mcopy -i "$IMG"@@512 ::/Image "$KERNEL_OUT" 2>/dev/null; then
        :
    elif mcopy -i "$IMG"@@1M ::/Image "$KERNEL_OUT" 2>/dev/null; then
        :
    else
        echo "could not extract kernel from $IMG" >&2
        exit 1
    fi
fi

LOGBASE="$WORK/boot"
# Launch QEMU detached; console goes to a log, SSH forwarded to localhost:$PORT.
"$QEMU" $CPU -machine "$MACHINE" -m 256M -nographic \
    -kernel "$KERNEL_OUT" \
    -append "$APPEND" \
    -drive file="$IMG",format=raw,if=none,id=hd0 \
    -device virtio-blk-device,drive=hd0 \
    -netdev user,id=net0,hostfwd=tcp::${PORT}-:22 \
    -device virtio-net-device,netdev=net0 \
    </dev/null >"$LOGBASE.log" 2>&1 &
QEMU_PID=$!

# Wait for SSH, then collect diagnostics.
DIAG="$WORK/diag.txt"
: >"$DIAG"
for i in $(seq 1 30); do
    if sshpass -p milkv ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=5 -p "$PORT" root@localhost \
        'echo "=== boot OK ==="; uname -a; echo "--- arch ---"; uname -m; echo "--- alpine ---"; . /etc/os-release; echo "$PRETTY_NAME"; echo "--- memory ---"; free -m; echo "--- disk ---"; df -h / ; echo "--- board ---"; cat /proc/device-tree/model 2>/dev/null; echo' >"$DIAG" 2>/dev/null; then
        break
    fi
    sleep 5
done

# Emit a single fenced code block: build log (if provided) + boot log + diagnostics.
echo '```'
echo "===== AUTO BUILD + BOOT TEST ($ARCH) ====="
if [ -n "$BUILD_LOG" ] && [ -f "$BUILD_LOG" ]; then
    echo "----- Build log (build.sh) -----"
    cat "$BUILD_LOG"
fi
echo "----- QEMU console (boot) -----"
cat "$LOGBASE.log"
echo "----- SSH diagnostics -----"
cat "$DIAG"
echo '```'

# Tidy up.
kill -9 "$QEMU_PID" 2>/dev/null || true
rm -rf "$WORK"
