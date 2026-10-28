# Folder cases for scripts/test-suite.sh (sourced): converting and processing the contents of folders.
#
# Fixture "Album" (built from the regular fixtures):
#   cover.png  Trip/{day 1.heic, day 2.jpg, day 10.tiff, clip.mp4}  Trip/Notes/{readme.txt, text.png, doc.pdf}
#   Extra/day 2.jpg (name collision for Flatten)  Viewer.app/… (package: opaque, never entered)
#   .hidden.jpg  .cache/thumb.jpg (hidden: skipped)  outside.jpg → fixture, elsewhere → fixtures dir (symlinks: skipped)
# Expected: 6 raster images, 1 video, 1 PDF, 1 text file, 1 package = 10 items.

FOLDER_TOOLS="flattenFolder folderReport"
ALBUM_IMAGES=6

gen_folder_fixtures() {
    local a="$FIX/Album"
    rm -rf "$a"; mkdir -p "$a/Trip/Notes" "$a/Extra" "$a/.cache" "$a/Viewer.app/Contents/Resources"
    cp "$FIX/alpha.png" "$a/cover.png"
    cp "$FIX/photo.heic" "$a/Trip/day 1.heic"
    cp "$FIX/oriented.jpg" "$a/Trip/day 2.jpg"
    cp "$FIX/photo.tiff" "$a/Trip/day 10.tiff"
    cp "$FIX/clip.mp4" "$a/Trip/clip.mp4"
    cp "$FIX/cp1251.txt" "$a/Trip/Notes/readme.txt"
    cp "$FIX/text.png" "$a/Trip/Notes/text.png"
    cp "$FIX/multipage.pdf" "$a/Trip/Notes/doc.pdf"
    cp "$FIX/oriented.jpg" "$a/Extra/day 2.jpg"
    cp "$FIX/oriented.jpg" "$a/.hidden.jpg"
    cp "$FIX/oriented.jpg" "$a/.cache/thumb.jpg"
    cp "$FIX/subject.png" "$a/Viewer.app/Contents/Resources/icon.png"
    printf '<?xml version="1.0"?><plist version="1.0"><dict/></plist>\n' > "$a/Viewer.app/Contents/Info.plist"
    ln -s "$FIX/oriented.jpg" "$a/outside.jpg"
    ln -s "$FIX" "$a/elsewhere"
    [[ -f "$a/Trip/clip.mp4" && -f "$a/Trip/Notes/text.png" && -L "$a/elsewhere" ]] && fixture_ok Album || fixture_fail Album "copy failed"
}

# Files (not folders) under DIR, excluding packages' insides: one relative path per line.
folder_files() { (cd "$1" && find . -path '*.app' -prune -o -type f -print | sed 's|^\./||' | sort); }

# Common checks for a mirrored output folder: no hidden files, no work folders, nothing from links or packages.
check_mirror_clean() { # DIR
    local bad
    bad=$(cd "$1" && find . -name '.*' ! -name '.' | head -3)
    [[ -z "$bad" ]] || { fail_v "hidden or work files in output: $bad"; return 1; }
    [[ ! -e "$1/outside.jpg" && ! -e "$1/elsewhere" ]] || { fail_v "followed a symbolic link"; return 1; }
    [[ -z "$(find "$1" -name 'icon.*' -o -name '*.app')" ]] || { fail_v "entered or copied a package"; return 1; }
}

expect_files() { # DIR "rel1|rel2|…" — exactly these files
    local want got
    want=$(echo "$2" | tr '|' '\n' | sort)
    got=$(folder_files "$1")
    [[ "$got" == "$want" ]] || { fail_v "files: [$(echo "$got" | tr '\n' ',')] expected [$(echo "$want" | tr '\n' ',')]"; return 1; }
}

v_folder_convert_jpg() {
    need_outputs 1 1 || return 1
    local o="${OUTS[0]}"
    [[ -d "$o" && "$(basename "$o")" == "Album (converted)" ]] || { fail_v "expected folder 'Album (converted)', got $o"; return 1; }
    check_mirror_clean "$o" || return 1
    expect_files "$o" "cover.jpg|Trip/day 1.jpg|Trip/day 2.jpg|Trip/day 10.jpg|Trip/Notes/text.jpg|Extra/day 2.jpg" || return 1
    local f; while IFS= read -r f; do
        [[ "$(sips -g format "$o/$f" 2>/dev/null | awk '/format/ {print $2}')" == jpeg ]] || { fail_v "$f isn't a JPEG"; return 1; }
    done < <(folder_files "$o")
    NOTE="6 JPGs, structure mirrored, hidden/links/package skipped"
}

