# shellcheck shell=bash
# Archive cases for scripts/test-suite.sh (sourced): every read and write format, CP866 / CP1251 names,
# password-protected zips, multi-volume archives, zip-slip, zip bombs and damaged archives.
# Fixtures come from gen_archive_formats in make-fixtures.sh (ZSTD_BIN, LZ4_BIN, ARCHIVE_PW are set there).

ARCHIVE_TOOLS="listArchive testArchive compressSingle"
ARCHIVE_TARGETS="zip 7z tar tgz tbz2 txz $([[ -n "$ZSTD_BIN" ]] && echo tzst) iso dmg"
# Conversion sources besides bundle.zip / .tar / .tar.gz (each converts to every target above).
ARCHIVE_CONVERSION_SOURCES="bundle.7z bundle.tar.bz2 bundle.tar.xz $([[ -n "$ZSTD_BIN" ]] && echo bundle.tar.zst)
bundle.iso bundle.dmg bundle.cpio bundle.pkg bundle.deb hello.txt.gz hello.txt.bz2 hello.txt.xz $([[ -n "$ZSTD_BIN" ]] && echo hello.txt.zst)"
ARCHIVE_PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

# archive_listing FILE FORMAT → one entry path per line (disk images are mounted read-only).
archive_listing() {
    local f=$1 fmt=$2
    if [[ $fmt == dmg ]]; then
        local mnt; mnt=$(mktemp -d "$WORK/mnt.XXXXXX")
        hdiutil attach -nobrowse -readonly -noautoopen -mountpoint "$mnt" "$f" >/dev/null 2>&1 || return 1
        (cd "$mnt" && find . -name '.*' ! -name '.' -prune -o -print | sed -e 's|^\./||' -e '/^\.$/d')
        hdiutil detach "$mnt" -force >/dev/null 2>&1
        return 0
    fi
    LC_ALL=en_US.UTF-8 PATH="$ARCHIVE_PATH" /usr/bin/bsdtar -tf "$f" 2>/dev/null
}

# The container type `file` reports for each written format.
archive_magic() {
    case "$1" in
        zip) echo "Zip archive" ;; 7z) echo "7-zip archive" ;; tar) echo "tar archive" ;; tgz) echo "gzip compressed" ;;
        tbz2) echo "bzip2 compressed" ;; txz) echo "XZ compressed" ;; tzst) echo "Zstandard compressed" ;;
        iso) echo "ISO 9660" ;; *) echo "" ;;
    esac
}

check_archive_type() { # FILE FORMAT
    if [[ $2 == dmg ]]; then
        hdiutil imageinfo "$1" 2>/dev/null | grep -q "Format: UDZO" || { fail_v "not a UDZO disk image"; return 1; }
        return 0
    fi
    local want; want=$(archive_magic "$2")
    [[ -z "$want" ]] || file -b "$1" | grep -q "$want" || { fail_v "not $want: $(file -b "$1" | cut -c1-60)"; return 1; }
}

