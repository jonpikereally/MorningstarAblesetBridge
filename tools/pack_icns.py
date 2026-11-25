#!/usr/bin/env python3
"""Packs an .iconset folder of PNGs into an .icns file (what `iconutil -c icns`
does; iconutil can't run inside Claude's sandbox).  pack_icns.py <iconset> <out.icns>"""
import os, struct, sys
src, out = sys.argv[1], sys.argv[2]
TYPES = [("icp4", "icon_16x16.png"), ("ic11", "icon_16x16@2x.png"), ("icp5", "icon_32x32.png"),
         ("ic12", "icon_32x32@2x.png"), ("ic07", "icon_128x128.png"), ("ic13", "icon_128x128@2x.png"),
         ("ic08", "icon_256x256.png"), ("ic14", "icon_256x256@2x.png"), ("ic09", "icon_512x512.png"),
         ("ic10", "icon_512x512@2x.png")]
chunks = b""
for ostype, name in TYPES:
    data = open(os.path.join(src, name), "rb").read()
    chunks += ostype.encode() + struct.pack(">I", len(data) + 8) + data
open(out, "wb").write(b"icns" + struct.pack(">I", len(chunks) + 8) + chunks)
print("wrote", out, len(chunks) + 8, "bytes")
