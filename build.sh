#!/bin/bash
# build.sh — build pipeline for Oppo F11 / CPH1911 (MT6771, oppo6771)
#
# Repo layout assumption: this script lives in the kernel source root.
#   1. kernel  : 4.14.186+, module signature verification DISABLED
#   2. modules : rebuilds the 6 vendor .ko from the Oppo modules tree
#   3. pack    : AnyKernel3 flashable zip (kernel + modules -> /vendor/lib/modules)
#   4. direct  : fastboot-ready boot.img (kernel + stock ramdisk + AVB flags 3)
#
# Usage:
#   ./build.sh                 everything in order
#   ./build.sh kernel          kernel only (long step)
#   ./build.sh modules         vendor modules only
#   ./build.sh pack            AnyKernel3 zip (uses cached kernel)
#   ./build.sh bootimg         direct boot.img (uses cached kernel)
#
# Requirements:
#   - clang r383902 (AOSP clang 11) and gcc 4.9 aarch64-linux-android toolchains
#     placed under ./toolchain (not committed to git) OR in the parent directory,
#     OR set CLANG_DIR / GCC_DIR environment variables.
#   - Oppo modules tree: clone next to this repo (path auto-detected) or set
#     MODULES_SRC. Modules tree top: android_kernel_modules_oppo_mt6771-*
#   - magiskboot for bootimg step: bundled in AnyKernel3/tools/magiskboot (default)
#   - stock boot dump for bootimg step: set STOCK_BOOT (default path below)
set -e

KROOT="$(cd "$(dirname "$0")" && pwd)"
OUT=$KROOT/out
DEFCONFIG=oppo6771_defconfig
JOBS=$(nproc)
RESULT=$KROOT/results
MOD_OUT=$KROOT/modules
AK3_DIR=$KROOT/AnyKernel3

# ---- toolchain detection -----------------------------------------------------
find_tc() {
    for base in "$KROOT/toolchain" "$KROOT/../toolchain" ; do
        if [ -d "$base" ]; then
            C=$(ls -d "$base"/clang/host/linux-x86/clang-*/bin 2>/dev/null | head -1)
            G=$(ls -d "$base"/gcc/linux-x86/aarch64/aarch64-linux-android-4.9/bin 2>/dev/null | head -1)
            [ -n "$C" ] && [ -n "$G" ] && { echo "$C $G"; return; }
        fi
    done
    if [ -n "$CLANG_DIR" ] && [ -n "$GCC_DIR" ]; then echo "$CLANG_DIR $GCC_DIR"; return; fi
    echo ""
}
TCPAIR=$(find_tc)
if [ -z "$TCPAIR" ]; then
    echo "!! toolchain not found. Put AOSP clang r383902 + gcc 4.9 under ./toolchain"
    echo "   (clang/host/linux-x86/clang-*/bin and gcc/linux-x86/aarch64/aarch64-linux-android-4.9/bin)"
    echo "   or set CLANG_DIR and GCC_DIR."
    exit 1
fi
TC=$(echo $TCPAIR | cut -d' ' -f1)
GC=$(echo $TCPAIR | cut -d' ' -f2)

# ---- modules tree detection --------------------------------------------------
find_mod() {
    if [ -n "$MODULES_SRC" ]; then echo "$MODULES_SRC"; return; fi
    for d in "$KROOT"/../android_kernel_modules_oppo_mt6771* ; do
        [ -d "$d" ] && { echo "$d/source/vendor/mediatek/kernel_modules"; return; }
    done
    echo ""
}
MODULES_SRC=$(find_mod)
export CONFIG_MTK_PLATFORM=mt6771
export TARGET_BUILD_VARIANT=user
export CLANG_TRIPLE=aarch64-linux-gnu
export AUTOCONF_H=$OUT/include/generated/autoconf.h

MAKE_ARGS="ARCH=arm64 CC=$TC/clang CROSS_COMPILE=$GC/aarch64-linux-android-"

MODULE_LIST="
gps_drv.ko connectivity/gps
wmt_drv.ko connectivity/common
wmt_chrdev_wifi.ko connectivity/wlan/adaptor
wlan_drv_gen3.ko connectivity/wlan/core/gen3
bt_drv.ko connectivity/bt/mt66xx/legacy
fmradio_drv.ko connectivity/fmradio
"
# Oppo-built originals matching 4.14.186+ (fpsgo/kheaders/met) live in ./modules/

stage() { echo; echo "===== $1 ====="; }