# Conversion output check (called by v_convert for archive targets).
check_archive() {
    local f=$1 list
    check_archive_type "$f" "$TARGET" || return 1
    list=$(archive_listing "$f" "$TARGET") || { fail_v "can't list the $TARGET output"; return 1; }
    case "$SRC_FMT" in
        gz|bz2|xz|zst) [[ "$list" == *hello.txt* ]] || { fail_v "archive lacks hello.txt"; return 1; } ;;
        deb) [[ "$list" == *debian-binary* && "$list" == *data.tar.xz* ]] || { fail_v "archive lacks the .deb members"; return 1; } ;;
        rar) [[ $(echo "$list" | grep -c .) -ge 1 ]] || { fail_v "archive is empty"; return 1; } ;;
        *)
            [[ "$list" == *bundle/hello.txt* ]] || { fail_v "archive lacks bundle/hello.txt"; return 1; }
            [[ "$list" == *inner/* ]] || { fail_v "archive lacks nested dir"; return 1; }
            [[ "$list" == *привет.txt* ]] || { fail_v "Cyrillic name lost"; return 1; } ;;
    esac
    NOTE="$(echo "$list" | grep -c .) entries"
}

# --- validators -------------------------------------------------------------------------

v_should_fail() { fail_v "succeeded, but this archive must be refused"; }

v_extract_single() { need_outputs 1 1 || return 1; local o="${OUTS[0]}"
    [[ -f "$o" && $(basename "$o") == hello.txt* ]] || { fail_v "expected hello.txt, got $(basename "$o")"; return 1; }
    grep -q "hello from petalwheel" "$o" || { fail_v "content differs"; return 1; }
    NOTE="$(basename "$o")"; }

v_extract_deb() { need_outputs 1 1 || return 1; local o="${OUTS[0]}"
    [[ -f "$o/debian-binary" && -f "$o/control.tar.gz" && -f "$o/data.tar.xz" ]] || { fail_v "deb members missing"; return 1; }
    NOTE="3 members"; }

v_extract_cyr() { need_outputs 1 1 || return 1; local o="${OUTS[0]}"
    [[ -f "$o/Документы/отчёт.txt" || -n "$(find "$o" -name 'отч*т.txt')" ]] || { fail_v "names not decoded: $(ls "$o" | head -3 | tr '\n' ' ')"; return 1; }
    grep -q "Привет из Windows" "$(find "$o" -name 'отч*т.txt' | head -1)" || { fail_v "content differs"; return 1; }
    [[ -f "$o/Фото.txt" ]] || { fail_v "Фото.txt missing"; return 1; }
    NOTE="Документы/отчёт.txt"; }

v_extract_volumes() { v_extract || return 1; local n
    n=$(find "${OUTS[0]}" -name noise.bin -size 150000c | head -1)
    [[ -n "$n" ]] || { fail_v "noise.bin (spans the volumes) missing or truncated"; return 1; }
    NOTE="$NOTE, all volumes joined"; }

v_extract_any() { need_outputs 1 1 || return 1; local o="${OUTS[0]}" n
    n=$(find "$o" -type f | wc -l | tr -d ' ')
    [[ $n -ge 1 ]] || { fail_v "nothing extracted"; return 1; }
    NOTE="$n files"; }

v_list() { local out="$CASE_DIR/.stdout"
    grep -q "hello.txt" "$out" && grep -q "привет.txt" "$out" || { fail_v "listing lacks the entries"; return 1; }
    NOTE="$(grep -c . "$out") lines"; }

v_list_cyr() { grep -q "Документы/отчёт.txt" "$CASE_DIR/.stdout" || grep -q "отче" "$CASE_DIR/.stdout" \
    || { fail_v "CP866 names not decoded in the listing"; return 1; }; NOTE="decoded"; }

v_list_any() { [[ $(grep -c . "$CASE_DIR/.stdout") -ge 3 ]] || { fail_v "empty listing"; return 1; }; NOTE="$(grep -c . "$CASE_DIR/.stdout") lines"; }

v_test_ok() { [[ "$MSGS" == *"is OK"* ]] || { fail_v "no OK message: $MSGS"; return 1; }; NOTE="$(echo "$MSGS" | head -1 | cut -c1-60)"; }

v_create_format() { need_outputs 1 1 || return 1; local o="${OUTS[0]}" list
    [[ "$o" == *."$CREATE_EXT" ]] || { fail_v "expected .$CREATE_EXT, got $(basename "$o")"; return 1; }
    check_archive_type "$o" "$CREATE_FMT" || return 1
    list=$(archive_listing "$o" "$CREATE_FMT") || { fail_v "can't list"; return 1; }
    [[ "$list" == *bundle/hello.txt* && "$list" == *привет.txt* ]] || { fail_v "entries missing: $(echo "$list" | head -3 | tr '\n' ' ')"; return 1; }
    NOTE="$(echo "$list" | grep -c .) entries"; }

v_create_encrypted() { need_outputs 1 1 || return 1; local o="${OUTS[0]}" d out
    python3 -I -c 'import sys, zipfile
fs = [i for i in zipfile.ZipFile(sys.argv[1]).infolist() if not i.is_dir()]
sys.exit(0 if fs and all(i.flag_bits & 1 and i.compress_type == 99 for i in fs) else 1)' "$o" \
        || { fail_v "entries aren't AES-encrypted"; return 1; }
    d="$CASE_DIR/roundtrip"; mkdir -p "$d"; cp "$o" "$d/"
    "$KQ_REAL_BIN" --tool extractArchive "$d/$(basename "$o")" >/dev/null 2>&1 && { fail_v "extracted without a password"; return 1; }
    out=$("$KQ_REAL_BIN" --tool extractArchive --password "$ARCHIVE_PW" "$d/$(basename "$o")" 2>/dev/null | head -1)
    [[ -d "$out" ]] && cmp -s "$out/notes.md" "$FIX/notes.md" && cmp -s "$out/page.html" "$FIX/page.html" \
        || { fail_v "password round trip failed"; return 1; }
    NOTE="AES-256, round trip OK"; }

v_compress_single() { need_outputs 1 1 || return 1; local o="${OUTS[0]}" in="${INPUTS[0]}"
    [[ $(basename "$o") == "$(basename "$in").$CS_EXT" ]] || { fail_v "expected $(basename "$in").$CS_EXT, got $(basename "$o")"; return 1; }
    case $CS_EXT in
        gz) gzip -dc "$o" ;;
        bz2) bzip2 -dc "$o" ;;
        xz) python3 -I -c 'import lzma, sys; sys.stdout.buffer.write(lzma.open(sys.argv[1]).read())' "$o" ;;
        zst) "$ZSTD_BIN" -dc "$o" ;;
    esac | cmp -s - "$in" || { fail_v "decompressed file differs"; return 1; }
    NOTE="$(stat -f %z "$o") bytes"; }

# --- runners ------------------------------------------------------------------------------

# Runs one case with extra CLI flags (--password, --archive-format) inserted after the tool name.
with_flags() { # "FLAGS" run_case-arguments…
    local flags=$1; shift
    local wrapper="$WORK/kq-archive-flags"
    if [[ ! -x "$wrapper" ]]; then
        printf '%s\n' '#!/bin/bash' 'mode=$1; arg=$2; shift 2' '# shellcheck disable=SC2086' \
            'exec "$KQ_REAL_BIN" "$mode" "$arg" $KQ_FLAGS "$@"' > "$wrapper"
        chmod +x "$wrapper"
    fi
    local saved=$BIN
    export KQ_REAL_BIN=$saved KQ_FLAGS=$flags
    BIN=$wrapper
    run_case "$@"
    BIN=$saved
    unset KQ_FLAGS
}

# A case that must end with a clean error mentioning PATTERN, with nothing written outside the case folder.
refuse_case() { # NAME PATTERN "FLAGS" MODE ARG INPUT…
    local name=$1 pattern=$2 flags=$3; shift 3
    if [[ -n "$FILTER" ]] && ! [[ "archive/$name" =~ $FILTER ]]; then return 0; fi
    with_flags "$flags" archive "$name" graceful v_should_fail "$@"
    if ! grep -qi -- "$pattern" "$CASE_DIR/.stderr" 2>/dev/null; then
        record archive "$name: message" FAIL 0 "stderr lacks '$pattern': $(head -c 160 "$CASE_DIR/.stderr" 2>/dev/null)"
    fi
    if [[ -e "$CASE_DIR/evil.txt" || -e "$RUNS/evil.txt" || -e /tmp/petalwheel-abs-evil.txt ]]; then
        record archive "$name: containment" FAIL 0 "a file was written outside the extraction folder"
    fi
}

archive_skip() { # NAME REASON
    [[ -z "$FILTER" || "archive/$1" =~ $FILTER ]] && record archive "$1" SKIP 0 "$2"
}

run_archive_tests() {
    local q=$QUICK fx fmt
    a() { # QUICKFLAG run_case-arguments…  (group "archive")
        local qf=$1; shift
        [[ $q -eq 1 && $qf != Q ]] && return 0
        run_case archive "$@"
    }
    af() { # QUICKFLAG "FLAGS" run_case-arguments…
        local qf=$1 flags=$2; shift 2
        [[ $q -eq 1 && $qf != Q ]] && return 0
        with_flags "$flags" archive "$@"
    }

    # Extract every read format.
    for fx in bundle.7z bundle.tar.bz2 bundle.tar.xz bundle.tar.lzma bundle.tar.lz bundle.iso bundle.cpio bundle.pkg bundle.dmg; do
        a - "extract ${fx#bundle.}" ok v_extract tool extractArchive "$fx"
    done
    if [[ -n "$ZSTD_BIN" ]]; then a Q "extract tar.zst" ok v_extract tool extractArchive bundle.tar.zst
    else archive_skip "extract tar.zst" "zstd isn't installed (brew install zstd): macOS libarchive has no zstd"; fi
    if [[ -n "$LZ4_BIN" ]]; then a - "extract tar.lz4" ok v_extract tool extractArchive bundle.tar.lz4
    else archive_skip "extract tar.lz4" "lz4 isn't installed (brew install lz4)"; fi
    a - "extract deb" ok v_extract_deb tool extractArchive bundle.deb
    for fx in hello.txt.gz hello.txt.bz2 hello.txt.xz; do a - "extract ${fx#hello.txt.} (single file)" ok v_extract_single tool extractArchive "$fx"; done
    [[ -n "$ZSTD_BIN" ]] && a - "extract zst (single file)" ok v_extract_single tool extractArchive hello.txt.zst
    archive_skip "extract cab, lzh" "no fixture: nothing on macOS creates CAB / LHA (read through libarchive)"

    # Windows code pages.
    a Q "extract CP866 names" ok v_extract_cyr tool extractArchive cp866.zip
    a - "extract CP1251 names" ok v_extract_cyr tool extractArchive cp1251.zip
    a - "list CP866 names" ok v_list_cyr tool listArchive cp866.zip

    # Passwords.
    af Q "--password $ARCHIVE_PW" "extract AES-256 zip" ok v_extract tool extractArchive enc-aes.zip
    af - "--password $ARCHIVE_PW" "extract ZipCrypto zip" ok v_extract tool extractArchive enc-zipcrypto.zip
    refuse_case "encrypted zip, no password" "password-protected" "" tool extractArchive enc-aes.zip
    refuse_case "encrypted zip, wrong password" "wrong" "--password nope" tool extractArchive enc-aes.zip
    af - "--archive-format zip --password $ARCHIVE_PW" "createArchive zip + password" ok v_create_encrypted \
        tool createArchive notes.md page.html

    # Multi-volume (all volumes dropped together: extracted once).
    a - "extract split zip (z01+z02+zip)" ok v_extract_volumes tool extractArchive split.zip split.z01 split.z02
    a - "extract 7z volumes (.001-.003)" ok v_extract_volumes tool extractArchive volumes.7z.001 volumes.7z.002 volumes.7z.003
    archive_skip "extract multi-volume rar" "no fixture: RAR volumes can't be created (license-restricted)"

    # Safety.
    refuse_case "zip-slip tar.xz (../)" "unsafe path" "" tool extractArchive evil.tar.xz
    refuse_case "zip-slip 7z (../)" "unsafe path" "" tool extractArchive evil.7z
    refuse_case "absolute path zip" "unsafe path" "" tool extractArchive evil-abs.zip
    refuse_case "zip bomb" "zip bomb" "" tool extractArchive bomb.zip
    refuse_case "convert zip-slip tar.xz" "unsafe path" "" convert zip evil.tar.xz

    # List and test.
    a Q "listArchive zip" ok v_list tool listArchive bundle.zip
    a - "listArchive 7z" ok v_list tool listArchive bundle.7z
    a - "listArchive dmg" ok v_list tool listArchive bundle.dmg
    for fx in bundle.zip bundle.7z bundle.tar.xz bundle.iso bundle.dmg hello.txt.xz; do
        a - "testArchive $fx" ok v_test_ok tool testArchive "$fx"
    done
    a Q "testArchive tar.gz" ok v_test_ok tool testArchive bundle.tar.gz
    af - "--password $ARCHIVE_PW" "testArchive AES-256 zip" ok v_test_ok tool testArchive enc-aes.zip
    refuse_case "testArchive damaged zip" "damaged" "" tool testArchive damaged.zip

    # Create every write format.
    for fmt in $ARCHIVE_TARGETS; do
        CREATE_FMT=$fmt
        case $fmt in tgz) CREATE_EXT=tar.gz ;; tbz2) CREATE_EXT=tar.bz2 ;; txz) CREATE_EXT=tar.xz ;; tzst) CREATE_EXT=tar.zst ;; *) CREATE_EXT=$fmt ;; esac
        local qf=-; [[ $fmt == 7z ]] && qf=Q
        af $qf "--archive-format $fmt" "createArchive $fmt" ok v_create_format tool createArchive bundle
    done
    archive_skip "createArchive rar" "never offered: creating RAR is license-restricted"

    # Compress one file.
    for CS_EXT in gz bz2 xz $([[ -n "$ZSTD_BIN" ]] && echo zst); do
        local qf=-; [[ $CS_EXT == gz ]] && qf=Q
        af $qf "--archive-format $CS_EXT" "compressSingle $CS_EXT" ok v_compress_single tool compressSingle notes.md
    done

    # RAR: read-only, from a sample found on this Mac.
    if [[ -f "$FIX/sample.rar" ]]; then
        a Q "extract rar (sample)" ok v_extract_any tool extractArchive sample.rar
        a - "listArchive rar (sample)" ok v_list_any tool listArchive sample.rar
        a - "testArchive rar (sample)" ok v_test_ok tool testArchive sample.rar
        SRC_FMT=rar; TARGET=zip
        a - "convert rar -> zip (sample)" ok v_convert convert zip sample.rar
        SRC_FMT=rar; TARGET=7z
        a - "convert rar -> 7z (sample)" ok v_convert convert 7z sample.rar
    else
        archive_skip "rar (extract, list, test, convert)" "no small .rar on this Mac; RAR fixtures can't be created (license-restricted)"
    fi
}
