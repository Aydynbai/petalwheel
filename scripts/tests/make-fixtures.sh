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
  <text x="160" y="190" font-family="Helvetica" font-size="18" text-anchor="middle">Kumquat</text>
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
    printf 'hello from kumquat\n' > "$src/bundle/hello.txt"
    printf '%s\n' "$CYR" > "$src/bundle/inner/привет.txt"
    find "$src" -exec touch -h -t 202401010000 {} +
    (cd "$src" && rm -f "$FIX/bundle.zip" && zip -qrX "$FIX/bundle.zip" bundle) && fixture_ok bundle.zip || fixture_fail bundle.zip "zip failed"
    (cd "$src" && COPYFILE_DISABLE=1 tar -cf "$FIX/bundle.tar" bundle) && fixture_ok bundle.tar || fixture_fail bundle.tar "tar failed"
    (cd "$src" && COPYFILE_DISABLE=1 tar -cf - bundle | gzip -n > "$FIX/bundle.tar.gz") && fixture_ok bundle.tar.gz || fixture_fail bundle.tar.gz "tgz failed"
}

generate_fixtures() {
    mkdir -p "$FIX"
    gen_images; gen_pdfs; gen_media; gen_documents; gen_subtitles; gen_archives
    gen_tables   # last: uses the app binary
}
