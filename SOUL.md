# SOUL.md - Alpine Linux for Milk-V Duo

## Project Identity

**Name:** alpine-milkv
**Purpose:** Minimal Alpine Linux distribution for Milk-V Duo S and Duo 256M RISC-V SBCs
**Base:** Alpine Linux v3.21
**Kernel:** Mainline Linux 7.1.3 with Milk-V Duo patches
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

## Architecture

### Dual-Core Design
The CV1812H has two cores:
1. **Main Core (RISC-V):** Runs Linux - this is what we build for
2. **Little Core (ARM Cortex-A7):** Used for real-time tasks, Arduino compatibility

### Boot Flow
```
SD Card -> FIP (Bootloader) -> U-Boot -> Linux Kernel -> Alpine Rootfs
```

## Build System

### Prerequisites
- Docker and Docker Compose (ONLY requirement - nothing installed on host)
- ~10GB free disk space
- Linux/macOS/Windows with WSL2

### Build Commands
```bash
# Build everything (kernel + rootfs + image)
docker compose run --rm builder make all

# Build just the kernel
docker compose run --rm builder make kernel

# Build just the rootfs  
docker compose run --rm builder make rootfs

# Create final SD card image
docker compose run --rm builder make image

# Flash to SD card (requires access to /dev/sdX)
docker compose run --rm --device /dev/sdX builder make flash SD=/dev/sdX
```

## Project Structure
```
alpine-milkv/
├── SOUL.md                    # This file
├── Makefile                   # Main build orchestration
├── docker-compose.yml         # Docker build environment
├── Dockerfile                 # Build container definition
├── scripts/
│   ├── build-kernel.sh        # Cross-compile Linux kernel
│   ├── build-rootfs.sh        # Create Alpine rootfs
│   ├── build-image.sh         # Assemble SD card image
│   ├── flash.sh               # Write image to SD card
│   ├── setup-kernel-config.sh # Configure kernel
│   └── test-image.sh          # Verify image integrity
├── kernel/
│   ├── defconfig              # Kernel config for Milk-V Duo
│   ├── patches/               # Kernel patches
│   └── modules/               # Out-of-tree modules
├── bootloader/
│   ├── fip.bin                # Vendor bootloader (binary blob)
│   └── u-boot.env             # U-Boot environment
├── rootfs/
│   ├── apkovl/                # Alpine overlays
│   ├── packages/              # Custom packages
│   └── overlays/              # Filesystem overlays
├── configs/
│   ├── genimage.cfg           # Image partition layout
│   └── kernel.config          # Full kernel config
└── images/                    # Output directory
```

## Key Technical Details

### Kernel Configuration
- Arch: riscv64
- Cross-compiler: riscv64-linux-gnu-gcc
- Defconfig: milkv-duos_defconfig
- Required modules: USB, Ethernet, WiFi (aic8800), I2S audio

### Rootfs Construction
- Alpine mkimage script for riscv64
- Packages: busybox, musl, linux-firmware, openssh, etc
- Init: OpenRC (Alpine default)
- Shell: ash (BusyBox)

### Image Layout (genimage.cfg)
```
Partition 1: FAT32 128MB - Boot (fip.bin, kernel, dtb)
Partition 2: swap 256MB
Partition 3: ext4 remaining - Root filesystem
```

### WiFi/Firmware
- aic8800 driver requires firmware blobs
- Located in /lib/firmware/aic8800/
- Must be included in rootfs

## Supported Features

| Feature | Status | Notes |
|---------|--------|-------|
| Boot | ✅ | Via vendor FIP + mainline U-Boot |
| Ethernet | ✅ | Built into kernel |
| USB Host | ✅ | USB-A port |
| USB Device | ✅ | USB-C (serial/network) |
| WiFi | ✅ | aic8800 driver |
| Bluetooth | ✅ | aic8800 driver |
| I2S Audio | ✅ | Built-in analog |
| SPI | ✅ | Via device tree |
| I2C | ✅ | Via device tree |
| UART | ✅ | Multiple ports |
| PWM | ✅ | With Duo S |
| GPIO | ✅ | Via sysfs/gpiod |
| Camera/MIPI | ❌ | Not yet mainlined |
| TPU/NPU | ❌ | Not yet mainlined |

## Default Credentials
- **Username:** root
- **Password:** milkv

## Networking
### USB CDC-NCM (Default)
- IP: 192.168.42.1
- Connect: `ssh root@192.168.42.1`

### Ethernet
- DHCP by default
- Or static via `/etc/network/interfaces`

## Important Notes

1. **Docker Only:** Never install build tools on host. Everything runs in containers.
2. **First Boot:** Takes ~2 min for SSH key gen and partition expansion.
3. **CPU Overdrive:** Default 1000MHz (vendor default). Can reduce for power saving.
4. **Partition Expand:** Root partition auto-expands to fill SD card on first boot.

## CRITICAL: Docker Build Rules

**NEVER USE `--no-cache` WITH DOCKER BUILDS!**

This is a hard rule. Breaking it wastes time and bandwidth.

- **BAD:** `docker compose build --no-cache builder`
- **GOOD:** `docker compose build builder`
- **GOOD:** `sudo docker builder prune -f` (if you need to force rebuild)

If a build fails, fix the issue in the Dockerfile, then rebuild normally.
Docker layer caching is our friend - it makes rebuilds fast.

If you absolutely must rebuild from scratch:
```bash
sudo docker builder prune -f
docker compose build builder
```

**NEVER** add `--no-cache` to any docker build command. Not in scripts, not in Makefile, not manually.

## Credits
- Based on: [milkv-duo-ubuntu](https://github.com/queenkjuul/milkv-duo-ubuntu)
- Alpine Linux: [alpinelinux.org](https://alpinelinux.org/)
- Milk-V: [milkv.io](https://milkv.io/)
- Kernel patches: [sophgo-linux](https://github.com/sophgo/linux)

## License
This project is open source. See LICENSE file for details.
