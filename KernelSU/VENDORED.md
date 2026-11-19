# KernelSU (BakaSU) — vendored copy

The kernel side of BakaSU is **committed into this repo** under `kernel/`
(`drivers/kernelsu` is a symlink to `../KernelSU/kernel`), together with
`uapi/` because `kernel/include/uapi` points at `../../uapi`.

Vendoring exists so the Kconfig entry for the 10th SUSFS feature,
`CONFIG_KSU_SUSFS_PRIORITY_UID_FILTER`, is **part of this branch** instead of
being injected into a throw-away clone at build time. Kconfig silently drops
unknown symbols, which is why the feature used to be compiled out with no
error at all (BakaSU `main` does not declare it; `sync-up` does).

| | |
|---|---|
| Source | https://github.com/Baka-SU/BakaSU |
| Branch | `main` |
| Commit | `7b65bde0` — *manager: ensure webview alive when interface callback (#666)* |
| Vendored dirs | `kernel/`, `uapi/` |
| Not vendored | `userspace/` (ksud), `manager/` (app), docs, tooling |

## Updating

Use the updater — one command, either branch:

```bash
./update_bakasu.sh                  # Baka-SU/BakaSU main  (stable)
./update_bakasu.sh sync-up          # Baka-SU/BakaSU sync-up (has ksud/manager support)
./update_bakasu.sh main --check     # show what would change, write nothing
./update_bakasu.sh sync-up --build  # update, then build + commit locally
./update_bakasu.sh main --force     # overwrite local edits inside KernelSU/
```

It clones upstream to a temp dir, prints the diff (changed files + SUSFS option
additions/removals), replaces `KernelSU/kernel` + `KernelSU/uapi`, runs
`patch_bakasu_kconfig.sh` as the fallback and rewrites the table above.

Manual equivalent, if the script ever breaks:

```bash
git clone --depth=1 -b main https://github.com/Baka-SU/BakaSU.git /tmp/bakasu
cd /path/to/android_kernel_oppo_mt6771_stock
rm -rf KernelSU/kernel KernelSU/uapi
cp -a /tmp/bakasu/kernel /tmp/bakasu/uapi KernelSU/
./patch_bakasu_kconfig.sh          # safety net: re-add the option if upstream dropped it
git status --short                 # review, then commit
```

`patch_bakasu_kconfig.sh` stays in the repo exactly for this: if a future
BakaSU update removes `CONFIG_KSU_SUSFS_PRIORITY_UID_FILTER` again, the builds
still fail loudly (`build.sh` aborts if the option does not survive
`olddefconfig`) and the script puts it back.

## Userspace caveat

Only the kernel half is vendored. BakaSU `main`'s ksud/manager still have no
`CMD_SUSFS_SET_PRIORITY_UID_FILTER` (0x60030) or manager tab, so the kernel hook
is enabled and reported in `show enabled_features`, but nothing can populate the
UID bitmap. BakaSU `sync-up` has the userspace side; the "BakaSU sync-up"
workflow builds that branch instead.
