# Testing Petalwheel

`scripts/test-suite.sh` is an end-to-end suite that drives the headless CLI
(`Petalwheel --convert …`, `--tool …`, `--list`). It checks the files the app produces, not just
its exit codes.

```bash
./scripts/build-app.sh               # or: swift build
./scripts/test-suite.sh              # full run (~300 cases, a few minutes)
./scripts/test-suite.sh --quick      # one representative per group (~30 s)
./scripts/test-suite.sh --binary .build/debug/Petalwheel
./scripts/test-suite.sh --filter 'tool/|clip.mp4' --keep   # subset, keep the outputs for inspection
```

| Option | Meaning |
|---|---|
| `--binary PATH` | executable to test. Default: `build/Petalwheel.app/Contents/MacOS/Petalwheel`, else `.build/debug/Petalwheel` |
| `--quick` | 8 conversions and 7 tools, one per format group, plus the CLI contract checks |
| `--keep` | keep the temp work dir (`fixtures/` plus one `runs/NNN/` dir per case, with `.stdout` and `.stderr`) |
| `--filter REGEX` | run only cases whose `group/name` matches, e.g. `convert/tone`, `tool/split` |
| `--timeout SECS` | per-case timeout (default 300) |

The suite prints a coloured PASS/FAIL/SKIP table with timings and writes `build/test-report.md`
and a JUnit file, `build/test-report.xml`. It exits 1 if any case fails and 2 on a setup error.
When the binary is inside an `.app`, the suite uses the embedded ffmpeg and ffprobe from
`Contents/Resources/Tools`. Otherwise it uses the Homebrew ones.

## Files

| File | Role |
|---|---|
| `scripts/test-suite.sh` | runner, conversion matrix, validators, report |
| `scripts/tests/make-fixtures.sh` | deterministic fixture generation |
| `scripts/tests/fixtures.swift` | helper compiled with `swiftc` per run. It makes the EXIF, alpha, QR (CoreImage), text-image, vector-PDF and image-only-PDF fixtures. It also reads page counts and text (PDFKit) and the displayed size and alpha of images (ImageIO) |
| `scripts/tests/make-pptx.py` | minimal, deterministic OOXML presentation (Quick Look renders it) |
| `scripts/tests/lib.sh` | timing, timeout, ffprobe and text helpers |

## Fixtures

Fixtures are generated into a temp dir. They use fixed content, `-fflags +bitexact` for
ffmpeg, fixed mtimes in archives and `gzip -n`.

- **Images:** `oriented.jpg` (stored 400×300 with EXIF orientation 6, so it displays 300×400; it
  also has Make and GPS tags), `alpha.png`, `subject.png`, `qr.png`, `text.png` ("PETALWHEEL TEST
  2024"), plus heic, tiff, bmp, avif (via `sips`), webp (via `cwebp`) and a hand-written svg.
- **PDFs:** `multipage.pdf` (3 pages, each with a vector text line in Cyrillic), `single.pdf`, and
  `scan.pdf` (an image only, no text layer).
- **Media (ffmpeg lavfi, 2 s, 320×240):** mp4 (h264+aac, with a title tag), mov, mkv (h264+opus),
  webm (vp9+opus), avi, wmv, `silent.mp4` (no audio), `second.mp4` (1 s, used for join),
  `anim.gif`. Audio: `padded.wav` (1 s silence, 1 s tone, 1 s silence), and mp3, flac, m4a,
  ogg, opus, aiff and wma versions of a 2 s tone.
- **Documents:** `notes.md` and `page.html` with Cyrillic text. docx, rtf, odt and rtfd made from
  the html with `textutil`. `cp1251.txt` encoded as Windows-1251. `letter.doc` (textutil).
  `deck.pptx` (2 slides, written by `scripts/tests/make-pptx.py`). `book.epub`, which the app
  itself creates from `notes.md`.
- **Tables and others:** `table.csv` (RFC 4180 quotes, a comma inside a field, a newline inside a
  field, Cyrillic), `table.tsv`, and `sheet.xlsx`, which the app itself creates from the csv.
  Also srt and vtt, and zip, tar and tar.gz archives containing a nested Cyrillic file name.

## What is covered

- **CLI contract:** `--list` returns only formats the suite knows, and every listed tool is
  covered. An unsupported pair is rejected with an error. An unknown format exits with 2. An
  interactive editor (`annotateImage`) is rejected when run headless.
- **Conversions:** every source fixture × every target from
  `Sources/Petalwheel/Model/ConversionCatalog.swift`. The matrix is mirrored in `targets_for()`.
  Keep the two in sync: if the catalog gains a format, `--list` coverage fails until the suite
  learns it.
- Formats the binary doesn't list in `--list` are skipped (so the suite works against older builds).
  `.xls`, `.key`, `.pages`, `.numbers` sources are reported as SKIP: they can't be authored
  deterministically without Excel / iWork.
- **Tools:** every non-interactive tool on suitable fixtures. `trimMedia` is interactive in the
  UI; if the CLI rejects it, the case is reported as SKIP.

### Validation rules

| Output | Check |
|---|---|
| raster image | ImageIO displayed size equals the source's (so orientation must be applied: the oriented jpg must come out 300×400). Alpha is kept for png, tiff, webp, heic and avif targets. Raw size comes from `sips -g pixelWidth -g pixelHeight` |
| PDF → images | one image per page |
| PDF | page count via PDFKit (`mdls` is useless in temp dirs that Spotlight doesn't index). The text layer contains "Привет" |
| video | ffprobe: expected codec for the container, an audio stream when the source has one, duration within ±0.5 s (±0.7 s for gif) |
| audio | ffprobe: expected codec, no video stream (cover art is ignored), duration within ±0.5 s |
| txt / md / html / docx / odt / rtf / rtfd | container structure (`unzip -l`, `{\rtf`, `TXT.rtf`) and text containing "Привет" (via `textutil -convert txt`) |
| xlsx / csv / tsv / html table | `unzip -l` lists workbook and worksheets. Cyrillic cell text. Quoting, comma and newline in fields survive the round trip |
| srt / vtt / txt subtitles | timings in the target syntax, Cyrillic cue text, no timings left in txt |
| zip / tar / tgz | lists `bundle/hello.txt` and the nested folder. `gzip -t` |
| tools | tool-specific: QR text decoded exactly, OCR finds "PETALWHEEL", crop gives a square result (1:1 default), mono gives 1 channel, 2× speed gives half the duration, split gives 2 × 1 s, join gives 3 s, normalize gives ≈ −16 LUFS, metadata stripping removes EXIF Make/GPS and the media title tags, and so on |

**Graceful cases.** Some pairs can't produce anything meaningful: `silent.mp4` to an audio
format, and the image-only `scan.pdf` to a text format. For these, a clean error (non-zero exit
plus a message) counts as PASS. A crash or timeout is always a FAIL.

**blurFaces.** The fixtures contain no real faces, so the expected result is the message
"No faces found".
