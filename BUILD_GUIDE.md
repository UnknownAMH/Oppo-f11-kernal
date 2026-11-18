# Building the BakaSU kernel (`bakasu` branch)

Oppo F11 / CPH1911 — MT6771, Linux 4.14.186, oppo6771.

This branch is a **pre-patched** kernel tree: the whole patch chain is already
committed, so there is nothing to apply before compiling. What is *not*
committed are the three big external pieces (vendor tree, KernelSU source,
toolchains) — this guide covers getting them.

---

## 1. What the branch already contains

| Component | Where |
|---|---|
| **BakaSU** integration | `drivers/kernelsu` → `../KernelSU/kernel` (source is cloned, not committed) |
| **SUSFS 2.4** (all 10 features) | `fs/susfs.c`, `include/linux/susfs.h`, `include/linux/susfs_def.h` |
| **SUSFS hooks, hand-merged** | `fs/namespace.c`, `fs/notify/fdinfo.c`, `fs/proc/task_mmu.c`, … |
| **Inline (syscall) hooks** | 10 files: exec, open, stat, read_write, namei, selinux, reboot, … |
| **Re:Kernel** (cgroup-v1 adapted) | `drivers/net/rekernel/` |
| **Droidspaces** | `kernel/cgroup/cgroup.c` patch + `arch/arm64/configs/droidspaces.config` |
| **NoMount** | `NoMount/kernel/src/` (`fs/nomount` → `../NoMount/kernel/src`) |
| **BPF arraymap fix** | `kernel/bpf/arraymap.c` (`array_map_update_elem`) |
| **Defconfig** | `arch/arm64/configs/oppo6771_defconfig` — `CONFIG_KSU=y`, all SUSFS features `=y`, `CONFIG_REKERNEL=y`, `CONFIG_NOMOUNT=y` |
| **AnyKernel3 template** | `AnyKernel3/` (CPH1911/OP4863/CPH1969, `do.modules=1`, `/vendor` rw-mount + `resize2fs` fallback) — **no image inside** |
| **Build scripts** | `build.sh`, `setup_build_env.sh`, `disable_avb.py` |

Verified: this source produced a kernel that **booted with working root** on a
CPH1911.

---

## 2. What is missing (and why it is not committed)

| Missing | Path expected | Size | Why external |
|---|---|---|---|
| **Clang r383902** (AOSP clang 11) | `toolchain/clang/host/linux-x86/clang-r383902/bin` | ~600 MB | gitignored, re-downloaded |
| **GCC 4.9 aarch64-linux-android** | `toolchain/gcc/linux-x86/aarch64/aarch64-linux-android-4.9/bin` | ~250 MB | gitignored, re-cloned |
| **KernelSU source (BakaSU)** | `KernelSU/` | ~96 MB | gitignored, re-cloned; `drivers/kernelsu` is a symlink into it |
| **Oppo vendor tree** | `<parent-of-repo>/vendor` | ~1 GB | separate repo; **92 symlinks** in the kernel tree point at `../vendor/*`, 5 of them are real source dependencies |
| `out/` build output | `out/` | 2–3 GB | build artifact |
| Stock boot dump | — | 32 MB | device-specific; needed only for `./build.sh bootimg` |
| Prebuilt `fpsgo.ko`, `kheaders.ko`, `met.ko` | `modules/` | small | no source in the vendor dump; optional extras |

The 5 vendor symlinks that matter:

```
arch/arm64/kernel/rootguard              -> ../../../../vendor/oplus/kernel/secureguard/rootguard/
block/oppo_foreground_io_opt             -> ../../vendor/oplus/kernel/oplus_performance/oppo_foreground_io_opt
drivers/input/oppo_fp_drivers            -> ../../../vendor/oplus/secure/biometrics/fingerprints/bsp/drivers/
drivers/input/oppo_secure_common         -> ../../../vendor/oplus/secure/common/bsp/drivers/
drivers/input/touchscreen/oppo_touchscreen -> ../../../../vendor/oplus/kernel/touchscreen/oppo_touchscreen
```

Without the vendor tree the build fails on dangling symlinks. Without
`KernelSU/` it fails on `drivers/kernelsu`.

---

## 3. Quick start (recommended)

