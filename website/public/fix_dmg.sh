#!/bin/bash
# KongGoo DMG 自動修復腳本
# 如果下載後顯示「已損毀」，執行此腳本即可修復

echo "🔧 KongGoo DMG 修復腳本"
echo ""

DMG_PATH="$HOME/Downloads/ios-location-simulator-mac.dmg"
if [ ! -f "$DMG_PATH" ]; then
    echo "❌ 找不到 DMG 檔案：$DMG_PATH"
    echo "請將下載的 DMG 檔案放在 Downloads 資料夾"
    exit 1
fi

echo "📦 找到 DMG：$DMG_PATH"
echo ""

# 掛載 DMG
echo "📂 掛載 DMG..."
MOUNT_POINT=$(hdiutil attach "$DMG_PATH" -quiet -nobrowse | tail -1 | awk '{print $3}')
if [ -z "$MOUNT_POINT" ]; then
    echo "❌ 無法掛載 DMG"
    exit 1
fi

APP_PATH="$MOUNT_POINT/KongGoo.app"
if [ ! -d "$APP_PATH" ]; then
    echo "❌ 找不到 App：$APP_PATH"
    hdiutil detach "$MOUNT_POINT" -quiet
    exit 1
fi

echo "✅ DMG 已掛載：$MOUNT_POINT"
echo ""

# 清除 quarantine
echo "🧹 清除 quarantine 屬性..."
xattr -cr "$APP_PATH" 2>/dev/null || sudo xattr -cr "$APP_PATH"
xattr -d com.apple.quarantine "$APP_PATH" 2>/dev/null || sudo xattr -d com.apple.quarantine "$APP_PATH" 2>/dev/null

# 清除 DMG 本身的 quarantine
xattr -cr "$DMG_PATH" 2>/dev/null || sudo xattr -cr "$DMG_PATH"
xattr -d com.apple.quarantine "$DMG_PATH" 2>/dev/null || sudo xattr -d com.apple.quarantine "$DMG_PATH" 2>/dev/null

echo "✅ Quarantine 已清除"
echo ""

# 驗證簽名
echo "🔍 驗證 App 簽名..."
if codesign -vv "$APP_PATH" 2>&1 | grep -q "valid on disk"; then
    echo "✅ App 簽名有效"
else
    echo "⚠️  App 簽名驗證失敗"
fi

# 卸載 DMG
echo ""
echo "📂 卸載 DMG..."
hdiutil detach "$MOUNT_POINT" -quiet

echo ""
echo "✅ 修復完成！"
echo "現在可以雙擊 DMG 打開，應該不會再顯示「已損毀」了"
echo ""
echo "如果還是顯示「已損毀」，請："
echo "1. 右鍵點擊 DMG > 選擇「打開」"
echo "2. 或在「系統設定」>「隱私權與安全性」中允許"
