# Alpine Linux for Milk-V Duo

Minimal, Docker-based build system for creating Alpine Linux images for Milk-V Duo S and Duo 256M RISC-V SBCs.

## Features

- **Alpine Linux Edge** - Minimal, security-oriented Linux distribution
- **Mainline Kernel** - Latest stable Linux kernel with Milk-V Duo patches
- **Docker-based** - No host dependencies except Docker
- **Both Boards** - Support for Duo S (512MB) and Duo 256M
- **WiFi/Bluetooth** - aic8800 driver support
- **USB** - Host and device mode (CDC-NCM)
- **Audio** - I2S with analog output

## Quick Start

### Prerequisites

- Docker and Docker Compose
- ~10GB free disk space
- SD card (8GB or larger)

### Build Everything

```bash
# Clone the repository
git clone https://github.com/yourusername/alpine-milkv.git
cd alpine-milkv

# Build everything (kernel + rootfs + image)
make all

# Or build step by step
make kernel    # Build kernel
make rootfs    # Build rootfs
make image     # Create SD card image
```

### Flash to SD Card

```bash
# Find your SD card device
lsblk

# Flash (replace /dev/sdX with your device)
make flash SD=/dev/sdX

# Or use dd directly
sudo dd if=images/alpine-milkv-duos.img of=/dev/sdX bs=4M status=progress
```

## Configuration

### Build Options

```bash
# Build for Duo 256M instead of Duo S
make BOARD=duo256m all

# Custom hostname
make HOSTNAME=my-milkv all

# Custom root password
make PASSWORD=secretpassword all

# Disable CPU overdrive (default: 1000MHz -> 850MHz)
make OVERDRIVE=n all
```

### Docker Compose Services

```bash
# Interactive shell in builder
docker compose run --rm builder

# Build only kernel
docker compose run --rm kernel

# Build only rootfs
docker compose run --rm rootfs

# Flash with device access
docker compose run --rm --privileged flash
```

## First Boot

1. Insert SD card into Milk-V Duo
2. Power on (takes ~2 minutes on first boot)
3. Connect via USB (CDC-NCM):
   ```bash
   ssh root@192.168.42.1
   ```
4. Default credentials:
   - Username: `root`
   - Password: `milkv`

## Project Structure

```
alpine-milkv/
├── SOUL.md              # Project documentation
├── Makefile             # Build orchestration
├── docker-compose.yml   # Docker services
├── Dockerfile           # Build environment
├── scripts/
│   ├── build-all.sh     # Full build
│   ├── build-kernel.sh  # Kernel compilation
│   ├── build-rootfs.sh  # Root filesystem
│   ├── build-image.sh   # SD card image
│   ├── flash.sh         # Flash to SD
│   ├── test-image.sh    # Image testing
│   └── setup-kernel-config.sh
├── kernel/
│   └── milkv-duos_defconfig
├── bootloader/
│   └── fip.bin          # Vendor bootloader
├── rootfs/
│   └── apkovl/          # Alpine overlays
└── images/              # Output images
```

## Kernel Configuration

```bash
# Interactive kernel config
make kernel-config

# Enable specific features
./scripts/setup-kernel-config.sh --board=duos
```

## Testing

```bash
# Test image integrity
make test

# Verify partitions and boot files
./scripts/test-image.sh --board=duos
```

## Troubleshooting

### Board doesn't boot

1. Verify SD card is properly inserted
2. Check if `fip.bin` exists in boot partition
3. Try re-flashing the image
4. Check serial console output

### WiFi not working

```bash
# Check if firmware is loaded
ls /lib/firmware/aic8800/

# Load driver manually
modprobe aic8800

# Check interface
ip link show
```

### USB not detected

```bash
# Check USB mode
lsusb

# Switch to device mode
echo device > /sys/kernel/debug/usb/comply/cm_config
```

## Credits

- [milkv-duo-ubuntu](https://github.com/queenkjuul/milkv-duo-ubuntu) - Ubuntu port
- [Alpine Linux](https://alpinelinux.org/) - Base distribution
- [Milk-V](https://milkv.io/) - Hardware
- [Sophgo](https://www.sophgo.com/) - SoC vendor

## License

MIT License - see [LICENSE](LICENSE) for details.
