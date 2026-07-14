# SOUL.md - Alpine Linux for Milk-V Duo

## Project Identity

**Name:** alpine-milkv
**Purpose:** Minimal Alpine Linux distribution for the Milk-V Duo 256M (SG2002) SBC
**Base:** Alpine Linux v3.24 (3.24.1)
**Kernel:** Latest stable Linux (auto-fetched from kernel.org, currently 7.1.3) with Milk-V Duo patches
**Target Hardware:** Sophgo SG2002 (RISC-V C906 + ARM64 Cortex-A53, 256MB)

## Hardware Specifications

### Milk-V Duo 256M (the only supported board)
- **CPU:** Sophgo SG2002 — RISC-V C906 @ 1GHz (riscv arch) **and** ARM64 Cortex-A53 (arm64 arch), switchable
- **RAM:** 256MB DDR3
- **Storage:** microSD slot
- **USB:** USB-C only (CDC-NCM device mode)
- **GPIO:** 26 pins

## Build System

### Prerequisites
- Docker, Docker Compose, and `tonistiigi/binfmt` (or `multiarch/qemu-user-static`) for arm64 emulation
- ~10GB free disk space

### Build Commands
```bash
# Build the RISC-V image (default board: duo256m)
docker compose run --rm builder bash /project/build.sh duo256m

# Build the ARM64 image
docker compose run --rm builder bash /project/build.sh --arch arm64 duo256m
```

Outputs land in `outputs/` (the compose `images` volume maps there):
`outputs/<arch>/alpine-milkv-duo256m-<arch>.img`, `outputs/kernel-<arch>/Image`,
`outputs/<arch>/{boot,dtb,swap,fip}`.

### QEMU Testing / Release Boot-Proof
```bash
# RISC-V (QEMU 'virt' supplies its own DTB; -kernel uses the build-time Image)
sudo qemu-system-riscv64 -machine virt -m 256M -nographic \
  -kernel outputs/kernel-riscv/Image \
  -append 'console=ttyS0 root=/dev/vda3 rootwait rw' \
  -drive  file=outputs/riscv/alpine-milkv-duo256m-riscv.img,format=raw,if=none,id=hd0 \
  -device virtio-blk-device,drive=hd0 \
  -netdev user,id=net0,hostfwd=tcp::2222-:22 -device virtio-net-device,netdev=net0

# ARM64
sudo qemu-system-aarch64 -machine virt -m 256M -cpu cortex-a53 -nographic \
  -kernel outputs/kernel-arm64/Image \
  -append 'console=ttyAMA0 root=/dev/vda3 rootwait rw' \
  -drive  file=outputs/arm64/alpine-milkv-duo256m-arm64.img,format=raw,if=none,id=hd0 \
  -device virtio-blk-device,drive=hd0 \
  -netdev user,id=net0,hostfwd=tcp::2223-:22 -device virtio-net-device,netdev=net0
```
The `scripts/capture-boot.sh <arch> <img> <kernel>` wrapper runs this and writes
the full boot log + SSH diagnostics to a fenced code block for the release notes.

## Project Structure
```
alpine-milk-v/
├── SOUL.md                    # This file
├── build.sh                   # Main build script (kernel + rootfs + image)
├── Makefile                   # Convenience wrappers (make build-image)
├── docker/
│   ├── Dockerfile             # Build container (Ubuntu 24.04 + riscv/arm64 cross-tools)
│   ├── docker-compose.yml     # binfmt + builder services
│   └── .dockerignore
├── genimage.cfg               # SD card partition layout
├── scripts/
│   ├── second-stage.sh        # Alpine rootfs configuration
│   ├── first-boot.sh          # First boot setup (partition expand, SSH keys)
│   ├── setup.sh               # Build container dependencies (+ ccache)
│   └── capture-boot.sh        # QEMU boot proof for releases
├── kernel/
│   ├── milkv-duo256m_defconfig # RISC-V kernel config (latest stable mainline)
│   ├── patches/               # RISC-V out-of-tree patches for CV18XX/SG200X
│   └── arm64-sg200x/          # ARM64 vendor kernel assets (scpcom/linux)
│       ├── defconfig          # Duo 256M ARM64 defconfig
│       ├── dts/               # Board DTS (cv181x_milkv_duo256m_sd.dts)
│       └── patches/           # Vendor driver backports (mailbox, reset, ...)
├── milkv-bootloader/
│   ├── duo256m/               # RISC-V fip.bin
│   └── duo256m-arm64/         # ARM64 (Cortex-A53) fip.bin
├── packages/                  # Custom out-of-tree packages
│   ├── kernel-modules/
│   └── userspace/
└── outputs/                   # Build artifacts (git-ignored)

## Build Behavior

### Automatic Kernel Management
- **Always fetches latest stable kernel** from kernel.org
- If version changes, re-downloads and re-patches
- Applies out-of-tree patches automatically (logged to `outputs/<arch>/patch-report.txt`)
- Failed/skipped patches are reported but do not abort the build

### Patch Strategy
The RISC-V build uses the **latest stable mainline kernel** (kernel.org) with
out-of-tree patches that add SG200X SoC/board support (DTS, thermal, PWM,
remote-proc C906L, DMA, Ethernet MDIO mux, eFuse, I2S/audio, timer/watchdog,
mailbox).

The **ARM64** build targets the real Duo 256M Cortex-A53 core and uses the
**vendor kernel from `scpcom/linux`** (branch `licheervnano-merged-5.10.y`,
pinned at `f5fb0eb` ≈ v5.10.260). Mainline Linux has no arm64 SG2002 support,
so the proven sophgo-sg200x-debian vendor tree is used. Its defconfig, board
DTS and driver backports live under `kernel/arm64-sg200x/`. On a persistent
source volume the correct tree is (re)cloned automatically when the arch
switches, and `git reset --hard HEAD` restores a pristine tree before patching.

See [sophgo-sg200x-debian](https://github.com/scpcom/sophgo-sg200x-debian) and
[Sophgo Linux Wiki](https://github.com/sophgo/linux/wiki) for upstream status.

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
