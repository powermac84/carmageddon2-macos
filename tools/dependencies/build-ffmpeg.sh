#!/bin/bash
# Unmodified FFmpeg source; LGPL-2.1-or-later configuration, no external codecs.
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/common.sh"
fetch_source ffmpeg-9.0.2.tar.xz https://ffmpeg.org/releases/ffmpeg-9.0.2.tar.xz 8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e
if [ ! -d "$DEP_WORK/sources/ffmpeg-9.0.2" ]; then
    tar -xf "$DEP_WORK/downloads/ffmpeg-9.0.2.tar.xz" -C "$DEP_WORK/sources"
fi
cd "$DEP_WORK/sources/ffmpeg-9.0.2"
# /usr/local is a neutral embedded data prefix; this script does not install there.
./configure --prefix=/usr/local --arch=aarch64 --target-os=darwin --cc=clang \
    --extra-cflags=-mmacosx-version-min=14.0 --extra-ldflags=-mmacosx-version-min=14.0 \
    --disable-everything --disable-autodetect --disable-doc --disable-debug \
    --disable-network --disable-shared --enable-static --enable-pthreads \
    --enable-ffmpeg --disable-ffplay --disable-ffprobe \
    --enable-decoder=smacker,smackaud --enable-demuxer=smacker \
    --enable-encoder=h264_videotoolbox,aac --enable-muxer=mp4 --enable-protocol=file \
    --enable-filter=scale,format,aresample,anull,null --enable-swscale \
    --enable-swresample --enable-videotoolbox --enable-parser=h264,aac \
    --enable-bsf=extract_extradata
make -j"$DEP_JOBS"
cp ffmpeg "$DEP_WORK/bin/ffmpeg"
verify_helper "$DEP_WORK/bin/ffmpeg"
printf '%s\n' "Built $DEP_WORK/bin/ffmpeg. Nothing was installed system-wide."
