# Bootloader Files

This directory contains the vendor bootloader (FIP) for Milk-V Duo boards.

## Files Needed

### fip.bin
The First Stage Image Processor (FIP) binary is required for booting.
This is a vendor-provided binary blob from Sophgo.

**Where to get it:**
- Download from [Milk-V releases](https://github.com/milkv-duo/duo-sdk/releases)
- Or extract from official Milk-V images

### Directory Structure
```
bootloader/
├── duos/
│   └── fip.bin          # For Duo S (512MB)
├── duo256m/
│   └── fip.bin          # For Duo 256M
└── patches/
    └── *.patch          # Bootloader patches (if needed)
```

## Notes

- The FIP binary is board-specific
- Do NOT modify the FIP binary
- Keep backups of working FIP files
- The build scripts will warn if FIP is missing
