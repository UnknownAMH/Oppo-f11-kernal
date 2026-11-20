#!/usr/bin/env bash
# update_components.sh — refresh the four externally maintained components
#
#   susfs       SUSFS 4.14 backport from NonGKI_Kernel_Build_2nd
#   nomount     NoMount driver from maxsteeel/nomount
#   droidspaces CONFIG fragment from ravindu644/Droidspaces-OSS
#   rekernel    compatibility audit (report only; no auto-update)
#
# The SUSFS and NoMount updates are "patch stack" updates: the copy under
# patches/ is the pristine upstream baseline, the working tree is
# baseline + local fixes, and a new upstream release is 3-way merged on top
# (base = vendored baseline, ours = tree, theirs = new upstream).  Nothing is
# written unless every file merges without conflicts.
#
# Usage:
#   ./update_components.sh                      # check everything
#   ./update_components.sh --apply              # update everything clean
#   ./update_components.sh susfs --check        # one component, dry run
#   ./update_components.sh nomount --apply      # write the merge result
#   ./update_components.sh susfs --ref 26f2313  # pick a builder commit/tag
#
# Environment:
#   BUILDER_REPO   NonGKI_Kernel_Build_2nd checkout   (default ~/NonGKI_Kernel_Build_2nd)
#   SUSFS_REF      builder commit/tag for the SUSFS patch (default HEAD)
#   NOMOUNT_REF    upstream branch/tag/commit          (default from patches/nomount/VERSION)
#   NOMOUNT_UPSTREAM  git URL override
#
# Exit status: 0 = clean (or only "nothing to do"), 1 = conflict/audit failure.
set -euo pipefail

KROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATCHES="$KROOT/patches"
BUILDER="${BUILDER_REPO:-/home/unknown/NonGKI_Kernel_Build_2nd}"
DROID_URL="https://raw.githubusercontent.com/ravindu644/Droidspaces-OSS/main/Documentation/Kernel-Configuration.md"

MODE=check
COMPONENTS=()
REF_OVERRIDE=""
WARN=0
FAIL=0

say()  { printf '%s\n' "$*"; }
sec()  { printf '\n=== %s ===\n' "$*"; }
ok()   { printf '  [ok]    %s\n' "$*"; }
info() { printf '  [info]  %s\n' "$*"; }
warn() { printf '  [warn]  %s\n' "$*"; WARN=$((WARN + 1)); }
fail() { printf '  [fail]  %s\n' "$*"; FAIL=$((FAIL + 1)); }
die()  { printf '[-] %s\n' "$*" >&2; exit 1; }

need() {
    command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

for arg in "$@"; do
    case "$arg" in
        --check) MODE=check ;;
        --apply) MODE=apply ;;
        --ref)   REF_OVERRIDE="__NEXT__" ;;
        --ref=*) REF_OVERRIDE="${arg#--ref=}" ;;
        -h|--help) sed -n '2,34p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        all|susfs|nomount|droidspaces|rekernel)
            COMPONENTS+=("$arg") ;;
        -*) die "unknown option: $arg (see --help)" ;;
        *)  if [ "$REF_OVERRIDE" = "__NEXT__" ]; then REF_OVERRIDE="$arg"
            else die "unknown argument: $arg (see --help)"; fi ;;
    esac
done