v_folder_convert_mov() {
    need_outputs 1 1 || return 1
    expect_files "${OUTS[0]}" "Trip/clip.mov" || return 1
    [[ -n "$(probe_codecs "${OUTS[0]}/Trip/clip.mov" v)" ]] || { fail_v "clip.mov has no video"; return 1; }
    NOTE="Video → MOV: 1 file"
}

v_folder_convert_mixed() { # Album + loose notes.md → Documents → PDF
    need_outputs 2 2 || return 1
    local dir="" pdf="" o
    for o in "${OUTS[@]}"; do [[ -d "$o" ]] && dir=$o || pdf=$o; done
    [[ -n "$dir" && "$(basename "$pdf")" == notes.pdf ]] || { fail_v "expected a folder and notes.pdf, got ${OUTS[*]}"; return 1; }
    expect_files "$dir" "Trip/Notes/readme.pdf|Trip/Notes/doc.pdf" || return 1
    pdf_pages "$dir/Trip/Notes/readme.pdf" >/dev/null || { fail_v "readme.pdf unreadable"; return 1; }
    pdf_pages "$pdf" >/dev/null || { fail_v "notes.pdf unreadable"; return 1; }
    NOTE="folder mirrored + loose file converted in place"
}

v_folder_compress() {
    need_outputs 1 1 || return 1
    local o="${OUTS[0]}"
    [[ "$(basename "$o")" == "Album (compressed)" ]] || { fail_v "unexpected output $o"; return 1; }
    check_mirror_clean "$o" || return 1
    # Names keep the source's base name; the extension may change (e.g. HEIC re-encoded).
    local base; base=$(folder_files "$o" | sed 's/\.[^.]*$//' | sort | tr '\n' '|')
    [[ "$base" == "Extra/day 2|Trip/Notes/doc|Trip/Notes/text|Trip/clip|Trip/day 1|Trip/day 10|Trip/day 2|cover|" ]] \
        || { fail_v "files: $base"; return 1; }
    local n; n=$(folder_files "$o" | wc -l | tr -d ' ')
    [[ $n -eq 8 ]] || { fail_v "expected 8 files (6 images, video, PDF), got $n"; return 1; }
    [[ -z "$(folder_files "$o" | grep -i 'readme')" ]] || { fail_v "text file copied"; return 1; }
    NOTE="8 files mirrored"
}

v_folder_clean() {
    need_outputs 1 1 || return 1
    local o="${OUTS[0]}"
    [[ "$(basename "$o")" == "Album (clean)" ]] || { fail_v "unexpected output $o"; return 1; }
    check_mirror_clean "$o" || return 1
    local n; n=$(folder_files "$o" | wc -l | tr -d ' ')
    [[ $n -eq 8 ]] || { fail_v "expected 8 files, got $n: $(folder_files "$o" | tr '\n' ',')"; return 1; }
    [[ -f "$o/Trip/day 2.jpg" ]] || { fail_v "Trip/day 2.jpg missing"; return 1; }
    ! grep -qa "PetalwheelTestCam" "$o/Trip/day 2.jpg" || { fail_v "EXIF Make still present"; return 1; }
    "$FFPROBE" -v error -show_entries format_tags -of default=nw=1 "$o/Trip/clip.mp4" | grep -q KQSECRETTITLE \
        && { fail_v "video title tag still present"; return 1; }
    NOTE="8 files, metadata stripped"
}

v_folder_pdf() {
    need_outputs 1 1 || return 1
    [[ "$(basename "${OUTS[0]}")" == "Album.pdf" ]] || { fail_v "expected Album.pdf, got ${OUTS[0]}"; return 1; }
    local p; p=$(pdf_pages "${OUTS[0]}") || { fail_v "not a PDF"; return 1; }
    [[ $p -eq $ALBUM_IMAGES ]] || { fail_v "$p pages, expected $ALBUM_IMAGES"; return 1; }
    NOTE="$p pages"
}

v_folder_collage() {
    need_outputs 1 1 || return 1
    [[ "$(basename "${OUTS[0]}")" == "Album (collage).png" ]] || { fail_v "unexpected output ${OUTS[0]}"; return 1; }
    check_image "${OUTS[0]}" || return 1
    [[ -z "$(find "$CASE_DIR" -name '.petalwheel-work*')" ]] || { fail_v "work folder left behind"; return 1; }
    [[ -z "$(find "$CASE_DIR/Album" -name 'Collage*')" ]] || { fail_v "wrote into the source folder"; return 1; }
}

