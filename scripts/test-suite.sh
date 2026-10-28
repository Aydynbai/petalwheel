#!/bin/bash
# End-to-end test suite for Petalwheel's headless CLI.
#
# Usage: scripts/test-suite.sh [--binary PATH] [--quick] [--keep] [--filter REGEX] [--timeout SECS]
#   --binary PATH   Petalwheel executable (default: build/Petalwheel.app/Contents/MacOS/Petalwheel,
#                   falling back to .build/debug/Petalwheel)
#   --quick         one representative conversion/tool per group (~1 minute)
#   --keep          keep the temp work dir (fixtures + outputs) for inspection
#   --filter REGEX  only run cases whose name matches (extended regex)
#   --timeout SECS  per-case timeout (default 300)
#
# Generates fixtures deterministically in a temp dir, runs every conversion pair the app offers
# (mirrors Sources/Petalwheel/Model/ConversionCatalog.swift) and every non-interactive tool, validates
# the produced files (dimensions, codecs, durations, page counts, text content), prints a PASS/FAIL
# table and writes build/test-report.md + build/test-report.xml. Exits 1 on any failure.
set -u   # no pipefail: validators use `cmd | grep -q`, which SIGPIPEs the producer

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HERE="$ROOT/scripts/tests"
# shellcheck source=tests/lib.sh
source "$HERE/lib.sh"
# shellcheck source=tests/make-fixtures.sh
source "$HERE/make-fixtures.sh"

BIN=""; QUICK=0; KEEP=0; FILTER=""; export KQ_TIMEOUT=300
while [[ $# -gt 0 ]]; do
    case "$1" in
        --binary) BIN="$2"; shift 2 ;;
        --quick) QUICK=1; shift ;;
        --keep) KEEP=1; shift ;;
        --filter) FILTER="$2"; shift 2 ;;
        --timeout) KQ_TIMEOUT="$2"; shift 2 ;;
        -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 2 ;;
    esac
done

if [[ -z "$BIN" ]]; then
    for c in "$ROOT/build/Petalwheel.app/Contents/MacOS/Petalwheel" "$ROOT/.build/debug/Petalwheel"; do
        [[ -x "$c" ]] && { BIN="$c"; break; }
    done
fi
[[ -n "$BIN" && -x "$BIN" ]] || { echo "No Petalwheel binary found; build first or pass --binary" >&2; exit 2; }
BIN="$(cd "$(dirname "$BIN")" && pwd)/$(basename "$BIN")"
ORIG_BIN="$BIN"

# Prefer the tools embedded next to the binary (same ffmpeg the app uses), else Homebrew.
TOOLS_DIR="$(dirname "$BIN")/../Resources/Tools"
pick_tool() { if [[ -x "$TOOLS_DIR/$1" ]]; then echo "$TOOLS_DIR/$1"; else command -v "$1" || true; fi; }
FFMPEG="$(pick_tool ffmpeg)"; FFPROBE="$(pick_tool ffprobe)"; CWEBP="$(pick_tool cwebp)"
[[ -n "$FFMPEG" && -n "$FFPROBE" ]] || { echo "ffmpeg/ffprobe not found (brew install ffmpeg)" >&2; exit 2; }
HAS_WEBP=0; [[ -n "$CWEBP" ]] && HAS_WEBP=1

