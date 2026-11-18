#!/usr/bin/env bash
# =============================================================================
#  setup_build_env.sh — stock-branch edition
# =============================================================================
#  This branch is the pristine Oppo F11 (CPH1911 / MT6771, 4.14.186) tree:
#  no BakaSU/KernelSU, no SUSFS, no Re:Kernel, no Droidspaces, no NoMount.
#
#  Two external pieces are needed to compile it and are not committed:
#
#    ./toolchain/        clang r383902 + gcc 4.9 aarch64-linux-android
#    <parent>/vendor     symlink targets of the 90 ../vendor/* links
#
#  (No KernelSU clone is required on this branch — there is no
#   drivers/kernelsu symlink here.)
#
#  Usage:
#    ./setup_build_env.sh            # fetch whatever is missing
#    ./setup_build_env.sh check      # only report what is missing
#    ./setup_build_env.sh toolchain
#    ./setup_build_env.sh vendor
#
#  Needs: git, curl, tar, python3, network, ~1.5 GB disk.
# =============================================================================
set -euo pipefail

KROOT=$(cd "$(dirname "$0")" && pwd)
PARENT=$(dirname "$KROOT")

CLANG_URL="https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/+archive/3857008389202edac32d57008bb8c99d2c957f9d/clang-r383902.tar.gz"
CLANG_DIR="$KROOT/toolchain/clang/host/linux-x86/clang-r383902"
GCC_URL="https://github.com/LineageOS/android_prebuilts_gcc_linux-x86_aarch64_aarch64-linux-android-4.9.git"
GCC_BRANCH="lineage-19.1"
GCC_DIR="$KROOT/toolchain/gcc/linux-x86/aarch64/aarch64-linux-android-4.9"

VENDOR_REPO="https://github.com/oppo-source/android_kernel_modules_oppo_mt6771.git"
VENDOR_BRANCH="oppo/mt6771_r_11"
VENDOR_CLONE="$PARENT/android_kernel_modules_oppo_mt6771"

stage(){ echo; echo "===== $* ====="; }

have_clang(){ [ -x "$CLANG_DIR/bin/clang" ]; }
have_gcc(){ [ -x "$GCC_DIR/bin/aarch64-linux-android-ld" ]; }
have_vendor(){ [ -d "$PARENT/vendor/oplus" ] && [ -d "$PARENT/vendor/mediatek/kernel_modules" ]; }

status(){
    stage "status"
    have_clang  && echo "[OK  ] clang r383902   $CLANG_DIR"   || echo "[MISS] clang r383902   $CLANG_DIR"
    have_gcc    && echo "[OK  ] gcc 4.9        $GCC_DIR"     || echo "[MISS] gcc 4.9        $GCC_DIR"
    have_vendor && echo "[OK  ] vendor tree     $PARENT/vendor" || echo "[MISS] vendor tree     $PARENT/vendor"
    echo "[--  ] KernelSU       not used on the stock branch"
}

do_toolchain(){
    stage "toolchain: clang r383902 (AOSP clang 11)"
    if have_clang; then
        echo "[+] already present, skipping"
    else
        mkdir -p "$CLANG_DIR"
        curl -fL --retry 3 -o /tmp/clang-r383902.tar.gz "$CLANG_URL"
        tar xzf /tmp/clang-r383902.tar.gz -C "$CLANG_DIR"
        rm -f /tmp/clang-r383902.tar.gz
        have_clang || { echo "!! clang extraction failed"; exit 1; }
        echo "[+] $( "$CLANG_DIR/bin/clang" --version | head -1 )"
    fi

    stage "toolchain: gcc 4.9 aarch64-linux-android (LineageOS)"
    if have_gcc; then
        echo "[+] already present, skipping"
    else
        mkdir -p "$(dirname "$GCC_DIR")"
        rm -rf "$GCC_DIR"
        git clone --depth=1 -b "$GCC_BRANCH" "$GCC_URL" "$GCC_DIR"
        rm -rf "$GCC_DIR/.git"
        have_gcc || { echo "!! gcc toolchain incomplete"; exit 1; }
        echo "[+] $( "$GCC_DIR/bin/aarch64-linux-android-ld" --version | head -1 )"
    fi
}

do_vendor(){
    stage "vendor tree: oppo mt6771_r_11 (symlink targets of ../vendor)"
    if [ ! -d "$VENDOR_CLONE/source/vendor/oplus" ]; then
        rm -rf "$VENDOR_CLONE"
        git clone --depth=1 -b "$VENDOR_BRANCH" "$VENDOR_REPO" "$VENDOR_CLONE"
    else
        echo "[+] clone already present, reusing"
    fi

    if [ -L "$PARENT/vendor" ] || [ ! -e "$PARENT/vendor" ]; then
        rm -f "$PARENT/vendor"
        ln -s "$(basename "$VENDOR_CLONE")/source/vendor" "$PARENT/vendor"
        echo "[+] $PARENT/vendor -> $(readlink "$PARENT/vendor")"
    else
        echo "[!] $PARENT/vendor exists and is not a symlink -- leaving it alone"
    fi

    # Drift fix: this copy takes an #else branch that includes a QC header
    # (<soc/qcom/smem.h>) absent from the MT6771 tree when TARGET_PRODUCT is
    # unset (kernel-only builds).
    local f="$VENDOR_CLONE/source/vendor/oplus/secure/common/bsp/drivers/oppo_secure_common/oppo_secure_common.c"
    if [ -f "$f" ] && grep -q '#include <soc/qcom/smem.h>' "$f"; then
        sed -i 's|#include <soc/qcom/smem.h>|#include <linux/uaccess.h>|' "$f"
        echo "[+] oppo_secure_common.c include drift fixed"
    fi

    have_vendor || { echo "!! vendor tree incomplete"; exit 1; }
    echo "[+] symlinks now resolve (rootguard, oppo_foreground_io_opt, oppo_secure_common, ...)"
}

verify_links(){
    stage "verify: repo symlinks that point outside the tree"
    local bad=0
    while IFS= read -r l; do
        if [ ! -e "$KROOT/$l" ]; then
            echo "   dangling: $l -> $(readlink "$KROOT/$l")"
            bad=$((bad+1))
        fi
    done < <(cd "$KROOT" && find . -maxdepth 4 -type l -not -path './out/*' -not -path './toolchain/*' -not -path './.git/*' | sed 's|^\./||')
    if [ "$bad" -eq 0 ]; then echo "[+] all symlinks resolve"; else echo "[!] $bad dangling link(s) -- usually the vendor tree (../vendor)"; fi
    return 0
}

need(){ for c in "$@"; do command -v "$c" >/dev/null || { echo "!! missing host tool: $c"; exit 1; }; done; }
need git curl tar python3

case "${1:-all}" in
    all)       do_toolchain; do_vendor; status; verify_links
               echo; echo "[+] environment ready -- run ./build.sh" ;;
    check)     status; verify_links ;;
    vendor)    do_vendor; verify_links ;;
    toolchain) do_toolchain ;;
    *)         echo "usage: $0 [all|check|vendor|toolchain]"; exit 1 ;;
esac
