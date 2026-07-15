# Workflows

This repository builds Alpine Linux for the Milk-V Duo 256M (Sophgo SG2002)
entirely inside GitHub Actions. There are three workflows. They all share one
prebaked Docker builder image, published to GitHub Container Registry (GHCR).

## Overview

```
                          GHCR (package registry)
                  +----------------------------------+
                  | ghcr.io/hkcfs/alpine-milk-v/builder
                  |   |- builder-riscv:latest       |
                  |   |- builder-arm64:latest       |
                  |   |- builder:latest (same image)|
                  +----------------------------------+
                       ^ push (build)      | pull (run)
        +--------------+----+   +----------+---------+   +----------+---------+
        | builder.yml        |   | kernel.yml            |   | release.yml           |
        | (image factory)    |   | (weekly compile test) |   | (monthly full image)  |
        | every 2 months     |   | every Monday 03:23 UTC |   | 1st of month 04:37 UTC |
        +--------------------+   +------------------------+   +------------------------+
                  |                       |                            |
            builds + pushes         build-builder job           build-builder job
            the container           (builds + pushes image)      (builds + pushes image)
                                       |                            |
                                       v                            v
                                 kernel matrix                image matrix
                                 riscv -+                  riscv -+
                                 arm64 -+                  arm64 -+
                                  (--kernel-only)              (full build)
                                       |                            |
                                       v                            v
                              GitHub Releases:              GitHub Releases:
                              kernel-<arch>-<date>          duo256m-<arch>-<Y-m>  (img.gz + boot proof)
                              (zip + tar.gz bundle)         duo256m-<Y-m>         (combined notes)
```

## Shared foundation: the builder image

All three workflows ultimately run `build.sh` **inside** the same Docker
container (amd64, built from `docker/Dockerfile`). The container bakes in the
toolchain, `genimage`, `qemu-system`, and your `kernel/` + `scripts/`. It runs
on x86 GitHub runners but cross-builds riscv/arm64 via **binfmt + qemu-user**
(registered with `docker/setup-qemu-action`) so the foreign-arch chroot works.

Two things are mounted in from the workspace for every build:

- `.kernel-src-<arch>` -> `/project/kernel/linux` (the kernel source tree;
  separate per arch so parallel runs do not clobber each other)
- `.ccache` -> `/project/.ccache` (compiler cache, speeds up rebuilds)

Each arch pulls its own prebaked image tag: `builder-riscv` or `builder-arm64`.
All three tags point to the same image.

## 1. builder.yml - the image factory

| | |
|---|---|
| File | `.github/workflows/builder.yml` |
| Trigger | Schedule: 1st and 15th of odd months, 04:17 UTC. Also manual (`workflow_dispatch`). |
| Jobs | one job: `build` |
| Permissions | `packages: write` (to push to GHCR) |
| Output | pushes `builder-riscv`, `builder-arm64`, `builder` to GHCR |

Steps: checkout -> `setup-buildx` -> login to GHCR -> `docker/build-push-action`
builds `docker/Dockerfile` and **pushes** the three tags. Uses GitHub Actions
cache (`type=gha`) so rebuilds are fast.

This keeps the heavy container build off the per-run path. The other two
workflows just pull it.

## 2. kernel.yml - weekly compile smoke-test + update bundle

| | |
|---|---|
| File | `.github/workflows/kernel.yml` |
| Trigger | Schedule: every Monday 03:23 UTC. Also manual. |
| Jobs | `build-builder` -> `kernel` (matrix: riscv, arm64) |
| Purpose | Prove the kernel still compiles from latest source, and ship an updatable bundle. |

Flow:

