#!/bin/bash
set -euo pipefail

# ============================================================
#  公证凭证配置（只需执行一次）
#  使用 Apple ID + App-Specific Password，通过 1Password 读取
# ============================================================

NOTARY_PROFILE="VoiceMate"

echo "========================================="
echo " 🔑 配置公证凭证 (notarytool)"
echo "========================================="
echo ""
echo "从 1Password 读取 Apple ID 和密码..."

TEAM_ID="$(op read op://key/apple/TEAM_ID)"
APPLE_ID="$(op read op://key/apple/apple_id)"
PASSWORD="$(op read op://key/apple/password)"

echo "   Apple ID: ${APPLE_ID}"
echo "   Team ID:  ${TEAM_ID}"
echo ""

xcrun notarytool store-credentials "${NOTARY_PROFILE}" \
  --apple-id "${APPLE_ID}" \
  --team-id "${TEAM_ID}" \
  --password "${PASSWORD}"

echo ""
echo "✅ 凭证已存入 Keychain (profile: ${NOTARY_PROFILE})"
echo ""
echo "验证: xcrun notarytool history --keychain-profile ${NOTARY_PROFILE}"
