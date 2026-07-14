# Alpine Linux for the Milk-V Duo 256M (SG2002)

Minimal, Docker-based build system that produces flashable **Alpine Linux**
images for the **Milk-V Duo 256M** (Sophgo SG2002) — both the **RISC-V**
(C906) and **ARM64** (Cortex-A53) cores. The latest Alpine release is pulled
in automatically, so the images stay current with no manual intervention.

## Features

- **Alpine Linux** (latest stable, currently 3.24) — minimal and secure
- **RISC-V kernel** — `build.sh` fetches the newest **stable mainline** kernel
  from kernel.org on every build
- **ARM64 kernel** — uses the proven **vendor kernel from `scpcom/linux`**
  (`licheervnano-merged-5.10.y`, ≈ v5.10.260), since mainline Linux has no
  arm64 SG2002 support. This is what actually runs on the Duo 256M's Cortex-A53.
- **Two architectures** — `riscv` (default) and `arm64`, selectable per build
- **Docker-only** — no host toolchain needed; everything builds inside a
  container
- **Automated** — GitHub Actions builds the kernel weekly and the full image
  monthly, and **boots each image in QEMU to prove it works** before publishing

## Quick start (local build)

```bash
# Build the RISC-V image (default)
make build-image

# Build the ARM64 image
make build-image ARCH=arm64
```

`build.sh` runs inside the builder container and uses absolute `/project/...`
paths, so always drive it via `make` / `docker compose` (never call it directly
on the host). The resulting image is written to
`outputs/<arch>/alpine-milkv-duo256m-<arch>.img`.

### Flash to SD card

```bash
lsblk                                   # find your SD card
gzip -cd outputs/riscv/alpine-milkv-duo256m-riscv.img.gz \
  | sudo dd of=/dev/sdX bs=4M status=progress
```

## Project layout

```
.
├── build.sh                 # Main build script (kernel + rootfs + image)
├── Makefile                 # Convenience wrappers (make build-image)
├── docker/
│   ├── Dockerfile           # Builder image (toolchain, genimage, deps)
│   ├── docker-compose.yml   # binfmt + builder services
│   └── .dockerignore
├── genimage.cfg             # SD card partition layout
├── kernel/
│   ├── milkv-duo256m_defconfig   # RISC-V kernel config (latest stable mainline)
│   ├── patches/             # RISC-V out-of-tree patches
│   └── arm64-sg200x/        # ARM64 vendor kernel assets (scpcom/linux)
│       ├── defconfig        # Duo 256M ARM64 defconfig
│       ├── dts/             # Board DTS (cv181x_milkv_duo256m_sd.dts)
│       └── patches/         # Vendor driver backports (mailbox, reset, ...)
├── milkv-bootloader/
│   ├── duo256m/             # RISC-V fip.bin
│   └── duo256m-arm64/       # ARM64 (Cortex-A53) fip.bin
├── scripts/
│   ├── setup.sh             # Installs build deps inside the container
│   ├── second-stage.sh      # Rootfs configuration (runs in chroot)
│   ├── first-boot.sh        # First-boot partition expansion / SSH keygen
│   └── capture-boot.sh      # Boots an image in QEMU and logs proof for releases
├── packages/                # Custom out-of-tree packages (kernel modules / userspace)
│   ├── kernel-modules/
│   └── userspace/
├── outputs/                 # Build artifacts (git-ignored)
└── .github/workflows/       # builder (2-month) / kernel (weekly) / release (monthly)
```

## Automated builds (GitHub Actions)

| Workflow        | Schedule            | Produces                                         |
|-----------------|---------------------|--------------------------------------------------|
| `builder.yml`   | every 2 months      | Prebaked builder image → GHCR (fast CI runs)     |
| `kernel.yml`    | every Monday        | Latest kernel `Image` + DTBs per arch (release)  |
| `release.yml`   | 1st of each month   | Full flashable image, **boot-tested in QEMU**, release with boot log |

Each monthly release's notes contain a code block with the **entire QEMU boot
log + SSH diagnostics**, so you can see the auto-built image actually boots
before you flash it.

## First boot

1. Flash the image to an SD card and insert it into the Duo 256M.
2. Power on (first boot expands the root partition).
3. Connect over serial (`ttyS0`, 115200n8) or SSH once networking is up.
4. Default credentials — user `root`, password `milkv`.

## Credits

- [milkv-duo-ubuntu](https://github.com/queenkjuul/milkv-duo-ubuntu) — original Ubuntu port
- [scpcom/sophgo-sg200x-debian](https://github.com/scpcom/sophgo-sg200x-debian) — SG200x kernel/slim-config reference
- [lupyuen/nuttx-sg2000](https://github.com/lupyuen/nuttx-sg2000) — automated daily-build + boot-proof release pattern
- [Alpine Linux](https://alpinelinux.org/), [Milk-V](https://milkv.io/), [Sophgo](https://www.sophgo.com/)

## License

MIT — see [LICENSE](LICENSE).
