#!/bin/bash
# ============================================================================
#  miniaudio_bridge 编译脚本 (Linux / macOS / Android NDK)
#
#  用法:
#    ./build_unix.sh linux     # Linux x86_64 → libminiaudio_bridge.so
#    ./build_unix.sh macos     # macOS        → libminiaudio_bridge.dylib
#    ./build_unix.sh android   # Android arm64 (需设置 $NDK 与 $ANDROID_API)
#
#  使用前:
#    1. 确保 miniaudio 子模块已拉取 (miniaudio/miniaudio.h, 勿手动下载覆盖):
#         git submodule update --init --recursive
#    2. Linux: 安装 gcc 和 libasound2-dev (ALSA) / libpulse-dev (PulseAudio)
#    3. macOS: 安装 Xcode Command Line Tools
#    4. Android: 设置 NDK 路径, 例如:
#         export NDK=$HOME/Android/Sdk/ndk/26.1.10909125
#         export ANDROID_API=24
# ============================================================================

set -e
cd "$(dirname "$0")"

if [ ! -f miniaudio/miniaudio.h ]; then
    echo "[ERROR] miniaudio/miniaudio.h not found. The miniaudio submodule is missing."
    echo "Run: git submodule update --init --recursive"
    exit 1
fi

TARGET="${1:-linux}"
CFLAGS="-O2 -fPIC -DNDEBUG -DMA_BRIDGE_EXPORTS"

case "$TARGET" in
    linux)
        echo "[1/2] Compiling for Linux x86_64..."
        gcc $CFLAGS -shared miniaudio_bridge.c \
            -o libminiaudio_bridge.so \
            -lasound -lpthread -lm
        mkdir -p ../libs/linux
        cp libminiaudio_bridge.so ../libs/linux/
        echo "[SUCCESS] → ../libs/linux/libminiaudio_bridge.so"
        ;;
    macos)
        echo "[1/2] Compiling for macOS (universal)..."
        # arm64 (Apple Silicon)
        clang $CFLAGS -arch arm64 -shared miniaudio_bridge.c \
            -o libminiaudio_bridge_arm64.dylib \
            -framework CoreAudio -framework AudioToolbox -framework CoreFoundation
        # x86_64 (Intel)
        clang $CFLAGS -arch x86_64 -shared miniaudio_bridge.c \
            -o libminiaudio_bridge_x86_64.dylib \
            -framework CoreAudio -framework AudioToolbox -framework CoreFoundation
        # 合并为 universal
        lipo -create libminiaudio_bridge_arm64.dylib libminiaudio_bridge_x86_64.dylib \
            -output libminiaudio_bridge.dylib
        rm -f libminiaudio_bridge_arm64.dylib libminiaudio_bridge_x86_64.dylib
        mkdir -p ../libs/macos
        cp libminiaudio_bridge.dylib ../libs/macos/
        echo "[SUCCESS] → ../libs/macos/libminiaudio_bridge.dylib (universal)"
        ;;
    android)
        if [ -z "$NDK" ]; then
            echo "[ERROR] NDK environment variable not set."
            echo "  export NDK=\$HOME/Android/Sdk/ndk/26.1.10909125"
            exit 1
        fi
        API="${ANDROID_API:-24}"
        # 兼容 linux-x86_64 和 darwin-x86_64 (macOS 主机)
        HOST_TAG="linux-x86_64"
        if [ "$(uname -s)" = "Darwin" ]; then
            HOST_TAG="darwin-x86_64"
        fi
        TOOLCHAIN="$NDK/toolchains/llvm/prebuilt/$HOST_TAG"
        CC="$TOOLCHAIN/bin/aarch64-linux-android$API-clang"

        echo "[1/3] Compiling for Android arm64 (API $API)..."
        $CC $CFLAGS -shared miniaudio_bridge.c \
            -o libminiaudio_bridge.so \
            -lOpenSLES

        echo "[2/3] Packaging AAR..."
        # AAR 结构: jni/arm64-v8a/libminiaudio_bridge.so + AndroidManifest.xml
        AAR_DIR="_aar_tmp"
        rm -rf "$AAR_DIR"
        mkdir -p "$AAR_DIR/jni/arm64-v8a"
        cp libminiaudio_bridge.so "$AAR_DIR/jni/arm64-v8a/"
        # 最小化 AndroidManifest.xml (AAR 必需)
        cat > "$AAR_DIR/AndroidManifest.xml" << 'XML'
<?xml version="1.0" encoding="utf-8"?>
<manifest xmlns:android="http://schemas.android.com/apk/res/android"
    package="com.godot.miniaudio">
</manifest>
XML
        mkdir -p ../libs/android
        # 生成 debug 和 release 两个 AAR (内容相同, 只是文件名不同)
        (cd "$AAR_DIR" && zip -q -r "../miniaudio_bridge-debug.aar" .)
        cp ../libs/android/miniaudio_bridge-debug.aar ../libs/android/miniaudio_bridge-release.aar
        rm -rf "$AAR_DIR"

        echo "[3/3] Copying .so to arm64/ (备用, 供直接使用)..."
        mkdir -p ../libs/android/arm64
        cp libminiaudio_bridge.so ../libs/android/arm64/

        echo "[SUCCESS] → ../libs/android/miniaudio_bridge-debug.aar"
        echo "[SUCCESS] → ../libs/android/miniaudio_bridge-release.aar"
        echo "[SUCCESS] → ../libs/android/arm64/libminiaudio_bridge.so"
        ;;
    *)
        echo "Usage: $0 {linux|macos|android}"
        exit 1
        ;;
esac
