#!/usr/bin/env bash
# =============================================================================
#  Oppo F11 (CPH1911) - BakaSU kernel build  (permanent local pipeline)
# =============================================================================
#  Kernel tree: android_kernel_oppo_mt6771_stock, branch `bakasu-local`
#  (full patch chain already committed: BakaSU + SUSFS 2.4 all features +
#   inline hooks + Re:Kernel cgroup-v1 + Droidspaces + NoMount + BPF fix).
#
#  Outputs:
#    results/new-boot.img     32MB boot image, AVB flags=3, ready for OFOX
#    modules/*.ko             6 vendor modules built against this kernel
#
#  Usage:
#    ./build_bakasu.sh            # kernel + modules + boot image
#    ./build_bakasu.sh kernel     # kernel only
#    ./build_bakasu.sh modules    # modules only
#    ./build_bakasu.sh pack       # repack boot image from existing Image
#
#  NOTE: the 6 vendor .ko MUST be installed together with the kernel
#  (stock prebuilt modules are CRC-incompatible under MODVERSIONS -> no Wi-Fi/BT).
# =============================================================================
set -euo pipefail

KERNEL_SRC=/home/unknown/android_kernel_oppo_mt6771_stock
MODULES_SRC=/home/unknown/android_kernel_modules_oppo_mt6771-oppo-mt6771_r_11/source/vendor/mediatek/kernel_modules
RESULT=/home/unknown/Desktop/KernelBuild/results
MOD_OUT=/home/unknown/Desktop/KernelBuild/modules
STOCK_BOOT="/home/unknown/oppo/Oppo f11 recovery Backup/boot.bin"
MAGISKBOOT=/home/unknown/magisk_work/tools/magiskboot
JOBS=$(nproc)

TC=$KERNEL_SRC/toolchain/clang/host/linux-x86/clang-r383902/bin
GC=$KERNEL_SRC/toolchain/gcc/linux-x86/aarch64/aarch64-linux-android-4.9/bin
export CLANG_TRIPLE=aarch64-linux-gnu          # required by this tree's Makefile
export CONFIG_MTK_PLATFORM=mt6771
export TARGET_BUILD_VARIANT=user
MAKE_ARGS="ARCH=arm64 CC=$TC/clang CROSS_COMPILE=$GC/aarch64-linux-android-"

# ko  <->  dir relative to MODULES_SRC   (gps/fmradio live under connectivity/)
MODULE_LIST="
wmt_drv.ko connectivity/common
wmt_chrdev_wifi.ko connectivity/wlan/adaptor
wlan_drv_gen3.ko connectivity/wlan/core/gen3
bt_drv.ko connectivity/bt/mt66xx/legacy
gps_drv.ko connectivity/gps
fmradio_drv.ko connectivity/fmradio
"

stage(){ echo; echo "===== $1 ====="; }

check_toolchain(){
    [ -x "$TC/clang" ] || { echo "!! missing clang at $TC"; exit 1; }
    [ -x "$GC/aarch64-linux-android-as" ] && [ -x "$GC/aarch64-linux-android-ld" ] || { echo "!! missing binutils at $GC"; exit 1; }
    "$TC/clang" --version | head -1
}

kernel_build(){
    stage "kernel: defconfig + build"
    cd "$KERNEL_SRC"
    export AUTOCONF_H=$KERNEL_SRC/out/include/generated/autoconf.h

    make O=out $MAKE_ARGS oppo6771_defconfig
    # module signature verification OFF (unsigned modules load freely)
    ./scripts/config --file out/.config \
        -e CONFIG_MODULES -e CONFIG_MODVERSIONS \
        -d CONFIG_MODULE_SIG -d CONFIG_MODULE_SIG_FORCE -d CONFIG_MODULE_SIG_SHA256
    # Droidspaces fragment (same merge as CI)
    ./scripts/kconfig/merge_config.sh -O out/ -m out/.config arch/arm64/configs/droidspaces.config
    make O=out $MAKE_ARGS olddefconfig

    stage "kernel: config sanity check"
    grep -E 'CONFIG_KSU=|CONFIG_KSU_SUSFS=|CONFIG_KSU_SUSFS_(SUS_PATH|SUS_MOUNT|SUS_KSTAT|SPOOF_UNAME|ENABLE_LOG|HIDE_KSU_SUSFS_SYMBOLS|SPOOF_CMDLINE_OR_BOOTCONFIG|OPEN_REDIRECT|SUS_MAP)=y$|CONFIG_REKERNEL=|CONFIG_NOMOUNT=' out/.config \
        || { echo "!! KSU/SUSFS configs missing - tree not patched?"; exit 1; }

    make -j"$JOBS" O=out $MAKE_ARGS 2>&1 | tee error.log
    grep -qE '^  (LD|OBJCOPY|GZIP|CAT)' error.log || true

    stage "kernel: image sanity check"
    local img=out/arch/arm64/boot/Image.gz-dtb
    ls -l "$img"
    md5sum "$img"
    local hits
    hits=$(strings out/vmlinux | grep -cE 'ksud|KernelSU|susfs' || true)
    echo "KSU/SUSFS string hits in vmlinux: $hits"
    [ "$hits" -gt 0 ] || { echo "!! vmlinux has no KSU/SUSFS - patch chain missing!"; exit 1; }
    echo "[+] kernel OK: $(cat out/include/config/kernel.release)"
}

