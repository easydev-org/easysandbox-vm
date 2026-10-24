#!/usr/bin/env python3
"""Turn a QEMU screendump (PPM P6) into a PNG and report its colour spread.

Two jobs in one pass:

  * PNG, so the CI artifact can be opened by a human and by an image tool.
  * A distinct-colour count, because that is the cheapest honest test for
    "is anything actually drawn". A guest that reached graphical.target but
    whose compositor never painted gives a single-colour framebuffer, and
    that is exactly the failure a serial log cannot show.

No Pillow: a P6 parser plus a zlib-backed PNG writer needs only IHDR/IDAT/IEND.
"""
import struct
import sys
import zlib

PNG_SIG = bytes([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

def read_ppm(path):
    with open(path, "rb") as f:
        data = f.read()
    if not data.startswith(b"P6"):
        raise SystemExit(path + ": not a P6 PPM")
    fields = []
    pos = 2
    while len(fields) < 3:
        while pos < len(data) and data[pos:pos+1].isspace():
            pos += 1
        if data[pos:pos+1] == b"#":
            while pos < len(data) and data[pos] != 10:
                pos += 1
            continue
        start = pos
        while pos < len(data) and not data[pos:pos+1].isspace():
            pos += 1
        fields.append(int(data[start:pos]))
    pos += 1
    w, h, maxval = fields
    if maxval != 255:
        raise SystemExit(path + ": only 8-bit PPM supported")
    return w, h, data[pos:pos + w*h*3]

def write_png(path, w, h, rgb):
    raw = bytearray()
    stride = w * 3
    for y in range(h):
        raw.append(0)
        raw += rgb[y*stride:(y+1)*stride]
    def chunk(tag, payload):
        crc = zlib.crc32(tag + payload) & 0xFFFFFFFF
        return struct.pack(">I", len(payload)) + tag + payload + struct.pack(">I", crc)
    out = PNG_SIG
    out += chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
    out += chunk(b"IDAT", zlib.compress(bytes(raw), 9))
    out += chunk(b"IEND", b"")
    with open(path, "wb") as f:
        f.write(out)

def main():
    src, dst = sys.argv[1], sys.argv[2]
    w, h, rgb = read_ppm(src)
    write_png(dst, w, h, rgb)
    seen = {}
    for i in range(0, len(rgb) - 2, 21):
        key = rgb[i:i+3]
        seen[key] = seen.get(key, 0) + 1
    total = max(1, sum(seen.values()))
    top = sorted(seen.items(), key=lambda kv: -kv[1])[:5]
    print(dst + " " + str(w) + "x" + str(h) + " distinct=" + str(len(seen)))
    for c, n in top:
        print("   rgb(%3d,%3d,%3d) %5.1f%%" % (c[0], c[1], c[2], 100.0*n/total))
    if len(seen) < 2:
        raise SystemExit("BLANK: " + dst + " has a single colour")
    print("PICTURE OK")

main()
