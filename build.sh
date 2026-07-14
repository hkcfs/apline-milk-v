#!/bin/bash
set -e

DEFAULT_BOARD=duos
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

echo "Downloading Alpine minirootfs for riscv64..."
rm -rf rootfs
mkdir -p rootfs
mkdir -p images

wget -q -O /tmp/alpine-minirootfs.tar.gz \
    "$ALPINE_MIRROR/$ALPINE_VERSION/releases/riscv64/alpine-minirootfs-3.21.0-riscv64.tar.gz"

echo "Extracting rootfs..."
tar -xzf /tmp/alpine-minirootfs.tar.gz -C rootfs
rm /tmp/alpine-minirootfs.tar.gz

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

echo -n "Installing Bootloader..."
cp milkv-bootloader/$BOARD/fip.bin$OVERDRIVE images/fip.bin 2>/dev/null || \
    cp milkv-bootloader/$BOARD/fip.bin images/fip.bin
echo "OK."

echo "Setting root password"
sed -i "s|^root:[^:]*:|root:$PASSWORD_HASH:|" ./rootfs/etc/shadow

echo "Generating SD Card Image..."
[ -n "$WIRELESS" ] && BOARD="duos-wifi"
dd if=/dev/zero of=images/swap.img bs=1M count=256 2>/dev/null
mkswap images/swap.img >/dev/null
fakeroot genimage --rootpath ./rootfs --config ./genimage.cfg --inputpath ./images
mv images/alpine-milkv.img images/alpine-milkv-$BOARD.img
echo "SD card image generated at ./images/alpine-milkv-$BOARD.img"
