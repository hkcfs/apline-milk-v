#!/bin/sh
set -e

BOARD=$1
HNAME=$2
PASSWORD=$3
WIRELESS=$4

[ -z "$BOARD" ] && { echo "No board!"; exit 1; }
[ -z "$HNAME" ] && { echo "No hostname!"; exit 1; }

ALPINE_MIRROR=https://dl-cdn.alpinelinux.org/alpine
ALPINE_VERSION=v3.24

echo "Configuring APK repositories..."
mkdir -p /etc/apk
cat > /etc/apk/repositories <<EOF
$ALPINE_MIRROR/$ALPINE_VERSION/main
$ALPINE_MIRROR/$ALPINE_VERSION/community
EOF

echo "Updating package index..."
apk update

echo "Installing base packages..."
apk add --no-cache \
    musl \
    musl-utils \
    openssh-server \
    openssh-client \
    sudo \
    curl \
    wget \
    e2fsprogs \
    dosfstools \
    parted \
    util-linux \
    chrony \
    openrc \
    eudev

echo "Installing network packages..."
apk add --no-cache \
    iproute2 \
    iptables \
    ethtool

echo "Installing tools..."
apk add --no-cache \
    vim \
    nano \
    htop \
    kmod

echo "Configuring system..."

# Set hostname
echo "$HNAME" > /etc/hostname

# Set root password
echo "root:$PASSWORD" | chpasswd

# Configure networking
cat > /etc/network/interfaces <<EOF
# Loopback
auto lo
iface lo inet loopback

# Ethernet
auto eth0
iface eth0 inet dhcp
EOF

# Enable services
rc-update add eudev boot 2>/dev/null || true
rc-update add hwclock boot 2>/dev/null || true
rc-update add sshd default 2>/dev/null || true
rc-update add networking default 2>/dev/null || true
rc-update add chronyd default 2>/dev/null || true

# Configure fstab
cat > /etc/fstab <<EOF
# <file system>	<mount pt>	<type>	<options>	<dump>	<pass>
/dev/root	/		ext4	rw,noatime	0	1
proc		/proc		proc	defaults	0	0
devpts		/dev/pts	devpts	defaults,gid=5,mode=620,ptmxmode=0666	0	0
tmpfs		/dev/shm	tmpfs	mode=0777	0	0
tmpfs		/tmp		tmpfs	mode=1777	0	0
tmpfs		/run		tmpfs	mode=0755,nosuid,nodev,size=64M	0	0
sysfs		/sys		sysfs	defaults	0	0
EOF

# Enable SSH root login
mkdir -p /etc/ssh
cat > /etc/ssh/sshd_config <<EOF
PermitRootLogin yes
PasswordAuthentication yes
EOF

# Ensure a login prompt (getty) on the serial console. The Milk-V Duo console
# and QEMU 'virt' both use ttyS0 @ 115200. Without this, boot completes but no
# login: prompt ever appears on the serial line.
touch /etc/inittab
if ! grep -q "^ttyS0:" /etc/inittab; then
    echo "ttyS0::respawn:/sbin/getty -L 115200 ttyS0 vt100" >> /etc/inittab
fi

# Create first-boot script
mkdir -p /usr/libexec/milkv
cat > /usr/libexec/milkv/first-boot.sh <<'BOOTEOF'
#!/bin/sh
echo "First Boot: Expanding root partition..."
parted -s -a opt /dev/mmcblk0 "resizepart 3 100%"
resize2fs /dev/mmcblk0p3 2>/dev/null || true

echo "First Boot: Generating SSH keys..."
ssh-keygen -A

echo "First Boot: Done"
rc-update del milkv-first-boot default 2>/dev/null || true
rm -f /etc/runlevels/default/milkv-first-boot
BOOTEOF
chmod +x /usr/libexec/milkv/first-boot.sh

# Create OpenRC init script for first boot
cat > /etc/init.d/milkv-first-boot <<'INITEOF'
#!/sbin/openrc-run

description="Milk-V Duo First Boot Setup"

depend() {
    need localmount
    before basic.services
}

start() {
    if [ ! -f /var/lib/milkv/first-boot-done ]; then
        /usr/libexec/milkv/first-boot.sh
        mkdir -p /var/lib/milkv
        touch /var/lib/milkv/first-boot-done
    fi
}
INITEOF
chmod +x /etc/init.d/milkv-first-boot
rc-update add milkv-first-boot default 2>/dev/null || true

# Configure sysctl
mkdir -p /etc/sysctl.d
cat > /etc/sysctl.d/99-milkv.conf <<EOF
vm.swappiness=10
net.core.rmem_max=16777216
net.core.wmem_max=16777216
EOF

# Set timezone
ln -sf /usr/share/zoneinfo/UTC /etc/localtime
echo "UTC" > /etc/timezone

# Clean up
rm -f /second-stage.sh /first-boot.sh
apk cache clean 2>/dev/null || true
rm -rf /tmp/*

echo "Second stage rootfs setup complete."
