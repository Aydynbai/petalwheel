# shellcheck shell=bash
# New-format cases for scripts/test-suite.sh (sourced): camera RAW, JPEG XL / PSD, ICO / ICNS, FB2,
# JSON / YAML / XML / plist / CSV, ASS / SSA. Fixtures come from gen_new_format_fixtures (make-fixtures.sh,
# via make-new-formats.py); content checks live in check-new-formats.py.

NF_CHECK() { python3 -I "$HERE/check-new-formats.py" "$@"; }

# Runs a check command; its last output line becomes NOTE (or DETAIL on failure).
nf_run() {
    local out
    if out=$("$@" 2>&1); then NOTE="$(echo "$out" | tail -1)"; return 0; fi
    fail_v "$(echo "$out" | tail -1)"
}

# Converts FILE to EXT with the app inside a fresh folder; prints the output path.
nf_convert() { # FILE EXT
    local d; d="$CASE_DIR/.step-$2-$RANDOM"; mkdir -p "$d"; cp "$1" "$d/"
    run_with_timeout 120 "$BIN" --convert "$2" "$d/$(basename "$1")" 2>/dev/null | grep -v '^» ' | head -1
}

# --- validators -------------------------------------------------------------------------

v_nf_raw() { # displayed 480x640 (orientation 6 applied); EXIF kept in JPEG/HEIC/TIFF
    need_outputs 1 1 || return 1
    local o="${OUTS[0]}"
    if [[ $TARGET == pdf ]]; then
        local p; p=$(pdf_pages "$o") || { fail_v "output isn't a PDF"; return 1; }
        [[ $p -eq 1 ]] || { fail_v "$p pages"; return 1; }; NOTE="1 page"; return 0
    fi
    check_image "$o" 480 640 || return 1
    if [[ $TARGET =~ ^(jpg|heic|tiff)$ ]]; then
        sips -g make "$o" 2>/dev/null | grep -q PetalwheelTestCam || { fail_v "camera Make not carried over"; return 1; }
        NOTE+=", EXIF kept"
    fi
}

v_nf_ico() { need_outputs 1 1 || return 1; nf_run NF_CHECK ico "${OUTS[0]}" ${NF_PADDED:-}; }

v_nf_icns() {
    need_outputs 1 1 || return 1
    local set="$CASE_DIR/check.iconset"
    iconutil -c iconset "${OUTS[0]}" -o "$set" 2>/dev/null || { fail_v "iconutil can't read the ICNS"; return 1; }
    local n; n=$(find "$set" -name '*.png' | wc -l | tr -d ' ')
    [[ $n -ge 10 ]] || { fail_v "$n sizes, expected 10 (16…512 @1x/@2x)"; return 1; }
    local w; w=$(sips -g pixelWidth "$set/icon_512x512@2x.png" 2>/dev/null | awk '/pixelWidth/ {print $2}')
    [[ $w == 1024 ]] || { fail_v "largest size ${w:-?}, expected 1024"; return 1; }
    NOTE="$n sizes up to 1024"
}

v_nf_image() { # EXPECT_W EXPECT_H [alpha]
    need_outputs 1 1 || return 1
    check_image "${OUTS[0]}" "$NF_W" "$NF_H" "${NF_ALPHA:-0}"
}

v_nf_epub() { need_outputs 1 1 || return 1; nf_run NF_CHECK epub-chapters "${OUTS[0]}" "$NF_CHAPTERS" "Привет"; }

v_nf_fb2_name() { # .fb2.zip → "zipped.epub", not "zipped.fb2.epub"
    v_nf_epub || return 1
    [[ "$(basename "${OUTS[0]}")" == zipped.epub ]] || { fail_v "output named $(basename "${OUTS[0]}")"; return 1; }
}

v_nf_fb2_doc() {
    need_outputs 1 || return 1
    local o="${OUTS[0]}"
    if [[ $TARGET == pdf ]]; then
        "$FIXTOOL" pdf-text "$o" | grep -q "Привет" || { fail_v "PDF text lacks 'Привет'"; return 1; }
        "$FIXTOOL" pdf-text "$o" | grep -q "Глава третья" || { fail_v "PDF lacks the last chapter"; return 1; }
        NOTE="$(pdf_pages "$o") page(s), Cyrillic OK"; return 0
    fi
    check_document "$o"
}

