#!/bin/bash
# Static Boost/liblzma; standard Apple zlib, bzip2, iconv and C++ runtime.
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/common.sh"
fetch_source innoextract-1.9.tar.gz https://codeload.github.com/dscharrer/innoextract/tar.gz/refs/tags/1.9 576657932e92835343a829c3be1baefc34593d1f84309df93eb1d39a8bb51510
fetch_source boost_1_85_0.tar.bz2 https://archives.boost.io/release/1.85.0/source/boost_1_85_0.tar.bz2 7009fe1faa1697476bdc7027703a2badb84e849b7b0baad5086b087b971f8617
fetch_source xz-5.8.4.tar.xz https://github.com/tukaani-project/xz/releases/download/v5.8.4/xz-5.8.4.tar.xz 4ce24038fd4221e0d13bc1a2de7a4db56e90b92b3bf75321f6c14be73f65de4b
for entry in 'innoextract-1.9:innoextract-1.9.tar.gz' 'boost_1_85_0:boost_1_85_0.tar.bz2' 'xz-5.8.4:xz-5.8.4.tar.xz'; do
    if [ ! -d "$DEP_WORK/sources/${entry%%:*}" ]; then
        tar -xf "$DEP_WORK/downloads/${entry#*:}" -C "$DEP_WORK/sources"
    fi
done
DEP_SDK="$(xcrun --sdk macosx --show-sdk-path)"
(
    cd "$DEP_WORK/sources/boost_1_85_0"
    ./bootstrap.sh --with-libraries=filesystem,iostreams,date_time,system,program_options --prefix="$DEP_WORK/boost-install"
    ./b2 -j"$DEP_JOBS" cxxstd=17 variant=release link=static threading=multi architecture=arm address-model=64 \
        cxxflags=-mmacosx-version-min=14.0 linkflags=-mmacosx-version-min=14.0 \
        -sZLIB_INCLUDE="$DEP_SDK/usr/include" -sBZIP2_INCLUDE="$DEP_SDK/usr/include" install
)
cmake -S "$DEP_WORK/sources/xz-5.8.4" -B "$DEP_WORK/xz-build" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 -DCMAKE_INSTALL_PREFIX="$DEP_WORK/xz-install" \
    -DBUILD_SHARED_LIBS=OFF -DXZ_TOOL_XZ=OFF -DXZ_TOOL_XZDEC=OFF \
    -DXZ_TOOL_LZMADEC=OFF -DXZ_TOOL_LZMAINFO=OFF -DBUILD_TESTING=OFF
cmake --build "$DEP_WORK/xz-build" -j"$DEP_JOBS"
cmake --install "$DEP_WORK/xz-build"
# Two build-compatibility changes only: CMake4 minimum policy and the explicit
# Boost filesystem directory-iterator header. No extraction behavior is changed.
python3 - "$DEP_WORK/sources/innoextract-1.9" <<'PY'
from pathlib import Path
import sys
root = Path(sys.argv[1])
p = root / 'cmake/VersionScript.cmake'
s = p.read_text()
old = 'cmake_minimum_required(VERSION 2.8)'
new = 'cmake_minimum_required(VERSION 3.5)'
if old in s:
    p.write_text(s.replace(old, new))
elif new not in s:
    raise SystemExit('Unexpected innoextract CMake source')
p = root / 'src/stream/slice.cpp'
s = p.read_text()
needle = '#include <boost/filesystem/operations.hpp>'
if '#include <boost/filesystem/directory.hpp>' not in s:
    if needle not in s:
        raise SystemExit('Unexpected innoextract filesystem source')
    p.write_text(s.replace(needle, needle + '\n#include <boost/filesystem/directory.hpp>'))
PY
cmake -S "$DEP_WORK/sources/innoextract-1.9" -B "$DEP_WORK/inno-build" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    -DBOOST_ROOT="$DEP_WORK/boost-install" -DBoost_NO_SYSTEM_PATHS=ON \
    -DBoost_NO_BOOST_CMAKE=ON -DBoost_USE_STATIC_LIBS=ON -DLZMA_USE_STATIC_LIBS=ON \
    -DLZMA_INCLUDE_DIR="$DEP_WORK/xz-install/include" \
    -DLZMA_LIBRARY="$DEP_WORK/xz-install/lib/liblzma.a" \
    -DCMAKE_PREFIX_PATH="$DEP_WORK/boost-install;$DEP_WORK/xz-install" -DUSE_LTO=OFF
cmake --build "$DEP_WORK/inno-build" -j"$DEP_JOBS"
cp "$DEP_WORK/inno-build/innoextract" "$DEP_WORK/bin/innoextract"
verify_helper "$DEP_WORK/bin/innoextract"
printf '%s\n' "Built $DEP_WORK/bin/innoextract. Nothing was installed system-wide."
