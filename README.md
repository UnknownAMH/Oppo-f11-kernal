# Oppo F11 Kernel (MT6771 / oppo6771)

Linux 4.14.186 kernel source for the Oppo F11 (CPH1911), synchronized with the
locally verified build — this exact source produced a boot-tested kernel on the
CPH1911 (Axion GSI, stock ramdisk).

## Build

See [BUILD_GUIDE.md](BUILD_GUIDE.md) for the full guide. Quick version:

```bash
# put toolchains under ./toolchain (or ../toolchain):
#   clang/host/linux-x86/clang-*/bin           (AOSP clang r383902 / clang 11)
#   gcc/linux-x86/aarch64/aarch64-linux-android-4.9/bin
# clone the Oppo modules tree next to this repo:
#   android_kernel_modules_oppo_mt6771-*

./build.sh kernel      # kernel + module verification disabled
./build.sh modules     # vendor .ko modules with matching vermagic
./build.sh pack        # AnyKernel3 zip (custom recovery)
./build.sh bootimg     # fastboot-ready boot.img (stock ramdisk + AVB flags 3)
```

## Artifacts

| File | Use |
|---|---|
| `results/boot_stockramdisk_avb3.img` | `fastboot flash boot` — proven boot path on this device |
| `results/AnyKernel3_oppo6771.zip` | OrangeFox/TWRP — flashes kernel, pushes modules to `/vendor/lib/modules` |

## Key facts baked into the pipeline

- **AVB**: the boot image's embedded vbmeta needs `Flags = 3` (verification
  disabled) or the device refuses modified kernels. `disable_avb.py` and
  `build.sh bootimg` do this automatically — the vbmeta offset is found by
  scanning for the `AVB0` magic, never hardcoded.
- **Modules**: the git-tree prebuilt `.ko` files are built for a different
  kernel (`4.14.336-+`) and get rejected. The pipeline rebuilds them from source
  with matching vermagic `4.14.186+`; `fpsgo.ko`, `kheaders.ko`, `met.ko`
  (Oppo-built originals) ship in `modules/`.
- **Module signature verification** is forced off (`CONFIG_MODULE_SIG=n`).