build_kernel() {
stage "kernel: defconfig + disable module signature verification"
cd "$KROOT"
make O=out $MAKE_ARGS $DEFCONFIG
# enforce: modules enabled, signature verification OFF (unsigned .ko load freely)
./scripts/config --file out/.config \
    -e CONFIG_MODULES -e CONFIG_MODVERSIONS \
    -d CONFIG_MODULE_SIG -d CONFIG_MODULE_SIG_FORCE -d CONFIG_MODULE_SIG_SHA256
make O=out $MAKE_ARGS olddefconfig
grep -E 'CONFIG_MODULE_SIG|CONFIG_MODULES=' out/.config
stage "kernel: build (long step)"
make O=out $MAKE_ARGS -j$JOBS Image.gz-dtb
echo "--> $OUT/arch/arm64/boot/Image.gz-dtb"
}

build_modules() {
stage "modules: build vendor .ko against the 4.14 kernel"
if [ ! -d "$MODULES_SRC" ]; then
    echo "!! modules tree not found. Clone the Oppo modules tree next to this repo"
    echo "   (android_kernel_modules_oppo_mt6771-*) or set MODULES_SRC."
    exit 1
fi
cd "$KROOT"
mkdir -p "$MOD_OUT"
# wmt_chrdev_wifi / wlan_drv_gen3 / bt_drv use symbols exported by wmt_drv
# (mtk_wcn_wmt_func_on/off, ...). Separate 'make M=' builds don't see each
# other's Module.symvers, so chain them explicitly (MODULE_LIST order matters).
# This 4.14 modpost reads only ONE extra symvers file (-e stores a single
# entry), so merge every previous module's exports into one file.
EXTRA_SYMS=/tmp/vendor-extra.symvers
: > "$EXTRA_SYMS"
while read -r ko dir; do
    [ -z "$ko" ] && continue
    echo "--- $ko (extra symbols: $EXTRA_SYMS, $(wc -l < "$EXTRA_SYMS") exported)"
    EXTRA_ARG=""
    if [ -n "$EXTRA_SYMS" ]; then EXTRA_ARG="KBUILD_EXTRA_SYMBOLS=$EXTRA_SYMS"; fi
    # KBUILD_MODPOST_WARN: MTK modules reference each other's symbols at load
    # time; modpost cannot always resolve them across separate 'make M=' runs.
    make O=out $MAKE_ARGS $EXTRA_ARG KBUILD_MODPOST_WARN=1 M=$MODULES_SRC/$dir modules \
        || { echo "!! FAILED: $ko"; exit 1; }
    if [ -f "$MODULES_SRC/$dir/Module.symvers" ]; then
        cat "$MODULES_SRC/$dir/Module.symvers" >> "$EXTRA_SYMS"
    fi
    $TC/llvm-objcopy --strip-debug "$MODULES_SRC/$dir/$ko" "$MOD_OUT/$ko"
done <<< "$MODULE_LIST"
for m in fpsgo.ko kheaders.ko met.ko modules.dep modules.alias modules.load modules.softdep; do
    [ -f "$MOD_OUT/$m" ] || echo "   (note: $m is optional / comes from the vendor dump)"
done
echo "--> modules in $MOD_OUT"
}

