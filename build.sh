#!/bin/bash
# =============================================================================
#  build.sh — stock-branch build pipeline (Oppo F11 / CPH1911, MT6771)
# =============================================================================
#  Pristine 4.14.186 Oppo tree: no KernelSU, no SUSFS, no NoMount/Re:Kernel.
#
#  Usage:
#    ./build.sh              # everything: kernel -> modules -> boot.img
#    ./build.sh kernel       # kernel only (long step)
#    ./build.sh modules      # 6 vendor .ko against the compiled kernel
#    ./build.sh bootimg      # boot.img from the cached kernel
#
#  Requirements (see BUILD.md / ./setup_build_env.sh):
#    - clang r383902 + gcc 4.9 under ./toolchain (or ../toolchain), or set
#      CLANG_DIR / GCC_DIR
#    - Oppo modules tree next to this repo (android_kernel_modules_oppo_mt6771*)
#      or set MODULES_SRC
#    - bootimg step: magiskboot (set MAGISKBOOT) + a stock boot dump (STOCK_BOOT)
# =============================================================================
set -e

KROOT="$(cd "$(dirname "$0")" && pwd)"
OUT=$KROOT/out
RESULT=$KROOT/results
MOD_OUT=$KROOT/modules-out
DEFCONFIG=oppo6771_defconfig
JOBS=$(nproc)

# ---- toolchain detection ----------------------------------------------------
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
    echo "   or run ./setup_build_env.sh toolchain (or set CLANG_DIR and GCC_DIR)."
    exit 1
fi
TC=$(echo $TCPAIR | cut -d' ' -f1)
GC=$(echo $TCPAIR | cut -d' ' -f2)

# ---- modules tree detection -------------------------------------------------
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

# Order matters: wmt_drv exports mtk_wcn_wmt_func_on/off used by the others.
MODULE_LIST="
wmt_drv.ko connectivity/common
wmt_chrdev_wifi.ko connectivity/wlan/adaptor
wlan_drv_gen3.ko connectivity/wlan/core/gen3
bt_drv.ko connectivity/bt/mt66xx/legacy
gps_drv.ko connectivity/gps
fmradio_drv.ko connectivity/fmradio
"

stage() { echo; echo "===== $1 ====="; }

build_kernel() {
stage "kernel: $DEFCONFIG"
cd "$KROOT"
make O=out $MAKE_ARGS $DEFCONFIG
# unsigned vendor modules must be able to load (already =n in the stock defconfig)
./scripts/config --file out/.config \
    -e CONFIG_MODULES -e CONFIG_MODVERSIONS \
    -d CONFIG_MODULE_SIG -d CONFIG_MODULE_SIG_FORCE -d CONFIG_MODULE_SIG_SHA256
make O=out $MAKE_ARGS olddefconfig
grep -E 'CONFIG_MODULE_SIG|CONFIG_MODULES=|CONFIG_MODVERSIONS' out/.config

stage "kernel: build (long step)"
make O=out $MAKE_ARGS -j$JOBS Image.gz-dtb
ls -l "$OUT/arch/arm64/boot/Image.gz-dtb"
cat "$OUT/include/config/kernel.release"
}

build_modules() {
stage "modules: build vendor .ko against this kernel"
if [ ! -d "$MODULES_SRC" ]; then
    echo "!! modules tree not found. Clone it next to this repo"
    echo "   (android_kernel_modules_oppo_mt6771-*) or set MODULES_SRC."
    exit 1
fi
mkdir -p "$MOD_OUT"
# Separate 'make M=' runs do not see each other's Module.symvers, and MTK
# modules reference symbols exported by other modules -> chain the symvers and
# tolerate modpost warnings (symbols resolve at load time).
EXTRA_SYMS=""
while read -r ko dir; do
    [ -z "$ko" ] && continue
    echo "--- $ko (extra symbols: ${EXTRA_SYMS:-none})"
    EXTRA_ARG=""
    if [ -n "$EXTRA_SYMS" ]; then EXTRA_ARG="KBUILD_EXTRA_SYMBOLS=$EXTRA_SYMS"; fi
    make O=out $MAKE_ARGS $EXTRA_ARG KBUILD_MODPOST_WARN=1 M=$MODULES_SRC/$dir modules \
        || { echo "!! FAILED: $ko"; exit 1; }
    if [ -f "$MODULES_SRC/$dir/Module.symvers" ]; then
        EXTRA_SYMS="${EXTRA_SYMS:+$EXTRA_SYMS }$MODULES_SRC/$dir/Module.symvers"
    fi
    $TC/llvm-objcopy --strip-debug "$MODULES_SRC/$dir/$ko" "$MOD_OUT/$ko"
done <<< "$MODULE_LIST"

stage "modules: vermagic check"
REL=$(cat "$OUT/include/config/kernel.release")
for ko in "$MOD_OUT"/*.ko; do
    VM=$(strings -a "$ko" | grep -m1 'vermagic=')
    echo "$(basename "$ko"): $VM"
    case "$VM" in *"$REL"*) ;; *) echo "!! vermagic mismatch for $(basename "$ko") (kernel $REL)"; exit 1;; esac
done
echo "--> modules in $MOD_OUT"
}

pack_bootimg() {
stage "pack: boot.img (stock ramdisk + AVB flags 3)"
MAGISKBOOT=${MAGISKBOOT:-$(command -v magiskboot 2>/dev/null || true)}
STOCK_BOOT=${STOCK_BOOT:-}
[ -n "$MAGISKBOOT" ] && [ -x "$MAGISKBOOT" ] || {
    echo "!! magiskboot not found. Set MAGISKBOOT=/path/to/magiskboot"
    echo "   (the stock branch has no bundled AnyKernel3/tools; grab the binary"
    echo "    from the bakasu branch: AnyKernel3/tools/magiskboot)"
    exit 1
}
[ -n "$STOCK_BOOT" ] && [ -f "$STOCK_BOOT" ] || {
    echo "!! stock boot dump not found. Set STOCK_BOOT=/path/to/boot.img"
    exit 1
}
[ -f "$OUT/arch/arm64/boot/Image.gz-dtb" ] || { echo "!! kernel not built yet — run ./build.sh kernel"; exit 1; }
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
cp "$STOCK_BOOT" "$W/base.bin"
cd "$W"
"$MAGISKBOOT" unpack base.bin >/dev/null
cp "$OUT/arch/arm64/boot/Image.gz-dtb" kernel
"$MAGISKBOOT" repack base.bin >/dev/null
# AVB: set vbmeta Flags = 3 (verification disabled) at AVB0 offset + 120
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
SZ=$(stat -c%s "$RESULT/boot_stockramdisk_avb3.img")
echo "--> $RESULT/boot_stockramdisk_avb3.img ($SZ bytes)"
[ "$SZ" -le 33554432 ] || { echo "!! image exceeds the 32 MiB boot partition"; exit 1; }
}

case "${1:-all}" in
    kernel)  build_kernel ;;
    modules) build_modules ;;
    bootimg) pack_bootimg ;;
    all)     build_kernel; build_modules; pack_bootimg ;;
    *) echo "usage: $0 [all|kernel|modules|bootimg]"; exit 1 ;;
esac
echo
echo "DONE. Artifacts: $OUT/arch/arm64/boot/Image.gz-dtb, $MOD_OUT/*.ko, $RESULT/boot_stockramdisk_avb3.img"
