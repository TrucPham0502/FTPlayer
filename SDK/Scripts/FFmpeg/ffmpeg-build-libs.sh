#!/bin/bash
# Derived from ffmpeg-build-all.sh; builds only the seven FFmpeg libraries.
# Usage: bash /path/to/ffmpeg-build-libs.sh [/path/to/ffmpeg-source]
# Repackage existing libraries: bash /path/to/ffmpeg-build-libs.sh --package-only [/path/to/ffmpeg-source]
# Default source: current directory (must contain configure and libavcodec/).
# Output: <source>/build-libs/xcframeworks/
# Optional environment: BUILD_ROOT, JOBS, MIN_IOS_VERSION, MIN_MACOS_VERSION.
# CoreVideo and Metal are supplied by Apple's SDK, not built by this script.
# Builds the supplied FFmpeg source unchanged; playback fixes belong in the SDK.
set -euo pipefail

die() { echo "Error: $*" >&2; exit 1; }

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    sed -n '2,9p' "$0"
    exit 0
fi
PACKAGE_ONLY=0
if [[ "${1:-}" == "--package-only" ]]; then
    PACKAGE_ONLY=1
    shift
fi
[[ $# -le 1 && "${1:-}" != -* ]] || die "Usage: bash $0 [--package-only] [/path/to/ffmpeg-source]"

SOURCE_DIR=$(cd "${1:-.}" && pwd -P)
[[ -x "$SOURCE_DIR/configure" && -d "$SOURCE_DIR/libavcodec" ]] ||
    die "Run from the FFmpeg source directory, or pass its path as the first argument."
[[ "$(uname -s)" == "Darwin" ]] || die "This script requires macOS and Xcode."

# Use separate build directories so each target gets its own config.h and objects.
# An already configured source tree prevents FFmpeg's out-of-tree builds.
if [[ "$PACKAGE_ONLY" == 0 ]] &&
    [[ -f "$SOURCE_DIR/config.h" || -f "$SOURCE_DIR/ffbuild/config.mak" ]]; then
    die "Source tree is already configured. Run 'make distclean' there before using this script."
fi

for tool in xcrun xcodebuild make lipo ar sysctl cmp; do
    command -v "$tool" >/dev/null 2>&1 || die "Missing required tool: $tool"
done

BUILD_ROOT=${BUILD_ROOT:-"$SOURCE_DIR/build-libs"}
mkdir -p "$BUILD_ROOT"
BUILD_ROOT=$(cd "$BUILD_ROOT" && pwd -P)
[[ "$BUILD_ROOT" != "/" && "$BUILD_ROOT" != "$SOURCE_DIR" ]] ||
    die "BUILD_ROOT must be a dedicated output directory."
XC_DIR="$BUILD_ROOT/xcframeworks"
mkdir -p "$XC_DIR"

MIN_IOS_VERSION=${MIN_IOS_VERSION:-13.0}
# Use the same deployment target for both macOS slices.
MIN_MACOS_VERSION=${MIN_MACOS_VERSION:-11.0}
JOBS=${JOBS:-$(sysctl -n hw.logicalcpu 2>/dev/null || echo 4)}
[[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || die "JOBS must be a positive integer."

LIBS=(libavcodec libavdevice libavfilter libavformat libavutil libswresample libswscale)
IOS_DIR="$BUILD_ROOT/ios"
SIM_DIR="$BUILD_ROOT/ios-simulator-arm64"
MACARM64_DIR="$BUILD_ROOT/macos-arm64"
MACX86_64_DIR="$BUILD_ROOT/macos-x86_64"
MACUNIVERSAL_DIR="$BUILD_ROOT/macos-universal"

IOS_SYSROOT=$(xcrun --sdk iphoneos --show-sdk-path)
SIM_SYSROOT=$(xcrun --sdk iphonesimulator --show-sdk-path)
MACOS_SYSROOT=$(xcrun --sdk macosx --show-sdk-path)
CLANG=$(xcrun --find clang)
AR=$(xcrun --find ar)
RANLIB=$(xcrun --find ranlib)

COMMON_FLAGS=(
    --enable-cross-compile --target-os=darwin
    --enable-static --disable-shared --enable-pic
    --disable-programs --disable-doc --disable-debug
    --enable-gpl
    --disable-audiotoolbox --disable-d3d11va --disable-dxva2
    # Avoid detecting Homebrew/host libraries that are unavailable on iOS.
    --disable-autodetect --enable-videotoolbox
    # Always include native HTTPS/HLS on every Apple target, including encrypted HLS.
    --enable-network --enable-securetransport
    --enable-demuxer=hls --enable-protocol=http,https,tcp,tls,crypto
)

# Older FFmpeg releases contain libpostproc; newer ones have removed it.
CONFIGURE_HELP=$("$SOURCE_DIR/configure" --help)
if [[ "$CONFIGURE_HELP" == *"--disable-postproc"* ]]; then
    COMMON_FLAGS+=(--disable-postproc)
fi

build_platform() (
    local PLATFORM=$1 ARCH=$2 SYSROOT=$3 TARGET=$4 PREFIX=$5
    local WORK_DIR="$BUILD_ROOT/work/$PLATFORM"
    local EXTRA_FLAGS=()

    # Keep x86 assembly when NASM is installed; otherwise allow a portable build.
    if [[ "$ARCH" == "x86_64" ]] && ! command -v nasm >/dev/null 2>&1; then
        echo "NASM not found: disabling x86 assembly for $PLATFORM."
        EXTRA_FLAGS+=(--disable-x86asm)
    fi

    mkdir -p "$WORK_DIR"
    cd "$WORK_DIR"
    # Use FFmpeg's own clean target, including its generated source link.
    # SRC_LINK may be recorded as ./src by an earlier configure invocation.
    [[ ! -f Makefile ]] || make distclean SRC_LINK=src
    echo "Building FFmpeg for $PLATFORM ($TARGET)..."
    "$SOURCE_DIR/configure" \
        "${COMMON_FLAGS[@]}" ${EXTRA_FLAGS[@]+"${EXTRA_FLAGS[@]}"} \
        --prefix="$PREFIX" --arch="$ARCH" \
        --cc="$CLANG" --ar="$AR" --ranlib="$RANLIB" \
        --sysroot="$SYSROOT" \
        --extra-cflags="-arch $ARCH -target $TARGET" \
        --extra-ldflags="-arch $ARCH -target $TARGET"
    # Configure may disable a component whose dependencies are unavailable.
    # Fail before compiling/packaging a library that cannot open HTTPS sources.
    local FEATURE
    for FEATURE in CONFIG_SECURETRANSPORT CONFIG_NETWORK; do
        grep -qx "#define $FEATURE 1" config.h ||
            die "$PLATFORM: missing $FEATURE; inspect ffbuild/config.log."
    done
    for FEATURE in CONFIG_HTTP_PROTOCOL CONFIG_HTTPS_PROTOCOL CONFIG_TLS_PROTOCOL CONFIG_TCP_PROTOCOL CONFIG_CRYPTO_PROTOCOL CONFIG_HLS_DEMUXER; do
        grep -qx "#define $FEATURE 1" config_components.h ||
            die "$PLATFORM: missing $FEATURE; inspect ffbuild/config.log."
    done
    make -j"$JOBS"
    make install

    # All seven libraries are required; missing output must stop the build.
    local LIB
    for LIB in "${LIBS[@]}"; do
        [[ -f "$PREFIX/lib/$LIB.a" && -d "$PREFIX/include/$LIB" ]] ||
            die "Missing $LIB library or headers for $PLATFORM."
        lipo "$PREFIX/lib/$LIB.a" -verify_arch "$ARCH"
    done
)

if [[ "$PACKAGE_ONLY" == 0 ]]; then
    build_platform ios arm64 "$IOS_SYSROOT" "arm64-apple-ios$MIN_IOS_VERSION" "$IOS_DIR"
    build_platform ios-simulator-arm64 arm64 "$SIM_SYSROOT" \
        "arm64-apple-ios$MIN_IOS_VERSION-simulator" "$SIM_DIR"
    build_platform macos-arm64 arm64 "$MACOS_SYSROOT" \
        "arm64-apple-macos$MIN_MACOS_VERSION" "$MACARM64_DIR"
    build_platform macos-x86_64 x86_64 "$MACOS_SYSROOT" \
        "x86_64-apple-macos$MIN_MACOS_VERSION" "$MACX86_64_DIR"
else
    echo "Repackaging existing libraries; compilation is skipped."
fi

get_header() {
    case "$1" in
        libavcodec) echo "avcodec.h" ;;
        libavdevice) echo "avdevice.h" ;;
        libavfilter) echo "avfilter.h" ;;
        libavformat) echo "avformat.h" ;;
        libavutil) echo "avutil.h" ;;
        libswresample) echo "swresample.h" ;;
        libswscale) echo "swscale.h" ;;
    esac
}

