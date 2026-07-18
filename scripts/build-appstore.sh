#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

# ============================================================
#  VoiceKit App Store Build Script
#  签名（Apple Distribution）→ Archive → Export → .pkg
# ============================================================

# ---- 配置 ---------------------------------------------------
APP_NAME="VoiceKit"
SCHEME="VoiceKit"
BUNDLE_ID="me.ckai.VoiceMate"
EXPORT_OPTIONS="./scripts/exportOptions-appstore.plist"
BUILD_DIR="./build"
ARCHIVE_PATH="${BUILD_DIR}/${APP_NAME}.xcarchive"
PKG_PATH="${BUILD_DIR}/${APP_NAME}.pkg"

# 开发者身份（与 build-release.sh 共用 1Password 凭证）
TEAM_ID="$(op read op://My-Keys/apple/TEAM_ID)"
SIGNING_NAME="$(op read op://My-Keys/apple/SIGNING_NAME)"
export VOICEMATE_TEAM_ID="${TEAM_ID}"
export VOICEMATE_SIGNING_NAME="${SIGNING_NAME}"
DIST_IDENTITY="Apple Distribution: ${SIGNING_NAME} (${TEAM_ID})"
# ------------------------------------------------------------

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

step()  { echo -e "\n${GREEN}▶${NC} $1"; }
warn()  { echo -e "${YELLOW}⚠${NC}  $1"; }
error() { echo -e "${RED}✗${NC}  $1"; exit 1; }

# ---- 版本号 -------------------------------------------------
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Sources/VoiceKit/Resources/Info.plist)
BUILD_NUM=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" Sources/VoiceKit/Resources/Info.plist)

echo    "========================================="
echo -e " 📦 ${GREEN}VoiceKit App Store Build${NC}"
echo    "    Version: ${VERSION} (build ${BUILD_NUM})"
echo    "    Team:    ${TEAM_ID}"
echo    "    Signing: ${DIST_IDENTITY}"
echo    "========================================="

# ---- 预检 ---------------------------------------------------
step "Pre-flight checks..."

# 证书
if ! security find-identity -v -p codesigning | grep -q "${DIST_IDENTITY}"; then
  error "找不到 Apple Distribution 证书: ${DIST_IDENTITY}"
fi
echo "   ✅ Apple Distribution 证书就绪"

# xcodegen 检查
if ! command -v xcodegen &>/dev/null; then
  warn "xcodegen 未安装，跳过项目生成。安装: brew install xcodegen"
fi

# ---- 生成项目 ------------------------------------------------
step "Generating project (xcodegen)..."
if command -v xcodegen &>/dev/null; then
  xcodegen generate --quiet 2>&1 || warn "xcodegen 警告（可能不影响构建）"
  SCHEMES_DIR="VoiceKit.xcodeproj/xcshareddata/xcschemes"
  mkdir -p "${SCHEMES_DIR}"
  if [ -f "scripts/xcschemes/VoiceKit.xcscheme" ]; then
    cp scripts/xcschemes/VoiceKit.xcscheme "${SCHEMES_DIR}/"
  fi
fi

# ---- 清理 ---------------------------------------------------
step "Cleaning previous builds..."
rm -rf "${ARCHIVE_PATH}" "${PKG_PATH}"
mkdir -p "${BUILD_DIR}"

# ---- 版本号自增 -----------------------------------------------
INFO_PLIST="Sources/VoiceKit/Resources/Info.plist"
OLD_BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "${INFO_PLIST}")
NEW_BUILD=$((OLD_BUILD + 1))
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${NEW_BUILD}" "${INFO_PLIST}"
echo "   📦 Build #: ${OLD_BUILD} → ${NEW_BUILD}"
sed -i '' "s/CFBundleVersion: \"${OLD_BUILD}\"/CFBundleVersion: \"${NEW_BUILD}\"/" project.yml
BUILD_NUM="${NEW_BUILD}"

# ---- Archive ------------------------------------------------
step "Archiving for App Store..."

# 生成带正确 teamID 的 export options
TMP_EXPORT_OPTS="${BUILD_DIR}/exportOptions.plist"
sed "s/\${TEAM_ID}/${TEAM_ID}/g" "${EXPORT_OPTIONS}" > "${TMP_EXPORT_OPTS}"

