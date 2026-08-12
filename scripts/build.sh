#!/bin/bash
# VoiceKit 构建脚本
#
# 用法:
#   ./scripts/build.sh              # 官网版（Developer ID 签名，用于分发）
#   ./scripts/build.sh local        # 官网本地测试版（优先 Developer ID 签名，权限授权可跨构建保留）
#   ./scripts/build.sh appstore     # App Store 版（Apple Distribution 签名）
#   ./scripts/build.sh appstore-local # App Store 本地测试版（无签名）

set -euo pipefail
cd "$(dirname "$0")/.."

# xcodegen 依赖 $USER 推导路径；CI/agent 环境下可能缺失，缺失时静默失败
export USER="${USER:-$(whoami)}"
export LOGNAME="${LOGNAME:-$USER}"

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
xcodegen generate

# xcodegen 重建工程会清空共享 scheme，恢复带单元测试配置的 scheme
SCHEMES_DIR="$PROJECT/xcshareddata/xcschemes"
mkdir -p "$SCHEMES_DIR"
if [ -f "scripts/xcschemes/VoiceKit.xcscheme" ]; then
    cp scripts/xcschemes/VoiceKit.xcscheme "$SCHEMES_DIR/"
fi

# 本地构建优先使用 Developer ID 签名：TCC（麦克风/辅助功能/键盘事件）按签名身份
# 记忆授权，无签名包每次构建都被当作新 App，导致授权弹窗循环。
# 找不到证书时回退无签名并明确提示。
detect_dev_identity() {
    security find-identity -v -p codesigning 2>/dev/null \
        | grep "Developer ID Application" | head -1 \
        | sed -E 's/.*"(Developer ID Application: .*)"/\1/' || true
}

case "$MODE" in
    local)
        IDENTITY="$(detect_dev_identity)"
        if [ -n "$IDENTITY" ]; then
            TEAM_ID="$(echo "$IDENTITY" | sed -E 's/.*\(([A-Z0-9]+)\)$/\1/')"
            echo "📦 构建官网版（本地测试，签名: ${IDENTITY}）..."
            xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
                CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="$TEAM_ID" \
                CODE_SIGN_IDENTITY="$IDENTITY" \
                build 2>&1 | grep -E "BUILD|error:"
        else
            echo "📦 构建官网版（本地测试，无签名）..."
            echo "⚠️  钥匙串中没有 Developer ID 证书，无签名包的系统权限授权不会被记住，每次构建都会重新弹窗"
            xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
                CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
                build 2>&1 | grep -E "BUILD|error:"
        fi
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
APP_PATH=$(find "$HOME/Library/Developer/Xcode/DerivedData/"VoiceKit-*/Build/Products/Release -name "VoiceKit.app" -maxdepth 1 2>/dev/null | head -1)
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