v_folder_ocr() {
    need_outputs 1 1 || return 1
    local o="${OUTS[0]}"
    [[ "$(basename "$o")" == "Album (text).txt" ]] || { fail_v "unexpected output $o"; return 1; }
    grep -q "$OCR_WORD" "$o" || { fail_v "no '$OCR_WORD' in the combined text"; return 1; }
    grep -q '=== Trip/Notes/doc.pdf ===' "$o" || { fail_v "PDF section missing"; return 1; }
    grep -q 'hidden\|thumb' "$o" && { fail_v "hidden file was read"; return 1; }
    [[ -z "$(find "$CASE_DIR/Album" -name '*.txt' ! -name readme.txt)" ]] || { fail_v "wrote .txt files into the source folder"; return 1; }
    NOTE="$(grep -c '^=== ' "$o") sections"
}

v_folder_flatten() {
    need_outputs 1 1 || return 1
    local o="${OUTS[0]}"
    [[ "$(basename "$o")" == "Album (flat)" ]] || { fail_v "unexpected output $o"; return 1; }
    local items; items=$(cd "$o" && ls -A | sort | tr '\n' '|')
    local want="clip.mp4|cover.png|day 1.heic|day 10.tiff|day 2 2.jpg|day 2.jpg|doc.pdf|readme.txt|text.png|Viewer.app|"
    [[ "$(echo "$items" | tr '|' '\n' | sort -f | tr '\n' '|')" == "$(echo "$want" | tr '|' '\n' | sort -f | tr '\n' '|')" ]] \
        || { fail_v "items [$items] expected [$want]"; return 1; }
    [[ -f "$o/Viewer.app/Contents/Resources/icon.png" ]] || { fail_v "package not copied whole"; return 1; }
    [[ -z "$(find "$o" -mindepth 1 -maxdepth 1 -type d ! -name '*.app')" ]] || { fail_v "subfolders left"; return 1; }
    NOTE="10 items, collision renamed"
}

v_folder_report() {
    need_outputs 0 0 || return 1
    local m="$MSGS"
    [[ "$m" == *"10 files"* ]] || { fail_v "report lacks '10 files': $(echo "$m" | head -3 | tr '\n' ' ')"; return 1; }
    [[ "$m" == *"Images: 6 files"* ]] || { fail_v "report lacks 'Images: 6 files'"; return 1; }
    [[ "$m" == *"Largest files"* && "$m" == *"Trip/"* ]] || { fail_v "no largest files"; return 1; }
    [[ "$m" == *"2 hidden items skipped"* ]] || { fail_v "hidden count wrong"; return 1; }
    [[ "$m" == *"2 symbolic links skipped"* ]] || { fail_v "symlink count wrong"; return 1; }
    [[ "$m" == *"1 package"*" counted"* ]] || { fail_v "package count wrong"; return 1; }
    NOTE="$(echo "$m" | sed -n 2p)"
}

run_folder_tests() {
    gen_folder_fixtures
    run_case folder "convert jpg Album"          ok v_folder_convert_jpg   convert jpg Album
    [[ $QUICK -eq 1 ]] && return 0
    run_case folder "convert mov Album"          ok v_folder_convert_mov   convert mov Album
    run_case folder "convert pdf Album+notes.md" ok v_folder_convert_mixed convert pdf Album notes.md
    run_case folder "compress Album"             ok v_folder_compress      tool compress Album
    run_case folder "removeMetadata Album"       ok v_folder_clean         tool removeMetadata Album
    run_case folder "createPDF Album"            ok v_folder_pdf           tool createPDF Album
    run_case folder "createCollage Album"        ok v_folder_collage       tool createCollage Album
    run_case folder "recognizeText Album"        ok v_folder_ocr           tool recognizeText Album
    run_case folder "flattenFolder Album"        ok v_folder_flatten       tool flattenFolder Album
    run_case folder "folderReport Album"         ok v_folder_report        tool folderReport Album

    # Safety cap: more than 10,000 files is refused with a clear message.
    [[ -z "$FILTER" || "folder/cap" =~ $FILTER ]] || return 0
    local big="$RUNS/folder-big/Big" t0 t1 code
    mkdir -p "$big"
    (cd "$big" && seq 1 10001 | sed 's/$/.txt/' | xargs touch)
    t0=$(now_ms); "$BIN" --tool folderReport "$big" >/dev/null 2>"$RUNS/folder-big/err"; code=$?; t1=$(now_ms)
    if [[ $code -ne 0 ]] && grep -q "more than 10.*000 files" "$RUNS/folder-big/err"; then
        record folder "cap 10,000 files" PASS $((t1 - t0)) "refused: $(head -c 80 "$RUNS/folder-big/err")"
    else
        record folder "cap 10,000 files" FAIL $((t1 - t0)) "exit $code: $(head -c 120 "$RUNS/folder-big/err")"
    fi
}