xcodebuild archive \
  -scheme "${SCHEME}" \
  -configuration Release \
  -archivePath "${ARCHIVE_PATH}" \
  -allowProvisioningUpdates \
  SWIFT_ACTIVE_COMPILATION_CONDITIONS='APP_STORE' \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="${DIST_IDENTITY}" \
  DEVELOPMENT_TEAM="${TEAM_ID}" \
  PRODUCT_BUNDLE_IDENTIFIER="${BUNDLE_ID}" \
  CODE_SIGN_ENTITLEMENTS="Sources/VoiceKit/Resources/VoiceMate.entitlements" \
  "OTHER_CODE_SIGN_FLAGS=--timestamp --options=runtime" \
  2>&1 | grep -E "(error:|warning:|BUILD|FAILED|Signing|Archive)" || true

if [ ! -d "${ARCHIVE_PATH}" ]; then
  error "Archive 失败。检查上方错误信息。"
fi
echo "   ✅ Archive: ${ARCHIVE_PATH}"

# ---- 剥离 get-task-allow（同独立分发流程）---------------------
step "Stripping get-task-allow..."
APP_IN_ARCHIVE="${ARCHIVE_PATH}/Products/Applications/${APP_NAME}.app"
if [ -d "${APP_IN_ARCHIVE}" ]; then
  # 从嵌入的 provisioning profile 提取 entitlements 并剥离 get-task-allow
  ENTITLEMENTS_TMP="${BUILD_DIR}/cleaned.entitlements"
  codesign -d --entitlements - "${APP_IN_ARCHIVE}" 2>/dev/null | \
    sed -n '/<?xml/,/<\/plist>/p' > "${ENTITLEMENTS_TMP}" 2>/dev/null || true
  if [ -f "${ENTITLEMENTS_TMP}" ] && grep -q "get-task-allow" "${ENTITLEMENTS_TMP}" 2>/dev/null; then
    python3 -c "
import plistlib
with open('${ENTITLEMENTS_TMP}', 'rb') as f:
    d = plistlib.load(f)
d.pop('com.apple.security.get-task-allow', None)
with open('${ENTITLEMENTS_TMP}', 'wb') as f:
    plistlib.dump(d, f)
"
    codesign --force --sign "${DIST_IDENTITY}" \
      --entitlements "${ENTITLEMENTS_TMP}" \
      --timestamp --options=runtime \
      "${APP_IN_ARCHIVE}" 2>&1
    echo "   ✅ get-task-allow 已剥离并重新签名"
  else
    echo "   ✅ 无需剥离（get-task-allow 不存在）"
  fi
fi

# ---- Export -------------------------------------------------
step "Exporting .pkg for App Store..."

xcodebuild -exportArchive \
  -archivePath "${ARCHIVE_PATH}" \
  -exportPath "${BUILD_DIR}" \
  -exportOptionsPlist "${TMP_EXPORT_OPTS}" \
  2>&1 | grep -E "(error:|warning:|EXPORT|FAILED|Signing)" || true

# xcodebuild export puts .pkg in a subdirectory; find it
FOUND_PKG=$(find "${BUILD_DIR}" -name "*.pkg" -not -path "*/dmg-staging/*" | head -1)
if [ -z "${FOUND_PKG}" ]; then
  error "Export 失败，未找到 .pkg。"
fi

# Rename to friendly name
mv "${FOUND_PKG}" "${PKG_PATH}"
echo "   ✅ Package: ${PKG_PATH}"

# ---- 完成 ---------------------------------------------------
echo ""
echo "========================================="
echo -e " ${GREEN}✅ App Store 构建完成${NC}"
echo ""
echo "    Version: ${VERSION} (${BUILD_NUM})"
echo "    Package: ${PKG_PATH}"
echo ""
echo "    上传: 使用 Transporter App 或:"
echo "      xcrun altool --upload-app -f ${PKG_PATH} -t macOS \\"
echo "        -u <apple-id> -p <app-specific-password>"
echo ""
echo "    或直接通过 Xcode → Organizer → Archives → Distribute App"
echo "========================================="