QR_TEXT="https://petalwheel.example/qr?id=42&lang=ru"
OCR_WORD="PETALWHEEL"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/petalwheel-tests.XXXXXX")"
FIX="$WORK/fixtures"; RUNS="$WORK/runs"; mkdir -p "$FIX" "$RUNS"
# Snapshot the app bundle so a concurrent build-app.sh (which deletes build/Petalwheel.app) can't break the run.
if [[ "$BIN" == *.app/Contents/MacOS/* ]]; then
    APP_SRC="${BIN%/Contents/MacOS/*}"
    ditto "$APP_SRC" "$WORK/$(basename "$APP_SRC")"
    # Renamed executable: `killall Petalwheel` / `pkill -x Petalwheel` (e.g. relaunching the menu-bar app) won't hit tests.
    mv "$WORK/$(basename "$APP_SRC")/Contents/MacOS/$(basename "$BIN")" "$WORK/$(basename "$APP_SRC")/Contents/MacOS/kq-under-test"
    BIN="$WORK/$(basename "$APP_SRC")/Contents/MacOS/kq-under-test"
    echo "Testing a snapshot of $APP_SRC"
else
    cp "$BIN" "$WORK/petalwheel-bin"; BIN="$WORK/petalwheel-bin"
fi
TOOLS_DIR="$(dirname "$BIN")/../Resources/Tools"
FFMPEG="$(pick_tool ffmpeg)"; FFPROBE="$(pick_tool ffprobe)"; CWEBP="$(pick_tool cwebp)"
cleanup() { [[ $KEEP -eq 1 ]] && echo "Work dir kept: $WORK" || rm -rf "$WORK"; }
trap cleanup EXIT

if [[ -t 1 || -n "${FORCE_COLOR:-}" ]]; then
    C_G=$'\033[32m'; C_R=$'\033[31m'; C_Y=$'\033[33m'; C_B=$'\033[1m'; C_D=$'\033[2m'; C_0=$'\033[0m'
else C_G=""; C_R=""; C_Y=""; C_B=""; C_D=""; C_0=""; fi

# --- results ------------------------------------------------------------------

R_GROUP=(); R_NAME=(); R_STATUS=(); R_MS=(); R_DETAIL=(); R_LOG=()
SUITE_START=$(now_ms)

record() { # GROUP NAME STATUS MS DETAIL [LOGFILE]
    R_GROUP+=("$1"); R_NAME+=("$2"); R_STATUS+=("$3"); R_MS+=("$4"); R_DETAIL+=("$5"); R_LOG+=("${6:-}")
    [[ $1 == fixture && $3 == PASS ]] && { FIXTURES_OK=$((FIXTURES_OK + 1)); return 0; }   # keep the table short
    local col=$C_G; [[ $3 == FAIL ]] && col=$C_R; [[ $3 == SKIP ]] && col=$C_Y
    printf "%s%-4s%s  %-12s %-46s %7.2fs  %s%s%s\n" "$col" "$3" "$C_0" "$1" "$2" \
        "$(awk -v m="$4" 'BEGIN{printf "%.2f", m/1000}')" "$C_D" "$5" "$C_0"
}

fixture_ok() { record fixture "$1" PASS 0 ""; }
fixture_fail() { record fixture "$1" FAIL 0 "$2"; }

# --- case runner ----------------------------------------------------------------

# State shared with validators.
OUTS=(); MSGS=""; DETAIL=""; NOTE=""; CASE_DIR=""; INPUTS=()
CASE_N=0

fail_v() { DETAIL="$*"; return 1; }

# run_case GROUP NAME EXPECT VALIDATOR MODE ARG INPUT…
#   EXPECT: ok        must succeed and validate
#           graceful  success+validation, or a clean error (non-zero exit with a message) both pass
#           optional  "rejected by CLI" → SKIP (used for interactive tools)
run_case() {
    local group=$1 name=$2 expect=$3 validator=$4 mode=$5 arg=$6; shift 6
    if [[ -n "$FILTER" ]] && ! [[ "$group/$name" =~ $FILTER ]]; then return 0; fi
    CASE_N=$((CASE_N + 1))
    CASE_DIR="$RUNS/$(printf '%03d' $CASE_N)"; mkdir -p "$CASE_DIR"
    INPUTS=()
    local f missing=""
    for f in "$@"; do
        if [[ -e "$FIX/$f" ]]; then cp -R "$FIX/$f" "$CASE_DIR/"; INPUTS+=("$CASE_DIR/$f")
        else missing+="$f "; fi
    done
    if [[ -n "$missing" ]]; then record "$group" "$name" FAIL 0 "fixture missing: $missing"; return; fi

    local out="$CASE_DIR/.stdout" err="$CASE_DIR/.stderr" t0 t1 code
    t0=$(now_ms)
    (cd "$CASE_DIR" && run_with_timeout "$KQ_TIMEOUT" "$BIN" "--$mode" "$arg" "${INPUTS[@]}" >"$out" 2>"$err")
    code=$?
    local retried=""
    if [[ $code -eq 143 ]]; then   # SIGTERM from outside (not our timeout): retry once in a clean dir
        retried="(retried after external SIGTERM) "
        find "$CASE_DIR" -mindepth 1 -maxdepth 1 ! -name '.std*' -exec rm -rf {} +
        for f in "$@"; do cp -R "$FIX/$f" "$CASE_DIR/"; done
        (cd "$CASE_DIR" && run_with_timeout "$KQ_TIMEOUT" "$BIN" "--$mode" "$arg" "${INPUTS[@]}" >"$out" 2>"$err")
        code=$?
    fi
    t1=$(now_ms)
    local ms=$((t1 - t0))

    OUTS=(); MSGS=""; DETAIL=""; NOTE=""
    local line
    while IFS= read -r line; do
        if [[ "$line" == "» "* ]]; then MSGS+="${line#» }"$'\n'
        elif [[ -n "$line" ]]; then OUTS+=("$line"); fi
    done < "$out"
    local errtxt; errtxt="$(tr '\n' ' ' < "$err" | cut -c1-220)"

    if [[ $code -ge 124 ]]; then
        local why="crashed (exit $code)"; [[ $code -eq 142 ]] && why="timed out after ${KQ_TIMEOUT}s"
        record "$group" "$name" FAIL "$ms" "$why $errtxt" "$err"; return
    fi
    if [[ $code -ne 0 ]]; then
        if [[ $expect == graceful && -s "$err" ]]; then
            record "$group" "$name" PASS "$ms" "clean error: $errtxt"; return
        fi
        if [[ $expect == optional ]]; then record "$group" "$name" SKIP "$ms" "rejected by CLI: $errtxt"; return; fi
        record "$group" "$name" FAIL "$ms" "exit $code: ${errtxt:-no message}" "$err"; return
    fi
    for f in "${OUTS[@]+"${OUTS[@]}"}"; do
        if [[ ! -e "$f" ]]; then record "$group" "$name" FAIL "$ms" "printed path doesn't exist: $f"; return; fi
        if [[ -f "$f" && ! -s "$f" ]]; then record "$group" "$name" FAIL "$ms" "empty output: $(basename "$f")"; return; fi
    done
    if "$validator"; then
        record "$group" "$name" PASS "$ms" "$retried$NOTE"
    else
        record "$group" "$name" FAIL "$ms" "$DETAIL" "$err"
    fi
}

need_outputs() { # MIN [MAX]
    local n=${#OUTS[@]}
    [[ $n -ge $1 ]] || fail_v "expected ≥$1 output(s), got $n${MSGS:+; messages: $(echo "$MSGS" | tr '\n' ' ')}" || return 1
    [[ -z "${2:-}" || $n -le $2 ]] || fail_v "expected ≤$2 output(s), got $n" || return 1
}

# --- source expectations ----------------------------------------------------------

# Displayed size / alpha of a fixture image: "w h alpha orientation".
image_info() { "$FIXTOOL" image-info "$1" 2>/dev/null; }
pdf_pages() { "$FIXTOOL" pages "$1" 2>/dev/null; }

has_cyrillic_text() { # fixture name → 0 when it contains the Cyrillic marker text
    case "$1" in scan.pdf|*.svg) return 1 ;; esac
    return 0
}

# --- validators: conversions ------------------------------------------------------

check_image() { # FILE [expected w h alpha]
    local f=$1 info w h a
    info=$(image_info "$f") || { fail_v "$(basename "$f") isn't a readable image"; return 1; }
    read -r w h a _ <<<"$info"
    local raw; raw=$(sips -g pixelWidth -g pixelHeight "$f" 2>/dev/null | awk '/pixel/ {printf "%s ", $2}')
    [[ ${w:-0} -gt 0 && ${h:-0} -gt 0 ]] || { fail_v "zero-size image (sips: $raw)"; return 1; }
    if [[ -n "${2:-}" ]]; then
        if [[ $w -ne $2 || $h -ne $3 ]]; then
            if [[ $2 -lt $3 && $w -gt $h ]]; then fail_v "EXIF orientation not applied: ${w}x${h}, expected ${2}x${3}"
            else fail_v "size ${w}x${h}, expected ${2}x${3} (sips raw: $raw)"; fi
            return 1
        fi
        if [[ "${4:-}" == 1 && $a -ne 1 ]]; then fail_v "alpha channel lost"; return 1; fi
    fi
    NOTE="${w}x${h}"
}

v_convert() {
    local src="${INPUTS[0]}" sname; sname=$(basename "$src")
    local tgt=$TARGET
    need_outputs 1 || return 1
    local o="${OUTS[0]}"
    case "$tgt" in
        jpg|png|heic|webp|avif|tiff|bmp)
            if [[ $SRC_GROUP == documents ]]; then      # pdf/pptx → one image per page/slide
                local pages; if [[ $SRC_FMT == pptx ]]; then pages=2; else pages=$(pdf_pages "$src"); fi
                if [[ ${#OUTS[@]} -eq 1 && -d "$o" ]]; then   # a folder of pages
                    OUTS=(); local x; while IFS= read -r x; do OUTS+=("$x"); done < <(find "$o" -type f ! -name '.*' | sort)
                fi
                [[ ${#OUTS[@]} -eq $pages ]] || { fail_v "$pages page(s) but ${#OUTS[@]} image(s)"; return 1; }
                local x; for x in "${OUTS[@]}"; do check_image "$x" || return 1; done
                NOTE="$pages image(s), $NOTE"; return 0
            fi
            if [[ $SRC_GROUP == video ]]; then check_image "$o"; return; fi   # gif → still frame
            if [[ $SRC_FMT == svg ]]; then check_image "$o"; return; fi
            local sw sh sa; read -r sw sh sa _ <<<"$(image_info "$src")"
            local keep_alpha=0
            # Only fixtures with real transparency (opaque RGBA sources may legitimately drop alpha).
            [[ $sa == 1 && $sname == alpha.* && $tgt =~ ^(png|tiff|webp|heic|avif)$ ]] && keep_alpha=1
            check_image "$o" "$sw" "$sh" "$keep_alpha" ;;
        gif)
            if [[ $SRC_GROUP == images ]]; then
                local sw sh; read -r sw sh _ <<<"$(image_info "$src")"
                [[ $SRC_FMT == svg ]] && { check_image "$o"; return; }
                check_image "$o" "$sw" "$sh"; return
            fi
            check_av "$o" video ;;
        pdf)
            local p; p=$(pdf_pages "$o") || { fail_v "output isn't a valid PDF"; return 1; }
            [[ $p -ge 1 ]] || { fail_v "PDF has 0 pages"; return 1; }
            if [[ $SRC_GROUP == images ]]; then [[ $p -eq 1 ]] || { fail_v "image → $p pages"; return 1; }
            elif [[ $SRC_FMT == pptx ]]; then [[ $p -eq 2 ]] || { fail_v "2 slides → $p pages"; return 1; }
                "$FIXTOOL" pdf-text "$o" | grep -q "Привет" || { fail_v "PDF text lacks Cyrillic 'Привет'"; return 1; }
            elif has_cyrillic_text "$sname"; then
                "$FIXTOOL" pdf-text "$o" | grep -q "Привет" || { fail_v "PDF text lacks Cyrillic 'Привет'"; return 1; }
            fi
            NOTE="$p page(s)" ;;
        mp4|mov|mkv|webm|avi|wmv) check_av "$o" video ;;
        mp3|m4a|wav|flac|ogg|opus|aiff|wma) check_av "$o" audio ;;
        txt|md|html|docx|odt|rtf|rtfd)
            if [[ $SRC_GROUP == subtitles ]]; then check_subtitle "$o"; return; fi
            if [[ $SRC_GROUP == spreadsheets ]]; then check_sheet "$o"; return; fi
            check_document "$o" ;;
        epub) check_epub "$o" ;;
        xlsx|csv|tsv) check_sheet "$o" ;;
        srt|vtt) check_subtitle "$o" ;;
        zip|tar|tgz) check_archive "$o" ;;
        *) fail_v "no validator for $tgt" ;;
    esac
}

expected_codec() { # TARGET KIND → regex
    case "$1:$2" in
        mp4:v|mov:v) echo '^(h264|hevc|prores)$' ;;
        mkv:v) echo '^(h264|hevc|vp9|av1)$' ;;
        webm:v) echo '^(vp8|vp9|av1)$' ;;
        avi:v) echo '^(mpeg4|h264|mjpeg|msmpeg4v3)$' ;;
        wmv:v) echo '^(wmv1|wmv2|msmpeg4v3|vc1)$' ;;
        gif:v) echo '^gif$' ;;
        webm:a) echo '^(opus|vorbis)$' ;;
        mp4:a|mov:a|m4a:a) echo '^(aac|alac)$' ;;
        mkv:a) echo '^(aac|opus|vorbis|flac|mp3|ac3)$' ;;
        avi:a) echo '^(mp3|aac|ac3|pcm_s16le)$' ;;
        wmv:a|wma:a) echo '^(wmav1|wmav2)$' ;;
        mp3:a) echo '^mp3$' ;;
        wav:a) echo '^pcm_' ;;
        flac:a) echo '^flac$' ;;
        ogg:a) echo '^(vorbis|opus|flac)$' ;;
        opus:a) echo '^opus$' ;;
        aiff:a) echo '^pcm_.*be$' ;;
        *) echo '.' ;;
    esac
}

check_av() { # FILE video|audio
    local f=$1 kind=$2 src="${INPUTS[0]}" tgt=$TARGET
    local vc ac d sd
    vc=$(probe_codecs "$f" v); ac=$(probe_codecs "$f" a)
    d=$(probe_duration "$f"); sd=$(probe_duration "$src")
    local src_ac; src_ac=$(probe_codecs "$src" a)
    if [[ $kind == video ]]; then
        [[ -n "$vc" ]] || { fail_v "no video stream"; return 1; }
        [[ "$vc" =~ $(expected_codec "$tgt" v) ]] || { fail_v "video codec '$vc' unexpected for .$tgt"; return 1; }
        if [[ $tgt == gif ]]; then
            [[ -z "$ac" ]] || { fail_v "GIF has audio?"; return 1; }
        elif [[ -n "$src_ac" ]]; then
            [[ -n "$ac" ]] || { fail_v "audio track dropped (source has $src_ac)"; return 1; }
            [[ "$ac" =~ $(expected_codec "$tgt" a) ]] || { fail_v "audio codec '$ac' unexpected for .$tgt"; return 1; }
        elif [[ -n "$ac" ]]; then
            NOTE="added audio track to silent source; "
        fi
    else
        [[ -n "$ac" ]] || { fail_v "no audio stream"; return 1; }
        [[ -z "$vc" ]] || { fail_v "audio file has a video stream ($vc)"; return 1; }
        [[ "$ac" =~ $(expected_codec "$tgt" a) ]] || { fail_v "audio codec '$ac' unexpected for .$tgt"; return 1; }
    fi
    local tol=0.5; [[ $tgt == gif || $SRC_FMT == gif ]] && tol=0.7
    if [[ -n "$sd" ]]; then
        float_near "$d" "$sd" "$tol" || { fail_v "duration ${d:-?}s vs source ${sd}s (±$tol)"; return 1; }
    fi
    NOTE+="${vc:+v=$vc }${ac:+a=$ac }$(printf '%.2fs' "${d:-0}")"
}

check_document() {
    local f=$1 tgt=$TARGET sname; sname=$(basename "${INPUTS[0]}")
    local text=""
    case "$tgt" in
        txt|md|html) text=$(cat "$f") ;;
        docx) unzip -l "$f" 2>/dev/null | grep -q 'word/document.xml' || { fail_v "docx lacks word/document.xml"; return 1; }
              text=$(doc_text "$f") ;;
        odt) unzip -l "$f" 2>/dev/null | grep -q 'content.xml' || { fail_v "odt lacks content.xml"; return 1; }
             text=$(doc_text "$f") ;;
        rtf) [[ "$(head -c 5 "$f")" == '{\rtf' ]] || { fail_v "not an RTF file"; return 1; }
             text=$(doc_text "$f") ;;
        rtfd) [[ -d "$f" && -f "$f/TXT.rtf" ]] || { fail_v "rtfd package lacks TXT.rtf"; return 1; }
              text=$(doc_text "$f") ;;
    esac
    if [[ $tgt == html ]] && ! grep -qi '<html\|<body\|<p' "$f"; then fail_v "HTML has no markup"; return 1; fi
    if has_cyrillic_text "$sname"; then
        [[ "$text" == *"Привет"* ]] || { fail_v "text lacks Cyrillic 'Привет' (got: $(echo "$text" | head -c 80 | tr '\n' ' '))"; return 1; }
        NOTE="Cyrillic OK"
    else
        NOTE="$(echo "$text" | wc -c | tr -d ' ') bytes"
    fi
}

check_epub() {
    local f=$1 l; l=$(unzip -l "$f" 2>/dev/null) || { fail_v "epub isn't a zip"; return 1; }
    [[ "$l" == *mimetype* && "$l" == *META-INF/container.xml* ]] || { fail_v "epub lacks mimetype/container.xml"; return 1; }
    [[ "$(unzip -p "$f" mimetype 2>/dev/null)" == "application/epub+zip" ]] || { fail_v "bad epub mimetype"; return 1; }
    if has_cyrillic_text "$(basename "${INPUTS[0]}")"; then
        unzip -p "$f" 2>/dev/null | grep -q "Привет" || { fail_v "epub content lacks 'Привет'"; return 1; }
    fi
    NOTE="$(echo "$l" | tail -1 | awk '{print $2}') parts"
}

check_sheet() {
    local f=$1 tgt=$TARGET word="Иван"
    [[ $SRC_FMT == tsv ]] && word="Кумкват"
    case "$tgt" in
        xlsx)
            local l; l=$(unzip -l "$f" 2>/dev/null)
            [[ "$l" == *xl/workbook.xml* && "$l" == *xl/worksheets/* ]] || { fail_v "xlsx missing workbook/worksheets"; return 1; }
            unzip -p "$f" 2>/dev/null | grep -q "$word" || { fail_v "xlsx lacks '$word'"; return 1; }
            NOTE="$(echo "$l" | tail -1 | awk '{print $2}') parts" ;;
        csv)
            contains "$f" "$word" || { fail_v "csv lacks '$word'"; return 1; }
            if [[ $SRC_FMT != tsv ]]; then
                contains "$f" '"He said ""hi"""' || { fail_v 'quote escaping lost ("He said ""hi""")'; return 1; }
                contains "$f" '"Smith, John"' || { fail_v "comma-in-field quoting lost"; return 1; }
                grep -q '"line one' "$f" && grep -q 'line two"' "$f" || { fail_v "embedded newline cell broken"; return 1; }
            fi
            NOTE="quoting OK" ;;
        tsv)
            grep -q $'\t' "$f" || { fail_v "no tab separators"; return 1; }
            contains "$f" "$word" || { fail_v "tsv lacks '$word'"; return 1; } ;;
        html)
            grep -qi '<table' "$f" || { fail_v "no <table>"; return 1; }
            contains "$f" "$word" || { fail_v "html lacks '$word'"; return 1; } ;;
    esac
}

check_subtitle() {
    local f=$1 tgt=$TARGET
    contains "$f" "Привет" || { fail_v "lacks Cyrillic cue text"; return 1; }
    case "$tgt" in
        srt) contains "$f" "00:00:01,000 --> 00:00:02,500" || { fail_v "srt timing missing/wrong"; return 1; } ;;
        vtt) head -1 "$f" | grep -q 'WEBVTT' || { fail_v "no WEBVTT header"; return 1; }
             contains "$f" "00:00:01.000 --> 00:00:02.500" || { fail_v "vtt timing missing/wrong"; return 1; } ;;
        txt) ! grep -qF -- '-->' "$f" || { fail_v "txt still contains timings"; return 1; }
             contains "$f" "Second" || { fail_v "second cue missing"; return 1; } ;;
    esac
    NOTE="$(grep -c . "$f") lines"
}

check_archive() {
    local f=$1 tgt=$TARGET list
    case "$tgt" in
        zip) list=$(unzip -l "$f" 2>/dev/null) ;;
        tar) list=$(tar -tf "$f" 2>/dev/null) ;;
        tgz) gzip -t "$f" 2>/dev/null || { fail_v "not gzip"; return 1; }; list=$(tar -tzf "$f" 2>/dev/null) ;;
    esac
    [[ "$list" == *bundle/hello.txt* ]] || { fail_v "archive lacks bundle/hello.txt"; return 1; }
    [[ "$list" == *inner/* ]] || { fail_v "archive lacks nested dir"; return 1; }
    NOTE="$(echo "$list" | grep -c .) entries"
}

# --- conversion matrix (mirror of ConversionCatalog.outputs, ffmpeg present) ------

group_of() {
    case "$1" in
        jpg|png|webp|heic|tiff|svg|avif|bmp) echo images ;;
        mp3|m4a|wav|flac|ogg|opus|aiff|wma) echo audio ;;
        mp4|mov|mkv|webm|avi|wmv|gif) echo video ;;
        pdf|docx|odt|rtf|rtfd|html|md|txt|epub|doc|pptx|key|pages) echo documents ;;
        xlsx|csv|tsv|xls|numbers) echo spreadsheets ;;
        srt|vtt) echo subtitles ;;
        zip|tar|tgz) echo archives ;;
    esac
}

targets_for() {
    local src=$1 r
    case "$(group_of "$src")" in
        images) r="jpg png heic webp avif tiff bmp gif pdf"; [[ $HAS_WEBP -eq 1 ]] || r=${r/webp /} ;;
        audio) r="mp3 m4a wav flac ogg opus aiff wma" ;;
        video) r="mp4 mov mkv webm avi wmv gif mp3 m4a wav"; [[ $src == gif ]] && r="mp4 mov webm png jpg" ;;
        documents)
            case "$src" in
                pdf) r="png jpg txt rtf docx html md" ;;
                epub) r="pdf docx odt rtf html md txt" ;;
                pptx|key) r="pdf png jpg" ;;
                pages) r="pdf docx rtf html md txt" ;;
                *) r="pdf docx odt rtf rtfd html md txt" ;;
            esac
            [[ " $KQ_FORMATS " == *" epub "* && $src =~ ^(docx|odt|rtf|rtfd|html|md|txt|doc)$ ]] && r+=" epub" ;;
        spreadsheets)
            case "$src" in xls) r="xlsx csv tsv html pdf" ;; numbers) r="pdf" ;; *) r="xlsx csv tsv html" ;; esac ;;
        subtitles) r="srt vtt txt" ;;
        archives) r="zip tar tgz" ;;
    esac
    local t out=""
    for t in $r; do [[ $t == "$src" ]] || out+="$t "; done
    echo "$out"
}

format_of() { case "$1" in *.tar.gz) echo tgz ;; *) echo "${1##*.}" ;; esac; }

# fixture → expectation override for "edge" sources (expected to possibly fail cleanly).
expect_for() { # FIXTURE TARGET
    case "$1:$2" in
        silent.mp4:mp3|silent.mp4:m4a|silent.mp4:wav) echo graceful ;;   # no audio track to extract
        scan.pdf:txt|scan.pdf:rtf|scan.pdf:docx|scan.pdf:html|scan.pdf:md) echo graceful ;;   # no text layer
        *) echo ok ;;
    esac
}

CONVERSION_SOURCES="oriented.jpg alpha.png photo.heic photo.tiff vector.svg alpha.webp photo.avif photo.bmp
tone.mp3 tone.m4a padded.wav tone.flac tone.ogg tone.opus tone.aiff tone.wma
clip.mp4 clip.mov clip.mkv clip.webm clip.avi clip.wmv anim.gif silent.mp4
multipage.pdf scan.pdf letter.docx letter.odt letter.rtf letter.rtfd page.html notes.md cp1251.txt
letter.doc deck.pptx book.epub
sheet.xlsx table.csv table.tsv
subs.srt subs.vtt
bundle.zip bundle.tar bundle.tar.gz"

QUICK_CONVERSIONS="oriented.jpg:png tone.mp3:wav clip.mp4:webm multipage.pdf:png notes.md:pdf sheet.xlsx:csv subs.srt:vtt bundle.zip:tgz"

run_conversion() { # FIXTURE TARGET
    SRC_FMT=$(format_of "$1"); SRC_GROUP=$(group_of "$SRC_FMT"); TARGET=$2
    run_case "convert" "$1 -> $2" "$(expect_for "$1" "$2")" v_convert convert "$2" "$1"
}

run_conversions() {
    local fx t
    if [[ $QUICK -eq 1 ]]; then
        for fx in $QUICK_CONVERSIONS; do run_conversion "${fx%%:*}" "${fx##*:}"; done
        return
    fi
    for fx in $CONVERSION_SOURCES; do
        [[ " $KQ_FORMATS " == *" $(format_of "$fx") "* ]] || continue   # format not in this build
        for t in $(targets_for "$(format_of "$fx")"); do run_conversion "$fx" "$t"; done
    done
    # Input-only formats that need proprietary apps to author (no deterministic generator here).
    for f in xls key pages numbers; do
        [[ " $KQ_FORMATS " == *" $f "* ]] || continue
        [[ -z "$FILTER" || "convert/$f" =~ $FILTER ]] || continue
        record convert "*.$f -> $(targets_for "$f" | tr ' ' ',' | sed 's/,$//')" SKIP 0 "no fixture: .$f needs Excel/iWork to author"
    done
}

# --- validators: tools ----------------------------------------------------------------

v_compress() {
    need_outputs 0 || return 1
    if [[ ${#OUTS[@]} -eq 0 ]]; then
        [[ -n "$MSGS" ]] || { fail_v "no output and no message"; return 1; }
        NOTE="message: $(echo "$MSGS" | head -1)"; return 0
    fi
    local o="${OUTS[0]}" s
    s=$(stat -f %z "${INPUTS[0]}"); local os; os=$(stat -f %z "$o")
    case "$o" in
        *.pdf) pdf_pages "$o" >/dev/null || { fail_v "compressed PDF unreadable"; return 1; } ;;
        *.mp4|*.mov|*.wav|*.mp3|*.m4a) [[ -n "$(probe_codecs "$o" a)$(probe_codecs "$o" v)" ]] || { fail_v "compressed media unreadable"; return 1; } ;;
        *) check_image "$o" || return 1 ;;
    esac
    NOTE="$s → $os bytes"
    [[ $os -le $s ]] || NOTE+=" (larger than original!)"
}

v_remove_metadata() {
    need_outputs 1 1 || return 1
    local o="${OUTS[0]}"
    case "$o" in
        *.jpg|*.png|*.heic|*.tiff)
            ! grep -qa "PetalwheelTestCam" "$o" || { fail_v "EXIF Make still present"; return 1; }
            local gps; gps=$(sips -g all "$o" 2>/dev/null | grep -ci gps || true)
            [[ $gps -eq 0 ]] || { fail_v "GPS metadata still present"; return 1; }
            # Orientation must survive as pixels (or tag): displayed portrait 300x400.
            check_image "$o" 300 400 || return 1 ;;
        *.mp4|*.mp3)
            "$FFPROBE" -v error -show_entries format_tags -of default=nw=1 "$o" | grep -q KQSECRETTITLE \
                && { fail_v "title tag still present"; return 1; }
            NOTE="tags cleared" ;;
        *.pdf) pdf_pages "$o" >/dev/null || { fail_v "unreadable PDF"; return 1; }; NOTE="ok" ;;
    esac
}

v_crop_image() { need_outputs 1 1 || return 1; local w h; read -r w h _ <<<"$(image_info "${OUTS[0]}")"
    [[ ${w:-0} -gt 0 && $w -eq $h ]] || { fail_v "expected square (1:1 default), got ${w}x${h}"; return 1; }; NOTE="${w}x${h}"; }

v_frame_image() { need_outputs 1 1 || return 1; local w h sw sh
    read -r w h _ <<<"$(image_info "${OUTS[0]}")"; read -r sw sh _ <<<"$(image_info "${INPUTS[0]}")"
    [[ ${w:-0} -gt $sw && ${h:-0} -gt $sh ]] || { fail_v "frame not larger than source (${w}x${h} vs ${sw}x${sh})"; return 1; }
    NOTE="${sw}x${sh} → ${w}x${h}"; }

v_remove_background() {
    if [[ ${#OUTS[@]} -eq 0 ]]; then fail_v "no cut-out: $(echo "$MSGS" | head -1)"; return 1; fi
    local w h a; read -r w h a _ <<<"$(image_info "${OUTS[0]}")"
    [[ $a -eq 1 ]] || { fail_v "result has no alpha channel"; return 1; }
    NOTE="${w}x${h} with alpha"
}

v_blur_faces() {
    # Synthetic fixtures contain no real faces: "No faces found" is the correct answer.
    if [[ ${#OUTS[@]} -eq 0 ]]; then
        [[ "$MSGS" == *"No faces"* ]] || { fail_v "no output and no 'No faces' message"; return 1; }
        NOTE="no faces (expected for synthetic image)"; return 0
    fi
    check_image "${OUTS[0]}"
}

v_read_qr() {
    [[ "$MSGS" == *"$QR_TEXT"* ]] || { fail_v "decoded '$(echo "$MSGS" | head -1)', expected '$QR_TEXT'"; return 1; }
    NOTE="decoded OK"
}

v_recognize_text() {
    local all="$MSGS" f
    for f in "${OUTS[@]+"${OUTS[@]}"}"; do [[ -f "$f" ]] && all+=$(cat "$f"); done
    [[ "$all" == *"$OCR_WORD"* ]] || { fail_v "OCR text lacks '$OCR_WORD' (got: $(echo "$all" | head -c 80 | tr '\n' ' '))"; return 1; }
    NOTE="found $OCR_WORD"
}

v_collage() { need_outputs 1 1 || return 1; check_image "${OUTS[0]}"; }

v_pdf_pages() { # expects $EXPECT_PAGES
    need_outputs 1 1 || return 1
    local p; p=$(pdf_pages "${OUTS[0]}") || { fail_v "output isn't a PDF"; return 1; }
    [[ $p -eq $EXPECT_PAGES ]] || { fail_v "$p pages, expected $EXPECT_PAGES"; return 1; }
    NOTE="$p pages"
}

v_split_pdf() {
    need_outputs 3 3 || return 1
    local f p; for f in "${OUTS[@]}"; do p=$(pdf_pages "$f"); [[ $p -eq 1 ]] || { fail_v "$(basename "$f") has $p pages"; return 1; }; done
    NOTE="3 × 1 page"
}

v_mute() { need_outputs 1 1 || return 1; local o="${OUTS[0]}"
    [[ -n "$(probe_codecs "$o" v)" ]] || { fail_v "no video"; return 1; }
    [[ -z "$(probe_codecs "$o" a)" ]] || { fail_v "audio still present"; return 1; }
    NOTE="video only, $(probe_duration "$o")s"; }

v_speed() { need_outputs 1 1 || return 1; local d sd; d=$(probe_duration "${OUTS[0]}"); sd=$(probe_duration "${INPUTS[0]}")
    local want; want=$(awk -v s="$sd" 'BEGIN{print s/2}')
    float_near "$d" "$want" 0.3 || { fail_v "duration ${d}s, expected ≈${want}s at 2×"; return 1; }
    [[ -n "$(probe_codecs "${OUTS[0]}" a)" ]] || NOTE="audio dropped; "
    NOTE+="${sd}s → ${d}s"; }

v_crop_video() { need_outputs 1 1 || return 1; local w h
    w=$(probe_stream_value "${OUTS[0]}" v:0 width); h=$(probe_stream_value "${OUTS[0]}" v:0 height)
    [[ -n "$w" && "$w" == "$h" ]] || { fail_v "expected square, got ${w}x${h}"; return 1; }; NOTE="${w}x${h}"; }

v_join() { need_outputs 1 1 || return 1; local d; d=$(probe_duration "${OUTS[0]}")
    float_near "$d" 3 0.4 || { fail_v "duration ${d}s, expected ≈3s (2s+1s)"; return 1; }
    [[ -n "$(probe_codecs "${OUTS[0]}" a)" ]] || { fail_v "joined video lost audio"; return 1; }
    NOTE="${d}s"; }

v_snapshots() { # either 6 image paths, or one folder holding 6 images
    need_outputs 1 || return 1
    local files=() f
    if [[ ${#OUTS[@]} -eq 1 && -d "${OUTS[0]}" ]]; then
        while IFS= read -r f; do files+=("$f"); done < <(find "${OUTS[0]}" -type f ! -name '.*' | sort)
    else files=("${OUTS[@]}"); fi
    [[ ${#files[@]} -eq 6 ]] || { fail_v "expected 6 frames (default snapshotCount), got ${#files[@]}"; return 1; }
    for f in "${files[@]}"; do check_image "$f" || return 1; done
    NOTE="6 frames $NOTE"; }

v_split_video() { need_outputs 2 2 || return 1; local f d tot=0
    for f in "${OUTS[@]}"; do d=$(probe_duration "$f"); float_near "$d" 1 0.35 || { fail_v "$(basename "$f") is ${d}s, expected ≈1s"; return 1; }; done
    NOTE="2 × ≈1s"; }

v_normalize() { need_outputs 1 1 || return 1; local o="${OUTS[0]}"
    [[ -n "$(probe_codecs "$o" a)" ]] || { fail_v "no audio"; return 1; }
    local sd d; sd=$(probe_duration "${INPUTS[0]}"); d=$(probe_duration "$o")
    float_near "$d" "$sd" 0.3 || { fail_v "duration changed ${sd}s → ${d}s"; return 1; }
    local lufs; lufs=$("$FFMPEG" -nostdin -hide_banner -i "$o" -af ebur128 -f null - 2>&1 | awk '/I:/ {v=$2} END {print v}')
    NOTE="I=${lufs} LUFS"
    [[ -z "$lufs" ]] || float_near "$lufs" -16 2.5 || { fail_v "integrated loudness $lufs LUFS, expected ≈-16"; return 1; }; }

v_channels() { need_outputs 1 1 || return 1; local c; c=$(probe_stream_value "${OUTS[0]}" a:0 channels)
    [[ "$c" == 1 ]] || { fail_v "channels=$c, expected 1 (mono default)"; return 1; }; NOTE="mono"; }

v_trim_silence() { need_outputs 1 1 || return 1; local d sd; d=$(probe_duration "${OUTS[0]}"); sd=$(probe_duration "${INPUTS[0]}")
    float_lt "$d" 2.0 || { fail_v "duration ${d}s (source ${sd}s with 2s of silence)"; return 1; }
    float_lt 0.7 "$d" || { fail_v "duration ${d}s: tone was cut too"; return 1; }
    NOTE="${sd}s → ${d}s"; }

v_audio_to_video() { need_outputs 1 1 || return 1; local o="${OUTS[0]}"
    [[ -n "$(probe_codecs "$o" v)" && -n "$(probe_codecs "$o" a)" ]] || { fail_v "needs both video and audio"; return 1; }
    local d sd; d=$(probe_duration "$o"); sd=$(probe_duration "${INPUTS[0]}")
    float_near "$d" "$sd" 0.5 || { fail_v "duration ${d}s vs ${sd}s"; return 1; }
    NOTE="v=$(probe_codecs "$o" v) ${d}s"; }

v_extract() { need_outputs 1 1 || return 1; local o="${OUTS[0]}"
    [[ -d "$o" ]] || { fail_v "output isn't a folder"; return 1; }
    local hello; hello=$(find "$o" -name hello.txt | head -1)
    [[ -n "$hello" ]] && grep -q "hello from petalwheel" "$hello" || { fail_v "hello.txt missing or wrong"; return 1; }
    [[ -n "$(find "$o" -name 'привет.txt')" ]] || { fail_v "Cyrillic file name lost"; return 1; }
    NOTE="$(find "$o" -type f | wc -l | tr -d ' ') files"; }

v_create_archive() { need_outputs 1 1 || return 1; local l; l=$(unzip -l "${OUTS[0]}" 2>/dev/null) || { fail_v "not a zip"; return 1; }
    local f; for f in "${INPUTS[@]}"; do [[ "$l" == *"$(basename "$f")"* ]] || { fail_v "zip lacks $(basename "$f")"; return 1; }; done
    NOTE="$(echo "$l" | tail -1 | awk '{print $2}') entries"; }

v_trim() { need_outputs 1 || return 1; [[ -n "$(probe_codecs "${OUTS[0]}" v)$(probe_codecs "${OUTS[0]}" a)" ]] || { fail_v "unreadable"; return 1; }; }

run_tools() {
    local q=$QUICK
    tool() { # QUICKFLAG GROUP NAME EXPECT VALIDATOR TOOL INPUTS…
        local qf=$1; shift
        [[ $q -eq 1 && $qf != Q ]] && return 0
        run_case "$@"
    }
    tool - tool "compress jpg"             ok v_compress tool compress oriented.jpg
    tool - tool "compress png"             ok v_compress tool compress subject.png
    tool - tool "compress pdf"             ok v_compress tool compress multipage.pdf
    tool - tool "compress mp4"             ok v_compress tool compress clip.mp4
    tool - tool "compress wav"             ok v_compress tool compress padded.wav
    tool Q tool "removeMetadata jpg"       ok v_remove_metadata tool removeMetadata oriented.jpg
    tool - tool "removeMetadata mp4"       ok v_remove_metadata tool removeMetadata clip.mp4
    tool - tool "removeMetadata mp3"       ok v_remove_metadata tool removeMetadata tone.mp3
    tool - tool "removeMetadata pdf"       ok v_remove_metadata tool removeMetadata multipage.pdf
    tool - tool "cropImage"                ok v_crop_image tool cropImage subject.png
    tool - tool "cropImage oriented"       ok v_crop_image tool cropImage oriented.jpg
    tool - tool "frameImage"               ok v_frame_image tool frameImage alpha.png
    tool - tool "removeBackground"         ok v_remove_background tool removeBackground subject.png
    tool - tool "blurFaces"                ok v_blur_faces tool blurFaces subject.png
    tool Q tool "readQRCode"               ok v_read_qr tool readQRCode qr.png
    tool Q tool "recognizeText png"        ok v_recognize_text tool recognizeText text.png
    tool - tool "recognizeText scan.pdf"   ok v_recognize_text tool recognizeText scan.pdf
    tool - tool "createCollage"            ok v_collage tool createCollage subject.png alpha.png oriented.jpg
    EXPECT_PAGES=2
    tool - tool "createPDF"                ok v_pdf_pages tool createPDF subject.png oriented.jpg
    EXPECT_PAGES=4
    tool Q tool "mergePDF"                 ok v_pdf_pages tool mergePDF multipage.pdf single.pdf
    tool - tool "splitPDF"                 ok v_split_pdf tool splitPDF multipage.pdf
    tool - tool "trimMedia"                optional v_trim tool trimMedia clip.mp4
    tool Q tool "muteVideo"                ok v_mute tool muteVideo clip.mp4
    tool - tool "changeVideoSpeed"         ok v_speed tool changeVideoSpeed clip.mp4
    tool - tool "changeVideoSpeed silent"  ok v_speed tool changeVideoSpeed silent.mp4
    tool - tool "cropVideo"                ok v_crop_video tool cropVideo clip.mp4
    tool - tool "joinVideos"               ok v_join tool joinVideos clip.mp4 second.mp4
    tool - tool "videoSnapshots"           ok v_snapshots tool videoSnapshots clip.mp4
    tool - tool "splitVideo"               ok v_split_video tool splitVideo clip.mp4
    tool Q tool "normalizeAudio"           ok v_normalize tool normalizeAudio tone.mp3
    tool - tool "normalizeAudio video"     ok v_normalize tool normalizeAudio clip.mp4
    tool - tool "audioChannels"            ok v_channels tool audioChannels tone.flac
    tool - tool "trimSilence"              ok v_trim_silence tool trimSilence padded.wav
    tool - tool "audioToVideo"             ok v_audio_to_video tool audioToVideo tone.mp3
    tool Q tool "extractArchive zip"       ok v_extract tool extractArchive bundle.zip
    tool - tool "extractArchive tar"       ok v_extract tool extractArchive bundle.tar
    tool - tool "extractArchive tgz"       ok v_extract tool extractArchive bundle.tar.gz
    tool - tool "createArchive"            ok v_create_archive tool createArchive notes.md page.html subject.png
}

# --- CLI contract -------------------------------------------------------------------

run_cli_checks() {
    [[ -n "$FILTER" ]] && ! [[ "cli/" =~ $FILTER ]] && return 0
    local t0 t1 out code
    t0=$(now_ms); out=$("$BIN" --list 2>&1); code=$?; t1=$(now_ms)
    local fmts tools missing="" f
    fmts=$(echo "$out" | sed -n 's/^formats: *//p'); tools=$(echo "$out" | sed -n 's/^tools: *//p')
    for f in $fmts; do [[ -n "$(group_of "$f")" ]] || missing+="$f "; done
    if [[ $code -eq 0 && -n "$fmts" && -n "$tools" && -z "$missing" ]]; then
        record cli "--list" PASS $((t1 - t0)) "$(echo $fmts | wc -w | tr -d ' ') formats, $(echo $tools | wc -w | tr -d ' ') tools"
    else
        record cli "--list" FAIL $((t1 - t0)) "exit $code; formats unknown to the suite: ${missing:-none}"
    fi
    # Every tool --list reports must be covered here (or be a known interactive editor).
    local covered="compress removeMetadata cropImage frameImage removeBackground blurFaces readQRCode recognizeText createCollage createPDF mergePDF splitPDF trimMedia muteVideo changeVideoSpeed cropVideo joinVideos videoSnapshots splitVideo normalizeAudio audioChannels trimSilence audioToVideo extractArchive createArchive annotateImage adjustImage redactImage organizePDF redactVideo bleepAudio"
    missing=""; for f in $tools; do [[ " $covered " == *" $f "* ]] || missing+="$f "; done
    [[ -z "$missing" ]] && record cli "tool coverage" PASS 0 "" || record cli "tool coverage" FAIL 0 "tools without tests: $missing"

    mkdir -p "$RUNS/cli"; cp "$FIX/tone.mp3" "$RUNS/cli/"
    t0=$(now_ms); "$BIN" --convert png "$RUNS/cli/tone.mp3" >/dev/null 2>"$RUNS/cli/err"; code=$?; t1=$(now_ms)
    [[ $code -ne 0 && -s "$RUNS/cli/err" ]] && record cli "unsupported pair rejected" PASS $((t1 - t0)) "exit $code" \
        || record cli "unsupported pair rejected" FAIL $((t1 - t0)) "mp3 → png exit $code"
    t0=$(now_ms); "$BIN" --convert nope "$RUNS/cli/tone.mp3" >/dev/null 2>&1; code=$?; t1=$(now_ms)
    [[ $code -eq 2 ]] && record cli "unknown format -> exit 2" PASS $((t1 - t0)) "" \
        || record cli "unknown format -> exit 2" FAIL $((t1 - t0)) "exit $code"
    t0=$(now_ms); "$BIN" --tool annotateImage "$FIX/subject.png" >/dev/null 2>&1; code=$?; t1=$(now_ms)
    [[ $code -ne 0 ]] && record cli "interactive tool rejected" PASS $((t1 - t0)) "exit $code" \
        || record cli "interactive tool rejected" FAIL $((t1 - t0)) "annotateImage exited 0 headless"
}

# --- report -----------------------------------------------------------------------------

write_reports() {
    local md="$ROOT/build/test-report.md" xml="$ROOT/build/test-report.xml"
    mkdir -p "$ROOT/build"
    local total=${#R_NAME[@]} pass=0 fail=0 skip=0 i
    for ((i = 0; i < total; i++)); do
        case "${R_STATUS[$i]}" in PASS) pass=$((pass + 1)) ;; FAIL) fail=$((fail + 1)) ;; SKIP) skip=$((skip + 1)) ;; esac
    done
    local secs; secs=$(awk -v m=$(( $(now_ms) - SUITE_START )) 'BEGIN{printf "%.1f", m/1000}')
    {
        echo "# Petalwheel test report"
        echo
        echo "- Binary: \`$ORIG_BIN\`"
        echo "- ffmpeg: \`$FFMPEG\`"
        echo "- Mode: $([[ $QUICK -eq 1 ]] && echo quick || echo full)${FILTER:+, filter \`$FILTER\`}"
        echo "- Date: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "- **Total $total · Pass $pass · Fail $fail · Skip $skip · ${secs}s**"
        echo
        if [[ $fail -gt 0 ]]; then
            echo "## Failures"; echo
            for ((i = 0; i < total; i++)); do
                [[ ${R_STATUS[$i]} == FAIL ]] || continue
                echo "- **${R_GROUP[$i]} / ${R_NAME[$i]}**: ${R_DETAIL[$i]}"
                if [[ -n "${R_LOG[$i]}" && -s "${R_LOG[$i]}" ]]; then
                    echo '  ```'; tail -5 "${R_LOG[$i]}" | sed 's/^/  /'; echo '  ```'
                fi
            done
            echo
        fi
        echo "## All results"; echo
        echo "| Status | Group | Case | Time (s) | Details |"
        echo "|---|---|---|---:|---|"
        for ((i = 0; i < total; i++)); do
            printf '| %s | %s | %s | %s | %s |\n' "${R_STATUS[$i]}" "${R_GROUP[$i]}" "${R_NAME[$i]}" \
                "$(awk -v m="${R_MS[$i]}" 'BEGIN{printf "%.2f", m/1000}')" "$(echo "${R_DETAIL[$i]}" | sed 's/|/\\|/g')"
        done
    } > "$md"
    xml_escape() { sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g'; }
    {
        echo '<?xml version="1.0" encoding="UTF-8"?>'
        echo "<testsuite name=\"petalwheel\" tests=\"$total\" failures=\"$fail\" skipped=\"$skip\" time=\"$secs\">"
        for ((i = 0; i < total; i++)); do
            printf '  <testcase classname="%s" name="%s" time="%s">' "${R_GROUP[$i]}" \
                "$(printf '%s' "${R_NAME[$i]}" | xml_escape)" "$(awk -v m="${R_MS[$i]}" 'BEGIN{printf "%.3f", m/1000}')"
            case "${R_STATUS[$i]}" in
                FAIL) printf '<failure message="%s"/>' "$(printf '%s' "${R_DETAIL[$i]}" | xml_escape)" ;;
                SKIP) printf '<skipped message="%s"/>' "$(printf '%s' "${R_DETAIL[$i]}" | xml_escape)" ;;
            esac
            echo '</testcase>'
        done
        echo '</testsuite>'
    } > "$xml"

    echo
    echo "${C_B}Summary:${C_0} $total cases · ${C_G}$pass passed${C_0} · ${C_R}$fail failed${C_0} · ${C_Y}$skip skipped${C_0} · ${secs}s"
    if [[ $fail -gt 0 ]]; then
        echo "${C_R}Failures:${C_0}"
        for ((i = 0; i < total; i++)); do
            [[ ${R_STATUS[$i]} == FAIL ]] && echo "  ${R_GROUP[$i]} / ${R_NAME[$i]}: ${R_DETAIL[$i]}"
        done
    fi
    echo "Report: $md (+ $(basename "$xml"))"
    FAILED=$fail
}

# --- main -----------------------------------------------------------------------------------

echo "${C_B}Petalwheel test suite${C_0} — $([[ $QUICK -eq 1 ]] && echo quick || echo full) — $ORIG_BIN"
echo "Work dir: $WORK"
FIXTOOL="$WORK/fixtures-tool"
swiftc -O "$HERE/fixtures.swift" -o "$FIXTOOL" 2>"$WORK/swiftc.log" \
    || { echo "Failed to compile scripts/tests/fixtures.swift:" >&2; cat "$WORK/swiftc.log" >&2; exit 2; }

printf "%s%-4s  %-12s %-46s %8s  %s%s\n" "$C_B" "" "GROUP" "CASE" "TIME" "DETAILS" "$C_0"
KQ_FORMATS="$("$BIN" --list 2>/dev/null | sed -n 's/^formats: *//p')"
FIXTURES_OK=0
generate_fixtures
echo "${C_G}PASS${C_0}  fixture      $FIXTURES_OK fixtures generated in $FIX"
run_cli_checks
run_conversions
run_tools
FAILED=0
write_reports
[[ $FAILED -eq 0 ]]
