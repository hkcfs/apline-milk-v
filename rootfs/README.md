# Root Filesystem Overlays

This directory contains Alpine Linux rootfs customizations.

## Directory Structure

```
rootfs/
├── apkovl/              # Alpine package overlays (.tar.gz)
├── packages/            # Custom packages to install
└── overlays/            # Files to copy into rootfs
    └── etc/             # System configuration
        ├── network/
        ├── init.d/
        └── ...
```

## Adding Custom Files

### System Configuration
Place files in `overlays/etc/` to add to `/etc/` on the target:
```
overlays/etc/hostname      -> /etc/hostname
overlays/etc/hosts         -> /etc/hosts
overlays/etc/network/interfaces -> /etc/network/interfaces
```

### Init Scripts
Place OpenRC init scripts in `overlays/etc/init.d/`:
```
overlays/etc/init.d/my-service -> /etc/init.d/my-service
```

### Custom Packages
Place `.apk` packages in `packages/` to install during rootfs build.

## Alpine Overlays (apkovl)

Create tar.gz archives with custom package sets:
```bash
tar -czf custom-nginx.apkovl etc/nginx usr/sbin/nginx
```

Place in `apkovl/` directory for inclusion.
