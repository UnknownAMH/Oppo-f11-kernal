# Oppo F11 Kernel (MT6771 / oppo6771)

Linux 4.14.186 kernel source for the Oppo F11 (CPH1911), synchronized with the
locally verified build — this exact source produced a boot-tested kernel on the
CPH1911 (Axion GSI, stock ramdisk).

## Build

See [BUILD_GUIDE.md](BUILD_GUIDE.md) for the full guide (what the branch has,
what is missing, flashing, Wi-Fi/BT modules, troubleshooting). Quick version:

```bash
./setup_build_env.sh   # fetch the 3 missing pieces: toolchain, KernelSU, vendor tree

./build.sh kernel      # kernel + module verification disabled
./build.sh modules     # vendor .ko modules with matching vermagic
./build.sh pack        # AnyKernel3 zip (custom recovery)
./build.sh bootimg     # fastboot-ready boot.img (stock ramdisk + AVB flags 3)
```

`setup_build_env.sh` replaces the manual steps below (kept for reference):

```bash
# put toolchains under ./toolchain (or ../toolchain):
#   clang/host/linux-x86/clang-*/bin           (AOSP clang r383902 / clang 11)
#   gcc/linux-x86/aarch64/aarch64-linux-android-4.9/bin
# clone the Oppo modules tree next to this repo (and link it as ../vendor):
#   android_kernel_modules_oppo_mt6771-*  ->  ../vendor
# clone BakaSU (KernelSU) into ./KernelSU
```

## What's missing (not in this repo)

Everything below is gitignored or lives in another repository on purpose. The
whole patch chain **is** committed — these are only build inputs and outputs.

| Missing | Expected path | Size | Get it with |
|---|---|---|---|
| Clang r383902 (AOSP clang 11) | `toolchain/clang/host/linux-x86/clang-r383902/bin` | ~600 MB | `./setup_build_env.sh toolchain` |
| GCC 4.9 `aarch64-linux-android` | `toolchain/gcc/linux-x86/aarch64/aarch64-linux-android-4.9/bin` | ~250 MB | `./setup_build_env.sh toolchain` |
| KernelSU source (**BakaSU**) | `KernelSU/` (`drivers/kernelsu` symlinks into it) | ~96 MB | `./setup_build_env.sh kernelsu` |
| Oppo vendor tree | `<parent>/vendor` → modules repo `source/vendor` | ~1 GB | `./setup_build_env.sh vendor` |
| Build output | `out/` | 2–3 GB | produced by `./build.sh kernel` |
| Stock boot dump | device-specific, `STOCK_BOOT=` override | 32 MB | only needed for `./build.sh bootimg` |
| `fpsgo.ko`, `kheaders.ko`, `met.ko` | `modules/` | small | no source in the vendor dump, optional (`PACK_EXTRA=1`) |

Two hard dependencies, if you prefer doing it by hand:

- **`KernelSU/`** — `drivers/kernelsu` is a symlink to `../KernelSU/kernel`, so a
  clone of `https://github.com/Baka-SU/BakaSU.git` (branch `main`) must sit at
  `./KernelSU`, otherwise the kernel build fails on a dangling link.
- **`vendor/`** — 92 symlinks in this tree point at `../vendor/*`; 5 are real
  source (`arch/arm64/kernel/rootguard`, `block/oppo_foreground_io_opt`,
  `drivers/input/oppo_fp_drivers`, `drivers/input/oppo_secure_common`,
  `drivers/input/touchscreen/oppo_touchscreen`). Clone
  `oppo-source/android_kernel_modules_oppo_mt6771` (branch `oppo/mt6771_r_11`)
  next to this repo and link `../vendor` to its `source/vendor`; also apply the
  `oppo_secure_common.c` include drift fix (`soc/qcom/smem.h` →
  `linux/uaccess.h`) — `setup_build_env.sh` does both.

Run `./setup_build_env.sh check` any time to see what is still missing.

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
- **Modules**: the prebuilt `.ko` files in the vendor tree are built for a
  different kernel (`4.14.336-+`) and get rejected under `CONFIG_MODVERSIONS`.
  The pipeline rebuilds the six that matter from source with matching vermagic
  `4.14.186+`. `fpsgo.ko`, `kheaders.ko`, `met.ko` have no source in the vendor
  dump — `modules/` only carries their metadata (`modules.dep` etc.); copy the
  Oppo-built originals there yourself if you want them packed.
- **Module signature verification** is forced off (`CONFIG_MODULE_SIG=n`).

