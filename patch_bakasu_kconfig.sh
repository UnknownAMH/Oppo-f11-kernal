#!/usr/bin/env bash
# patch_bakasu_kconfig.sh — restore the 10th SUSFS feature option on BakaSU main
#
# BakaSU `main` does not declare CONFIG_KSU_SUSFS_PRIORITY_UID_FILTER in
# KernelSU/kernel/Kconfig. The kernel tree already ships the implementation
# (fs/susfs.c, include/linux/susfs_def.h, fs/namespace.c, the
# getpriority/setpriority/ioprio_{g,s}et hooks) and oppo6771_defconfig enables
# it, but Kconfig silently drops symbols it does not know about -- so the
# feature was compiled out with no error at all.
#
# BakaSU `sync-up` adds the option; this inserts the very same block (idempotent)
# so every build path gets it: ./build.sh, ./setup_build_env.sh, the CI workflow
# and the local Desktop pipeline.
#
# Usage:
#   ./patch_bakasu_kconfig.sh [KernelSU dir]   # default: ./KernelSU
#   ./patch_bakasu_kconfig.sh --revert [dir]   # remove the inserted block
set -euo pipefail

KROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODE=apply
if [ "${1:-}" = "--revert" ]; then
    MODE=revert
    shift
fi
KSU_DIR="${1:-$KROOT/KernelSU}"
KCONFIG="$KSU_DIR/kernel/Kconfig"

[ -f "$KCONFIG" ] || {
    echo "[-] missing $KCONFIG"
    echo "    clone BakaSU first: ./setup_build_env.sh kernelsu"
    exit 1
}

if [ "$MODE" = revert ]; then
    if ! grep -q '^config KSU_SUSFS_PRIORITY_UID_FILTER' "$KCONFIG"; then
        echo "[+] nothing to revert"
        exit 0
    fi
    tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
    awk '
        /^config KSU_SUSFS_PRIORITY_UID_FILTER/ { skip = 1; next }
        skip && (/^config / || /^endmenu/) { skip = 0 }
        !skip { print }
    ' "$KCONFIG" > "$tmp"
    mv "$tmp" "$KCONFIG"
    echo "[+] removed KSU_SUSFS_PRIORITY_UID_FILTER from $KCONFIG"
    exit 0
fi

if grep -q '^config KSU_SUSFS_PRIORITY_UID_FILTER' "$KCONFIG"; then
    echo "[+] KSU_SUSFS_PRIORITY_UID_FILTER already in Kconfig"
    exit 0
fi

grep -q '^menu "KernelSU - SUSFS"' "$KCONFIG" || {
    echo "[-] 'menu \"KernelSU - SUSFS\"' not found in $KCONFIG"
    echo "    BakaSU layout changed -- update patch_bakasu_kconfig.sh"
    exit 1
}

tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
awk '
    /^menu "KernelSU - SUSFS"/ { in_susfs = 1 }
    in_susfs && !done && /^endmenu/ {
        print ""
        print "config KSU_SUSFS_PRIORITY_UID_FILTER"
        print "    bool \"Enable SUSFS priority UID filter\""
        print "    depends on KSU_SUSFS"
        print "    default y"
        print "    help"
        print "        Hide configured application UIDs from getpriority, setpriority,"
        print "        ioprio_get, and ioprio_set for unprivileged app processes."
        print ""
        done = 1
        in_susfs = 0
    }
    { print }
' "$KCONFIG" > "$tmp"

grep -q '^config KSU_SUSFS_PRIORITY_UID_FILTER' "$tmp" || {
    echo "[-] insertion failed"
    exit 1
}
mv "$tmp" "$KCONFIG"
echo "[+] inserted KSU_SUSFS_PRIORITY_UID_FILTER into $KCONFIG"
echo "    verify with: grep -c KSU_SUSFS_PRIORITY out/.config   (expect 1)"