```bash
git clone -b bakasu https://github.com/UnknownAMH/Oppo-f11-kernal.git kernel && cd kernel

./setup_build_env.sh          # toolchain + KernelSU + vendor tree (~1.6 GB, needs network)
./build.sh kernel             # compile (30–90 min on a laptop)
./build.sh modules            # 6 vendor .ko with matching vermagic
./build.sh pack               # flashable zip in results/ (custom recovery)
./build.sh bootimg            # boot.img in results/ (OFOX "install image" / fastboot)
```

`./setup_build_env.sh check` reports what is already present and resolves the
symlinks check; each piece can be fetched separately:
`./setup_build_env.sh toolchain|kernelsu|vendor`.

Host packages: `git curl tar python3` plus a normal kernel build host
(`make`, `bc`, `flex`, `bison`, `libssl-dev`/`openssl`).

---

## 4. Manual prerequisites (if you skip the script)

```bash
# 4.1 Clang r383902
mkdir -p toolchain/clang/host/linux-x86/clang-r383902
curl -L 'https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/+archive/3857008389202edac32d57008bb8c99d2c957f9d/clang-r383902.tar.gz' \
  | tar xz -C toolchain/clang/host/linux-x86/clang-r383902

# 4.2 GCC 4.9 (used for the final link / module link)
git clone --depth=1 -b lineage-19.1 \
  https://github.com/LineageOS/android_prebuilts_gcc_linux-x86_aarch64_aarch64-linux-android-4.9.git \
  toolchain/gcc/linux-x86/aarch64/aarch64-linux-android-4.9

# 4.3 KernelSU (BakaSU) — must be at ./KernelSU
git clone --depth=1 -b main https://github.com/Baka-SU/BakaSU.git KernelSU

# 4.4 Vendor tree — next to the kernel repo, not inside it
git clone --depth=1 -b oppo/mt6771_r_11 \
  https://github.com/oppo-source/android_kernel_modules_oppo_mt6771.git ../android_kernel_modules_oppo_mt6771
ln -s android_kernel_modules_oppo_mt6771/source/vendor ../vendor
# drift fix for kernel-only builds (QC header not present in this tree):
sed -i 's|#include <soc/qcom/smem.h>|#include <linux/uaccess.h>|' \
  ../vendor/oplus/secure/common/bsp/drivers/oppo_secure_common/oppo_secure_common.c
```

`build.sh` auto-detects `./toolchain` (or `../toolchain`), `../android_kernel_modules_oppo_mt6771*`,
and honours `CLANG_DIR`, `GCC_DIR`, `MODULES_SRC`, `STOCK_BOOT`, `MAGISKBOOT`
overrides.

---

## 5. Build modes and outputs

