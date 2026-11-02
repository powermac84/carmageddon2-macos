# Bundled open-source helpers

End users do not need Homebrew, Python, Node.js, developer tools, or Wine to run
these two helpers. They are arm64 binaries targeting macOS14; their only dynamic
dependencies are standard Apple/system libraries.

| Helper | Version | Purpose | License |
| --- | --- | --- | --- |
| innoextract | 1.9 | Extract a user's Inno Setup/GOG installer without executing its scripts. | zlib |
| Boost libraries inside innoextract | 1.85.0 | Filesystem, options and compressed streams. | Boost Software License1.0 |
| liblzma inside innoextract | XZ5.8.4 | LZMA decompression. | 0BSD |
| FFmpeg | 9.0.2 | Convert user-supplied Smacker movies for the native player. | LGPL-2.1-or-later |

The FFmpeg configuration disables network protocols and automatic external-library
detection. It enables the Smacker demuxer/video/audio decoders, Apple's H.264
VideoToolbox encoder, built-in AAC, MP4, and the required conversion filters.
It does not enable GPL, nonfree, libx264, or other external codecs. This is a
special-purpose converter, not a full-featured FFmpeg installation.

All license texts are in [`licenses`](licenses/). Exact source URLs and archive
SHA-256 checksums are in [`sources.json`](sources.json). Release packaging must
include the helper licenses and make the exact FFmpeg corresponding-source
archive available alongside the binary downloads. The FFmpeg source is unmodified;
the complete build configuration is in `build-ffmpeg.sh`. The two documented
innoextract changes only adapt its build to CMake4 and Boost's explicit headers.

## Rebuild

Building from source requires Xcode command-line tools, CMake, Ninja, Python3,
make, and curl. These are developer prerequisites, not player requirements.

```bash
C2_DEP_WORK="$PWD/build/dependencies" JOBS=8 bash tools/dependencies/build-ffmpeg.sh
C2_DEP_WORK="$PWD/build/dependencies" JOBS=8 bash tools/dependencies/build-innoextract.sh
```

Downloads are pinned and checksum-checked. For an offline build, put the exact
source archives in `$C2_DEP_WORK/downloads` and set `C2_OFFLINE=1`.
Outputs are `$C2_DEP_WORK/bin/ffmpeg` and `$C2_DEP_WORK/bin/innoextract`.
The scripts write only to that working directory; `/usr/local` is an embedded
neutral FFmpeg data prefix and is never installed into by these scripts.

For an offline FFmpeg-only rebuild from the provided source release asset, copy
its `ffmpeg-9.0.2.tar.xz` into the downloads directory and run `build-ffmpeg.sh`.
No Boost or XZ download is needed for that converter build. Source code for the
other permissively licensed helpers is available from the pinned upstream URLs.

## Validated invocation

```bash
innoextract --extract --exclude-temp --silent --output-dir extracted setup_carmageddon2_2.1.0.28.exe
ffmpeg -nostdin -hide_banner -loglevel error -y -i mix_intr.smk \
  -c:v h264_videotoolbox -allow_sw 1 -b:v 2000k -pix_fmt yuv420p \
  -c:a aac -ar 44100 -b:a 128k -movflags +faststart mix_intr.mp4
```

The native application runs outside the development command sandbox. That sandbox
blocks VideoToolbox encode/decode services; developer tests requiring those services
must run under normal macOS process permissions. No extra permission prompt or
access change is required by the distributed converter itself.

The GOG extraction reproduced the tested engine executable exactly. Both complete
original movies converted successfully and were playable with AVFoundation, with
one video and one audio track and an actual decoded frame. The helper audit also
checks arm64 architecture, system-only linkage, and absence of personal build paths.
