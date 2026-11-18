# Building this branch (stock / pristine tree)

Oppo F11 / CPH1911 — MT6771, Linux 4.14.186, defconfig `oppo6771_defconfig`.

This branch is the **pristine OEM tree**, kept as a restore/reference point:

- ❌ no KernelSU / BakaSU (no `drivers/kernelsu`)
- ❌ no SUSFS, no Re:Kernel, no Droidspaces
- ❌ no NoMount (no `fs/nomount`), no AnyKernel3 template
- ✅ `build.sh` + `setup_build_env.sh` added for convenience
- ✅ same defconfig / same toolchain as the `bakasu` branch

For the rooted build (BakaSU + SUSFS + hooks + NoMount) use the `bakasu` branch
and its `BUILD_GUIDE.md`.

---

## 1. Quick start

```bash
git clone -b backup-stock-pre-bakasu-20261117 <repo> kernel && cd kernel
./setup_build_env.sh     # toolchain + vendor tree (~1.5 GB, network needed)
./build.sh               # kernel -> 6 vendor modules -> boot.img
```

Individual steps:

```bash
./build.sh kernel     # out/arch/arm64/boot/Image.gz-dtb
./build.sh modules    # modules-out/*.ko  (vermagic-checked)
./build.sh bootimg    # results/boot_stockramdisk_avb3.img (needs MAGISKBOOT + STOCK_BOOT)
```

Host packages (Arch/CachyOS):

```bash
sudo pacman -S --needed base-devel bc flex bison cpio openssl python git curl zip unzip
```

(Debian/Ubuntu: `build-essential bc flex bison cpio libssl-dev python3 git curl`.)

---

## 2. What is missing (not committed)

| Missing | Path | Size | Get it with |
|---|---|---|---|
| Clang r383902 (AOSP clang 11) | `toolchain/clang/host/linux-x86/clang-r383902/bin` | ~600 MB | `./setup_build_env.sh toolchain` |
| GCC 4.9 `aarch64-linux-android` | `toolchain/gcc/linux-x86/aarch64/aarch64-linux-android-4.9/bin` | ~250 MB | `./setup_build_env.sh toolchain` |
| Oppo vendor tree | `<parent>/vendor` → modules repo `source/vendor` | ~1 GB | `./setup_build_env.sh vendor` |
| Build output | `out/` | 2–3 GB | `./build.sh kernel` |
| Stock boot dump | `STOCK_BOOT=` | 32 MB | your own device dump |
| `magiskboot` | `MAGISKBOOT=` | tiny | `AnyKernel3/tools/magiskboot` from the `bakasu` branch, or `command -v magiskboot` |
| KernelSU | — | — | **not used on this branch** |

`setup_build_env.sh` clones the vendor repo **next to** the kernel repo and points
`../vendor` at it (90 symlinks in this tree, 5 of them real source), plus the
`oppo_secure_common.c` include drift fix (`soc/qcom/smem.h` → `linux/uaccess.h`).
`./setup_build_env.sh check` shows what is still missing.

Manual equivalent:

```bash
git clone --depth=1 -b oppo/mt6771_r_11 \
  https://github.com/oppo-source/android_kernel_modules_oppo_mt6771.git ../android_kernel_modules_oppo_mt6771
ln -s android_kernel_modules_oppo_mt6771/source/vendor ../vendor
sed -i 's|#include <soc/qcom/smem.h>|#include <linux/uaccess.h>|' \
  ../vendor/oplus/secure/common/bsp/drivers/oppo_secure_common/oppo_secure_common.c
```

---

## 3. Vendor modules

`./build.sh modules` rebuilds the six that matter for Wi-Fi/BT on this device:

```
wmt_drv.ko  wmt_chrdev_wifi.ko  wlan_drv_gen3.ko  bt_drv.ko  gps_drv.ko  fmradio_drv.ko
```

Two things the script handles for you:

1. **merged symvers** — separate `make M=` builds don't see each other's
   `Module.symvers`; `wmt_drv` is built first and all exports are merged into a
   single file passed via `KBUILD_EXTRA_SYMBOLS` (this 4.14 modpost only reads
   one extra symvers file).
2. **modpost warnings** — MTK modules reference each other's symbols, which the
   kernel resolves at load time; `KBUILD_MODPOST_WARN=1` keeps that non-fatal.

Output goes to `modules-out/*.ko` (kept separate from the tracked `modules/`
metadata dir). `build.sh` prints each module's vermagic and fails on a mismatch
with `out/include/config/kernel.release`.

Install on a rooted device (stock `.ko` will not match a rebuilt kernel under
`CONFIG_MODVERSIONS`):

```bash
adb push modules-out/. /data/local/tmp/mods/
adb shell su -c 'mount -o rw,remount /vendor; cp /data/local/tmp/mods/*.ko /vendor/lib/modules/; chmod 644 /vendor/lib/modules/*.ko'
adb reboot
```

---

## 4. Flashing

Boot partition is exactly **32 MiB**. `./build.sh bootimg` produces
`results/boot_stockramdisk_avb3.img` (stock ramdisk, kernel replaced, AVB
`Flags=3`), and refuses to write an image larger than the partition.

```bash
fastboot flash boot results/boot_stockramdisk_avb3.img
```

Or in OrangeFox: *Install → Install image → select the .img → Boot*.

---

## 5. Notes

- This branch has **no** AnyKernel3 template, so there is no `./build.sh pack`
  (flashable zip). Use the boot image above, or take `AnyKernel3/` from the
  `bakasu` branch.
- `CLANG_TRIPLE=aarch64-linux-gnu` is required by this tree's Makefile;
  `build.sh` exports it.
- No `KernelSU/` clone is needed here — nothing references it.