```
build-builder  -- builds and pushes the same builder image (so the run never
      |            races a missing image)
      v
kernel (riscv) -+
kernel (arm64) -+   (run in parallel; concurrency group = kernel-<arch> so
                       same-arch re-runs queue instead of overlapping)

   each kernel job:
   1. setup-qemu (binfmt)
   2. docker pull builder-<arch>
   3. docker run build.sh --arch <arch> --kernel-only duo256m
         -> builds Image + DTBs + modules ONLY (no rootfs / image)
         -> writes outputs/kernel-<arch>/{Image, dtb/, modules/, *.tar.gz bundle}
   4. package: zip of Image + dtb + modules + patch-report + the .tar.gz bundle
   5. upload artifact (kernel-<arch>.zip)
   6. set date (shell step -> step output)
   7. publish release:
        tag  kernel-<arch>-YYYY-MM-DD
        files kernel-<arch>.zip  +  alpine-milkv-kernel-<arch>.tar.gz
```

Releases produced: `kernel-riscv-2026-07-14`, `kernel-arm64-2026-07-14`, etc.
Each lets a user update a running board with:

```
tar -xzf alpine-milkv-kernel-<arch>.tar.gz -C / && depmod -a && reboot
```

The bundle contains `boot/Image`, `boot/dtb/sophgo/*.dtb`, and
`lib/modules/<kver>/*`, laid out to extract at `/` on the device.

## 3. release.yml - monthly full image + QEMU boot proof

| | |
|---|---|
| File | `.github/workflows/release.yml` |
| Trigger | Schedule: 1st of month 04:37 UTC. Also manual. |
| Jobs | `build-builder` -> `image` (matrix riscv, arm64) -> `release-notes` |
| Purpose | Build the complete flashable SD image, boot it in QEMU to prove it works, and publish. |

Flow:

```
build-builder -- builds and pushes builder image
      |
image (riscv) -+
image (arm64) -+   (parallel; each is a FULL build, not --kernel-only)

   each image job:
   1. setup-qemu (binfmt)
   2. apt-get install qemu-system-riscv64/qemu-system-arm, sshpass, mtools
   3. docker pull builder-<arch>
   4. docker run build.sh --arch <arch> duo256m
         -> kernel + Alpine rootfs + bootloader + genimage
         -> outputs/<arch>/alpine-milkv-duo256m-<arch>.img
   5. capture-boot.sh  -> boots the .img in QEMU, SSHs in, logs proof
                           -> outputs/boot-<arch>.md
   6. gzip the .img
   7. write per-arch release notes (flash command + boot proof)
   8. set date
   9. publish per-arch release:
        tag  duo256m-<arch>-YYYY-MM
        file alpine-milkv-duo256m-<arch>.img.gz
   10. upload boot-<arch>.md artifact

release-notes (after BOTH image jobs finish):
   1. download boot-riscv.md + boot-arm64.md artifacts
   2. assemble one combined NOTES.md (both arches + combined download block)
   3. set date
   4. publish combined release:
        tag  duo256m-YYYY-MM
        body NOTES.md   (notes only, no image files)
```

Releases produced each month:

- `duo256m-riscv-2026-07` and `duo256m-arm64-2026-07` - each with the
  `.img.gz` and the auto-captured QEMU boot proof.
- `duo256m-2026-07` - combined notes pointing at both images.

## How the three relate

- `builder.yml` is the only workflow that *creates* the container.
  `kernel.yml` and `release.yml` each also have a `build-builder` job that
  rebuilds and pushes it (this guarantees the image exists even if
  `builder.yml` has not run recently - it fixes the earlier "image missing"
  race). All three push the identical image under three tags.
- `kernel.yml` is the lightweight weekly check (does the kernel still compile?
  here is an update bundle). `release.yml` is the heavy monthly integration
  test (does the whole image build *and actually boot* in QEMU?).
- **riscv** always uses the latest mainline stable (fetched at build time).
  **arm64** uses the pinned vendor `scpcom/linux` kernel. Both paths live in
  `build.sh`; the workflows just pass `--arch`.

## Local builds

The same `build.sh` drives local builds via the Makefile / docker compose.
Run `make build-image ARCH=riscv` (or `ARCH=arm64`). The image is built
locally as `alpine-milkv-builder:latest` and is not fetched from GHCR.
