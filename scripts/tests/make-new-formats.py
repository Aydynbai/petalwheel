#!/usr/bin/env python3
"""Fixtures for the RAW / icon / FB2 / data / ASS formats (scripts/test-suite.sh).

Usage: make-new-formats.py OUTDIR

Writes, deterministically:
  camera.dng      640x480 Bayer (RGGB) DNG, EXIF orientation 6 (displayed 480x640), Make PetalwheelTestCam, ISO 400
  wide.png        300x120 RGBA (non-square, for icon padding)
  book.fb2        FictionBook 2, UTF-8: 3 chapters (one with a subsection), epigraph, poem, notes, a PNG binary
  book-1251.fb2   the same book encoded as windows-1251
  zipped.fb2.zip  book.fb2 zipped
  sample.json     nested data with Cyrillic, numbers, booleans, null, multi-line strings
  config.yaml     hand-written YAML: comments, anchors/merge, flow collections, block scalars
  data.xml        records with attributes
  data.plist      XML property list
  people.json     array of objects (tabular)
  subs.ass        ASS with styles, override tags, a comment line and a drawing
  subs.ssa        SSA v4 variant
"""
import os
import plistlib
import struct
import sys
import zipfile
import zlib
import base64

OUT = sys.argv[1]
os.makedirs(OUT, exist_ok=True)


def path(name):
    return os.path.join(OUT, name)


# --- PNG (no third-party modules) ------------------------------------------------

def png(width, height, pixel):
    raw = bytearray()
    for y in range(height):
        raw.append(0)
        for x in range(width):
            raw += bytes(pixel(x, y))
    def chunk(tag, data):
        c = struct.pack(">I", len(data)) + tag + data
        return c + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)
    ihdr = struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr) + chunk(b"IDAT", zlib.compress(bytes(raw), 9)) + chunk(b"IEND", b"")


def wide_pixel(x, y):
    if (x - 60) ** 2 + (y - 60) ** 2 < 50 ** 2:
        return (255, 140, 26, 255)
    if x > 150:
        return (42, 122, 176, 255)
    return (0, 0, 0, 0)


with open(path("wide.png"), "wb") as f:
    f.write(png(300, 120, wide_pixel))

small_png = png(48, 32, lambda x, y: (200, 60, 40, 255) if x < 24 else (40, 90, 200, 255))


# --- DNG ----------------------------------------------------------------------------

TYPES = {1: "B", 2: "s", 3: "H", 4: "I", 5: "II", 10: "ii"}


class IFD:
    def __init__(self):
        self.e = {}

    def add(self, tag, typ, vals):
        if typ == 2:
            b = vals.encode() + b"\0"
            n = len(b)
        else:
            f = TYPES[typ]
            b = b"".join(struct.pack("<" + f, *(v if isinstance(v, tuple) else (v,))) for v in vals)
            n = len(vals)
        self.e[tag] = (typ, n, b)

    def size(self):
        return 2 + 12 * len(self.e) + 4 + sum(len(b) + len(b) % 2 for (_, _, b) in self.e.values() if len(b) > 4)

    def bytes(self, base):
        out = struct.pack("<H", len(self.e))
        data = b""
        ds = base + 2 + 12 * len(self.e) + 4
        for tag in sorted(self.e):
            typ, n, b = self.e[tag]
            if len(b) <= 4:
                out += struct.pack("<HHI", tag, typ, n) + b.ljust(4, b"\0")
            else:
                out += struct.pack("<HHII", tag, typ, n, ds + len(data))
                data += b + (b"\0" if len(b) % 2 else b"")
        return out + struct.pack("<I", 0) + data


