#!/bin/bash
set -euo pipefail

# ============================================================
#  公证凭证配置（只需执行一次）
#  将 App Store Connect API Key 存入 Keychain
# ============================================================

NOTARY_PROFILE="VoiceMate"
TEAM_ID="F2J85LVHS4"

echo "========================================="
echo " 🔑 配置公证凭证 (notarytool)"
echo "========================================="
echo ""
echo "需要准备:"
echo "  1. App Store Connect API Key (.p8 文件)"
echo "  2. Key ID (在 App Store Connect → 用户与访问 → API 密钥)"
echo "  3. Issuer ID (同一个页面顶部)"
echo ""
echo "获取地址: https://appstoreconnect.apple.com/access/integrations/api"
echo ""

read -rp "Key ID:       " KEY_ID
read -rp "Issuer ID:    " ISSUER_ID
read -rp ".p8 文件路径: " P8_PATH

if [ ! -f "${P8_PATH}" ]; then
  echo "❌ 文件不存在: ${P8_PATH}"
  exit 1
fi

xcrun notarytool store-credentials "${NOTARY_PROFILE}" \
  --key "${P8_PATH}" \
  --key-id "${KEY_ID}" \
  --issuer "${ISSUER_ID}" \
  --team-id "${TEAM_ID}"

echo ""
echo "✅ 凭证已存入 Keychain (profile: ${NOTARY_PROFILE})"
echo ""
echo "验证: xcrun notarytool history --keychain-profile ${NOTARY_PROFILE}"