create_framework() {
    local SRC=$1 LIB=$2 PLATFORM=$3 MIN_VERSION=$4
    local FRAMEWORK="$SRC/$LIB.framework"
    local HEADER
    HEADER=$(get_header "$LIB")
    [[ -f "$SRC/lib/$LIB.a" && -f "$SRC/include/$LIB/$HEADER" ]] ||
        die "Missing library or public header for $LIB in $SRC."

    rm -rf "$FRAMEWORK"
    mkdir -p "$FRAMEWORK/Headers" "$FRAMEWORK/Modules"
    cp "$SRC/lib/$LIB.a" "$FRAMEWORK/$LIB"
    cp "$SRC/include/$LIB/"*.h "$FRAMEWORK/Headers/"

    # Match ffmpeg-build-all.sh: import the main header and named submodules.
    # An umbrella over all headers also imports optional backends (AMF, CUDA,
    # Vulkan, etc.) whose SDK headers need not exist on Apple platforms.
    cat > "$FRAMEWORK/Modules/module.modulemap" <<EOF
framework module $LIB {
    header "$HEADER"
    export *
EOF
    if [[ "$LIB" == "libavutil" ]]; then
        cat >> "$FRAMEWORK/Modules/module.modulemap" <<'EOF'

    explicit module imgutils {
        header "imgutils.h"
        export *
    }
    explicit module error {
        header "error.h"
        export *
    }
EOF
    fi
    echo "}" >> "$FRAMEWORK/Modules/module.modulemap"
    cat > "$FRAMEWORK/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$LIB</string>
    <key>CFBundleExecutable</key><string>$LIB</string>
    <key>CFBundleIdentifier</key><string>org.ffmpeg.$LIB</string>
    <key>CFBundlePackageType</key><string>FMWK</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleSupportedPlatforms</key><array><string>$PLATFORM</string></array>
    <key>MinimumOSVersion</key><string>$MIN_VERSION</string>
</dict>
</plist>
EOF
}

mkdir -p "$MACUNIVERSAL_DIR/lib" "$MACUNIVERSAL_DIR/include"
for LIB in "${LIBS[@]}"; do
    echo "Packaging $LIB..."
    create_framework "$IOS_DIR" "$LIB" iPhoneOS "$MIN_IOS_VERSION"
    create_framework "$SIM_DIR" "$LIB" iPhoneSimulator "$MIN_IOS_VERSION"

    # A universal framework shares one set of headers across its architectures.
    # Refuse to silently use ARM headers if the x86 configuration differs.
    for HEADER_PATH in "$MACARM64_DIR/include/$LIB/"*.h; do
        cmp -s "$HEADER_PATH" "$MACX86_64_DIR/include/$LIB/${HEADER_PATH##*/}" ||
            die "macOS headers differ across architectures: $HEADER_PATH"
    done
    rm -rf "$MACUNIVERSAL_DIR/include/$LIB"
    cp -R "$MACARM64_DIR/include/$LIB" "$MACUNIVERSAL_DIR/include/$LIB"
    lipo -create "$MACARM64_DIR/lib/$LIB.a" "$MACX86_64_DIR/lib/$LIB.a" \
        -output "$MACUNIVERSAL_DIR/lib/$LIB.a"
    lipo "$MACUNIVERSAL_DIR/lib/$LIB.a" -verify_arch arm64 x86_64
    create_framework "$MACUNIVERSAL_DIR" "$LIB" MacOSX "$MIN_MACOS_VERSION"

    rm -rf "$XC_DIR/$LIB.xcframework"
    xcodebuild -create-xcframework \
        -framework "$IOS_DIR/$LIB.framework" \
        -framework "$SIM_DIR/$LIB.framework" \
        -framework "$MACUNIVERSAL_DIR/$LIB.framework" \
        -output "$XC_DIR/$LIB.xcframework"
done

echo "Done. Seven FFmpeg XCFrameworks are available in: $XC_DIR"