def dng(file, W=640, H=480, orient=6):
    def color(x, y):
        if y < H // 8:
            return (60000, 60000, 60000)
        return (52000, 26000, 4000) if x < W // 2 else (4000, 16000, 48000)
    raw = bytearray()
    for y in range(H):
        for x in range(W):
            c = color(x, y)
            idx = 0 if (y % 2 == 0 and x % 2 == 0) else (2 if (y % 2 == 1 and x % 2 == 1) else 1)
            raw += struct.pack("<H", c[idx])
    TW, TH = W // 8, H // 8
    thumb = bytearray()
    for y in range(TH):
        for x in range(TW):
            thumb += bytes(v >> 8 for v in color(x * 8, y * 8))
    ifd0, sub, ex = IFD(), IFD(), IFD()
    ifd0.add(254, 4, [1]); ifd0.add(256, 4, [TW]); ifd0.add(257, 4, [TH]); ifd0.add(258, 3, [8, 8, 8])
    ifd0.add(259, 3, [1]); ifd0.add(262, 3, [2]); ifd0.add(271, 2, "PetalwheelTestCam"); ifd0.add(272, 2, "PW-1")
    ifd0.add(273, 4, [0]); ifd0.add(274, 3, [orient]); ifd0.add(277, 3, [3]); ifd0.add(278, 4, [TH])
    ifd0.add(279, 4, [len(thumb)]); ifd0.add(284, 3, [1]); ifd0.add(305, 2, "Petalwheel fixtures")
    ifd0.add(330, 4, [0]); ifd0.add(34665, 4, [0])
    ifd0.add(50706, 1, [1, 4, 0, 0]); ifd0.add(50707, 1, [1, 1, 0, 0]); ifd0.add(50708, 2, "Petalwheel Test Camera")
    # XYZ (D65) -> linear sRGB, so the "camera" is an sRGB sensor.
    cm = [(32404542, 10000000), (-15371385, 10000000), (-4985314, 10000000), (-9692660, 10000000), (18760108, 10000000),
          (415560, 10000000), (556434, 10000000), (-2040259, 10000000), (10572252, 10000000)]
    ifd0.add(50721, 10, cm); ifd0.add(50728, 5, [(1, 1), (1, 1), (1, 1)]); ifd0.add(50778, 3, [21])
    sub.add(254, 4, [0]); sub.add(256, 4, [W]); sub.add(257, 4, [H]); sub.add(258, 3, [16]); sub.add(259, 3, [1])
    sub.add(262, 3, [32803]); sub.add(273, 4, [0]); sub.add(277, 3, [1]); sub.add(278, 4, [H])
    sub.add(279, 4, [len(raw)]); sub.add(284, 3, [1]); sub.add(33421, 3, [2, 2]); sub.add(33422, 1, [0, 1, 1, 2])
    sub.add(50710, 1, [0, 1, 2]); sub.add(50711, 3, [1]); sub.add(50714, 4, [0]); sub.add(50717, 4, [65535])
    sub.add(50719, 4, [0, 0]); sub.add(50720, 4, [W, H])
    ex.add(34855, 3, [400]); ex.add(36867, 2, "2024:05:06 07:08:09"); ex.add(33434, 5, [(1, 125)])
    o0 = 8
    osub = o0 + ifd0.size()
    oex = osub + sub.size()
    othumb = oex + ex.size()
    oraw = othumb + len(thumb)
    ifd0.add(273, 4, [othumb]); ifd0.add(330, 4, [osub]); ifd0.add(34665, 4, [oex]); sub.add(273, 4, [oraw])
    blob = b"II*\0" + struct.pack("<I", o0) + ifd0.bytes(o0) + sub.bytes(osub) + ex.bytes(oex)
    assert len(blob) == othumb
    with open(file, "wb") as f:
        f.write(blob + bytes(thumb) + bytes(raw))


dng(path("camera.dng"))


# --- FB2 ----------------------------------------------------------------------------

def fb2(encoding):
    image = base64.encodebytes(small_png).decode()
    return f"""<?xml version="1.0" encoding="{encoding}"?>
<FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0" xmlns:l="http://www.w3.org/1999/xlink">
  <description>
    <title-info>
      <genre>prose_contemporary</genre>
      <author><first-name>Иван</first-name><last-name>Петров</last-name></author>
      <book-title>Тестовая книга</book-title>
      <annotation><p>Короткая аннотация к книге.</p></annotation>
      <lang>ru</lang>
    </title-info>
    <document-info><author><nickname>tester</nickname></author><id>pw-test-1</id><version>1.0</version></document-info>
  </description>
  <body>
    <title><p>Тестовая книга</p></title>
    <epigraph><p>Всё будет хорошо.</p><text-author>Народная мудрость</text-author></epigraph>
    <section>
      <title><p>Глава первая</p></title>
      <p>Привет, мир! Это <emphasis>курсив</emphasis> и <strong>жирный</strong> текст.<a l:href="#n1" type="note">[1]</a></p>
      <image l:href="#pic.png"/>
      <p>Второй абзац главы.</p>
    </section>
    <section>
      <title><p>Глава вторая</p><p>Стихи</p></title>
      <poem>
        <title><p>Песня</p></title>
        <stanza><v>Первая строка стиха,</v><v>вторая строка стиха.</v></stanza>
        <text-author>Автор стиха</text-author>
      </poem>
      <section>
        <title><p>Подраздел</p></title>
        <p>Текст подраздела.</p>
        <empty-line/>
        <cite><p>Цитата внутри.</p></cite>
      </section>
    </section>
    <section>
      <title><p>Глава третья</p></title>
      <subtitle>* * *</subtitle>
      <p>Последний абзац книги. <strikethrough>Зачёркнуто</strikethrough>, H<sub>2</sub>O.</p>
      <table><tr><th>Имя</th><th>Число</th></tr><tr><td>яблоко</td><td>1</td></tr></table>
    </section>
  </body>
  <body name="notes">
    <title><p>Примечания</p></title>
    <section id="n1"><title><p>1</p></title><p>Текст примечания.</p></section>
  </body>
  <binary id="pic.png" content-type="image/png">
{image}  </binary>
</FictionBook>
"""


