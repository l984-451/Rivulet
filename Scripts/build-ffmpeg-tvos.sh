#!/bin/bash
#
# Build FFmpeg for tvOS (arm64 only)
# Produces static libraries + headers for Rivulet's remux pipeline.
#
# Includes: demuxers (MKV, MP4, HLS), muxers (fMP4), parsers,
#           decoders (DTS/TrueHD for audio transcode, subtitles),
#           encoders (EAC3 for audio transcode), and swresample.
#
# Usage: ./build-ffmpeg-tvos.sh [ffmpeg-source-dir]
#
# Prerequisites:
#   - Xcode with tvOS SDK installed
#   - FFmpeg source (git clone https://git.ffmpeg.org/ffmpeg.git && git checkout n7.1)
#   - pkg-config (brew install pkg-config)
#
# Output: ./ffmpeg-tvos-build/lib/*.a and ./ffmpeg-tvos-build/include/*

set -euo pipefail

# Resolve script and project paths up front. The build later cds into the
# FFmpeg source dir, so anything relying on $0 or $(pwd) past that point would
# break — capture the absolute paths now.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
FW_DIR="$PROJECT_DIR/Frameworks"

FFMPEG_SRC="${1:-$(pwd)/ffmpeg}"
BUILD_DIR="$(pwd)/ffmpeg-tvos-build"
TVOS_MIN="18.0"
ARCH="arm64"

if [ ! -d "$FFMPEG_SRC" ]; then
    echo "Error: FFmpeg source directory not found at $FFMPEG_SRC"
    echo "Usage: $0 [path-to-ffmpeg-source]"
    echo ""
    echo "To get FFmpeg source:"
    echo "  git clone https://git.ffmpeg.org/ffmpeg.git"
    echo "  cd ffmpeg && git checkout n8.1"
    exit 1
fi

# Find tvOS SDK
TVOS_SDK=$(xcrun --sdk appletvos --show-sdk-path 2>/dev/null)
if [ -z "$TVOS_SDK" ]; then
    echo "Error: tvOS SDK not found. Install Xcode with tvOS support."
    exit 1
fi
echo "Using tvOS SDK: $TVOS_SDK"

# Clean previous build
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

cd "$FFMPEG_SRC"

# Clean any previous FFmpeg build artifacts
make distclean 2>/dev/null || true

echo "Configuring FFmpeg for tvOS arm64..."

# Configure build: demuxers + mp4 muxer + audio transcode (DTS/TrueHD → EAC3)
./configure \
    --prefix="$BUILD_DIR" \
    --target-os=darwin \
    --arch="$ARCH" \
    --enable-cross-compile \
    --cc="xcrun -sdk appletvos clang" \
    --as="xcrun -sdk appletvos clang" \
    --ar="xcrun -sdk appletvos ar" \
    --ranlib="xcrun -sdk appletvos ranlib" \
    --strip="xcrun -sdk appletvos strip" \
    --extra-cflags="-arch $ARCH -mtvos-version-min=$TVOS_MIN -isysroot $TVOS_SDK -fembed-bitcode -DCONFIG_SECURETRANSPORT=1" \
    --extra-ldflags="-arch $ARCH -mtvos-version-min=$TVOS_MIN -isysroot $TVOS_SDK" \
    --disable-everything \
    \
    --enable-demuxer=matroska,mov,mpegts,hls,flv,avi,ogg,wav,aiff,flac,mp3,concat,srt,webvtt,ass \
    --enable-muxer=mp4,ipod \
    --enable-parser=hevc,h264,aac,ac3,eac3,flac,opus,vorbis,h263 \
    --enable-protocol=file,http,https,tcp,tls,crypto \
    --enable-decoder=srt,webvtt,ass,ssa,subrip,pgssub,dvdsub,dvbsub,truehd,mlp,dca,flac,pcm_s16le,pcm_s24le,aac,aac_latm,ac3,eac3,mp3,alac \
    --enable-encoder=eac3 \
    \
    --disable-filters \
    --disable-bsfs \
    --disable-indevs \
    --disable-outdevs \
    --disable-programs \
    --disable-doc \
    --disable-htmlpages \
    --disable-manpages \
    --disable-podpages \
    --disable-txtpages \
    --enable-network \
    --disable-debug \
    --disable-symver \
    --disable-stripping \
    --disable-avdevice \
    --enable-swresample \
    --disable-swscale \
    --disable-avfilter \
    --enable-small \
    --enable-pic \
    --enable-static \
    --disable-shared \
    --enable-securetransport \
    --disable-videotoolbox \
    --disable-audiotoolbox

