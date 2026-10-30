# Personal customization

This fork is the starting point for a personal macOS file conversion app based on Petalwheel (formerly Kumquat).

## Current state

- Upstream: https://github.com/TheAlexRay/petalwheel
- Baseline: db043016e6609460004fa503ab103028bcac6e39 (1.2.0).
- The unmodified baseline compiles successfully with Swift on Apple Silicon.
- Added explicit fast and quality-first SDR video compression modes.
- Upstream copyright, MIT license and third-party notices must be retained.

## Development

Use `nur/custom` for personal changes. Keep `main` available for upstream updates.

Build the development executable with `swift build`.
Package a local app using `./scripts/build-app.sh --no-tools`; this variant uses locally installed media tools, so it is not a standalone distribution.

## Next step

Review the two compression modes on sample media before selecting further custom features.

## Video compression modes

For a video, choose Optimize > Compress, then one of the two Kazakh-labelled modes:

- **Тез сығу** (`fast`): Apple VideoToolbox HEVC, constant quality 73, hardware required.
- **Сапаға басымдық** (`quality`): software libx265 HEVC, CRF 20, slow preset. Requires an FFmpeg build with libx265; the upstream bundled LGPL build does not include it.

Both keep source dimensions and frame cadence, copy all audio tracks without re-encoding, preserve ordinary metadata/chapters, and write a separate file. MP4 is used for compatible audio; other audio codecs use MKV. A result that is not smaller is discarded. Neither mode is lossless. This first version accepts 8-bit SDR YUV420 video only; HDR, 10-bit, alpha and other pixel formats are rejected rather than silently converted. Subtitle/data tracks are not included.

Legacy presets without a mode retain the previous compression behaviour. New mode selections are retained in presets and history. Image/audio compression controls are unchanged.

CLI:

```sh
Petalwheel --tool compress --video-mode fast input.mov
Petalwheel --tool compress --video-mode quality input.mov
```

Integration check (small generated fixtures; does not upload media):

```sh
python3 scripts/tests/video-compression-modes.py .build/debug/Petalwheel
```