[ "$REF_OVERRIDE" = "__NEXT__" ] && die "--ref needs a value"
[ ${#COMPONENTS[@]} -eq 0 ] && COMPONENTS=(all)

if [ ${#COMPONENTS[@]} -eq 1 ] && [ "${COMPONENTS[0]}" = all ]; then
    COMPONENTS=(susfs nomount droidspaces rekernel)
fi

TMPBASE="${TMPDIR:-$HOME/.cache}"
mkdir -p "$TMPBASE"
TMP="$(mktemp -d "$TMPBASE/update-components.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# ---------------------------------------------------------------- helpers

# Paths a unified diff touches (old and new side; /dev/null dropped).
patch_paths() {
    sed -n -e 's|^+++ b/||p' -e 's|^--- a/||p' "$1" \
        | grep -v '^/dev/null$' | grep -v '^[a-z]*$' | sort -u
}

# Files the inline-hook script edits (its patch_files=( ... ) array).
hook_paths() {
    sed -n '/^patch_files=(/,/^)/p' "$1" \
        | grep -oE '[A-Za-z0-9_./-]+\.(c|h)' | sort -u
}

# git merge-file wrapper.  Prints the number of conflict hunks on stdout and
# returns 0 (clean), 1 (conflicts), 2 (error).  Result lands in $4.
merge3() {
    local base="$1" ours="$2" theirs="$3" out="$4" rc=0
    mkdir -p "$(dirname "$out")"
    git merge-file -p --diff3 "$ours" "$base" "$theirs" >"$out" 2>"$TMP/merge.err" || rc=$?
    if [ "$rc" -gt 1 ]; then
        warn "merge-file failed for ${out#$TMP/merged/}: $(head -1 "$TMP/merge.err")"
        return 2
    fi
    if [ "$rc" -eq 1 ]; then
        grep -c '^<<<<<<<' "$out" || true
        return 1
    fi
    echo 0
    return 0
}

metric() { # label value
    printf '  %-28s %s\n' "$1" "$2"
}

# ---------------------------------------------------------------- SUSFS

susfs_env() {
    # shellcheck disable=SC1090
    . "$PATCHES/susfs/VERSION"
    SUSFS_OLD_PATCH="$PATCHES/susfs/${BASE_PATCH:-base-4.14.patch}"
    SUSFS_OLD_FIXUP="$PATCHES/susfs/${FIXUP:-oppo-fixup.patch}"
    SUSFS_OLD_HOOKS="$PATCHES/susfs/${INLINE_HOOKS:-inline-hooks.sh}"
    SUSFS_STOCK_REF="${STOCK_REF:-backup-stock-pre-bakasu-20261117}"
    SUSFS_OLD_VER="${SUSFS_VERSION:-unknown}"
}

susfs_extract_seed() { # dest
    local dest="$1" p paths=()
    mkdir -p "$dest"
    while IFS= read -r p; do
        git -C "$KROOT" cat-file -e "$SUSFS_STOCK_SHA:$p" 2>/dev/null && paths+=("$p")
    done < <(sort -u "$TMP/susfs.paths")
    [ ${#paths[@]} -gt 0 ] || die "no SUSFS paths exist at $SUSFS_STOCK_REF"
    git -C "$KROOT" archive "$SUSFS_STOCK_SHA" -- "${paths[@]}" | tar -x -C "$dest"
}

susfs_apply_pass() { # seed patch hooks fixup tag
    local seed="$1" patch="$2" hooks="$3" fixup="$4" tag="$5"
    patch -p1 -d "$seed" --batch --forward -F3 --no-backup-if-mismatch \
        <"$patch" >>"$TMP/susfs-$tag-patch.log" 2>&1 || true
    ( cd "$seed" && bash "$hooks" ) >>"$TMP/susfs-$tag-hooks.log" 2>&1 || true
    patch -p1 -d "$seed" --batch --forward -F3 --no-backup-if-mismatch \
        <"$fixup" >>"$TMP/susfs-$tag-fixup.log" 2>&1 || true
    find "$seed" -name '*.rej' -delete
    find "$seed" -name '*.orig' -delete
    info "$tag pass: $(find "$seed" -type f | wc -l) files, $(grep -c '^patching file' "$TMP/susfs-$tag-patch.log" 2>/dev/null || echo 0) patched by base"
}

susfs_run() {
    need git
    need patch
    need cmp
    [ -d "$BUILDER/.git" ] || die "builder repo not found: $BUILDER (set BUILDER_REPO)"
    [ -f "$PATCHES/susfs/VERSION" ] || die "patches/susfs/VERSION missing"
    susfs_env
    [ -f "$SUSFS_OLD_PATCH" ] || die "$SUSFS_OLD_PATCH missing"
    [ -f "$SUSFS_OLD_HOOKS" ] || die "$SUSFS_OLD_HOOKS missing"

    local ref="${SUSFS_REF:-${REF_OVERRIDE:-HEAD}}"
    local sha
    sha="$(git -C "$BUILDER" rev-parse --verify "$ref^{commit}")" 2>/dev/null \
        || die "unknown ref in builder repo: $ref"
    SUSFS_STOCK_SHA="$(git -C "$KROOT" rev-parse --verify "$SUSFS_STOCK_REF^{commit}")" \
        || die "stock ref not found: $SUSFS_STOCK_REF"

    local new_patch="$TMP/susfs-new-base.patch"
    git -C "$BUILDER" show "$sha:Patches/Patch/susfs_patch_to_4.14.patch" >"$new_patch" 2>/dev/null \
        || die "$sha has no Patches/Patch/susfs_patch_to_4.14.patch"
    local new_ver
    new_ver="$(grep -m1 -oE '#define[[:space:]]+SUSFS_VERSION[[:space:]]+"[^"]+"' "$new_patch" 2>/dev/null \
        | sed 's/.*"\(.*\)"/\1/' || true)"
    new_ver="${new_ver:-$SUSFS_OLD_VER}"

    local new_fixup="$TMP/susfs-new-fixup.patch" new_hooks="$TMP/susfs-new-hooks.sh"
    if git -C "$BUILDER" cat-file -e "$sha:Patches/oppo_f11/susfs_24_fix.patch" 2>/dev/null; then
        git -C "$BUILDER" show "$sha:Patches/oppo_f11/susfs_24_fix.patch" >"$new_fixup"
    else
        cp "$SUSFS_OLD_FIXUP" "$new_fixup"
    fi
    if git -C "$BUILDER" cat-file -e "$sha:Patches/susfs_inline_hook_patches.sh" 2>/dev/null; then
        git -C "$BUILDER" show "$sha:Patches/susfs_inline_hook_patches.sh" >"$new_hooks"
    else
        cp "$SUSFS_OLD_HOOKS" "$new_hooks"
    fi

    sec "SUSFS: $SUSFS_OLD_VER @ ${BASE_BUILDER_COMMIT:-?} -> $new_ver @ ${sha:0:9}"
    metric "stock baseline" "$SUSFS_STOCK_REF (${SUSFS_STOCK_SHA:0:9})"
    metric "base patch (old)" "$(wc -l <"$SUSFS_OLD_PATCH") lines"
    metric "base patch (new)" "$(wc -l <"$new_patch") lines"

    if cmp -s "$SUSFS_OLD_PATCH" "$new_patch"; then
        ok "builder already at the vendored SUSFS base — nothing to merge"
        metric "vendored base commit" "${BASE_BUILDER_COMMIT:-?}"
        return 0
    fi

    # Union of files touched by old/new patch, fixup and inline hooks.
    {
        patch_paths "$SUSFS_OLD_PATCH"
        patch_paths "$new_patch"
        patch_paths "$new_fixup"
        patch_paths "$SUSFS_OLD_FIXUP"
        hook_paths "$SUSFS_OLD_HOOKS"
        echo Makefile
    } | sort -u >"$TMP/susfs.paths"
    info "reconstruction set: $(wc -l <"$TMP/susfs.paths") files"

    local seed="$TMP/susfs-seed" stock="$TMP/susfs-stock"
    local snap_old="$TMP/susfs-old" snap_new="$TMP/susfs-new"
    mkdir -p "$stock" "$snap_old" "$snap_new"

    susfs_extract_seed "$seed"
    cp -a "$seed/." "$stock/"

    susfs_apply_pass "$seed" "$SUSFS_OLD_PATCH" "$SUSFS_OLD_HOOKS" "$SUSFS_OLD_FIXUP" old
    cp -a "$seed/." "$snap_old/"

    if [ -f "$seed/fs/susfs.c" ] && ! cmp -s "$seed/fs/susfs.c" "$KROOT/fs/susfs.c"; then
        warn "old baseline reconstruction differs from fs/susfs.c (expected if the vendored base is stale)"
    else
        ok "old baseline reproduces this tree's fs/susfs.c"
    fi

    rm -rf "$seed"
    susfs_extract_seed "$seed"
    susfs_apply_pass "$seed" "$new_patch" "$new_hooks" "$new_fixup" new
    cp -a "$seed/." "$snap_new/"

    ( cd "$snap_old" && find . -type f | sed 's|^\./||' | sort ) >"$TMP/susfs-old.list"
    ( cd "$snap_new" && find . -type f | sed 's|^\./||' | sort ) >"$TMP/susfs-new.list"

    local merged="$TMP/merged" f base theirs out conflicts total=0 blocked=0
    while IFS= read -r f; do
        [ -z "$f" ] && continue
        base="$snap_old/$f"
        theirs="$snap_new/$f"
        out="$merged/$f"

        if [ ! -f "$theirs" ]; then
            warn "$f: removed by the new base (not touched automatically)"
            continue
        fi
        if [ ! -f "$base" ]; then
            if [ -f "$stock/$f" ]; then
                base="$stock/$f"
            else
                base="$TMP/empty"; : >"$base"
            fi
        fi

        # Unchanged between the two bases: nothing to merge.
        if cmp -s "$base" "$theirs"; then
            continue
        fi

        if [ ! -f "$KROOT/$f" ]; then
            if [ -f "$base" ] && [ -s "$base" ]; then
                warn "$f: exists upstream but was deleted locally — check manually"
                continue
            fi
            mkdir -p "$(dirname "$out")"
            cp "$theirs" "$out"
            info "$f: new file, taken as-is"
            total=$((total + 1))
            continue
        fi

        local rc=0
        set +e
        conflicts="$(merge3 "$base" "$KROOT/$f" "$theirs" "$out")"
        rc=$?
        set -e
        if [ "$rc" -eq 2 ]; then
            blocked=$((blocked + 1))
            continue
        fi
        total=$((total + 1))
        if [ "${conflicts:-0}" -gt 0 ]; then
            printf '  [merge] %-42s %s conflict(s)\n' "$f" "$conflicts"
            blocked=$((blocked + 1))
        else
            printf '  [merge] %-42s clean\n' "$f"
        fi
    done < <(sort -u "$TMP/susfs-old.list" "$TMP/susfs-new.list")

    if [ "$total" -eq 0 ]; then
        ok "no delta files between the two bases"
        return 0
    fi

    if [ "$blocked" -gt 0 ]; then
        fail "$blocked file(s) need manual resolution (see $TMP/merged — kept until exit)"
        say "    Nothing was written. Resolve, or re-run after updating the vendored baseline."
        # Keep the merge output for the user.
        trap 'say "[i] merge output kept in $TMP"; ' EXIT
        return 1
    fi

    if [ "$MODE" != apply ]; then
        ok "$total file(s) merge cleanly — run with --apply to write them"
        return 0
    fi

    while IFS= read -r f; do
        [ -z "$f" ] && continue
        [ -f "$merged/$f" ] || continue
        mkdir -p "$(dirname "$KROOT/$f")"
        cp "$merged/$f" "$KROOT/$f"
    done < <(cd "$merged" && find . -type f | sed 's|^\./||' | sort)

    cp "$new_patch" "$SUSFS_OLD_PATCH"
    cp "$new_fixup" "$SUSFS_OLD_FIXUP"
    cp "$new_hooks" "$SUSFS_OLD_HOOKS"

    {
        echo '# SUSFS backport update state (read by update_components.sh)'
        echo '# BASE_BUILDER_COMMIT is the NonGKI_Kernel_Build_2nd commit whose'
        echo '# Patches/Patch/susfs_patch_to_4.14.patch is stored in base-4.14.patch.'
        echo "BASE_BUILDER_COMMIT=$sha"
        echo "BASE_PATCH=${BASE_PATCH:-base-4.14.patch}"
        echo "FIXUP=${FIXUP:-oppo-fixup.patch}"
        echo "INLINE_HOOKS=${INLINE_HOOKS:-inline-hooks.sh}"
        echo "STOCK_REF=$SUSFS_STOCK_REF"
        echo "SUSFS_VERSION=$new_ver"
        echo "UPDATED=$(date +%F)"
    } >"$PATCHES/susfs/VERSION"

    ok "applied $total file(s); vendored base is now ${sha:0:9} ($new_ver)"
    say "    next: ./update_build_bakasu.sh   (or a full build) to verify"
    git -C "$KROOT" diff --stat | sed -n '1,12p' || true
    return 0
}

# ---------------------------------------------------------------- NoMount

nomount_run() {
    need git
    need cmp
    local ndir="$PATCHES/nomount"
    [ -f "$ndir/VERSION" ] || die "$ndir/VERSION missing"
    local url ref
    url="$(sed -n 's/^UPSTREAM=//p' "$ndir/VERSION" | head -1)"
    ref="${NOMOUNT_REF:-${REF_OVERRIDE:-$(sed -n 's/^BASE_BRANCH=//p' "$ndir/VERSION" | head -1)}}"
    url="${NOMOUNT_UPSTREAM:-$url}"
    [ -n "$url" ] && [ -n "$ref" ] || die "NoMount upstream/ref not configured"

    local clone="$TMP/nomount-upstream"
    if ! git clone -q --depth 1 --branch "$ref" "$url" "$clone" 2>/dev/null; then
        git clone -q "$url" "$clone" 2>/dev/null || die "cannot clone $url"
        git -C "$clone" checkout -q "$ref" 2>/dev/null || die "cannot checkout $ref in $url"
    fi
    local sha ver
    sha="$(git -C "$clone" rev-parse --short HEAD)"
    ver="$(git -C "$clone" describe --tags --always 2>/dev/null || echo "$sha")"

    sec "NoMount: vendored $(sed -n 's/^BASE_REF=//p' "$ndir/VERSION" | head -1) -> $ref @ $sha ($ver)"
    local f base ours theirs out conflicts total=0 blocked=0 merged="$TMP/nomount-merged"
    for f in nomount.c nomount.h; do
        base="$ndir/upstream/$f"
        ours="$KROOT/NoMount/kernel/src/$f"
        theirs="$clone/kernel/src/$f"
        [ -f "$base" ] || die "missing baseline $base"
        [ -f "$ours" ] || die "missing tree file $ours"
        [ -f "$theirs" ] || die "upstream no longer ships kernel/src/$f"

        if cmp -s "$theirs" "$base"; then
            info "$f: unchanged upstream"
            continue
        fi
        local rc=0
        set +e
        conflicts="$(merge3 "$base" "$ours" "$theirs" "$merged/$f")"
        rc=$?
        set -e
        total=$((total + 1))
        if [ "$rc" -ne 0 ] || [ "${conflicts:-0}" -gt 0 ]; then
            printf '  [merge] %-12s %s conflict(s)\n' "$f" "${conflicts:-?}"
            blocked=$((blocked + 1))
        else
            printf '  [merge] %-12s clean\n' "$f"
        fi
    done

    if [ "$total" -eq 0 ]; then
        ok "NoMount is already at $ref"
        return 0
    fi
    if [ "$blocked" -gt 0 ]; then
        fail "NoMount needs a manual port (upstream refactored; local 4.14 fixes conflict)"
        say "    Merge output: $merged"
        trap 'say "[i] merge output kept in $TMP"; ' EXIT
        return 1
    fi
    if [ "$MODE" != apply ]; then
        ok "NoMount merges cleanly — run with --apply to write it"
        return 0
    fi

    cp "$merged/nomount.c" "$KROOT/NoMount/kernel/src/nomount.c"
    cp "$merged/nomount.h" "$KROOT/NoMount/kernel/src/nomount.h"
    cp "$clone/kernel/src/nomount.c" "$ndir/upstream/nomount.c"
    cp "$clone/kernel/src/nomount.h" "$ndir/upstream/nomount.h"
    {
        echo '# NoMount update state (read by update_components.sh)'
        echo '# upstream/ holds the pristine upstream sources the tree was last based on;'
        echo '# the local 4.14 fixes live as a diff on top of it.'
        echo "UPSTREAM=$url"
        echo "BASE_REF=$sha"
        echo "BASE_BRANCH=$ref"
        echo "UPDATED=$(date +%F)"
    } >"$ndir/VERSION"
    ok "NoMount updated to $ref @ $sha ($ver)"
    say "    reminder: the NoMount metamodule must be updated to the same release"
    return 0
}

# ---------------------------------------------------------------- Droidspaces

droidspaces_run() {
    need git
    local doc="$PATCHES/droidspaces/Kernel-Configuration.md"
    local frag="$KROOT/arch/arm64/configs/droidspaces.config"
    [ -f "$frag" ] || die "$frag missing"

    sec "Droidspaces: CONFIG fragment"
    if command -v curl >/dev/null 2>&1; then
        if curl -fsSL --max-time 30 "$DROID_URL" -o "$TMP/droidspaces.md"; then
            if ! cmp -s "$TMP/droidspaces.md" "$doc"; then
                info "upstream document changed"
                [ "$MODE" = apply ] && cp "$TMP/droidspaces.md" "$doc"
            else
                ok "cached upstream document is current"
            fi
        else
            warn "cannot fetch upstream document; using cached copy"
            cp "$doc" "$TMP/droidspaces.md"
        fi
    else
        warn "curl not available; using cached upstream document"
        cp "$doc" "$TMP/droidspaces.md"
    fi

    local up local_keys missing extra
    up="$(grep -oE '^CONFIG_[A-Z0-9_]+' "$TMP/droidspaces.md" | sort -u)"
    local_keys="$(grep -oE '^CONFIG_[A-Z0-9_]+' "$frag" | sort -u)"
    missing="$(comm -23 <(printf '%s\n' "$up") <(printf '%s\n' "$local_keys"))"
    extra="$(comm -13 <(printf '%s\n' "$up") <(printf '%s\n' "$local_keys") | wc -l)"

    metric "upstream options" "$(printf '%s\n' "$up" | grep -c '^CONFIG_' || true)"
    metric "fragment options" "$(printf '%s\n' "$local_keys" | grep -c '^CONFIG_' || true)"
    metric "fragment-only options" "$extra"

    if [ -z "$missing" ]; then
        ok "fragment contains every upstream option"
    else
        while IFS= read -r k; do
            [ -z "$k" ] && continue
            info "missing: $(grep -m1 "^$k=" "$TMP/droidspaces.md" || echo "$k=y")"
        done <<<"$missing"

        if [ "$MODE" = apply ]; then
            {
                echo
                echo "# --- added by update_components.sh $(date +%F) (Droidspaces upstream) ---"
                while IFS= read -r k; do
                    [ -z "$k" ] && continue
                    grep -m1 "^$k=" "$TMP/droidspaces.md" || echo "$k=y"
                done <<<"$missing"
            } >>"$frag"
            ok "appended $(printf '%s\n' "$missing" | grep -c . || true) option(s)"

            local bfrag="$BUILDER/Patches/Droidspaces/droidspaces.config"
            if [ -f "$bfrag" ]; then
                cp "$frag" "$bfrag"
                ok "synced $bfrag"
            else
                warn "builder copy not found: $bfrag"
            fi
        else
            ok "run with --apply to append them"
        fi
    fi

    # Duplicate keys inside the fragment are always a bug.
    local dup
    dup="$(grep -oE '^CONFIG_[A-Z0-9_]+' "$frag" | sort | uniq -d)"
    if [ -n "$dup" ]; then
        fail "duplicate keys in $frag: $(echo $dup)"
    else
        ok "no duplicate keys in the fragment"
    fi
    return 0
}

# ---------------------------------------------------------------- Re:Kernel

rekernel_run() {
    sec "Re:Kernel: integration audit (report only)"
    local d="$KROOT/drivers/rekernel" missing="" inc
    local legacy=1

    if [ -f "$d/rekernel.c" ] && [ -f "$d/rekernel.h" ]; then
        ok "legacy non-GKI driver present (drivers/rekernel)"
    elif [ -f "$KROOT/drivers/net/rekernel/rekernel_main.c" ]; then
        fail "LKM/v11 driver layout found — it needs trace/hooks/* which this 4.14 tree lacks"
        legacy=0
    else
        fail "no Re:Kernel driver found"
        legacy=0
    fi

    if [ "$legacy" = 1 ]; then
        while IFS= read -r inc; do
            [ -z "$inc" ] && continue
            missing="$missing $inc"
        done < <(grep -rhoE '#include <trace/hooks/[a-z0-9_]+\.h>' "$d" 2>/dev/null | sort -u)
        if [ -n "$missing" ]; then
            fail "driver still includes missing vendor hooks:$missing"
        else
            ok "no vendor-hook (trace/hooks) dependency"
        fi

        grep -q 'late_initcall' "$d/rekernel.c" \
            && ok "server starts from late_initcall (safe under binder/signal locks)" \
            || warn "no late_initcall — lazy start may sleep in atomic context"

        grep -qE '#define[[:space:]]+JOBCTL_TRAP_FREEZE' "$d/rekernel.h" \
            && ok "JOBCTL_TRAP_FREEZE 4.14 fallback present" \
            || warn "JOBCTL_TRAP_FREEZE fallback missing (cgroup-v1 build break)"

        grep -qE 'cgroup_freezing' "$d/rekernel.h" \
            && ok "freeze check uses cgroup_freezing()" \
            || warn "freeze check does not use cgroup_freezing()"
    fi

    # Hook wiring (works for both layouts, but the names differ).
    if grep -q 'binder_reply_handler' "$KROOT/drivers/android/binder.c"; then
        ok "binder.c: reply hook wired"
    else
        fail "binder.c: binder_reply_handler() not called"
    fi
    if grep -q 'binder_trans_handler' "$KROOT/drivers/android/binder.c"; then
        ok "binder.c: transaction hook wired"
    else
        fail "binder.c: binder_trans_handler() not called"
    fi
    if grep -q 'binder_overflow_handler' "$KROOT/drivers/android/binder_alloc.c"; then
        ok "binder_alloc.c: overflow hook wired"
    else
        fail "binder_alloc.c: binder_overflow_handler() not called"
    fi
    if grep -q 'rekernel_report(RK_SIGNAL' "$KROOT/kernel/signal.c"; then
        ok "signal.c: fatal-signal hook wired (RK_SIGNAL)"
    else
        fail "signal.c: rekernel_report(RK_SIGNAL, ...) missing"
    fi
    if grep -qE '\bSIGNAL,' "$KROOT/kernel/signal.c" && ! grep -q 'RK_SIGNAL' "$KROOT/kernel/signal.c"; then
        warn "bare SIGNAL in signal.c can collide with include/linux/hans.h"
    fi

    say "    upstream guide: Sakion-Team/Re-Kernel/Integrate (legacy, non-GKI)"
    say "    v11.x is LKM/vendor-hook based and cannot be dropped into 4.14 as-is."
    [ "$MODE" = apply ] && say "    (report only: nothing was written)"
    return 0
}

# ---------------------------------------------------------------- dispatch

for c in "${COMPONENTS[@]}"; do
    case "$c" in
        susfs)       susfs_run || FAIL=$((FAIL + 1)) ;;
        nomount)     nomount_run || FAIL=$((FAIL + 1)) ;;
        droidspaces) droidspaces_run || FAIL=$((FAIL + 1)) ;;
        rekernel)    rekernel_run || FAIL=$((FAIL + 1)) ;;
        *) die "unknown component: $c" ;;
    esac
done

printf '\n---\n'
if [ "$FAIL" -gt 0 ]; then
    say "result: $FAIL component(s) need attention, $WARN warning(s)"
    exit 1
fi
say "result: clean${WARN:+, $WARN warning(s)} (mode: $MODE)"
