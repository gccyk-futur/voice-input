#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

# ============================================================
#  VoiceMate Release Build Script
#  签名 → 公证 → 打包 DMG
# ============================================================

# ---- 配置 ---------------------------------------------------
APP_NAME="VoiceMate"
SCHEME="VoiceMate"
TEAM_ID="F2J85LVHS4"
BUNDLE_ID="me.ckai.VoiceMate"
SIGNING_IDENTITY="Developer ID Application: Kai Meng (${TEAM_ID})"
ENTITLEMENTS="Sources/VoiceMate/Resources/VoiceMate.entitlements"
NOTARY_PROFILE="VoiceMate"   # 需先执行一次: scripts/setup-notary.sh
BUILD_DIR="./build"
# ------------------------------------------------------------

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

step()  { echo -e "\n${GREEN}▶${NC} $1"; }
warn()  { echo -e "${YELLOW}⚠${NC}  $1"; }
error() { echo -e "${RED}✗${NC}  $1"; exit 1; }

# ---- 版本号 -------------------------------------------------
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Sources/VoiceMate/Resources/Info.plist)
BUILD_NUM=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" Sources/VoiceMate/Resources/Info.plist)

echo    "========================================="
echo -e " 🔨 ${GREEN}VoiceMate Release Build${NC}"
echo    "    Version: ${VERSION} (build ${BUILD_NUM})"
echo    "    Team:    ${TEAM_ID}"
echo    "    Signing: ${SIGNING_IDENTITY}"
echo    "========================================="

# ---- 预检 ---------------------------------------------------
step "Pre-flight checks..."

# 证书
if ! security find-identity -v -p codesigning | grep -q "${SIGNING_IDENTITY}"; then
  error "找不到签名证书: ${SIGNING_IDENTITY}"
fi
echo "   ✅ 签名证书就绪"

# 公证凭证
if ! xcrun notarytool history --keychain-profile "${NOTARY_PROFILE}" &>/dev/null; then
  warn "公证凭证未配置。请先运行:  ./scripts/setup-notary.sh"
  warn "跳过公证步骤，仅构建签名 .app（不会打包 DMG）"
  SKIP_NOTARY=true
else
  echo "   ✅ 公证凭证就绪"
  SKIP_NOTARY=false
fi

# xcodegen 检查
if ! command -v xcodegen &>/dev/null; then
  warn "xcodegen 未安装，跳过项目生成。安装: brew install xcodegen"
fi

# ---- 生成项目 ------------------------------------------------
step "Generating project (xcodegen)..."
if command -v xcodegen &>/dev/null; then
  xcodegen generate --quiet 2>&1 || warn "xcodegen 警告（可能不影响构建）"
fi

# ---- 清理 ---------------------------------------------------
step "Cleaning build artifacts..."
rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}"

# ---- 构建 ---------------------------------------------------
step "Building Release (arm64 + x86_64)..."
xcodebuild \
  -target "${SCHEME}" \
  -configuration Release \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="${SIGNING_IDENTITY}" \
  DEVELOPMENT_TEAM="${TEAM_ID}" \
  PRODUCT_BUNDLE_IDENTIFIER="${BUNDLE_ID}" \
  "OTHER_CODE_SIGN_FLAGS=--timestamp --options=runtime" \
  build \
  2>&1 | grep -E "(error:|warning:|BUILD|FAILED|Signing)" || true

APP_PATH="${BUILD_DIR}/Release/${APP_NAME}.app"

if [ -z "${APP_PATH}" ] || [ ! -d "${APP_PATH}" ]; then
  error "构建失败，未找到 .app。检查上方错误信息。"
fi

echo "   ✅ App: ${APP_PATH}"

# ---- 验证签名 ------------------------------------------------
step "Verifying code signature..."
echo ""
codesign -dvv "${APP_PATH}" 2>&1
echo ""
spctl -a -t exec -vv "${APP_PATH}" 2>&1 || warn "spctl 验证警告（公证后可解决）"

# ---- 公证 ---------------------------------------------------
if [ "${SKIP_NOTARY}" = true ]; then
  warn "跳过公证。.app 位于: ${APP_PATH}"
  echo ""
  echo "========================================="
  echo " ⚠️  构建完成（未公证）"
  echo "    如需公证，请先配置凭证:"
  echo "      ./scripts/setup-notary.sh"
  echo "    .app: ${APP_PATH}"
  echo "========================================="
  exit 0
fi

step "Submitting for notarization..."
NOTARY_DIR="${BUILD_DIR}/notary"
mkdir -p "${NOTARY_DIR}"

ZIP_PATH="${NOTARY_DIR}/${APP_NAME}.zip"
ditto -c -k --keepParent "${APP_PATH}" "${ZIP_PATH}"

xcrun notarytool submit "${ZIP_PATH}" \
  --keychain-profile "${NOTARY_PROFILE}" \
  --wait \
  --team-id "${TEAM_ID}" \
  2>&1

# ---- 装订 (Staple) ------------------------------------------
step "Stapling notarization ticket..."
xcrun stapler staple "${APP_PATH}" 2>&1
echo "   ✅ Stapled"

# ---- 制作 DMG ------------------------------------------------
step "Creating DMG..."
DMG_PATH="${BUILD_DIR}/${APP_NAME}-${VERSION}.dmg"

hdiutil create -volname "${APP_NAME}" \
  -srcfolder "${APP_PATH}" \
  -ov -format UDZO \
  "${DMG_PATH}" 2>&1

# 签名 DMG
codesign --sign "${SIGNING_IDENTITY}" --timestamp "${DMG_PATH}" 2>&1

# 公证 DMG
step "Notarizing DMG..."
xcrun notarytool submit "${DMG_PATH}" \
  --keychain-profile "${NOTARY_PROFILE}" \
  --wait \
  --team-id "${TEAM_ID}" \
  2>&1

xcrun stapler staple "${DMG_PATH}" 2>&1

# ---- 完成 ---------------------------------------------------
echo ""
echo "========================================="
echo -e " ${GREEN}✅ Release 构建完成${NC}"
echo ""
echo "    DMG:  ${DMG_PATH}"
echo "    App:  ${APP_PATH}"
echo ""
echo "    分发: 将 .dmg 上传到网站/网盘即可"
echo "    用户: 下载 → 双击挂载 → 拖入 Applications"
echo "========================================="
