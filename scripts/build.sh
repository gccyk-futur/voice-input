#!/bin/bash
# VoiceKit 构建脚本
#
# 用法:
#   ./scripts/build.sh              # 官网版（Developer ID 签名，用于分发）
#   ./scripts/build.sh local        # 官网本地测试版（无签名，本机运行）
#   ./scripts/build.sh appstore     # App Store 版（Apple Distribution 签名）
#   ./scripts/build.sh appstore-local # App Store 本地测试版（无签名）

set -euo pipefail
cd "$(dirname "$0")/.."

MODE="${1:-direct}"
SCHEME="VoiceKit"
PROJECT="VoiceKit.xcodeproj"
DERIVED_DATA=$(xcodebuild -project "$PROJECT" -scheme "$SCHEME" -showBuildSettings 2>/dev/null | grep "BUILD_DIR" | head -1 | awk '{print $3}' || echo "")

# xcodegen 生成工程
if [ ! -d "$PROJECT" ]; then
    echo "🔧 生成 Xcode 工程..."
    xcodegen generate
fi

# xcodegen 重新生成确保最新
echo "🔧 刷新工程..."
xcodegen generate > /dev/null 2>&1

case "$MODE" in
    local)
        echo "📦 构建官网版（本地测试，无签名）..."
        xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
            CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
            build 2>&1 | grep -E "BUILD|error:"
        SUFFIX=""
        ;;
    appstore-local)
        echo "📦 构建 App Store 版（本地测试，无签名）..."
        xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
            SWIFT_ACTIVE_COMPILATION_CONDITIONS='APP_STORE' \
            CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
            build 2>&1 | grep -E "BUILD|error:"
        SUFFIX="-AppStore"
        ;;
    appstore)
        echo "📦 构建 App Store 分发版..."
        xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
            SWIFT_ACTIVE_COMPILATION_CONDITIONS='APP_STORE' \
            build 2>&1 | grep -E "BUILD|error:"
        SUFFIX="-AppStore"
        ;;
    *)
        echo "📦 构建官网分发版..."
        xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
            build 2>&1 | grep -E "BUILD|error:"
        SUFFIX=""
        ;;
esac

# 复制产物
APP_PATH=$(find /Users/ckai/Library/Developer/Xcode/DerivedData/VoiceKit-*/Build/Products/Release -name "VoiceKit.app" -maxdepth 1 2>/dev/null | head -1)
if [ -n "$APP_PATH" ] && [ -d "$APP_PATH" ]; then
    DEST="./build/VoiceKit${SUFFIX}.app"
    rm -rf "$DEST"
    cp -R "$APP_PATH" "$DEST"
    xattr -cr "$DEST"
    echo ""
    echo "✅ 产物: $DEST"
    ls -lh "$DEST/Contents/MacOS/VoiceKit"
else
    echo "❌ 未找到产物"
    exit 1
fi
