#!/usr/bin/env bash
# =============================================================================
#  update + build + deliver  for the bakasu kernel branch
# =============================================================================
#  1. update : fast-forward the local branch from  UnknownAMH/Oppo-f11-kernal
#  2. build  : kernel + 6 vendor modules + 32MB boot image (build_bakasu.sh)
#  3. deliver: copies to ~/Desktop/BakaSU_<timestamp>/  (+ .zip)
#  4. commit : commits any source changes and pushes to the bakasu branch
#
#  usage:  ./update_build_bakasu.sh            # everything
#          ./update_build_bakasu.sh --no-push  # skip step 4 push
# =============================================================================
set -euo pipefail

KERNEL_SRC=/home/unknown/android_kernel_oppo_mt6771_stock
BUILDER=/home/unknown/Desktop/KernelBuild/build_bakasu.sh
LOCAL_BRANCH=bakasu-local
REMOTE=bakasu
FORK_URL=https://github.com/UnknownAMH/Oppo-f11-kernal.git
PUSH=${PUSH:-1}

[ "${1:-}" = "--no-push" ] && PUSH=0

TS=$(date +%Y%m%d_%H%M)
OUTDIR=/home/unknown/Desktop/BakaSU_$TS

stage(){ echo; echo "===== $* ====="; }
die(){ echo "!! $*" >&2; exit 1; }

# ---------------------------------------------------------------- 0. token
# Pushing needs auth. Export GITHUB_TOKEN, or edit TOKEN below.
TOKEN=${GITHUB_TOKEN:-${GH_TOKEN:-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}}
AUTH_URL=$(printf '%s' "$FORK_URL" | sed "s|https://|https://UnknownAMH:${TOKEN}@|")

# ---------------------------------------------------------------- 1. update
stage "update: fetching $REMOTE from Oppo-f11-kernal"
cd "$KERNEL_SRC"
git fetch "$AUTH_URL" "$REMOTE" 2>&1 | tail -1
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
stage "commit: source changes -> $REMOTE"
cd "$KERNEL_SRC"
# build outputs are gitignored (out/, *.ko, *.img) - only real source edits land
git add -u
# also pick up new tracked-by-policy files (never the ignored build dirs)
git add -f --dry-run >/dev/null 2>&1 || true

if git diff --cached --quiet; then
    echo "[+] no source changes to commit"
else
    git -c user.name="UnknownAMH" -c user.email="UnknownAMH@users.noreply.github.com" \
        commit -m "build: $TS - kernel $(md5sum out/arch/arm64/boot/Image.gz-dtb | cut -c1-8) modules $(ls /home/unknown/Desktop/KernelBuild/modules/*.ko | wc -l)"
    if [ "$PUSH" = "1" ]; then
        git push "$AUTH_URL" "$LOCAL_BRANCH:$REMOTE" 2>&1 | tail -1
    else
        echo "[+] --no-push: commit kept locally"
    fi
fi

stage "done"
cat <<EOF
boot image : $OUTDIR/new-boot.img        <- OFOX > Install image > boot
kernel     : $OUTDIR/Image.gz-dtb
modules    : $OUTDIR/modules/*.ko        <- must match the flashed kernel
zip        : $OUTDIR/BakaSU_CPH1911_$TS.tar.gz
EOF
