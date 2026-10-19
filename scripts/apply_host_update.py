#!/usr/bin/env python3
"""Replace Payload/DmIOS.app/DmIOS in an existing IPA with a host-only rebuild.

The game files (RomFS), shader libraries and tables do not change when only the
host C/Objective-C sources are fixed, so the IPA does not have to be downloaded
again: download the small "host" artifact from the ipa workflow, extract
DmIOS.bin, and run this script against the IPA that is already on the PC.
The signing tool (AltStore / Sideloadly) re-signs the whole bundle afterwards.

Usage: apply_host_update.py <existing.ipa> <DmIOS.bin> [out.ipa]
       (default out: <existing.ipa>.patched.ipa)
"""
import os
import shutil
import sys
import zipfile

TARGET = "Payload/DmIOS.app/DmIOS"


def main():
    if len(sys.argv) not in (3, 4):
        raise SystemExit(__doc__)
    ipa, exe = sys.argv[1:3]
    out = sys.argv[3] if len(sys.argv) == 4 else ipa + ".patched.ipa"
    if os.path.abspath(out) == os.path.abspath(ipa):
        raise SystemExit("out must differ from the input IPA")
    if not os.path.isfile(ipa):
        raise SystemExit(f"no IPA: {ipa}")
    if not os.path.isfile(exe):
        raise SystemExit(f"no executable: {exe}")

    replaced = False
    with zipfile.ZipFile(ipa, "r") as zin, zipfile.ZipFile(out, "w") as zout:
        for info in zin.infolist():
            if info.filename == TARGET:
                info.compress_type = zipfile.ZIP_DEFLATED
                with open(exe, "rb") as src, zout.open(info, "w") as dst:
                    shutil.copyfileobj(src, dst)
                replaced = True
                print(f"replaced {TARGET} ({os.path.getsize(exe)} bytes)")
                continue
            if info.is_dir():
                zout.writestr(info, b"")
                continue
            with zin.open(info, "r") as src, zout.open(info, "w") as dst:
                shutil.copyfileobj(src, dst)
    if not replaced:
        raise SystemExit(f"{TARGET} not found in {ipa}")
    print(f"done: {out} ({os.path.getsize(out)} bytes)")


if __name__ == "__main__":
    main()
