#!/usr/bin/env bash
# =============================================================================
#  update + build + deliver  for the bakasu kernel branch
# =============================================================================
#  1. update : fast-forward the local branch from  UnknownAMH/Oppo-f11-kernal
#              (public repo - anonymous fetch, no token needed)
#  2. build  : kernel + 6 vendor modules + 32MB boot image (build_bakasu.sh)
#  3. deliver: copies to ~/Desktop/BakaSU_<timestamp>/  (+ .tar.gz)
#  4. commit : commits any source changes LOCALLY (no push - you push manually)
#
#  usage:  ./update_build_bakasu.sh
#
#  to publish the commit when ready:
#     git -C /home/unknown/android_kernel_oppo_mt6771_stock push fork bakasu
# =============================================================================
set -euo pipefail

KERNEL_SRC=/home/unknown/android_kernel_oppo_mt6771_stock
BUILDER=/home/unknown/Desktop/KernelBuild/build_bakasu.sh
LOCAL_BRANCH=bakasu
REMOTE=bakasu
FORK_URL=https://github.com/UnknownAMH/Oppo-f11-kernal.git

TS=$(date +%Y%m%d_%H%M)
OUTDIR=/home/unknown/Desktop/BakaSU_$TS

stage(){ echo; echo "===== $* ====="; }

# ---------------------------------------------------------------- 1. update
stage "update: fetching $REMOTE from Oppo-f11-kernal"
cd "$KERNEL_SRC"
git fetch "$FORK_URL" "$REMOTE" 2>&1 | tail -1
git checkout "$LOCAL_BRANCH" 2>/dev/null || git checkout -b "$LOCAL_BRANCH"

if git merge-base --is-ancestor FETCH_HEAD HEAD; then
    echo "[+] already up to date with origin/$REMOTE"
elif [ -z "$(git status --porcelain | grep -v '^??')" ]; then
    git merge --ff-only FETCH_HEAD && echo "[+] fast-forwarded to $(git rev-parse --short HEAD)"
else
    echo "[!] local uncommitted changes -> skipping update; building current tree"
fi

echo "--- HEAD: $(git log --oneline -1)"

# ---------------------------------------------------------------- 2. build
stage "build: kernel + modules + boot image"
bash "$BUILDER" all

# ---------------------------------------------------------------- 3. deliver
stage "deliver: $OUTDIR"
mkdir -p "$OUTDIR/modules"
cp "$KERNEL_SRC/out/arch/arm64/boot/Image.gz-dtb" "$OUTDIR/"
cp /home/unknown/Desktop/KernelBuild/results/new-boot.img "$OUTDIR/"
cp /home/unknown/Desktop/KernelBuild/modules/*.ko "$OUTDIR/modules/"
cp "$KERNEL_SRC/out/.config" "$OUTDIR/.config"
(
  cd "$OUTDIR"
  tar czf "BakaSU_CPH1911_$TS.tar.gz" new-boot.img Image.gz-dtb .config modules/*.ko
)
echo "--- delivered:"
ls -l "$OUTDIR"
md5sum "$OUTDIR/new-boot.img" "$OUTDIR/Image.gz-dtb"

# ---------------------------------------------------------------- 4. commit
stage "commit: source changes (local only, no push)"
cd "$KERNEL_SRC"
# build outputs are gitignored (out/, *.ko, *.img), so -A only picks up real
# source work: modifications AND brand-new files (git add -u missed new files)
git add -A
echo "--- staged:"
git diff --cached --stat | tail -20

if git diff --cached --quiet; then
    echo "[+] no source changes to commit"
else
    git -c user.name="UnknownAMH" -c user.email="UnknownAMH@users.noreply.github.com" \
        commit -m "build: $TS - kernel $(md5sum out/arch/arm64/boot/Image.gz-dtb | cut -c1-8) modules $(ls /home/unknown/Desktop/KernelBuild/modules/*.ko | wc -l)"
    echo "[+] committed locally - push manually when ready:"
    echo "    git -C $KERNEL_SRC push fork $LOCAL_BRANCH:$REMOTE"
fi

stage "done"
cat <<EOF
boot image : $OUTDIR/new-boot.img        <- OFOX > Install image > boot
kernel     : $OUTDIR/Image.gz-dtb
modules    : $OUTDIR/modules/*.ko        <- must match the flashed kernel
tar.gz     : $OUTDIR/BakaSU_CPH1911_$TS.tar.gz
EOF
