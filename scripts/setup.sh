#!/bin/bash
set -e

[ "$EUID" -ne 0 ] && { echo "must be root"; exit 1; }

export DEBIAN_FRONTEND=noninteractive

BUILD_DEPS=(qemu-user-static qemu-system-riscv64 binfmt-support dpkg-cross \
  arch-test mmdebstrap fakechroot libfakeroot:riscv64 libfakechroot:riscv64 \
  libconfuse-dev debhelper devscripts libssl-dev:riscv64 \
  u-boot-tools gcc-riscv64-linux-gnu libc6-dev-riscv64-cross kmod \
  pkg-config build-essential ninja-build automake autoconf autoconf-archive \
  libtool wget curl git gcc libssl-dev bc squashfs-tools android-sdk-libsparse-utils \
  jq python3-setuptools scons parallel tree python3-dev python3-pip device-tree-compiler ssh \
  cpio fakeroot flex bison libncurses5-dev genext2fs rsync unzip dosfstools mtools \
  tcl openssh-client cmake expect libconfuse2 libarchive-tools)
MISSING_DEPS=()

dpkg --add-architecture riscv64
cat >/etc/apt/sources.list.d/riscv64.sources <<EOF
Types: deb
URIs: http://ports.ubuntu.com/ubuntu-ports
Suites: noble noble-updates noble-backports noble-security
Components: main restricted universe multiverse
Architectures: riscv64
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
EOF

cat >/etc/apt/sources.list.d/ubuntu.sources <<EOF
Types: deb
URIs: http://archive.ubuntu.com/ubuntu/
Suites: noble noble-updates noble-backports
Components: main universe restricted multiverse
Architectures: amd64  
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
EOF

apt-get update
apt-get upgrade -y

echo "Checking dependencies..."
for pkg in "${BUILD_DEPS[@]}"; do
    if ! dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "ok installed"; then
        echo "  [ ] $pkg is missing" >&2
        MISSING_DEPS+=("$pkg")
    else
        echo "  [x] $pkg is found" >&2
    fi
done
echo "Installing dependencies..."
if [ ! ${#MISSING_DEPS[@]} -eq 0 ]; then
    apt-get install --no-install-recommends -y "${MISSING_DEPS[@]}"
fi
echo "OK."

if ! which genimage && [ -z $DOCKER_BUILD ];then
    echo "Installing genimage..."
    [ -d ../genimage ] && cd ../genimage || cd genimage
    ./autogen.sh
    ./configure
    make
    make install
    echo "OK."
fi

# Register binfmt_misc for riscv64 emulation
if [ -n "$DOCKER_BUILD" ]; then
    echo "Setting up binfmt_misc for riscv64..."
    # Copy qemu binary to a persistent location
    cp /usr/bin/qemu-riscv64-static /usr/local/bin/ 2>/dev/null || true
    # Register binfmt if not already done
    if [ ! -f /proc/sys/fs/binfmt_misc/qemu-riscv64 ]; then
        apt-get install -y --no-install-recommends binfmt-support qemu-user-static
        update-binfmts --enable qemu-riscv64 2>/dev/null || true
    fi
fi
