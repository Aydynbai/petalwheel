# Releasing Petalwheel

`scripts/release.sh` builds the app, packages it into `build/Petalwheel-<version>.dmg` and, when
credentials are available, signs it with a Developer ID and notarizes it.

```bash
./scripts/release.sh                 # build + DMG (ad-hoc unless the env vars below are set)
./scripts/release.sh --skip-build    # package the existing build/Petalwheel.app
./scripts/release.sh --no-verify     # skip mounting the DMG to check it
```

The version comes from `CFBundleShortVersionString` in the built `Info.plist` (set by
`VERSION=` in `scripts/build-app.sh`).

## What the script does

1. Runs `scripts/build-app.sh` (release build, ffmpeg/ffprobe/cwebp and their dylibs embedded in
   `Contents/Resources/Tools`, ad-hoc signature). Build `build/ffmpeg-lgpl` first with
   `scripts/build-ffmpeg.sh` so the from-source macOS 14 toolchain is embedded (see
   [Licensing note](#licensing-note)).
2. Picks the signing mode:
   - **Developer ID**: when both `DEVELOPER_ID` and `NOTARY_PROFILE` are set. It re-signs every
     Mach-O from the inside out: the dylibs in `Tools/lib`, then the `ffmpeg`, `ffprobe` and `cwebp`
     executables, then the app. Every signature uses `--options runtime --timestamp`. The
     executables and the app get `scripts/Petalwheel.entitlements`, which contains only
     `com.apple.security.cs.disable-library-validation`. No JIT entitlements are needed. The
     script then checks that every nested Mach-O carries the hardened-runtime flag.
   - **Ad-hoc**: otherwise. The script keeps the ad-hoc signature from `build-app.sh` and prints
     which variables are missing.
3. Stages `Petalwheel.app` (copied with `ditto`) plus an `Applications` symlink and the app icon as
   the volume icon. It then runs `hdiutil create -volname Petalwheel -format UDZO` and
   `hdiutil verify`.
4. In Developer ID mode it signs the DMG and runs
   `xcrun notarytool submit --wait --keychain-profile "$NOTARY_PROFILE"`. If the upload is
   rejected, it prints the notary log. Otherwise it runs `xcrun stapler staple`,
   `stapler validate` and `spctl --assess`. The JSON result is saved to
   `build/notarytool-<version>.json`.
5. Verification: mounts the DMG with `hdiutil attach -nobrowse -readonly` and checks the
   `Applications` symlink. It runs `codesign --verify --deep --strict` on the app inside the DMG,
   runs `Petalwheel --list` from the mounted image, and in Developer ID mode also runs
   `spctl --assess`. Then it detaches the image and prints the SHA-256 of the DMG.

## Getting a Developer ID certificate

1. Join the [Apple Developer Program](https://developer.apple.com/programs/) (paid, individual or
   organization). Only the Account Holder can create Developer ID certificates.
2. Create a certificate signing request: open Keychain Access, then choose
   **Certificate Assistant → Request a Certificate From a Certificate Authority…** and save it to disk.
3. In [Certificates, IDs & Profiles](https://developer.apple.com/account/resources/certificates/list),
   click **+** and choose **Developer ID Application**. Upload the CSR, then download the
   certificate and double-click it to install it into the login keychain.
4. Check it and copy the exact identity name:
   ```bash
   security find-identity -v -p codesigning
   #  1) ABCDEF… "Developer ID Application: Jane Doe (TEAMID1234)"
   ```

Xcode is not required: the certificate and `codesign` work with Command Line Tools alone.

## Creating the notary profile

`xcrun notarytool` ships with Xcode 13+ and Command Line Tools 13+. On this machine it is
available from Command Line Tools: `/Library/Developer/CommandLineTools/usr/bin/notarytool`
version 1.1.3, and `stapler` is there too. Older setups that only have `altool` can't notarize
any more, because Apple retired altool notarization in Nov 2023.

1. Create an app-specific password at [appleid.apple.com](https://appleid.apple.com) under
   **Sign-In and Security → App-Specific Passwords**. As an alternative, use an App Store Connect
   API key (`--key`, `--key-id`, `--issuer`).
2. Store the credentials in the keychain under a profile name:
   ```bash
   xcrun notarytool store-credentials petalwheel-notary \
       --apple-id you@example.com --team-id TEAMID1234
   # prompts for the app-specific password; it is stored in the keychain, not on disk
   ```
3. Check it: `xcrun notarytool history --keychain-profile petalwheel-notary`.

## Running a signed, notarized release

```bash
export DEVELOPER_ID="Developer ID Application: Jane Doe (TEAMID1234)"
export NOTARY_PROFILE="petalwheel-notary"
./scripts/release.sh
```

Notarization usually takes 1–5 minutes. Common rejections:

- *"The executable does not have the hardened runtime enabled"*: a Mach-O was added to the bundle
  after signing. Rebuild, or rerun the script, which signs every file under `Resources/Tools`.
- *"The signature does not include a secure timestamp"*: there was no network access to Apple's
  timestamp server during `codesign --timestamp`.
- *"The binary is not signed with a valid Developer ID certificate"*: you used an "Apple
  Development" or "Mac App Distribution" identity instead of "Developer ID Application".

## Licensing note

Release builds embed the LGPL toolchain built from source (`scripts/build-ffmpeg.sh`, which runs
`scripts/build-deps.sh`): ffmpeg 9.0.2 without `--enable-gpl`/nonfree, plus lame, opus, libvpx,
dav1d, SVT-AV1, libwebp (cwebp), libpng, libjpeg-turbo and xz, each downloaded from its official
release URL, pinned and SHA-256 verified, and compiled for arm64 with
`MACOSX_DEPLOYMENT_TARGET=14.0` into `build/deps`. Homebrew supplies only the build tools
(`brew install pkgconf meson ninja cmake`). The codec libraries are linked statically. FFmpeg's
`libav*` libraries and the LGPL `libmp3lame` stay as dylibs in `Tools/lib`, so users can replace
them. `bundle-tools.py` fails the build if any embedded Mach-O has `minos` above 14.0, which matches
`LSMinimumSystemVersion`. Ship `Tools/licenses/` (one directory per project) and offer the
corresponding source: the pinned tarballs in `build/deps-src` and `build/ffmpeg-src`.
If you build with `--homebrew-ffmpeg` instead, the embedded ffmpeg is GPL (x264/x265) and its
Homebrew dylibs require the macOS version they were built for, so `bundle-tools.py` rejects them
on a newer build host. That mode is for local use only.