echo ""
echo "Building FFmpeg..."
make -j$(sysctl -n hw.ncpu)

echo ""
echo "Installing to $BUILD_DIR..."
make install

echo ""
echo "Build complete! Packaging xcframeworks..."

# Remove non-Apple platform headers that break Clang module compilation.
# FFmpeg installs headers for all platforms (AMD AMF, CUDA, D3D, VAAPI, etc.)
# but only VideoToolbox is relevant on tvOS.
echo ""
echo "Stripping non-Apple platform headers..."

# Libavutil: remove all hwcontext_* except hwcontext.h and hwcontext_videotoolbox.h
for h in "$BUILD_DIR/include/libavutil/hwcontext_"*.h; do
    name=$(basename "$h")
    case "$name" in
        hwcontext_videotoolbox.h) ;; # keep
        *) echo "  Removing libavutil/$name"; rm "$h" ;;
    esac
done
# Also remove iamf.h if it has non-Apple references
rm -f "$BUILD_DIR/include/libavutil/hwcontext_amf.h" 2>/dev/null

# Libavcodec: remove platform-specific codec headers
for h in d3d11va.h dxva2.h vdpau.h mediacodec.h qsv.h jni.h; do
    rm -f "$BUILD_DIR/include/libavcodec/$h" 2>/dev/null && echo "  Removing libavcodec/$h"
done

# Package each library as an xcframework
for lib in avformat avcodec avutil swresample; do
    LIB_NAME="Lib${lib}"
    echo ""
    echo "Packaging $LIB_NAME.xcframework..."

    DEVICE_FW="$BUILD_DIR/fw/${LIB_NAME}/${LIB_NAME}.framework"
    mkdir -p "$DEVICE_FW/Headers" "$DEVICE_FW/Modules"

    cp "$BUILD_DIR/lib/lib${lib}.a" "$DEVICE_FW/$LIB_NAME"
    cp "$BUILD_DIR/include/lib${lib}/"*.h "$DEVICE_FW/Headers/"

    cat > "$DEVICE_FW/Modules/module.modulemap" << MODEOF
framework module ${LIB_NAME} [system] {
    umbrella "."
    export *
}
MODEOF

    cat > "$DEVICE_FW/Info.plist" << PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>org.ffmpeg.${lib}</string>
    <key>CFBundleName</key><string>${LIB_NAME}</string>
    <key>CFBundleVersion</key><string>8.0.1</string>
    <key>CFBundleShortVersionString</key><string>8.0.1</string>
    <key>MinimumOSVersion</key><string>${TVOS_MIN}</string>
</dict>
</plist>
PLISTEOF

    rm -rf "$FW_DIR/${LIB_NAME}.xcframework"
    xcodebuild -create-xcframework \
        -framework "$DEVICE_FW" \
        -output "$FW_DIR/${LIB_NAME}.xcframework" 2>&1 | tail -1
done

echo ""
echo "=== Done ==="
echo ""
echo "Installed xcframeworks:"
ls -d "$FW_DIR"/Lib*.xcframework 2>/dev/null
echo ""
TOTAL_SIZE=$(du -sh "$FW_DIR/" | cut -f1)
echo "Total Frameworks size: $TOTAL_SIZE"
