# CoovaStudioVendor

[中文](README.zh-CN.md)

Third-party dependencies of Coova Studio (酷丸工具箱), built here from source with pinned
versions and published as releases. The app repository only downloads what is published
here; nothing depends on what a user has installed.

Only ffmpeg so far. Any future dependency follows the same pattern.

## ffmpeg

`ffmpeg/build.sh` builds statically linked `ffmpeg` and `ffprobe` for macOS on Apple silicon
from upstream sources.

- Every version, source URL and SHA-256 is pinned at the top of the script; upgrading means
  changing only that block.
- All third-party libraries are linked statically. The binaries depend only on libraries and
  frameworks that ship with macOS, and the script verifies that with `otool -L`.
- Runs on macOS 12 and newer.
- GPL build (x264 and x265 included), with no nonfree components (no fdk-aac).

The first version includes x264, x265 (8-bit), libvpx, dav1d, opus, libogg + libvorbis and lame;
SVT-AV1 (AV1 encoding) joined in `ffmpeg-9.0.1-2`.
Hardware encoding and decoding use the system's VideoToolbox; AAC uses ffmpeg's built-in encoder.

### Building locally

```sh
brew install cmake meson ninja pkgconf   # build tools only, nothing is needed at runtime
ffmpeg/build.sh
```

Output lands in `dist/ffmpeg/`:

- `ffmpeg-<version>-macos-arm64.tar.gz` with `ffmpeg`, `ffprobe` and the license text
- `SHA256SUMS`
- `BUILD-INFO.txt`: the version of every library and ffmpeg's configure line
- `sources/`: every source archive that went into the build (the GPL asks for it to travel
  with the binaries)

Intermediate files live in `work/`. Neither `work/` nor `dist/` is tracked by git.

### Releases from CI

GitHub Actions (`.github/workflows/ffmpeg.yml`) runs the same script on `macos-latest`
(Apple silicon). Pushing a tag such as `ffmpeg-9.0.1` builds and publishes a release with the
archive, the checksums and the sources; a manual run only builds.

The app repository's `scripts/fetch-ffmpeg.sh` points at a release here and pins its SHA-256.

### Upgrading ffmpeg or a library

1. Change the version and hash at the top of `ffmpeg/build.sh`.
2. Build locally, or push a tag and let CI build.
3. Update the release tag and hash in the app repository's `scripts/fetch-ffmpeg.sh`; every
   developer re-runs that script and gets the same binaries.
