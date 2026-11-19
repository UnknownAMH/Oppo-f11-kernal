#!/usr/bin/env bash
# update_bakasu.sh — refresh the vendored BakaSU source (KernelSU/kernel + uapi)
#
# BakaSU is committed in this branch (see KernelSU/VENDORED.md). This script
# pulls a newer snapshot from upstream, swaps it in, re-applies the Kconfig
# safety net and updates the VENDORED.md metadata.
#
# Usage:
#   ./update_bakasu.sh                     # update from Baka-SU/BakaSU main
#   ./update_bakasu.sh sync-up             # update from the dev branch
#   ./update_bakasu.sh main --check        # show what would change, touch nothing
#   ./update_bakasu.sh sync-up --build     # update, then build + commit locally
#   ./update_bakasu.sh <branch> --force    # overwrite local edits in KernelSU/
#
# What it updates:
#   KernelSU/kernel/  KernelSU/uapi/   (BakaSU kernel side; uapi is needed by
#                                       kernel/include/uapi -> ../../uapi)
#   KernelSU/kernel/Kconfig            (CONFIG_KSU_SUSFS_PRIORITY_UID_FILTER is
#                                       re-added by patch_bakasu_kconfig.sh if the
#                                       new snapshot dropped it)
#   KernelSU/VENDORED.md               (branch + commit + subject)
#
# What it does NOT touch: userspace/ (ksud) and manager/ (APK) are not vendored;
# the vendor module tree and toolchains are unrelated to BakaSU.
set -euo pipefail

KROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KSU_DIR="$KROOT/KernelSU"
UPSTREAM="https://github.com/Baka-SU/BakaSU.git"

BRANCH="main"
MODE=apply
DO_BUILD=0
FORCE=0

for arg in "$@"; do
    case "$arg" in
        --check) MODE=check ;;
        --build) DO_BUILD=1 ;;
        --force) FORCE=1 ;;
        -h|--help) sed -n '2,26p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*) echo "[-] unknown option: $arg (see --help)"; exit 1 ;;
        *) BRANCH="$arg" ;;
    esac
done

stage(){ echo; echo "===== $* ====="; }
die(){ echo "[-] $*"; exit 1; }

[ -f "$KSU_DIR/VENDORED.md" ] || die "$KSU_DIR/VENDORED.md missing — this tree does not ship a vendored BakaSU"
[ -d "$KSU_DIR/kernel" ] || die "$KSU_DIR/kernel missing"

OLD_COMMIT=$(grep -oE '^\| Commit \| `[0-9a-f]+`' "$KSU_DIR/VENDORED.md" | grep -oE '[0-9a-f]{7,40}' | head -1 || true)
OLD_BRANCH=$(grep -oE '^\| Branch \| `[^`]+`' "$KSU_DIR/VENDORED.md" | sed 's/.*`\(.*\)`/\1/' | head -1 || true)
echo "[i] vendored now : ${OLD_BRANCH:-unknown} @ ${OLD_COMMIT:-unknown}"

# ---------------------------------------------------------------- fetch upstream
stage "fetch: $UPSTREAM ($BRANCH)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

git ls-remote --exit-code --heads "$UPSTREAM" "$BRANCH" >/dev/null 2>&1 ||
    die "branch '$BRANCH' not found in $UPSTREAM"
git clone --quiet --depth=1 -b "$BRANCH" "$UPSTREAM" "$TMP/bakasu"
NEW_COMMIT=$(git -C "$TMP/bakasu" rev-parse HEAD)
NEW_SUBJECT=$(git -C "$TMP/bakasu" log -1 --pretty=%s)
echo "[i] upstream    : $BRANCH @ ${NEW_COMMIT:0:9}  $NEW_SUBJECT"
# compare against the post-patch state: the vendored Kconfig carries the
# PRIORITY_UID_FILTER entry, upstream may not, and that is not a "change"
"$KROOT/patch_bakasu_kconfig.sh" "$TMP/bakasu" >/dev/null

# ---------------------------------------------------------------- diff summary
stage "compare"
# pipefail: diff exits 1 when files differ, so neutralise it for the counts
CHANGED=$( { diff -rq "$KSU_DIR/kernel" "$TMP/bakasu/kernel" 2>/dev/null || true; } | wc -l)
CHANGED=$((CHANGED + $( { diff -rq "$KSU_DIR/uapi" "$TMP/bakasu/uapi" 2>/dev/null || true; } | wc -l)))
echo "[i] changed files: $CHANGED"

