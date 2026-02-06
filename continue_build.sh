#!/bin/bash
# 繼續完成打包流程（從 Notarization 之後開始）

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

APP_NAME="KongGoo"
APP_PATH="build_direct/export/${APP_NAME}.app"
DMG_OUT_DIR="website/public/downloads"
DMG_PATH="$DMG_OUT_DIR/ios-location-simulator-mac.dmg"

NOTARY_ISSUER_ID="${NOTARY_ISSUER_ID:-b627bc7d-4dd7-4d57-bae2-e35730c37071}"
NOTARY_KEY_ID="${NOTARY_KEY_ID:-NG5D9GR926}"
NOTARY_KEY_PATH="${NOTARY_KEY_PATH:-/Users/rain/Desktop/AI資料/AuthKey_NG5D9GR926.p8}"

SIGN_IDENTITY=$(security find-identity -v -p codesigning | sed -n 's/.*"Developer ID Application: \(.*\)"/\1/p' | head -n 1)

NOTARY_ARGS=(--key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID")

SUBMIT_ID="6c98fd3a-07e8-4992-8d95-d4d1c2b4b5b9"

echo "🔍 檢查 Notarization 狀態..."
MAX_WAIT=1800  # 30 分鐘
ELAPSED=0

while [ $ELAPSED -lt $MAX_WAIT ]; do
    STATUS_OUTPUT=$(xcrun notarytool info "$SUBMIT_ID" "${NOTARY_ARGS[@]}" --output-format json 2>&1)
    STATUS=$(echo "$STATUS_OUTPUT" | python3 -c "import sys, json; d=json.load(sys.stdin); print(d.get('status', 'Unknown'))" 2>/dev/null || echo "Unknown")
    
    if [ "$STATUS" = "Accepted" ]; then
        echo ""
        echo "✅ Notarization 已完成！"
        break
    elif [ "$STATUS" = "Invalid" ] || [ "$STATUS" = "Rejected" ]; then
        echo ""
        echo "❌ Notarization 失敗：$STATUS"
        xcrun notarytool log "$SUBMIT_ID" "${NOTARY_ARGS[@]}" 2>&1
        exit 1
    else
        if [ $((ELAPSED % 60)) -eq 0 ]; then
            echo ""
            echo "[$((ELAPSED/60))/$((MAX_WAIT/60)) 分鐘] 狀態: $STATUS"
        else
            echo -n "."
        fi
    fi
    sleep 10
    ELAPSED=$((ELAPSED + 10))
done

if [ $ELAPSED -ge $MAX_WAIT ]; then
    echo ""
    echo "⚠️  等待超時，但繼續嘗試 staple（可能已經完成）"
fi

echo ""
echo "📌 Staple..."
xcrun stapler staple "$APP_PATH"

echo "🧹 清除 quarantine..."
xattr -cr "$APP_PATH" || true

echo "💿 產出 DMG（覆蓋網站下載檔）..."
mkdir -p "$DMG_OUT_DIR"
TMP_DMG_DIR="$(mktemp -d)"
cp -R "$APP_PATH" "$TMP_DMG_DIR/${APP_NAME}.app"
ln -s /Applications "$TMP_DMG_DIR/Applications"
xattr -cr "$TMP_DMG_DIR/${APP_NAME}.app" 2>/dev/null || true
rm -f "$DMG_PATH"
hdiutil create -volname "$APP_NAME" -srcfolder "$TMP_DMG_DIR" -ov -format UDZO -imagekey zlib-level=9 "$DMG_PATH" >/dev/null
rm -rf "$TMP_DMG_DIR"

echo "🔐 簽名 DMG 本身..."
codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$DMG_PATH" 2>&1 | head -3 || echo "⚠️  DMG 簽名失敗（繼續）"
xattr -cr "$DMG_PATH" 2>/dev/null || true
xattr -d com.apple.quarantine "$DMG_PATH" 2>/dev/null || true

echo "🧾 Notarize DMG..."
DMG_SUBMIT=$(xcrun notarytool submit "$DMG_PATH" "${NOTARY_ARGS[@]}" --wait 2>&1)
echo "$DMG_SUBMIT" | tail -6

echo "📌 Staple DMG..."
xcrun stapler staple "$DMG_PATH" >/dev/null || true
xcrun stapler validate "$DMG_PATH" >/dev/null || true

echo "✅ 完成：$DMG_PATH"
echo ""
echo "🔍 執行驗證檢查..."
if [ -f "$ROOT_DIR/validate_dmg.sh" ]; then
  bash "$ROOT_DIR/validate_dmg.sh" "$DMG_PATH" || {
    echo ""
    echo "⚠️  驗證檢查發現問題，請檢查上述輸出"
    exit 1
  }
fi
