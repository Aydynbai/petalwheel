# Personal customization

This fork is the starting point for a personal macOS file conversion app based on Petalwheel (formerly Kumquat).

## Current state

- Upstream: https://github.com/TheAlexRay/petalwheel
- Baseline: db043016e6609460004fa503ab103028bcac6e39 (1.2.0).
- The unmodified baseline compiles successfully with Swift on Apple Silicon.
- Custom features have not been selected or implemented yet.
- Upstream copyright, MIT license and third-party notices must be retained.

## Development

Use `nur/custom` for personal changes. Keep `main` available for upstream updates.

Build the development executable with `swift build`.
Package a local app using `./scripts/build-app.sh --no-tools`; this variant uses locally installed media tools, so it is not a standalone distribution.

## Next step

Choose the first custom feature, implement it, and verify it on disposable sample files before using it with original media.