v_nf_fb2() { need_outputs 1 1 || return 1; nf_run NF_CHECK fb2 "${OUTS[0]}" "${NF_SECTIONS:-1}" "${NF_WORD:-Привет}"; }

v_nf_fb2_roundtrip() { # fb2 → epub (this case) → fb2: title page + 3 chapters + notes = 5 sections
    v_nf_epub || return 1
    local back; back=$(nf_convert "${OUTS[0]}" fb2)
    [[ -n "$back" && -s "$back" ]] || { fail_v "epub → fb2 failed"; return 1; }
    nf_run NF_CHECK fb2 "$back" 5 "Подраздел"
}

v_nf_roundtrip() { # source → $TARGET (this case) → source format, compared with the source
    need_outputs 1 1 || return 1
    local src="${INPUTS[0]}" ext="${INPUTS[0]##*.}" back
    back=$(nf_convert "${OUTS[0]}" "$ext")
    [[ -n "$back" && -s "$back" ]] || { fail_v "$TARGET → $ext failed"; return 1; }
    if [[ $ext == plist ]]; then nf_run NF_CHECK plist-equal "$src" "$back"; else nf_run NF_CHECK json-equal "$src" "$back"; fi
}

v_nf_json() { need_outputs 1 1 || return 1; nf_run NF_CHECK json-check "${OUTS[0]}" "$NF_EXPR"; }

v_nf_wellformed() {
    need_outputs 1 1 || return 1
    local o="${OUTS[0]}"
    case "$TARGET" in
        xml) xmllint --noout "$o" 2>/dev/null || { fail_v "XML isn't well-formed"; return 1; } ;;
        plist) plutil -lint -s "$o" || { fail_v "plutil rejects the plist"; return 1; } ;;
        yaml) head -c 4 "$o" | grep -q '[[:alnum:]"-]' || { fail_v "empty YAML"; return 1; } ;;
    esac
    contains "$o" "${NF_WORD:-Петальвил}" || { fail_v "lacks '${NF_WORD:-Петальвил}'"; return 1; }
    NOTE="well-formed, Cyrillic OK"
}

v_nf_table() {
    need_outputs 1 1 || return 1
    local o="${OUTS[0]}"
    contains "$o" "$NF_WORD" || { fail_v "lacks '$NF_WORD'"; return 1; }
    if [[ $TARGET == csv ]]; then
        contains "$o" '"Smith, John"' || { fail_v "comma-in-field quoting lost"; return 1; }
        grep -q '"line one' "$o" || { fail_v "embedded newline not quoted"; return 1; }
    else
        grep -q $'\t' "$o" || { fail_v "no tab separators"; return 1; }
    fi
    NOTE="$(grep -c . "$o") lines"
}

v_nf_sub() { # ASS/SSA → srt/vtt/txt: the standard checks + styling handled
    need_outputs 1 1 || return 1
    check_subtitle "${OUTS[0]}" || return 1
    local o="${OUTS[0]}"
    ! grep -q "hidden comment\|m 0 0 l" "$o" || { fail_v "comment or drawing leaked into the output"; return 1; }
    ! grep -q '{\\pos\|{\\b1}' "$o" || { fail_v "ASS override tags left in the text"; return 1; }
    if [[ $TARGET == srt && ${INPUTS[0]} == *.ass ]]; then
        contains "$o" "<b>Привет</b>" || { fail_v "bold override not converted to <b>"; return 1; }
        contains "$o" '{\an8}<b>Top sign</b>' || { fail_v "top-aligned bold style lost"; return 1; }
    fi
    if [[ $TARGET == vtt && ${INPUTS[0]} == *.ass ]]; then
        grep -q -- '--> 00:00:06.000 line:0' "$o" || { fail_v "top alignment not mapped to line:0"; return 1; }
    fi
}

