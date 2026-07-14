# Custom packages

This directory holds out-of-tree packages that get baked into the image
alongside the stock Alpine + mainline kernel. It mirrors the way the kernel
lives in its own tree (`kernel/`) - keep board-specific extras here instead of
patching the rootfs by hand.

```
packages/
|-- userspace/      # prebuilt .apk packages installed into the rootfs
`-- kernel-modules/ # out-of-tree .ko kernel modules for the running kernel
```

## userspace/

Drop prebuilt `.apk` packages in `packages/userspace/`. During the rootfs
stage (`scripts/second-stage.sh`) each one is installed with:

```sh
apk add --allow-untrusted --no-cache packages/userspace/<pkg>.apk
```

To build an `.apk` from your own source, use `apk-tools`/`abuild` on Alpine
(e.g. `abuild -r`) and copy the resulting package here.

## kernel-modules/

Drop out-of-tree `.ko` modules in `packages/kernel-modules/`. They are copied
to `/lib/modules/<kernel-version>/extra/` and `depmod` is run so they load on
boot. Build them against the kernel source that `build.sh` checks out
(`kernel/linux`), using the same `ARCH`/`CROSS_COMPILE` as the main build.

## Notes

- Both subdirs are optional - an empty dir is a no-op.
- The mechanism is wired into the build (`build.sh` copies `packages/` into the
  rootfs; `scripts/second-stage.sh` installs from it). No extra step required.
