# NurTo

Offline file tools at your cursor. Select a file (or drag it), hold **Ctrl for 2.5 seconds**, then click to choose while holding Ctrl.

A personal fork of [Petalwheel](https://github.com/TheAlexRay/petalwheel) (formerly Kumquat).

## The wheel

A larger white translucent wheel over your unchanged desktop, short English labels and 4–5 contextual actions:

- **Convert** — choose an output format.
- **Compress** — reduce image, audio or video file size.
- **Level Audio** — reduce loud/quiet differences within a recording; also works on a video's audio.
- **Trim / Edit** — the relevant editor for the file.
- **More** — the remaining tools and presets.

No dashboard or automatic result window. The wheel is the main interface.
Hover only highlights. Keep Ctrl held while choosing a category or function.
Release Ctrl to close the wheel without selecting anything. Click the center to go back one level.

## Video compression

**Fast** uses hardware HEVC. **Quality** uses software HEVC.
Choose a frame and click **Compare**. Drag the Before/After divider to compare the same detail.
Use **+ / −** to zoom, drag the image to pan, and click the scale value to reset.
Nothing moves or zooms merely because the pointer passes over it. Comparison is optional; **Compress** works directly.
Detail inspection uses full-resolution decoded still frames.
A short test encode is used internally to produce the comparison frame; it is not a full-file quality guarantee.

The original is kept; output is saved beside it. Audio tracks are copied without re-encoding.
Output is MP4 or MKV according to audio compatibility. Neither mode is lossless.
Currently accepts 8-bit SDR YUV420 video; unsupported HDR/10-bit inputs are rejected safely.

## Audio leveling

**Level Audio** is a one-step action, distinct from file-size compression and whole-file normalization.
It applies compression, dynamic normalization and measured loudness normalization (-16 LUFS, -1.5 dBTP target).
For videos, the video stream is copied. A separate `leveled` file is created.
Louder background noise can also become more audible; this is level control, not noise removal.

## Build

Apple Silicon, macOS 14+, Xcode Command Line Tools and Homebrew:

```sh
brew install ffmpeg webp
swift build
./scripts/build-app.sh --no-tools
open build/NurTo.app
```

This development build uses local Homebrew helpers. Quality mode needs FFmpeg with libx265.
The internal SwiftPM executable is still `Petalwheel`; the app bundle and process are **NurTo**.
The icon is generated from `scripts/make-icon.swift`.

## Checks

```sh
.build/debug/Petalwheel --self-check
python3 scripts/tests/video-compression-modes.py .build/debug/Petalwheel
python3 scripts/tests/audio-leveling.py .build/debug/Petalwheel
python3 scripts/check-l10n.py
```

## License

[MIT](LICENSE). Original source © 2026 kipperstudio. Upstream attribution and
[third-party notices](THIRD_PARTY_NOTICES.md) are retained.
Older upstream documentation/screenshots may show the original interface.
