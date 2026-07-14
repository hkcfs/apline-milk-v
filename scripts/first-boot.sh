#!/bin/bash

echo "First Boot: Setting Hostname"
echo "$HNAME" > /etc/hostname

echo "First Boot: Generating SSH keys"
ssh-keygen -A

echo -n "First Boot: Expanding root partition..."
parted -s -a opt /dev/mmcblk0 "resizepart 3 100%"
resize2fs /dev/mmcblk0p3 2>/dev/null || true
echo "OK."

echo "First Boot: Fixing permissions"
chmod -R 700 /root/.ssh 2>/dev/null || true

systemctl disable milkv-first-boot.service 2>/dev/null || \
    rc-update del milkv-first-boot default 2>/dev/null || true
