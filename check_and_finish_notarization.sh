#!/bin/bash
# 檢查 Notarization 狀態並完成打包

SUBMIT_ID="e7d439e1-61e8-4cf5-ba56-b47fad47727e"
PROFILE_NAME="konggoo-notary"
APP_PATH="build_direct/export/KongGoo.app"
DMG_PATH="website/downloads/ios-location-simulator-mac.dmg"

echo "🔍 檢查 Notarization 狀態..."
STATUS=$(xcrun notarytool info "$SUBMIT_ID" --keychain-profile "$PROFILE_NAME" --output-format json 2>&1 | python3 -c "import sys, json; d=json.load(sys.stdin); print(d.get('status', 'Unknown'))" 2>/dev/null)

if [ "$STATUS" = "Accepted" ]; then
    echo "✅ Notarization 成功！"
    echo "📌 正在 Staple..."
    xcrun stapler staple "$APP_PATH"
    
    echo "💿 重新打包 DMG..."
    rm -f "$DMG_PATH"
    TMP_DMG_DIR=$(mktemp -d)
    cp -R "$APP_PATH" "$TMP_DMG_DIR/KongGoo.app"
    ln -s /Applications "$TMP_DMG_DIR/Applications"
    hdiutil create -volname "KongGoo" -srcfolder "$TMP_DMG_DIR" -ov -format UDZO -imagekey zlib-level=9 "$DMG_PATH"
    rm -rf "$TMP_DMG_DIR"
    
    echo "✅ 完成！DMG 已更新：$DMG_PATH"
    ls -lh "$DMG_PATH"
elif [ "$STATUS" = "Invalid" ] || [ "$STATUS" = "Rejected" ]; then
    echo "❌ Notarization 失敗：$STATUS"
    xcrun notarytool log "$SUBMIT_ID" --keychain-profile "$PROFILE_NAME" 2>&1 | head -30
else
    echo "⏳ 仍在處理中：$STATUS"
    echo "請稍後再執行此腳本"
fi
