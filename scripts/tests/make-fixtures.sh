# shellcheck shell=bash
# Deterministic fixture generation for scripts/test-suite.sh.
# Requires: $FIX (output dir), $FIXTOOL (compiled fixtures.swift), $FFMPEG, $BIN (for xlsx), fixture_ok/fixture_fail.

CYR="Привет, мир"

ff() { "$FFMPEG" -nostdin -hide_banner -loglevel error -y "$@"; }
# Bit-exact flags keep encoder/muxer output stable across runs.
FFX=(-fflags +bitexact -flags:v +bitexact -flags:a +bitexact -map_metadata -1)

make_fixture() { # NAME COMMAND…  (runs the command, records the fixture result)
    local name=$1; shift
    local log="$FIX/.log-$name"
    if "$@" >"$log" 2>&1 && [[ -s "$FIX/$name" || -d "$FIX/$name" ]]; then
        fixture_ok "$name"
    else
        fixture_fail "$name" "$(tail -3 "$log" | tr '\n' ' ')"
    fi
}

# sips can write AVIF only on newer macOS (not on the macOS 15 CI runners); fall back to ffmpeg's SVT-AV1.
make_avif() {
    sips -s format avif "$1" --out "$2" && [[ -s "$2" ]] && return 0
    "$FFMPEG" -nostdin -hide_banner -loglevel error -y -i "$1" -c:v libsvtav1 -pix_fmt yuv420p -frames:v 1 "$2"
}

gen_images() {
    make_fixture oriented.jpg "$FIXTOOL" orient-jpg "$FIX/oriented.jpg"
    make_fixture alpha.png    "$FIXTOOL" alpha-png "$FIX/alpha.png"
    make_fixture subject.png  "$FIXTOOL" subject-png "$FIX/subject.png"
    make_fixture qr.png       "$FIXTOOL" qr "$FIX/qr.png" "$QR_TEXT"
    make_fixture text.png     "$FIXTOOL" text-image "$FIX/text.png" "$OCR_WORD TEST 2024"
    make_fixture photo.heic   sips -s format heic "$FIX/subject.png" --out "$FIX/photo.heic"
    make_fixture photo.tiff   sips -s format tiff "$FIX/subject.png" --out "$FIX/photo.tiff"
    make_fixture photo.bmp    sips -s format bmp "$FIX/subject.png" --out "$FIX/photo.bmp"
    make_fixture photo.avif   make_avif "$FIX/subject.png" "$FIX/photo.avif"
    if [[ -n "$CWEBP" ]]; then
        make_fixture alpha.webp "$CWEBP" -quiet -lossless -metadata none "$FIX/alpha.png" -o "$FIX/alpha.webp"
    else
        make_fixture alpha.webp ff -i "$FIX/alpha.png" -c:v libwebp -lossless 1 "$FIX/alpha.webp"
    fi
    cat > "$FIX/vector.svg" <<'SVG'
<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg" width="320" height="200" viewBox="0 0 320 200">
  <rect width="320" height="200" fill="#ffefd5"/>
  <circle cx="100" cy="100" r="70" fill="#ff8c1a"/>
  <rect x="190" y="40" width="100" height="120" rx="16" fill="#2a7ab0"/>
  <text x="160" y="190" font-family="Helvetica" font-size="18" text-anchor="middle">Petalwheel</text>
</svg>
SVG
    [[ -s "$FIX/vector.svg" ]] && fixture_ok vector.svg || fixture_fail vector.svg "write failed"
}

gen_pdfs() {
    make_fixture multipage.pdf "$FIXTOOL" pdf "$FIX/multipage.pdf" 3
    make_fixture single.pdf    "$FIXTOOL" pdf "$FIX/single.pdf" 1
    make_fixture scan.pdf      "$FIXTOOL" image-pdf "$FIX/scan.pdf" "$FIX/text.png"
}

