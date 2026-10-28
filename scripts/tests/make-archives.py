#!/usr/bin/env python3
"""Archive fixtures that the system tools can't make directly (used by make-fixtures.sh).

  cyr-zip OUT ENCODING     zip with Russian names stored as raw CP866 / CP1251 bytes, no UTF-8 flag
                           (what Windows Explorer and old WinZip write)
  bomb-zip OUT             tiny zip whose central directory declares ~3.75 GB of content
  evil-tarxz OUT           tar.xz with a "../evil.txt" entry (zip-slip)
  abs-zip OUT              zip with an absolute "/tmp/…" entry
  xz IN OUT                single-file xz
  random OUT SIZE SEED     incompressible deterministic bytes
  split IN SIZE            byte-split IN into IN.001, IN.002, …
  bad-crc IN OUT           copy of a zip with a wrong CRC for its last file (damaged archive)
  ar OUT FILE…             GNU/SVR4 ar archive, the container of .deb packages (macOS ar adds a symbol table)
"""
import io
import lzma
import random
import struct
import sys
import tarfile
import zipfile


def cyr_zip(out, enc):
    entries = [("Документы/", b""), ("Документы/отчёт.txt", "Привет из Windows\n".encode()), ("Фото.txt", b"photo")]
    buf = io.BytesIO()
    swaps = []
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as z:
        for i, (name, data) in enumerate(entries):
            raw = name.encode(enc)
            # ASCII placeholder of the same byte length, swapped for the raw bytes afterwards
            # (zipfile would otherwise store UTF-8 and set the UTF-8 flag).
            folder = name.endswith("/")
            ph = chr(65 + i) * (len(raw) - (1 if folder else 0)) + ("/" if folder else "")
            swaps.append((ph.encode(), raw))
            info = zipfile.ZipInfo(ph, date_time=(2024, 1, 1, 0, 0, 0))
            info.create_system = 0  # MS-DOS
            z.writestr(info, data)
    data = buf.getvalue()
    for ph, raw in swaps:
        data = data.replace(ph, raw)
    open(out, "wb").write(data)


def bomb_zip(out):
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as z:
        info = zipfile.ZipInfo("huge.bin", date_time=(2024, 1, 1, 0, 0, 0))
        z.writestr(info, b"\0" * 1024)
    data = bytearray(buf.getvalue())
    fake = 0xF0000000
    # Patch the declared uncompressed size in the local header and the central directory.
    lh = data.find(b"PK\x03\x04")
    struct.pack_into("<I", data, lh + 22, fake)
    cd = data.find(b"PK\x01\x02")
    struct.pack_into("<I", data, cd + 24, fake)
    open(out, "wb").write(bytes(data))


def evil_tarxz(out):
    payload = b"escaped!\n"
    with tarfile.open(out, "w:xz", format=tarfile.USTAR_FORMAT) as t:
        ok = tarfile.TarInfo("safe.txt")
        ok.size = 3
        t.addfile(ok, io.BytesIO(b"ok\n"))
        evil = tarfile.TarInfo("../evil.txt")
        evil.size = len(payload)
        t.addfile(evil, io.BytesIO(payload))


def abs_zip(out):
    with zipfile.ZipFile(out, "w") as z:
        z.writestr("ok.txt", "ok\n")
        z.writestr("/tmp/petalwheel-abs-evil.txt", "escaped!\n")


def bad_crc(src, out):
    data = bytearray(open(src, "rb").read())
    # Last central-directory entry that is a file (directories have no data to check).
    cd, pos = -1, data.find(b"PK\x01\x02")
    while pos >= 0:
        n = struct.unpack_from("<H", data, pos + 28)[0]
        if not bytes(data[pos + 46:pos + 46 + n]).endswith(b"/"):
            cd = pos
        pos = data.find(b"PK\x01\x02", pos + 4)
    crc = struct.unpack_from("<I", data, cd + 16)[0] ^ 0xFFFFFFFF
    offset = struct.unpack_from("<I", data, cd + 42)[0]
    struct.pack_into("<I", data, cd + 16, crc)
    struct.pack_into("<I", data, offset + 14, crc)
    open(out, "wb").write(bytes(data))


def ar(out, files):
    import os
    with open(out, "wb") as o:
        o.write(b"!<arch>\n")
        for f in files:
            data = open(f, "rb").read()
            name = (os.path.basename(f) + "/").encode()
            o.write(b"%-16s%-12d%-6d%-6d%-8s%-10d`\n" % (name, 1704067200, 0, 0, b"100644", len(data)))
            o.write(data)
            if len(data) % 2:
                o.write(b"\n")


def main(argv):
    cmd = argv[1]
    if cmd == "cyr-zip":
        cyr_zip(argv[2], argv[3])
    elif cmd == "bomb-zip":
        bomb_zip(argv[2])
    elif cmd == "evil-tarxz":
        evil_tarxz(argv[2])
    elif cmd == "abs-zip":
        abs_zip(argv[2])
    elif cmd == "xz":
        with open(argv[2], "rb") as f, lzma.open(argv[3], "wb", format=lzma.FORMAT_XZ) as o:
            o.write(f.read())
    elif cmd == "random":
        rng = random.Random(int(argv[4]))
        open(argv[2], "wb").write(bytes(rng.getrandbits(8) for _ in range(int(argv[3]))))
    elif cmd == "split":
        data = open(argv[2], "rb").read()
        size = int(argv[3])
        for i in range(0, max(len(data), 1), size):
            open("%s.%03d" % (argv[2], i // size + 1), "wb").write(data[i:i + size])
    elif cmd == "ar":
        ar(argv[2], argv[3:])
    elif cmd == "bad-crc":
        bad_crc(argv[2], argv[3])
    else:
        sys.exit("unknown command " + cmd)


if __name__ == "__main__":
    main(sys.argv)
