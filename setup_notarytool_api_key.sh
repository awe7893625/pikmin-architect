#!/bin/bash
set -euo pipefail

# 用 App Store Connect API Key 建立 notarytool profile（只需要做一次）
#
# 你需要準備：
# - Issuer ID（UUID）
# - Key ID（10 字元）
# - AuthKey_XXXXXXXXXX.p8 檔案路徑
#
# 使用方式：
#   ./setup_notarytool_api_key.sh "<ISSUER_ID>" "<KEY_ID>" "/path/to/AuthKey_XXXXXX.p8"
#

PROFILE_NAME="${PROFILE_NAME:-konggoo-notary}"

ISSUER_ID="${1:-}"
KEY_ID="${2:-}"
P8_PATH="${3:-}"

if [[ -z "$ISSUER_ID" || -z "$KEY_ID" || -z "$P8_PATH" ]]; then
  echo "❌ 參數不足"
  echo "用法：$0 \"<ISSUER_ID>\" \"<KEY_ID>\" \"/path/to/AuthKey_XXXXXX.p8\""
  exit 1
fi

if [[ ! -f "$P8_PATH" ]]; then
  echo "❌ 找不到 p8 檔案：$P8_PATH"
  exit 1
fi

echo "🔐 建立 notarytool profile：$PROFILE_NAME"
echo "  - Issuer ID: $ISSUER_ID"
echo "  - Key ID: $KEY_ID"
echo "  - p8: $P8_PATH"

xcrun notarytool store-credentials "$PROFILE_NAME" \
  --issuer "$ISSUER_ID" \
  --key-id "$KEY_ID" \
  --key "$P8_PATH"

echo "✅ 完成。你可以用以下指令檢查："
echo "xcrun notarytool history --keychain-profile \"$PROFILE_NAME\""

