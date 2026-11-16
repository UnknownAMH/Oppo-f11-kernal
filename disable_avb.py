#!/usr/bin/env python3
"""
disable_avb.py — patch the vbmeta flags in a boot image so AVB verification is disabled.

Sets vbmeta Flags = 3 (hashtree disabled + verification disabled).
Works on boot images with an embedded vbmeta (boot.bin / boot.img style).

Usage:
    python3 disable_avb.py <image.img> [more.img ...]
    python3 disable_avb.py --revert <image.img>      (set flags back to 0)
    python3 disable_avb.py --check  <image.img>      (only show current flags)

For each image:
  - finds every "AVB0" vbmeta header,
  - backs the file up next to it (<name>.bak) if no backup exists,
  - writes Flags = 3 at vbmeta_offset + 120,
  - verifies by re-reading.
"""

import sys
import os
import hashlib
import shutil

AVB_MAGIC = b"AVB0"
FLAGS_OFFSET = 120  # AvbVBMetaImageHeader.flags field, uint32 big-endian
FLAGS_DISABLED = 3  # HASHTREE_DISABLED | VERIFICATION_DISABLED


def find_vbmetas(data: bytes):
    offs = []
    start = 0
    while True:
        i = data.find(AVB_MAGIC, start)
        if i < 0 or i + FLAGS_OFFSET + 4 > len(data):
            break
        offs.append(i)
        start = i + 1
    return offs


def sha256(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def patch(path: str, flags: int, backup: bool) -> int:
    with open(path, "rb") as f:
        data = bytearray(f.read())

    offs = find_vbmetas(data)
    if not offs:
        print(f"[!] {path}: no vbmeta (AVB0) header found — nothing to do")
        return 1

    for o in offs:
        cur = int.from_bytes(data[o + FLAGS_OFFSET:o + FLAGS_OFFSET + 4], "big")
        label = f"vbmeta @ 0x{o:x}"
        if cur == flags:
            print(f"[=] {path}: {label} flags already {cur}")
        else:
            print(f"[*] {path}: {label} flags {cur} -> {flags}")
            data[o + FLAGS_OFFSET:o + FLAGS_OFFSET + 4] = flags.to_bytes(4, "big")

    if backup and not os.path.exists(path + ".bak"):
        shutil.copy2(path, path + ".bak")
        print(f"[+] backup saved: {path}.bak")

    with open(path, "wb") as f:
        f.write(data)

    # verify
    with open(path, "rb") as f:
        v = f.read()
    ok = all(int.from_bytes(v[o + FLAGS_OFFSET:o + FLAGS_OFFSET + 4], "big") == flags for o in offs)
    print(f"[{'OK' if ok else 'FAIL'}] {path} verified flags={flags}  sha256={sha256(path)[:16]}…")
    return 0 if ok else 2


def main() -> int:
    args = sys.argv[1:]
    flags = FLAGS_DISABLED
    mode = "patch"
    if args and args[0] in ("--revert", "--check"):
        mode = "revert" if args[0] == "--revert" else "check"
        args = args[1:]
    if not args:
        print(__doc__)
        return 1

    rc = 0
    for p in args:
        if not os.path.isfile(p):
            print(f"[!] not found: {p}")
            rc = 1
            continue
        if mode == "check":
            with open(p, "rb") as f:
                data = f.read()
            for o in find_vbmetas(data):
                cur = int.from_bytes(data[o + FLAGS_OFFSET:o + FLAGS_OFFSET + 4], "big")
                print(f"[*] {p}: vbmeta @ 0x{o:x} flags = {cur}")
        else:
            rc |= patch(p, flags, backup=(mode == "patch"))
    return rc


if __name__ == "__main__":
    sys.exit(main())