gen_media() {
    local v=(-f lavfi -i "testsrc2=size=320x240:rate=25:duration=2")
    local a=(-f lavfi -i "sine=frequency=440:duration=2:sample_rate=44100")
    # The embedded LGPL ffmpeg has no libx264; use the hardware H.264 encoder there.
    local x264
    if "$FFMPEG" -hide_banner -encoders 2>/dev/null | grep -q " libx264 "; then
        x264=(-c:v libx264 -preset veryfast -pix_fmt yuv420p -threads 1)
    else
        x264=(-c:v h264_videotoolbox -allow_sw 1 -b:v 600k -pix_fmt yuv420p)
    fi
    make_fixture clip.mp4    ff "${v[@]}" "${a[@]}" "${x264[@]}" -c:a aac -b:a 96k -ac 2 -shortest "${FFX[@]}" \
                                -metadata title=KQSECRETTITLE "$FIX/clip.mp4"
    make_fixture clip.mov    ff "${v[@]}" "${a[@]}" "${x264[@]}" -c:a aac -ac 2 -shortest "${FFX[@]}" "$FIX/clip.mov"
    make_fixture clip.mkv    ff "${v[@]}" "${a[@]}" "${x264[@]}" -c:a libopus -ac 2 -shortest "${FFX[@]}" "$FIX/clip.mkv"
    make_fixture clip.webm   ff "${v[@]}" "${a[@]}" -c:v libvpx-vp9 -deadline realtime -cpu-used 8 -b:v 300k -threads 1 \
                                -c:a libopus -ac 2 -shortest "${FFX[@]}" "$FIX/clip.webm"
    make_fixture clip.avi    ff "${v[@]}" "${a[@]}" -c:v mpeg4 -q:v 5 -c:a libmp3lame -ac 2 -shortest "${FFX[@]}" "$FIX/clip.avi"
    make_fixture clip.wmv    ff "${v[@]}" "${a[@]}" -c:v wmv2 -b:v 400k -c:a wmav2 -ac 2 -shortest "${FFX[@]}" "$FIX/clip.wmv"
    make_fixture silent.mp4  ff "${v[@]}" "${x264[@]}" -an "${FFX[@]}" "$FIX/silent.mp4"
    make_fixture second.mp4  ff -f lavfi -i "testsrc=size=320x240:rate=25:duration=1" \
                                -f lavfi -i "sine=frequency=880:duration=1:sample_rate=44100" \
                                "${x264[@]}" -c:a aac -ac 2 -shortest "${FFX[@]}" "$FIX/second.mp4"
    make_fixture anim.gif    ff -f lavfi -i "testsrc2=size=160x120:rate=10:duration=2" -vf "split[a][b];[a]palettegen[p];[b][p]paletteuse" \
                                "${FFX[@]}" "$FIX/anim.gif"

    local s=(-f lavfi -i "sine=frequency=440:duration=2:sample_rate=44100" -ac 2)
    # 1 s silence + 1 s tone + 1 s silence, stereo, 16-bit PCM.
    make_fixture padded.wav  ff -f lavfi -i "sine=frequency=440:duration=1:sample_rate=44100" \
                                -af "adelay=1000:all=1,apad=pad_dur=1" -ac 2 -c:a pcm_s16le "${FFX[@]}" "$FIX/padded.wav"
    make_fixture tone.mp3    ff "${s[@]}" -c:a libmp3lame -b:a 128k "${FFX[@]}" -metadata title=KQSECRETTITLE "$FIX/tone.mp3"
    make_fixture tone.flac   ff "${s[@]}" -c:a flac "${FFX[@]}" "$FIX/tone.flac"
    make_fixture tone.m4a    ff "${s[@]}" -c:a aac -b:a 128k "${FFX[@]}" "$FIX/tone.m4a"
    make_fixture tone.ogg    ff "${s[@]}" -c:a libopus "${FFX[@]}" "$FIX/tone.ogg"
    make_fixture tone.opus   ff "${s[@]}" -c:a libopus "${FFX[@]}" "$FIX/tone.opus"
    make_fixture tone.aiff   ff "${s[@]}" -c:a pcm_s16be "${FFX[@]}" "$FIX/tone.aiff"
    make_fixture tone.wma    ff "${s[@]}" -c:a wmav2 -b:a 128k "${FFX[@]}" "$FIX/tone.wma"
}

