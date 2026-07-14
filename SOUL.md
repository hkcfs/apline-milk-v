# SOUL.md - Alpine Linux for Milk-V Duo

## Project Identity

**Name:** alpine-milkv
**Purpose:** Minimal Alpine Linux distribution for Milk-V Duo S and Duo 256M RISC-V SBCs
**Base:** Alpine Linux v3.21
**Kernel:** Latest stable Linux (auto-fetched from kernel.org, currently 7.1.3) with Milk-V Duo patches
**Target Hardware:** Sophgo CV1812H/SG2000/SG2002 (RISC-V 64)

## Hardware Specifications

### Milk-V Duo S
- **CPU:** RISC-V CV1812H @ 1GHz
- **RAM:** 512MB DDR3
- **Storage:** microSD slot
- **Network:** Ethernet, WiFi 2.4/5GHz, Bluetooth
- **USB:** USB-C (device), USB-A (host)
- **Audio:** I2S + analog output
- **GPIO:** 26 pins

### Milk-V Duo 256M
- **CPU:** RISC-V CV1812H @ 1GHz  
- **RAM:** 256MB DDR3
- **Storage:** microSD slot
- **USB:** USB-C only
- **GPIO:** 26 pins

## Build System

### Prerequisites
- Docker and Docker Compose (ONLY requirement - nothing installed on host)
- ~10GB free disk space

### Build Commands
```bash
# Build for Duo 256M (default)
docker compose run --rm builder bash /project/build.sh duo256m

# Build for Duo S
docker compose run --rm builder bash /project/build.sh duos

# Build for Duo S with WiFi
docker compose run --rm builder bash /project/build.sh duos-wifi
```

### QEMU Testing
```bash
sudo qemu-system-riscv64 -machine virt -m 512M -nographic \
  -kernel images/kernel/Image \
  -append 'console=ttyS0 root=/dev/vda3 rootwait rw' \
  -drive file=images/alpine-milkv-duo256m.img,format=raw,if=none,id=hd0 \
  -device virtio-blk-device,drive=hd0
```

## Project Structure
```
alpine-milk-v/
├── SOUL.md                    # This file
├── build.sh                   # Main build script (kernel + rootfs + image)
├── docker-compose.yml         # Docker build environment
├── Dockerfile                 # Build container (Ubuntu 24.04 + RISC-V cross-tools)
├── genimage.cfg               # SD card partition layout
├── scripts/
│   ├── second-stage.sh        # Alpine rootfs configuration
│   ├── first-boot.sh          # First boot setup (partition expand, SSH keys)
│   └── setup.sh               # Build container dependencies
├── kernel/
│   ├── milkv-duos_defconfig   # Kernel config for Duo S
│   ├── milkv-duo256m_defconfig # Kernel config for Duo 256M
│   └── patches/               # 37 out-of-tree patches for CV18XX
├── milkv-bootloader/
│   ├── duos/fip.bin           # Vendor bootloader for Duo S
│   └── duo256m/fip.bin        # Vendor bootloader for Duo 256M
└── images/                    # Output directory
    ├── alpine-milkv-*.img     # SD card images
    ├── patch-report.txt       # Patch application report
    └── kernel/                # Built kernel Image + DTBs
```

## Build Behavior

### Automatic Kernel Management
- **Always fetches latest stable kernel** from kernel.org
- If version changes, re-downloads and re-patches
- Applies 37 out-of-tree patches automatically
- Failed/skipped patches are logged to `images/patch-report.txt`

### Patch Strategy
The 37 patches add support for:
- **Duo-S board DTS** (12 patches) - not yet upstream, expected v7.2
- **Thermal driver** (4 patches) - under review
- **PWM driver** (4 patches) - under review
- **Remote-proc C906L** (4 patches) - under review
- **DMA CV1800B** (3 patches) - partially upstream
- **Ethernet MDIO mux** (3 patches) - under review
- **eFuse driver** (3 patches) - under review
- **I2S/Audio** (2 patches) - under review
- **Timer, Watchdog, Mailbox** (remaining)

See [Sophgo Linux Wiki](https://github.com/sophgo/linux/wiki) for upstream status.

## CRITICAL: Docker Build Rules

**NEVER USE `--no-cache` WITH DOCKER BUILDS!**

- **BAD:** `docker compose build --no-cache builder`
- **GOOD:** `docker compose build builder`
- **GOOD:** `sudo docker builder prune -f` (if you need to force rebuild)

## Default Credentials
- **Username:** root
- **Password:** milkv

## Credits
- Based on: [milkv-duo-ubuntu](https://github.com/queenkjuul/milkv-duo-ubuntu)
- Alpine Linux: [alpinelinux.org](https://alpinelinux.org/)
- Milk-V: [milkv.io](https://milkv.io/)
- Kernel patches: [sophgo-linux](https://github.com/sophgo/linux)
- Upstream status: [Sophgo Linux Wiki](https://github.com/sophgo/linux/wiki)
