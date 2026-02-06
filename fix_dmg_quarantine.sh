#!/bin/bash
# 修復 DMG 的 quarantine 屬性並檢查公證狀態

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

echo "🔍 檢查 DMG: $DMG_PATH"
echo ""

# 檢查檔案大小
FILE_SIZE=$(ls -lh "$DMG_PATH" | awk '{print $5}')
echo "📦 檔案大小: $FILE_SIZE"
echo ""

# 檢查 quarantine 屬性
echo "🔒 檢查 quarantine 屬性..."
if xattr -l "$DMG_PATH" 2>/dev/null | grep -q "com.apple.quarantine"; then
    echo "⚠️  發現 quarantine 屬性，正在移除..."
    xattr -d com.apple.quarantine "$DMG_PATH" 2>/dev/null
    echo "✅ quarantine 屬性已移除"
else
    echo "✅ 沒有 quarantine 屬性"
fi
echo ""

# 檢查公證狀態
echo "🔏 檢查公證狀態..."
if spctl -a -t open --context context:primary-signature -v "$DMG_PATH" 2>&1 | grep -q "accepted"; then
    echo "✅ DMG 已通過公證"
else
    echo "⚠️  DMG 未通過公證檢查"
    spctl -a -t open --context context:primary-signature -v "$DMG_PATH" 2>&1 | head -3
fi
echo ""

# 檢查 staple 狀態
echo "📌 檢查 staple 狀態..."
if xcrun stapler validate "$DMG_PATH" 2>&1 | grep -q "validated"; then
    echo "✅ DMG 已正確 stapled"
else
    echo "⚠️  DMG 未正確 stapled"
    xcrun stapler validate "$DMG_PATH" 2>&1 | head -3
fi
echo ""

# 掛載 DMG 並檢查 App
echo "💿 掛載 DMG..."
MOUNT_POINT=$(hdiutil attach "$DMG_PATH" -nobrowse -noverify -noautoopen 2>&1 | grep -o '/Volumes/[^ ]*' | head -1)

if [ -n "$MOUNT_POINT" ]; then
    echo "✅ DMG 已掛載到: $MOUNT_POINT"
    
    # 查找 App
    APP_PATH=$(find "$MOUNT_POINT" -name "*.app" -type d | head -1)
    
    if [ -n "$APP_PATH" ]; then
        echo "📱 找到 App: $APP_PATH"
        echo ""
        
        # 檢查 App 的公證狀態
        echo "🔏 檢查 App 公證狀態..."
        if spctl -a -t open --context context:primary-signature -v "$APP_PATH" 2>&1 | grep -q "accepted"; then
            echo "✅ App 已通過公證"
        else
            echo "⚠️  App 未通過公證檢查"
            spctl -a -t open --context context:primary-signature -v "$APP_PATH" 2>&1 | head -3
        fi
        echo ""
        
        # 檢查 App 的 staple 狀態
        echo "📌 檢查 App staple 狀態..."
        if xcrun stapler validate "$APP_PATH" 2>&1 | grep -q "validated"; then
            echo "✅ App 已正確 stapled"
        else
            echo "⚠️  App 未正確 stapled"
            xcrun stapler validate "$APP_PATH" 2>&1 | head -3
        fi
        echo ""
        
        # 移除 App 的 quarantine 屬性
        echo "🔒 檢查 App quarantine 屬性..."
        if xattr -l "$APP_PATH" 2>/dev/null | grep -q "com.apple.quarantine"; then
            echo "⚠️  發現 quarantine 屬性，正在移除..."
            xattr -d com.apple.quarantine "$APP_PATH" 2>/dev/null
            echo "✅ quarantine 屬性已移除"
        else
            echo "✅ 沒有 quarantine 屬性"
        fi
    else
        echo "❌ 未找到 App"
    fi
    
    echo ""
    echo "💿 卸載 DMG..."
    hdiutil detach "$MOUNT_POINT" >/dev/null 2>&1
    echo "✅ DMG 已卸載"
else
    echo "❌ 無法掛載 DMG"
fi

echo ""
echo "✅ 修復完成！現在可以嘗試打開 DMG 和 App 了。"
echo ""
echo "💡 如果仍然無法打開，請："
echo "1. 前往「系統設定」→「隱私權與安全性」"
echo "2. 找到「已阻擋的應用程式」"
echo "3. 點擊「仍要打開」"
