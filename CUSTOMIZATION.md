# NurTo development state

Personal fork of Petalwheel/Kumquat. Work on `nur/custom`; retain upstream copyright and licenses.

## Current product direction

The Ctrl-triggered radial wheel is the primary interface. No dashboard, full-screen visual overlay, lengthy explanatory UI or automatic comparison result window.
English labels, a white translucent glass wheel, an unchanged desktop backdrop, thin sector divisions and a blue selection border. The wheel is about 13% wider than the upstream wheel for the same five symbol items.
Contextual actions: Compress, Convert, Level Audio, Trim/Edit, More. All original tools remain under More.
Navigation is deliberate: Hold Ctrl for 2.5 seconds with a dragged file or Finder selection to open the wheel. The wheel closes when Ctrl is released, without auto-selecting anything. Releasing only the mouse after the initial drag does not select a function. Hover only highlights; deliberate clicks open a category/function, and center-click goes back one level. There are no hover navigation timers. A deterministic gate test covers the exact 2.5-second threshold, one open per hold, early release and close-on-release.

## Implemented

- NurTo bundle/display/process name and `app.nurto.mac` identity, generated N icon.
- One-time copy of old preferences/support data; one-time migration to Ctrl and English.
- Fix for video-only settings leaking into photo/audio/GIF/mixed selections.
- Two video modes: hardware HEVC q73; libx265 CRF20 slow.
- Compact optional preview panel, a frame selector, optional Compare, one draggable before/after split view, stepwise 1–4× zoom, drag-to-pan and click-scale-to-reset. There is no hover panning, automatic zoom or playback-mode switching in the UI.
- Preview shares encoding arguments with full export; cancellation and invalidation clean up temporary media.
- Level Audio: compressor + dynamic normalizer + measured two-pass loudness normalization. One click, separate output, copy video when present.
- Legacy presets, image/audio size compression and remaining tools retained.

## Validation

Regression checks: media-state isolation, target-size controls, legacy/new preset roundtrips, 4–5 root actions and nonrecursive More navigation.
Generated media tests: both video modes, playable previews, PCM stream-copy integrity, unchanged originals and safe 10-bit refusal.
Audio test: 24-second recording with three levels. Center-section spread reduced from 28.8 dB to 3.7 dB; no clipping, unchanged source and duration.
A mouse-release regression check verifies that only a subsequent real click selects an action.
A render of the actual FanView is available via `--render-wheel <png>` for design QA.

## Developer commands

```sh
swift build
.build/debug/Petalwheel --self-check
python3 scripts/tests/video-compression-modes.py .build/debug/Petalwheel
python3 scripts/tests/audio-leveling.py .build/debug/Petalwheel
./scripts/build-app.sh --no-tools
```

`--compress-window <video>` opens the preview panel for local UI QA.
`--preview fast|quality <video>` writes a short temporary preview; the CLI caller cleans up its directory.
The internal SwiftPM executable remains Petalwheel. The installed executable is NurTo.

## Scope limits

Local Homebrew FFmpeg required by this build; the upstream LGPL bundle does not include libx265.
Video compression accepts 8-bit SDR YUV420 only, copies audio and omits subtitle/data tracks.
No lossless promise or broad codec/HDR guarantee. Level control can raise background noise; it is not speech isolation.