| Command | Output |
|---|---|
| `./build.sh kernel` | `out/arch/arm64/boot/Image.gz-dtb` |
| `./build.sh modules` | `modules/*.ko` (6 modules, strip-debug'd) |
| `./build.sh pack` | `results/AnyKernel3_oppo6771.zip` — kernel + `modules/vendor/lib/modules/*.ko` |
| `./build.sh bootimg` | `results/boot_stockramdisk_avb3.img` — stock ramdisk + AVB `flags=3` |
| `./build.sh` | all of the above, in order |

What `kernel` does before compiling:

1. `make oppo6771_defconfig`
2. disables **module signature verification** (`CONFIG_MODULE_SIG*` off) —
   required so unsigned vendor `.ko` load;
3. `olddefconfig`, then builds `Image.gz-dtb`.

This tree **requires** `CLANG_TRIPLE=aarch64-linux-gnu` (set by `build.sh`);
without it the Makefile errors out.

---

## 6. Flashing the Oppo F11

The boot partition is exactly **32 MiB (33,554,432 bytes)** and the stock image
fills it. Two paths:

**A. Direct boot image (proven)** — `results/boot_stockramdisk_avb3.img`

```bash
adb reboot bootloader           # or OrangeFox -> Reboot -> Fastboot
fastboot flash boot results/boot_stockramdisk_avb3.img
fastboot reboot
```

Or in OrangeFox: *Install → Install image → select the .img → Boot*.

**B. AnyKernel3 zip** — `results/AnyKernel3_oppo6771.zip` from a **custom**
recovery (OrangeFox/TWRP). It installs the kernel, mounts `/vendor` rw and
copies the modules.

If flashing fails with `New image larger than target partition`, use path **A** —
that error means the repacked boot image exceeded the 32 MiB partition.

Flashed and booted successfully already with images built from this source
(Axion GSI, stock ramdisk).

---

## 7. Modules, Wi-Fi and Bluetooth

The kernel is built with `CONFIG_MODVERSIONS`, so a module only loads if its
symbol CRCs match the running kernel. **The stock `/vendor/lib/modules/*.ko`
will not match this kernel** — Wi-Fi/BT/touch modules then fail with
`disagrees about version of symbol` / `Unknown symbol`.

`./build.sh modules` rebuilds the six that matter:

```
wlan_drv_gen3.ko  wmt_chrdev_wifi.ko  wmt_drv.ko  bt_drv.ko  gps_drv.ko  fmradio_drv.ko
```

Expected vermagic: `4.14.186++ SMP preempt mod_unload modversions aarch64`
(the exact kernel release string; `build.sh` prints a mismatch warning).

Install them on the device (with root):

```bash
adb push modules/. /data/local/tmp/mods/
adb shell su -c 'mount -o rw,remount /vendor
  cp /vendor/lib/modules/wlan_drv_gen3.ko /vendor/lib/modules/wlan_drv_gen3.ko.bak
  cp /data/local/tmp/mods/*.ko /vendor/lib/modules/
  chmod 644 /vendor/lib/modules/*.ko'
adb reboot
```

Or just flash the AnyKernel3 zip — it already carries them.

`fpsgo.ko`, `kheaders.ko`, `met.ko` have no source in the vendor dump; if
`dmesg` shows CRC errors for those, they are optional performance modules and
can be removed from `/vendor/lib/modules`.

---

## 8. Verify the build actually contains the features

```bash
grep -E 'CONFIG_KSU=|CONFIG_KSU_SUSFS=|CONFIG_REKERNEL=|CONFIG_NOMOUNT=' out/.config
strings out/vmlinux | grep -cE 'ksud|KernelSU|susfs'      # expect > 0
```

CI fails the build if either check comes back empty — the same test is worth
running locally.

---

## 9. Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `arch/arm64/kernel/rootguard: No such file or directory` | vendor tree missing → `./setup_build_env.sh vendor` |
| `drivers/kernelsu/Kconfig: No such file` | KernelSU missing → `./setup_build_env.sh kernelsu` |
| `error: unable to find clang` / `!! toolchain not found` | toolchain missing → `./setup_build_env.sh toolchain` |
| `Makefile: ... CLANG_TRIPLE ...` | export `CLANG_TRIPLE=aarch64-linux-gnu` (build.sh does it) |
| `BTF: .tmp_vmlinux.btf` / pahole errors | not used here; ignore or install `pahole` |
| `scripts/extract-cert.c` errors about `ENGINE` | old OpenSSL on the host; the pkcs11 branch in this tree is already neutered |
| `New image larger than target partition` | 32 MiB boot partition — flash `results/boot_stockramdisk_avb3.img` instead of the zip |
| Module loads then `disagrees about version of symbol` | module built against another kernel — rebuild with `./build.sh modules` after the kernel |
| `CONFIG_KSU` missing from `out/.config` | wrong defconfig/tree — must be `oppo6771_defconfig` on branch `bakasu` |

---

## 10. CI equivalent

`.github/workflows/build-oppo-f11.yml` in
`UnknownAMH/NonGKI_Kernel_Build_2nd` builds the exact same thing with
`KERNEL_PREPATCHED=true` (no patch steps), `PACK_KMODULES=true`:

- `KERNEL_SOURCE` = this repo, `KERNEL_BRANCH` = `bakasu`
- `KERNELSU_AUTO_FORK` clones `Baka-SU/BakaSU` into `KernelSU/`
- a step clones the vendor repo and creates the `vendor` symlink + drift fix
- kernel build → config/vmlinux sanity check → 6 vendor modules → pack-process
  (which always re-copies the freshly built `Image.gz-dtb`, so a stale image
  inside the AnyKernel3 template can never win)

So a green CI run and a local `./build.sh` should produce equivalent artifacts.