with open(path("book.fb2"), "w", encoding="utf-8") as f:
    f.write(fb2("UTF-8"))
with open(path("book-1251.fb2"), "wb") as f:
    f.write(fb2("windows-1251").encode("cp1251"))
with zipfile.ZipFile(path("zipped.fb2.zip"), "w", zipfile.ZIP_DEFLATED) as z:
    info = zipfile.ZipInfo("zipped.fb2", date_time=(2024, 1, 1, 0, 0, 0))
    z.writestr(info, fb2("UTF-8"))


# --- data ---------------------------------------------------------------------------

with open(path("sample.json"), "w", encoding="utf-8") as f:
    f.write("""{
  "name": "Петальвил",
  "version": 3,
  "ratio": 0.25,
  "enabled": true,
  "missing": null,
  "empty": "",
  "tags": ["a", "b: c", "#hash", "true", "123", " padded "],
  "nested": {"items": [{"id": 1, "title": "One"}, {"id": 2, "title": "Two\\nlines\\n"}], "none": [], "obj": {}},
  "multi": "line1\\nline2",
  "matrix": [[1, 2], [3, 4]],
  "quote": "He said \\"hi\\""
}
""")

with open(path("people.json"), "w", encoding="utf-8") as f:
    f.write("""[
  {"id": 1, "name": "Smith, John", "note": "He said \\"hi\\"", "active": true},
  {"id": 2, "name": "Иван", "note": "line one\\nline two", "active": false},
  {"id": 3, "name": "plain", "code": "007"}
]
""")

with open(path("config.yaml"), "w", encoding="utf-8") as f:
    f.write("""# Service configuration
defaults: &defaults
  adapter: postgres   # inline comment
  host: localhost
development:
  <<: *defaults
  database: dev_db
ports: [80, 443, "8080"]
inline: {a: 1, b: [x, y]}
servers:
- name: alpha
  ip: 10.0.0.1
- name: Бета
  roles:
    - web
    - db
description: >
  Folded text
  continues here.
script: |
  echo hi
  exit 0
quoted: 'it''s'
empty:
""")

with open(path("data.xml"), "w", encoding="utf-8") as f:
    f.write("""<?xml version="1.0" encoding="UTF-8"?>
<catalog version="2">
  <!-- comment -->
  <book id="b1" lang="ru"><title>Война и мир</title><year>1869</year></book>
  <book id="b2"><title>Anna &amp; Co</title><year>1877</year></book>
</catalog>
""")

with open(path("data.plist"), "wb") as f:
    plistlib.dump({"Name": "Петальвил", "Count": 3, "Enabled": True, "Ratio": 1.5,
                   "Items": [{"id": 1, "title": "One"}, {"id": 2, "title": "Two"}]}, f, sort_keys=True)


# --- subtitles ----------------------------------------------------------------------

ASS = """[Script Info]
Title: Test
ScriptType: v4.00+
PlayResX: 1280
PlayResY: 720

[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Default,Arial,40,&H00FFFFFF,&H000000FF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,2,1,2,10,10,10,1
Style: Sign,Arial,40,&H00FFFFFF,&H000000FF,&H00000000,&H00000000,-1,0,0,0,100,100,0,0,1,2,1,8,10,10,10,1

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
Dialogue: 0,0:00:03.00,0:00:04.00,Default,,0,0,0,,Second {\\i1}cue{\\i0}, with a comma
Dialogue: 0,0:00:01.00,0:00:02.50,Default,,0,0,0,,{\\pos(640,600)\\b1}Привет{\\b0}, мир\\Nline two
Comment: 0,0:00:01.00,0:00:02.50,Default,,0,0,0,,hidden comment
Dialogue: 0,0:00:05.00,0:00:06.00,Sign,,0,0,0,,Top sign
Dialogue: 0,0:00:07.00,0:00:08.00,Default,,0,0,0,,{\\p1}m 0 0 l 100 0 100 100{\\p0}
"""

SSA = """[Script Info]
Title: Test
ScriptType: v4.00

[V4 Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, TertiaryColour, BackColour, Bold, Italic, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, AlphaLevel, Encoding
Style: Default,Arial,40,16777215,255,0,0,0,0,1,2,1,2,10,10,10,0,1

[Events]
Format: Marked, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
Dialogue: Marked=0,0:00:01.00,0:00:02.50,Default,,0,0,0,,Привет, мир
Dialogue: Marked=0,0:00:03.00,0:00:04.00,Default,,0,0,0,,{\\a6}Second cue
"""

with open(path("subs.ass"), "w", encoding="utf-8-sig") as f:
    f.write(ASS)
with open(path("subs.ssa"), "w", encoding="utf-8") as f:
    f.write(SSA)
