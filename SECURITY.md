# Security Policy

## Supported versions

| Version | Supported |
|---|---|
| 1.0.x (latest: 1.0.1) | Yes |

## Reporting a vulnerability

Please **do not** open a public issue for security problems.

Report them privately through GitHub: open the repository's **Security** tab and choose
**Report a vulnerability** (private vulnerability reporting). Include the Kumquat version,
your macOS version, steps to reproduce and, if possible, a sample file.

You can expect an acknowledgement within 7 days. Confirmed issues are fixed in a patch
release and credited in the release notes unless you prefer to stay anonymous.

## Scope

Kumquat processes files locally and makes no network requests of its own. Areas that are
in scope include:

- crafted input files (images, media, documents, archives) that crash the app, escape the
  output folder or overwrite unrelated files;
- archive extraction (path traversal, symlinks pointing outside the destination);
- the bundled ffmpeg, ffprobe and cwebp builds and how Kumquat invokes them;
- Finder Services, the global hotkey and watch folders.

Vulnerabilities in third-party components (FFmpeg, libwebp and others) should also be
reported upstream; we will update the bundled versions once fixes are released.
