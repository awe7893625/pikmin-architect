#!/bin/bash
# 手動檢查 Notarization 狀態並 Staple（備案方案）

set -euo pipefail

PROFILE_NAME="${PROFILE_NAME:-konggoo-notary}"
SUBMIT_ID="${1:-4b6e06c9-012c-4d1d-8fd0-1047c44ebdc0}"
APP_PATH="${2:-build_direct/export/KongGoo.app}"

if [ ! -d "$APP_PATH" ]; then
  echo "❌ 找不到 App：$APP_PATH"
  exit 1
fi

echo "🔍 檢查 Submission: $SUBMIT_ID"
STATUS_OUTPUT=$(xcrun notarytool info "$SUBMIT_ID" --keychain-profile "$PROFILE_NAME" --output-format json 2>&1)

if echo "$STATUS_OUTPUT" | grep -q "does not exist\|Could not find"; then
  echo "❌ Submission ID 不存在"
  echo "$STATUS_OUTPUT"
  exit 1
fi

STATUS=$(echo "$STATUS_OUTPUT" | python3 -c "import sys, json; d=json.load(sys.stdin); print(d.get('status', 'Unknown'))" 2>/dev/null || echo "Unknown")
echo "📊 狀態: $STATUS"

if [ "$STATUS" = "Accepted" ]; then
  echo ""
  echo "✅ Notarization 已成功！正在 staple..."
  xcrun stapler staple "$APP_PATH"
  echo ""
  echo "✅ 已完成 staple"
  echo "App 路徑: $APP_PATH"
  exit 0
elif [ "$STATUS" = "Invalid" ] || [ "$STATUS" = "Rejected" ]; then
  echo ""
  echo "❌ Notarization 失敗：$STATUS"
  echo "查看詳細日誌："
  xcrun notarytool log "$SUBMIT_ID" --keychain-profile "$PROFILE_NAME" 2>&1 | head -100
  exit 1
else
  echo ""
  echo "⏳ 狀態: $STATUS（仍在處理中）"
  echo ""
  echo "建議："
  echo "  1. 繼續等待（大型 App 可能需要數小時）"
  echo "  2. 檢查 Apple Developer 網站：https://developer.apple.com/account/resources/identifiers/list/notaryCert"
  echo "  3. 如果超過 24 小時仍無回應，可能需要重新提交"
  exit 0
fi