v_nf_ass() { # → ASS / SSA
    need_outputs 1 1 || return 1
    local o="${OUTS[0]}" type="v4.00+"
    [[ $TARGET == ssa ]] && type="v4.00"
    grep -q "^ScriptType: $type\$" "$o" || { fail_v "ScriptType isn't $type"; return 1; }
    grep -q '^\[Events\]' "$o" || { fail_v "no [Events] section"; return 1; }
    grep -q "^Dialogue: .*0:00:01.00,0:00:02.50,Default,.*Привет" "$o" || { fail_v "first cue timing/text wrong"; return 1; }
    if [[ ${INPUTS[0]} == *.srt ]]; then
        contains "$o" 'Second {\i1}cue{\i0}' || { fail_v "<i> not converted to {\\i1}"; return 1; }
    fi
    NOTE="$(grep -c '^Dialogue:' "$o") events"
}

# --- cases ------------------------------------------------------------------------------

run_new_format_tests() {
    local q=$QUICK t
    nf() { # QUICKFLAG GROUP NAME EXPECT VALIDATOR TARGET INPUT
        local qf=$1; shift
        [[ $q -eq 1 && $qf != Q ]] && return 0
        TARGET=$5; SRC_FMT="${6##*.}"; SRC_GROUP=$(group_of "$SRC_FMT")
        run_case "$1" "$2" "$3" "$4" convert "$5" "$6"
    }

    # Camera RAW (synthetic Bayer DNG; real camera files aren't redistributable).
    local raw_targets="jpg png heic tiff avif pdf"; [[ $HAS_WEBP -eq 1 ]] && raw_targets+=" webp"
    for t in $raw_targets; do
        local qf=-; [[ $t == jpg ]] && qf=Q
        nf $qf raw "camera.dng -> $t" ok v_nf_raw "$t" camera.dng
    done
    [[ -z "$FILTER" || "raw/" =~ $FILTER ]] && record raw "cr2 cr3 nef arw raf orf rw2" SKIP 0 \
        "no sample files: same CIRAWFilter path as DNG, can't be generated without camera firmware"

    # PSD (ImageIO writes it) and JPEG XL (decode only; no encoder on macOS to make a fixture).
    NF_W=300; NF_H=120; NF_ALPHA=0
    nf - image "layered.psd -> jpg" ok v_nf_image jpg layered.psd
    NF_ALPHA=1
    nf - image "layered.psd -> png" ok v_nf_image png layered.psd
    if [[ -s "$FIX/photo.jxl" ]]; then
        nf - image "photo.jxl -> png" ok v_nf_image png photo.jxl
    elif [[ -z "$FILTER" || "image/" =~ $FILTER ]]; then
        record image "*.jxl -> jpg,png,…" SKIP 0 "no JPEG XL encoder on this Mac to build a fixture"
    fi

    # Icons.
    NF_PADDED=padded
    nf Q icon "wide.png -> ico" ok v_nf_ico ico wide.png
    NF_PADDED=""
    nf - icon "oriented.jpg -> ico" ok v_nf_ico ico oriented.jpg
    nf - icon "vector.svg -> ico" ok v_nf_ico ico vector.svg
    nf - icon "layered.psd -> ico" ok v_nf_ico ico layered.psd
    nf - icon "wide.png -> icns" ok v_nf_icns icns wide.png
    nf - icon "photo.heic -> icns" ok v_nf_icns icns photo.heic
    NF_W=256; NF_H=256; NF_ALPHA=1
    nf - icon "favicon.ico -> png (largest)" ok v_nf_image png favicon.ico
    NF_W=1024; NF_H=1024
    nf - icon "app.icns -> png (largest)" ok v_nf_image png app.icns
    nf - icon "favicon.ico -> icns" ok v_nf_icns icns favicon.ico

    # FB2 → …: title page + 3 chapters + notes.
    NF_CHAPTERS=5
    nf Q fb2 "book.fb2 -> epub" ok v_nf_fb2_roundtrip epub book.fb2
    nf - fb2 "book-1251.fb2 -> epub" ok v_nf_epub epub book-1251.fb2
    nf - fb2 "zipped.fb2.zip -> epub" ok v_nf_fb2_name epub zipped.fb2.zip
    for t in pdf docx odt rtf html md txt; do
        nf - fb2 "book.fb2 -> $t" ok v_nf_fb2_doc "$t" book.fb2
    done
    # … → FB2 (existing document fixtures).
    NF_SECTIONS=1; NF_WORD="Привет"
    for f in notes.md page.html letter.docx letter.odt letter.rtf letter.rtfd letter.doc cp1251.txt; do
        nf - fb2 "$f -> fb2" ok v_nf_fb2 fb2 "$f"
    done
    nf - fb2 "book.epub -> fb2" ok v_nf_fb2 fb2 book.epub

    # Data.
    nf Q data "sample.json -> yaml -> json" ok v_nf_roundtrip yaml sample.json
    NF_WORD="Петальвил"
    nf - data "sample.json -> xml" ok v_nf_wellformed xml sample.json
    nf - data "sample.json -> plist" ok v_nf_wellformed plist sample.json
    nf - data "data.plist -> json -> plist" ok v_nf_roundtrip json data.plist
    nf - data "data.plist -> yaml -> plist" ok v_nf_roundtrip yaml data.plist
    NF_WORD="Иван"
    nf - data "people.json -> xml" ok v_nf_wellformed xml people.json
    NF_EXPR='d["development"] == {"adapter": "postgres", "host": "localhost", "database": "dev_db"} and d["ports"] == [80, 443, "8080"] and d["inline"] == {"a": 1, "b": ["x", "y"]} and d["servers"][1]["name"] == "Бета" and d["servers"][1]["roles"] == ["web", "db"] and d["description"] == "Folded text continues here.\n" and d["script"] == "echo hi\nexit 0\n" and d["quoted"] == "it'"'"'s" and d["empty"] is None'
    nf - data "config.yaml -> json (values)" ok v_nf_json json config.yaml
    NF_EXPR='d["catalog"]["@version"] == "2" and len(d["catalog"]["book"]) == 2 and d["catalog"]["book"][0]["@id"] == "b1" and d["catalog"]["book"][0]["title"] == "Война и мир" and d["catalog"]["book"][1]["title"] == "Anna & Co"'
    nf - data "data.xml -> json (values)" ok v_nf_json json data.xml
    NF_WORD="Война и мир"
    nf - data "data.xml -> yaml" ok v_nf_wellformed yaml data.xml
    nf - data "data.xml -> csv" ok v_nf_table_xml csv data.xml
    NF_WORD="Иван"
    nf - data "people.json -> csv" ok v_nf_table csv people.json
    nf - data "people.json -> tsv" ok v_nf_table tsv people.json
    NF_EXPR='len(d) == 3 and d[0]["name"] == "Smith, John" and d[0]["note"] == "He said \"hi\"" and d[1]["note"] == "line one\nline two" and d[0]["id"] == 1'
    nf - data "table.csv -> json (records)" ok v_nf_json json table.csv
    NF_EXPR='any(r.get("note") == "Кумкват" for r in d)'
    nf - data "table.tsv -> json" ok v_nf_json json table.tsv
    NF_EXPR='any("Иван" in str(r.values()) for r in d)'
    nf - data "sheet.xlsx -> json" ok v_nf_json json sheet.xlsx
    NF_WORD="Иван"
    nf - data "table.csv -> yaml" ok v_nf_wellformed yaml table.csv
    nf - data "table.csv -> xml" ok v_nf_wellformed xml table.csv
    nf - data "config.yaml -> csv (not tabular)" graceful v_nf_table csv config.yaml

    # Subtitles.
    for t in srt vtt txt; do
        local qf=-; [[ $t == srt ]] && qf=Q
        nf $qf ass "subs.ass -> $t" ok v_nf_sub "$t" subs.ass
    done
    nf - ass "subs.ssa -> srt" ok v_nf_sub srt subs.ssa
    nf - ass "subs.ass -> ssa" ok v_nf_ass ssa subs.ass
    nf - ass "subs.ssa -> ass" ok v_nf_ass ass subs.ssa
    nf - ass "subs.srt -> ass" ok v_nf_ass ass subs.srt
    nf - ass "subs.srt -> ssa" ok v_nf_ass ssa subs.srt
    nf - ass "subs.vtt -> ass" ok v_nf_ass ass subs.vtt
}

v_nf_table_xml() { # catalog/book records → rows
    need_outputs 1 1 || return 1
    contains "${OUTS[0]}" "Война и мир" || { fail_v "lacks 'Война и мир'"; return 1; }
    head -1 "${OUTS[0]}" | grep -q '@id' || { fail_v "attribute column missing"; return 1; }
    NOTE="$(grep -c . "${OUTS[0]}") lines"
}
