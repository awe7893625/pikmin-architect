#!/bin/bash
# 修復 DMG 中的符號連結問題

DMG_PATH="$1"

if [ -z "$DMG_PATH" ]; then
    echo "用法: $0 <DMG檔案路徑>"
    echo "範例: $0 ~/Downloads/ios-location-simulator-mac.dmg"
    exit 1
fi

if [ ! -f "$DMG_PATH" ]; then
    echo "❌ 檔案不存在: $DMG_PATH"
    exit 1
fi

echo "🔍 修復 DMG 中的符號連結: $DMG_PATH"
echo ""

# 掛載 DMG
echo "💿 掛載 DMG..."
MOUNT_POINT=$(hdiutil attach "$DMG_PATH" -nobrowse -noverify -noautoopen 2>&1 | grep -o '/Volumes/[^ ]*' | head -1)

if [ -z "$MOUNT_POINT" ]; then
    echo "❌ 無法掛載 DMG"
    exit 1
fi

echo "✅ DMG 已掛載到: $MOUNT_POINT"

# 查找 App
APP_PATH=$(find "$MOUNT_POINT" -name "*.app" -type d | head -1)

if [ -z "$APP_PATH" ]; then
    echo "❌ 未找到 App"
    hdiutil detach "$MOUNT_POINT" >/dev/null 2>&1
    exit 1
fi

echo "📱 找到 App: $APP_PATH"
echo ""

# 修復符號連結
echo "🔗 修復符號連結..."
FIXED_COUNT=0
REMOVED_COUNT=0

find "$APP_PATH/Contents/Resources" -type l | while read -r symlink; do
    target=$(readlink "$symlink")
    
    # 如果是絕對路徑（指向 bundle 外部）
    if [[ "$target" == /* ]]; then
        if [[ -f "$target" ]]; then
            echo "  替換: $symlink -> $target"
            rm "$symlink"
            cp "$target" "$symlink"
            chmod +x "$symlink" 2>/dev/null || true
            FIXED_COUNT=$((FIXED_COUNT + 1))
        elif [[ -d "$target" ]]; then
            echo "  警告: 符號連結指向目錄，跳過: $symlink -> $target"
        else
            echo "  移除無效符號連結: $symlink -> $target"
            rm "$symlink"
            REMOVED_COUNT=$((REMOVED_COUNT + 1))
        fi
    fi
done

echo ""
echo "✅ 已修復 $FIXED_COUNT 個符號連結，移除 $REMOVED_COUNT 個無效符號連結"
echo ""

# 重新簽名 App（需要開發者證書）
echo "🔏 重新簽名 App..."
SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application: Rain (NG5D9GR926)}"

if security find-identity -v -p codesigning | grep -q "$SIGN_IDENTITY"; then
    echo "使用簽名身份: $SIGN_IDENTITY"
    codesign --force --deep --sign "$SIGN_IDENTITY" "$APP_PATH" 2>&1 | head -5
    echo ""
    echo "✅ App 已重新簽名"
else
    echo "⚠️  找不到簽名身份，跳過簽名"
fi

echo ""
echo "💿 卸載 DMG..."
hdiutil detach "$MOUNT_POINT" >/dev/null 2>&1
echo "✅ DMG 已卸載"
echo ""
echo "✅ 修復完成！"
echo ""
echo "💡 注意："
echo "1. 這個修復只是臨時解決方案"
echo "2. 建議重新下載最新版本的 DMG（已修復符號連結問題）"
echo "3. 或者重新打包 App 以確保所有問題都被修復"