modules_build(){
    stage "modules: build 6 vendor .ko against this kernel"
    cd "$KERNEL_SRC"
    export AUTOCONF_H=$KERNEL_SRC/out/include/generated/autoconf.h
    mkdir -p "$MOD_OUT"
    echo "$MODULE_LIST" | while read -r ko dir; do
        [ -z "$ko" ] && continue
        echo "--- $ko ($dir)"
        make O=out $MAKE_ARGS M="$MODULES_SRC/$dir" modules || { echo "!! FAILED: $ko"; exit 1; }
        "$TC/llvm-objcopy" --strip-debug "$MODULES_SRC/$dir/$ko" "$MOD_OUT/$ko"
    done
    local rel; rel=$(cat out/include/config/kernel.release)
    echo "$MODULE_LIST" | while read -r ko _; do
        [ -z "$ko" ] && continue
        local vm; vm=$(strings -a "$MOD_OUT/$ko" | grep -m1 'vermagic=')
        echo "$ko -> $vm"
        case "$vm" in *"$rel"*) ;; *) echo "!! vermagic mismatch for $ko (kernel $rel)"; exit 1;; esac
    done
    echo "[+] modules OK in $MOD_OUT"
}

pack_boot(){
    stage "pack: boot image (kernel + stock ramdisk + modules note) + AVB flags=3"
    local W; W=$(mktemp -d /tmp/bootpack.XXXXXX)
    trap 'rm -rf "$W"' RETURN
    cp "$STOCK_BOOT" "$W/base.bin"
    ( cd "$W" && "$MAGISKBOOT" unpack base.bin >/dev/null \
        && cp "$KERNEL_SRC/out/arch/arm64/boot/Image.gz-dtb" kernel \
        && "$MAGISKBOOT" repack base.bin >/dev/null )
    python3 - "$W/new-boot.img" <<'PY'
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
open(p, 'wb').write(d)
print("vbmeta flags -> 3 at", [hex(o) for o in offs])
PY
    mkdir -p "$RESULT"
    cp "$W/new-boot.img" "$RESULT/new-boot.img"
    ls -l "$RESULT/new-boot.img"
    local sz; sz=$(stat -c%s "$RESULT/new-boot.img")
    [ "$sz" -le 33554432 ] || { echo "!! image too big for 32MB boot partition"; exit 1; }
    echo "[+] $RESULT/new-boot.img  (flash via OFOX -> Install image -> boot)"
}

case "${1:-all}" in
    kernel)  check_toolchain; kernel_build ;;
    modules) check_toolchain; modules_build ;;
    pack)    pack_boot ;;
    all)     check_toolchain; kernel_build; modules_build; pack_boot ;;
    *)       echo "usage: $0 [all|kernel|modules|pack]"; exit 1 ;;
esac

stage "done"
cat <<EOF
Kernel image : $KERNEL_SRC/out/arch/arm64/boot/Image.gz-dtb
Boot image   : $RESULT/new-boot.img        <- flash this
Modules      : $MOD_OUT/*.ko               <- push to /vendor/lib/modules (back up originals!)
                       adb push $MOD_OUT/. /data/local/tmp/modules/
                       adb shell su -c 'mount -o rw,remount /vendor; cp /data/local/tmp/modules/*.ko /vendor/lib/modules/; chmod 644 /vendor/lib/modules/*.ko'
EOF