pack_anykernel() {
stage "pack: AnyKernel3 flashable zip"
[ -d "$AK3_DIR" ] || { echo "!! $AK3_DIR missing"; exit 1; }
[ -f "$OUT/arch/arm64/boot/Image.gz-dtb" ] || { echo "!! kernel not built yet — run ./build.sh kernel"; exit 1; }
# Stage a throwaway copy: the tracked AnyKernel3/ tree is never modified.
STAGE=$(mktemp -d "${TMPDIR:-/tmp}/ak3.XXXXXX")
trap 'rm -rf "$STAGE"' RETURN
cp -rp "$AK3_DIR"/. "$STAGE"/
rm -rf "$STAGE/.git"
# This template installs from modules/vendor/lib/modules -> /vendor/lib/modules
mkdir -p "$STAGE/modules/vendor/lib/modules"
rm -f "$STAGE/modules/vendor/lib/modules/placeholder"
cp -f "$OUT/arch/arm64/boot/Image.gz-dtb" "$STAGE/"
packed=0
while read -r ko _; do
    [ -z "$ko" ] && continue
    if [ -f "$MOD_OUT/$ko" ]; then
        cp -f "$MOD_OUT/$ko" "$STAGE/modules/vendor/lib/modules/"
        packed=$((packed+1))
    else
        echo "   !! $ko missing from $MOD_OUT (run ./build.sh modules)"
    fi
done <<< "$MODULE_LIST"
# Optional extras with no source in the vendor dump (fpsgo/kheaders/met):
# only packed on request, since CRC compatibility is not guaranteed.
if [ "${PACK_EXTRA:-0}" = "1" ]; then
    for ko in "$MOD_OUT"/*.ko; do
        [ -f "$ko" ] || continue
        b=$(basename "$ko")
        case "$MODULE_LIST" in *"$b"*) continue ;; esac
        cp -f "$ko" "$STAGE/modules/vendor/lib/modules/"
        packed=$((packed+1))
    done
fi
if [ "$packed" -eq 0 ]; then
    echo "   !! no .ko packed — the zip would boot but Wi-Fi/BT stay broken"
else
    echo "   packed $packed module(s) -> modules/vendor/lib/modules/"
fi
for f in modules.dep modules.alias modules.softdep modules.load; do
    [ -f "$MOD_OUT/$f" ] && cp -f "$MOD_OUT/$f" "$STAGE/modules/vendor/lib/modules/"
done
mkdir -p "$RESULT"
rm -f "$RESULT/AnyKernel3_oppo6771.zip"
python3 - "$STAGE" "$RESULT/AnyKernel3_oppo6771.zip" <<'EOF'
import os, sys, zipfile
stage, out = sys.argv[1], sys.argv[2]
skip = ('.git', 'README.md', 'anykernel.sh.orig')
with zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED) as z:
    for root, dirs, files in os.walk(stage):
        dirs[:] = [d for d in dirs if d not in ('.git',)]
        for f in files:
            p = os.path.join(root, f)
            rel = os.path.relpath(p, stage)
            if any(s in rel for s in skip):
                continue
            z.write(p, rel)
print("zip entries:", len(zipfile.ZipFile(out).namelist()))
EOF
echo "--> $RESULT/AnyKernel3_oppo6771.zip  (flash from a CUSTOM recovery, e.g. OrangeFox)"
}

pack_bootimg() {
stage "pack: direct fastboot boot.img (kernel + stock ramdisk + AVB flags 3)"
MAGISKBOOT=${MAGISKBOOT:-$AK3_DIR/tools/magiskboot}
STOCK_BOOT=${STOCK_BOOT:-/home/unknown/oppo/Oppo\ f11\ recovery\ Backup/boot.bin}
[ -f "$MAGISKBOOT" ] || { echo "!! magiskboot not found at $MAGISKBOOT (set MAGISKBOOT)"; exit 1; }
[ -f "$STOCK_BOOT" ] || { echo "!! stock boot dump not found at $STOCK_BOOT (set STOCK_BOOT)"; exit 1; }
[ -f "$OUT/arch/arm64/boot/Image.gz-dtb" ] || { echo "!! kernel not built yet — run ./build.sh kernel"; exit 1; }
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
cp "$STOCK_BOOT" "$W/base.bin"
cd "$W"
"$MAGISKBOOT" unpack base.bin >/dev/null
cp "$OUT/arch/arm64/boot/Image.gz-dtb" kernel
"$MAGISKBOOT" repack base.bin >/dev/null
# disable AVB: patch vbmeta Flags (u32 BE) at AVB0_offset + 120
python3 - "$W/new-boot.img" <<'EOF'
import sys
p = sys.argv[1]
d = bytearray(open(p, 'rb').read())
offs, s = [], 0
while True:
    i = d.find(b'AVB0', s)
    if i < 0 or i + 124 > len(d): break
    offs.append(i); s = i + 1
assert offs, "no vbmeta found"
for o in offs:
    d[o+120:o+124] = (3).to_bytes(4, 'big')
    print(f"vbmeta @ 0x{o:x} flags -> 3")
open(p, 'wb').write(d)
EOF
mkdir -p "$RESULT"
cp "$W/new-boot.img" "$RESULT/boot_stockramdisk_avb3.img"
echo "--> $RESULT/boot_stockramdisk_avb3.img  (fastboot flash boot <file>)"
}

case "${1:-all}" in
    kernel)  build_kernel ;;
    modules) build_modules ;;
    pack)    pack_anykernel ;;
    bootimg) pack_bootimg ;;
    all)     build_kernel; build_modules; pack_anykernel; pack_bootimg ;;
    *) echo "usage: $0 [all|kernel|modules|pack|bootimg]"; exit 1 ;;
esac
echo
echo "ALL DONE. Artifacts in $RESULT"
