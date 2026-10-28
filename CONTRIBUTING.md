# Contributing to Petalwheel

Thanks for helping! Bug reports, format requests and pull requests are all welcome.

## Reporting bugs

Open an issue with the bug report template. Include your macOS version, the Petalwheel version
(Settings › About), the file format involved and, if possible, a small sample file.
Security problems: see [SECURITY.md](SECURITY.md) instead of opening a public issue.

## Development setup

```bash
brew install ffmpeg webp          # quick development without the bundled toolchain
swift build && .build/debug/Petalwheel
```

For a full app bundle with the embedded LGPL toolchain, see the Build section of the README.

## Before opening a pull request

1. Keep the change focused; one feature or fix per PR.
2. Run the checks:
   ```bash
   ./scripts/test-suite.sh --binary .build/debug/Petalwheel --quick
   python3 scripts/check-l10n.py
   ```
3. New user-facing strings go through `L()` / `Lp()` and need English and Russian entries in
   `Resources/{en,ru}.lproj/Localizable.strings`.
4. SwiftUI: the project builds with Command Line Tools only, so macro-based property wrappers
   such as `@State` and `@Observable` don't compile. Use `ObservableObject` with `@StateObject`
   or `@ObservedObject`.

By contributing you agree that your contributions are licensed under the MIT License.
