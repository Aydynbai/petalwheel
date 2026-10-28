#!/usr/bin/env python3
"""Validators for the RAW / icon / FB2 / data / ASS cases of scripts/test-suite.sh.

Each subcommand prints a short note on success, or an error message and exits 1.

  ico FILE                    6 PNG entries 16/32/48/64/128/256; the 256 px entry is padded (transparent corner)
  png-transparent-corner FILE top-left pixel of an RGBA PNG is fully transparent
  epub-chapters FILE N WORD   spine has N chapters, text contains WORD
  fb2 FILE MIN_SECTIONS WORD  well-formed FictionBook with ≥ MIN top-level sections, text contains WORD
  json-equal A B              both files parse to equal JSON
  json-check FILE EXPR        Python expression over `d` (the parsed JSON) is true
  plist-equal A B             both property lists are equal
"""
import json
import plistlib
import re
import struct
import sys
import zipfile
import zlib
import xml.etree.ElementTree as ET


def fail(msg):
    print(msg)
    sys.exit(1)


def png_rgba(data):
    """Decodes an 8-bit RGBA, non-interlaced PNG → (w, h, rows of bytes)."""
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        fail("not a PNG")
    pos, idat = 8, b""
    w = h = 0
    ctype = bits = 0
    while pos < len(data):
        n = struct.unpack(">I", data[pos:pos + 4])[0]
        tag = data[pos + 4:pos + 8]
        body = data[pos + 8:pos + 8 + n]
        if tag == b"IHDR":
            w, h, bits, ctype = struct.unpack(">IIBB", body[:10])
        elif tag == b"IDAT":
            idat += body
        pos += 12 + n
    if bits != 8 or ctype not in (6, 2):
        fail(f"unsupported PNG layout (bits {bits}, colour type {ctype})")
    bpp = 4 if ctype == 6 else 3
    raw = zlib.decompress(idat)
    stride = w * bpp
    rows, prev, i = [], bytearray(stride), 0
    for _ in range(h):
        f = raw[i]
        line = bytearray(raw[i + 1:i + 1 + stride])
        i += 1 + stride
        for x in range(stride):
            a = line[x - bpp] if x >= bpp else 0
            b = prev[x]
            c = prev[x - bpp] if x >= bpp else 0
            if f == 1:
                line[x] = (line[x] + a) & 255
            elif f == 2:
                line[x] = (line[x] + b) & 255
            elif f == 3:
                line[x] = (line[x] + (a + b) // 2) & 255
            elif f == 4:
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                line[x] = (line[x] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
        rows.append(bytes(line))
        prev = line
    return w, h, bpp, rows


def cmd_ico(path):
    d = open(path, "rb").read()
    reserved, typ, count = struct.unpack("<HHH", d[:6])
    if reserved != 0 or typ != 1:
        fail(f"bad ICONDIR (reserved {reserved}, type {typ})")
    if count != 6:
        fail(f"{count} entries, expected 6")
    sizes = []
    big = None
    for i in range(count):
        w, h, _, _, planes, bpp, size, off = struct.unpack("<BBBBHHII", d[6 + 16 * i:22 + 16 * i])
        w, h = w or 256, h or 256
        payload = d[off:off + size]
        if payload[:4] != b"\x89PNG" or len(payload) != size:
            fail(f"entry {w}x{h} isn't a complete PNG")
        pw, ph = struct.unpack(">II", payload[16:24])
        if (pw, ph) != (w, h):
            fail(f"entry says {w}x{h} but its PNG is {pw}x{ph}")
        sizes.append(w)
        if w == 256:
            big = payload
    if sizes != [16, 32, 48, 64, 128, 256]:
        fail(f"sizes {sizes}")
    note = "6 PNG entries 16–256"
    if len(sys.argv) > 3 and sys.argv[3] == "padded":
        w, h, bpp, rows = png_rgba(big)
        if bpp != 4 or rows[0][3] != 0:
            fail("256 px entry: corner isn't transparent (non-square source not padded)")
        mid = rows[h // 2]
        if max(mid[x * 4 + 3] for x in range(w)) == 0:
            fail("256 px entry: middle row is empty")
        note += ", transparent padding"
    print(note)


def cmd_png_corner(path):
    w, h, bpp, rows = png_rgba(open(path, "rb").read())
    if bpp != 4 or rows[0][3] != 0:
        fail("corner pixel isn't transparent")
    print(f"{w}x{h}, transparent corner")


def cmd_epub_chapters(path, n, word):
    z = zipfile.ZipFile(path)
    opf_path = re.search(r'full-path="([^"]+)"', z.read("META-INF/container.xml").decode()).group(1)
    opf = z.read(opf_path).decode()
    spine = re.findall(r"<itemref\b", opf)
    if len(spine) != int(n):
        fail(f"{len(spine)} chapters in the spine, expected {n}")
    text = "".join(z.read(i).decode("utf-8", "replace") for i in z.namelist() if i.endswith(".xhtml"))
    if word not in text:
        fail(f"chapters lack '{word}'")
    images = [i for i in z.namelist() if "/images/" in i]
    print(f"{len(spine)} chapters, {len(images)} image(s), '{word}' OK")


NS = "{http://www.gribuser.ru/xml/fictionbook/2.0}"


def cmd_fb2(path, min_sections, word):
    try:
        root = ET.parse(path).getroot()
    except ET.ParseError as e:
        fail(f"not well-formed XML: {e}")
    if root.tag != NS + "FictionBook":
        fail(f"root is {root.tag}")
    ti = root.find(f"{NS}description/{NS}title-info")
    if ti is None or ti.find(NS + "book-title") is None or ti.find(NS + "author") is None or ti.find(NS + "lang") is None:
        fail("title-info lacks book-title/author/lang")
    body = root.find(NS + "body")
    sections = body.findall(NS + "section") if body is not None else []
    if len(sections) < int(min_sections):
        fail(f"{len(sections)} top-level sections, expected ≥ {min_sections}")
    # A section holds either subsections or content, never both.
    for s in root.iter(NS + "section"):
        kids = [c.tag for c in s if c.tag not in (NS + "title", NS + "epigraph", NS + "image", NS + "annotation")]
        if NS + "section" in kids and any(k != NS + "section" for k in kids):
            fail("a section mixes content and subsections")
    ids = {b.get("id") for b in root.findall(NS + "binary")}
    for img in root.iter(NS + "image"):
        href = img.get("{http://www.w3.org/1999/xlink}href", "")
        if href.lstrip("#") not in ids:
            fail(f"image {href} has no binary")
    text = "".join(body.itertext())
    if word not in text:
        fail(f"text lacks '{word}'")
    print(f"{len(sections)} sections, {len(ids)} binaries, '{word}' OK")


def cmd_json_equal(a, b):
    x, y = json.load(open(a, encoding="utf-8-sig")), json.load(open(b, encoding="utf-8-sig"))
    if x != y:
        fail("round trip differs")
    print("round trip equal")


def cmd_json_check(path, expr):
    d = json.load(open(path, encoding="utf-8-sig"))
    try:
        ok = eval(expr, {}, {"d": d})
    except Exception as e:      # noqa: BLE001 - report any lookup error as a failure
        fail(f"{expr}: {type(e).__name__}: {e}")
    if not ok:
        fail(f"check failed: {expr}")
    print("values OK")


def cmd_plist_equal(a, b):
    if plistlib.load(open(a, "rb")) != plistlib.load(open(b, "rb")):
        fail("property lists differ")
    print("plist round trip equal")


cmd, args = sys.argv[1], sys.argv[2:]
{
    "ico": lambda: cmd_ico(*args[:1]),
    "png-transparent-corner": lambda: cmd_png_corner(*args),
    "epub-chapters": lambda: cmd_epub_chapters(*args),
    "fb2": lambda: cmd_fb2(*args),
    "json-equal": lambda: cmd_json_equal(*args),
    "json-check": lambda: cmd_json_check(*args),
    "plist-equal": lambda: cmd_plist_equal(*args),
}[cmd]()