if [ "$CHANGED" -eq 0 ]; then
    echo "[+] KernelSU/kernel and KernelSU/uapi already match $BRANCH @ ${NEW_COMMIT:0:9}"
else
    diff -rq "$KSU_DIR/kernel" "$TMP/bakasu/kernel" 2>/dev/null \
        | sed -E 's|^Files [^ ]* and .*/bakasu/([^ ]*) differ$|  M \1|' | head -15 || true
    diff -rq "$KSU_DIR/uapi" "$TMP/bakasu/uapi" 2>/dev/null \
        | sed -E 's|^Files [^ ]* and .*/bakasu/([^ ]*) differ$|  M \1|' | head -5 || true
    [ "$CHANGED" -le 20 ] || echo "  ... and $((CHANGED - 20)) more"
fi

echo "[i] SUSFS options (current -> upstream):"
grep -oE '^config KSU_SUSFS[A-Z_0-9]*' "$KSU_DIR/kernel/Kconfig" 2>/dev/null | sed 's/config //' | sort > "$TMP/old.opts"
grep -oE '^config KSU_SUSFS[A-Z_0-9]*' "$TMP/bakasu/kernel/Kconfig" 2>/dev/null | sed 's/config //' | sort > "$TMP/new.opts"
if diff -q "$TMP/old.opts" "$TMP/new.opts" >/dev/null; then
    echo "  (unchanged, $(wc -l < "$TMP/new.opts") options)"
else
    diff "$TMP/old.opts" "$TMP/new.opts" | grep -E '^[<>]' | sed 's/^</  -/' | sed 's/^>/  +/' || true
fi

[ "$MODE" = check ] && { echo; echo "[i] --check: nothing written"; exit 0; }

if [ "$CHANGED" -eq 0 ]; then
    echo "[+] nothing to do"
    exit 0
fi

# ---------------------------------------------------------------- apply
stage "apply"
if [ -n "$(git -C "$KROOT" status --porcelain -- KernelSU/kernel KernelSU/uapi)" ] && [ "$FORCE" -ne 1 ]; then
    die "local edits inside KernelSU/kernel or KernelSU/uapi — commit/stash them, or pass --force"
fi

rm -rf "$KSU_DIR/kernel" "$KSU_DIR/uapi"
cp -a "$TMP/bakasu/kernel" "$TMP/bakasu/uapi" "$KSU_DIR/"
echo "[+] replaced KernelSU/kernel and KernelSU/uapi"

# Kconfig safety net: upstream may not declare the 10th SUSFS feature.
stage "kconfig"
"$KROOT/patch_bakasu_kconfig.sh" "$KSU_DIR"
grep -q 'config KSU_SUSFS_PRIORITY_UID_FILTER' "$KSU_DIR/kernel/Kconfig" ||
    die "KSU_SUSFS_PRIORITY_UID_FILTER still missing from KernelSU/kernel/Kconfig"

# metadata
python3 - "$KSU_DIR/VENDORED.md" "$BRANCH" "$NEW_COMMIT" "$NEW_SUBJECT" <<'PY'
import re, sys
path, branch, commit, subject = sys.argv[1:5]
d = open(path).read()
d = re.sub(r'^\| Branch \| `[^`]*` \|$', f'| Branch | `{branch}` |', d, flags=re.M)
d = re.sub(r'^\| Commit \| `[0-9a-f]+`.*\|$',
           f'| Commit | `{commit[:9]}` — *{subject}* |', d, flags=re.M)
open(path, 'w').write(d)
PY
echo "[+] KernelSU/VENDORED.md updated"

# ---------------------------------------------------------------- result
if [ "$BRANCH" != "main" ]; then
    echo
    echo "[i] note: only the kernel side of BakaSU is vendored. $BRANCH also changes"
    echo "    ksud/manager (userspace), which this repo does not carry — install the"
    echo "    matching BakaSU manager APK if you want the new userspace features."
fi

stage "result"
git -C "$KROOT" status --short -- KernelSU | head -10
echo "[i] staged files: $(git -C "$KROOT" status --porcelain -- KernelSU | wc -l)"
echo "[i] review the diff, then: ./update_build_bakasu.sh   (builds + commits locally)"

if [ "$DO_BUILD" -eq 1 ]; then
    stage "build: chaining update_build_bakasu.sh"
    exec "$KROOT/update_build_bakasu.sh"
fi