gen_documents() {
    cat > "$FIX/notes.md" <<MD
# Заголовок документа

$CYR! This is **bold** and *italic* text.

- первый пункт
- second item

| Колонка | Value |
|---|---|
| яблоко | 1 |

\`\`\`
code block
\`\`\`
MD
    fixture_ok notes.md
    cat > "$FIX/page.html" <<HTML
<!DOCTYPE html>
<html lang="ru"><head><meta charset="utf-8"><title>Тест</title></head>
<body>
<h1>Заголовок</h1>
<p>$CYR! <b>Bold</b> and <i>italic</i>.</p>
<ul><li>один</li><li>два</li></ul>
<table border="1"><tr><td>яблоко</td><td>1</td></tr></table>
</body></html>
HTML
    fixture_ok page.html
    make_fixture letter.docx /usr/bin/textutil -convert docx "$FIX/page.html" -output "$FIX/letter.docx"
    make_fixture letter.rtf  /usr/bin/textutil -convert rtf  "$FIX/page.html" -output "$FIX/letter.rtf"
    make_fixture letter.odt  /usr/bin/textutil -convert odt  "$FIX/page.html" -output "$FIX/letter.odt"
    make_fixture letter.rtfd /usr/bin/textutil -convert rtfd "$FIX/page.html" -output "$FIX/letter.rtfd"
    make_fixture letter.doc  /usr/bin/textutil -convert doc  "$FIX/page.html" -output "$FIX/letter.doc"
    make_fixture deck.pptx   python3 -I "$HERE/make-pptx.py" "$FIX/deck.pptx"
    printf '%s\r\nВторая строка в кодировке Windows-1251.\r\n' "$CYR" | iconv -f UTF-8 -t WINDOWS-1251 > "$FIX/cp1251.txt"
    [[ -s "$FIX/cp1251.txt" ]] && fixture_ok cp1251.txt || fixture_fail cp1251.txt "iconv failed"
}

# Produce a fixture with the app itself (e.g. csv → xlsx, md → epub). APP_FIXTURE SOURCE TARGET_EXT NAME
app_fixture() {
    local src=$1 ext=$2 name=$3 d="$FIX/.app-$3" out
    mkdir -p "$d"; cp "$FIX/$src" "$d/"
    out=$(run_with_timeout 120 "$BIN" --convert "$ext" "$d/$src" 2>"$FIX/.log-$name" | grep -v '^» ' | head -1)
    if [[ -n "$out" && -s "$out" ]]; then mv "$out" "$FIX/$name"; fixture_ok "$name"
    else fixture_fail "$name" "app $src → $ext failed: $(tail -2 "$FIX/.log-$name" | tr '\n' ' ')"; fi
}

gen_tables() {
    # RFC 4180: embedded quotes, commas and a newline inside a quoted field.
    printf 'id,name,note\r\n1,"Smith, John","He said ""hi"""\r\n2,Иван,"line one\r\nline two"\r\n3,plain,%s\r\n' "$CYR" > "$FIX/table.csv"
    fixture_ok table.csv
    printf 'id\tname\tnote\n1\tSmith\tКумкват\n2\tDoe\tplain\n' > "$FIX/table.tsv"
    fixture_ok table.tsv
    # xlsx and epub are produced by the app itself.
    app_fixture table.csv xlsx sheet.xlsx
    if [[ " $KQ_FORMATS " == *" epub "* ]]; then app_fixture notes.md epub book.epub; fi
}

gen_subtitles() {
    printf '1\r\n00:00:01,000 --> 00:00:02,500\r\n%s\r\n\r\n2\r\n00:00:03,000 --> 00:00:04,000\r\nSecond <i>cue</i>\r\n\r\n' "$CYR" > "$FIX/subs.srt"
    fixture_ok subs.srt
    printf 'WEBVTT\n\n00:00:01.000 --> 00:00:02.500\n%s\n\n00:00:03.000 --> 00:00:04.000\nSecond cue\n' "$CYR" > "$FIX/subs.vtt"
    fixture_ok subs.vtt
}

gen_archives() {
    local src="$FIX/.archive-src"
    rm -rf "$src"; mkdir -p "$src/bundle/inner"
    printf 'hello from petalwheel\n' > "$src/bundle/hello.txt"
    printf '%s\n' "$CYR" > "$src/bundle/inner/привет.txt"
    find "$src" -exec touch -h -t 202401010000 {} +
    (cd "$src" && rm -f "$FIX/bundle.zip" && zip -qrX "$FIX/bundle.zip" bundle) && fixture_ok bundle.zip || fixture_fail bundle.zip "zip failed"
    (cd "$src" && COPYFILE_DISABLE=1 tar -cf "$FIX/bundle.tar" bundle) && fixture_ok bundle.tar || fixture_fail bundle.tar "tar failed"
    (cd "$src" && COPYFILE_DISABLE=1 tar -cf - bundle | gzip -n > "$FIX/bundle.tar.gz") && fixture_ok bundle.tar.gz || fixture_fail bundle.tar.gz "tgz failed"
    gen_archive_formats
}

# --- archives: every read format, Windows code pages, passwords, volumes, unsafe and damaged archives ---
# zstd / lz4 aren't part of macOS: those fixtures (and the matching cases) exist only when the tools do.
find_archive_tool() { local d; for d in /opt/homebrew/bin /usr/local/bin /usr/bin; do [[ -x "$d/$1" ]] && { echo "$d/$1"; return; }; done; }
ZSTD_BIN="$(find_archive_tool zstd)"
LZ4_BIN="$(find_archive_tool lz4)"
ARCHIVE_PW="petal-pw"

bt() { PATH="/opt/homebrew/bin:/usr/local/bin:$PATH" /usr/bin/bsdtar "$@"; }
mkarc() { python3 -I "$HERE/make-archives.py" "$@"; }

gen_archive_formats() {
    local src="$FIX/.archive-src" t
    rm -rf "$FIX/bundle"; cp -R "$src/bundle" "$FIX/bundle" && fixture_ok bundle || fixture_fail bundle "copy failed"
    make_fixture bundle.7z       bt -c --format 7zip -f "$FIX/bundle.7z" -C "$src" bundle
    make_fixture bundle.tar.bz2  bt -c --bzip2 -f "$FIX/bundle.tar.bz2" -C "$src" bundle
    make_fixture bundle.tar.xz   bt -c --xz -f "$FIX/bundle.tar.xz" -C "$src" bundle
    make_fixture bundle.tar.lzma bt -c --lzma -f "$FIX/bundle.tar.lzma" -C "$src" bundle
    make_fixture bundle.tar.lz   bt -c --lzip -f "$FIX/bundle.tar.lz" -C "$src" bundle
    [[ -n "$ZSTD_BIN" ]] && make_fixture bundle.tar.zst bt -c --zstd -f "$FIX/bundle.tar.zst" -C "$src" bundle
    [[ -n "$LZ4_BIN" ]] && make_fixture bundle.tar.lz4 bt -c --lz4 -f "$FIX/bundle.tar.lz4" -C "$src" bundle
    make_fixture bundle.iso      bt -c --format iso9660 -f "$FIX/bundle.iso" -C "$src" bundle
    make_fixture bundle.cpio     bt -c --format newc -f "$FIX/bundle.cpio" -C "$src" bundle
    make_fixture bundle.pkg      bt -c --format xar -f "$FIX/bundle.pkg" -C "$src" bundle
    rm -f "$FIX/bundle.dmg"
    make_fixture bundle.dmg      hdiutil create -quiet -srcfolder "$src" -volname bundle -format UDZO "$FIX/bundle.dmg"
    # .deb: an ar archive of debian-binary, control.tar.gz and data.tar.xz.
    t="$FIX/.deb-src"; rm -rf "$t"; mkdir -p "$t/control"
    printf '2.0\n' > "$t/debian-binary"
    printf 'Package: petalwheel-test\nVersion: 1.0\nArchitecture: all\n' > "$t/control/control"
    bt -c --gzip -f "$t/control.tar.gz" -C "$t/control" control
    bt -c --xz -f "$t/data.tar.xz" -C "$src" bundle
    rm -f "$FIX/bundle.deb"
    make_fixture bundle.deb      mkarc ar "$FIX/bundle.deb" "$t/debian-binary" "$t/control.tar.gz" "$t/data.tar.xz"
    # Single-file compressors.
    printf 'hello from petalwheel\n' > "$FIX/hello.txt"
    make_fixture hello.txt.gz    bash -c 'gzip -n -c "$1" > "$2"' _ "$FIX/hello.txt" "$FIX/hello.txt.gz"
    make_fixture hello.txt.bz2   bash -c 'bzip2 -c "$1" > "$2"' _ "$FIX/hello.txt" "$FIX/hello.txt.bz2"
    make_fixture hello.txt.xz    mkarc xz "$FIX/hello.txt" "$FIX/hello.txt.xz"
    [[ -n "$ZSTD_BIN" ]] && make_fixture hello.txt.zst "$ZSTD_BIN" -q -f "$FIX/hello.txt" -o "$FIX/hello.txt.zst"
    # Zips made on Russian Windows: names in CP866 (Explorer) or CP1251, without the UTF-8 flag.
    make_fixture cp866.zip       mkarc cyr-zip "$FIX/cp866.zip" cp866
    make_fixture cp1251.zip      mkarc cyr-zip "$FIX/cp1251.zip" cp1251
    # Password-protected zips: AES-256 (bsdtar) and traditional ZipCrypto (Info-ZIP).
    make_fixture enc-aes.zip     bt -c --format zip --options zip:encryption=aes256 --passphrase "$ARCHIVE_PW" -f "$FIX/enc-aes.zip" -C "$src" bundle
    rm -f "$FIX/enc-zipcrypto.zip"
    make_fixture enc-zipcrypto.zip bash -c 'cd "$1" && zip -qrX -P "$2" "$3" bundle' _ "$src" "$ARCHIVE_PW" "$FIX/enc-zipcrypto.zip"
    # Multi-volume: a split zip (split.z01, split.z02…, split.zip) and a byte-split 7z (volumes.7z.001…).
    t="$FIX/.split-src"; rm -rf "$t"; mkdir -p "$t"; cp -R "$src/bundle" "$t/bundle"
    mkarc random "$t/bundle/noise.bin" 150000 7
    rm -f "$FIX"/split.z* "$FIX"/volumes.7z*
    make_fixture split.zip       bash -c 'cd "$1" && zip -qrX -s 64k "$2" bundle && [[ -f "${2%.zip}.z01" ]]' _ "$t" "$FIX/split.zip"
    make_fixture volumes.7z.001  bash -c 'bsdtar -c --format 7zip -f "$2" -C "$1" bundle && python3 -I "$3" split "$2" 60000 && rm "$2"' \
                                     _ "$t" "$FIX/volumes.7z" "$HERE/make-archives.py"
    # Unsafe and damaged archives.
    make_fixture evil.tar.xz     mkarc evil-tarxz "$FIX/evil.tar.xz"
    t="$FIX/.evil-src"; rm -rf "$t"; mkdir -p "$t"; printf 'escaped!\n' > "$t/evil.txt"
    make_fixture evil.7z         bt -c --format 7zip -f "$FIX/evil.7z" -s ',^,../,' -C "$t" evil.txt
    make_fixture evil-abs.zip    mkarc abs-zip "$FIX/evil-abs.zip"
    make_fixture bomb.zip        mkarc bomb-zip "$FIX/bomb.zip"
    make_fixture damaged.zip     mkarc bad-crc "$FIX/bundle.zip" "$FIX/damaged.zip"
    # RAR can't be created (license-restricted): use a small sample from this Mac when there is one.
    local rar
    # (read-only: the smallest one under 3 MB that libarchive extracts cleanly, copied into the work dir)
    rar=$(mdfind 'kMDItemFSName == "*.rar"' 2>/dev/null | while IFS= read -r f; do
              [[ -f "$f" ]] && echo "$(stat -f %z "$f") $f"; done | sort -n | while read -r size f; do
              [[ $size -lt 3000000 ]] || break
              t="$FIX/.rar-check"; rm -rf "$t"; mkdir -p "$t"
              /usr/bin/bsdtar -xf "$f" -C "$t" 2>/dev/null && { rm -rf "$t"; echo "$f"; break; }
              rm -rf "$t"; done)
    if [[ -n "$rar" ]]; then make_fixture sample.rar cp "$rar" "$FIX/sample.rar"; fi
}

generate_fixtures() {
    mkdir -p "$FIX"
    gen_images; gen_pdfs; gen_media; gen_documents; gen_subtitles; gen_archives
    gen_new_format_fixtures   # New formats (RAW, icons, FB2, data, ASS)
    gen_tables   # last: uses the app binary
}

# --- New formats: camera RAW, PSD, icons, FB2, data, ASS/SSA ---------------------------------------
gen_new_format_fixtures() {
    local list="camera.dng wide.png book.fb2 book-1251.fb2 zipped.fb2.zip sample.json people.json config.yaml data.xml data.plist subs.ass subs.ssa"
    local log="$FIX/.log-new-formats" f
    if python3 -I "$HERE/make-new-formats.py" "$FIX" >"$log" 2>&1; then
        for f in $list; do [[ -s "$FIX/$f" ]] && fixture_ok "$f" || fixture_fail "$f" "not written"; done
    else
        for f in $list; do fixture_fail "$f" "$(tail -2 "$log" | tr '\n' ' ')"; done
    fi
    make_fixture layered.psd sips -s format psd "$FIX/wide.png" --out "$FIX/layered.psd"
    # A 256 px ICO and a full ICNS made with Apple's own tools (not with the app under test).
    make_fixture favicon.ico sh -c 'sips -z 256 256 "$1" --out "$2/.fav.png" && sips -s format ico "$2/.fav.png" --out "$2/favicon.ico"' \
        _ "$FIX/subject.png" "$FIX"
    make_fixture app.icns sh -c 'set -e; d="$2/.app.iconset"; rm -rf "$d"; mkdir -p "$d"
        for s in 16 32 128 256 512; do
            sips -z $s $s "$1" --out "$d/icon_${s}x${s}.png" >/dev/null
            sips -z $((s * 2)) $((s * 2)) "$1" --out "$d/icon_${s}x${s}@2x.png" >/dev/null
        done
        iconutil -c icns "$d" -o "$2/app.icns"' _ "$FIX/subject.png" "$FIX"
}
