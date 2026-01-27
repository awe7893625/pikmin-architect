#!/bin/bash
# DMG 完整驗證腳本
# 用法: ./validate_dmg.sh <DMG檔案路徑>

set -euo pipefail

DMG_PATH="${1:-}"

if [ -z "$DMG_PATH" ]; then
    echo "用法: $0 <DMG檔案路徑>"
    echo "範例: $0 website/public/downloads/ios-location-simulator-mac.dmg"
    exit 1
fi

if [ ! -f "$DMG_PATH" ]; then
    echo "❌ 檔案不存在: $DMG_PATH"
    exit 1
fi

echo "=========================================="
echo "🔍 DMG 完整驗證檢查"
echo "=========================================="
echo "檔案: $DMG_PATH"
echo ""

ERRORS=0
WARNINGS=0

# 1. 檢查檔案大小
echo "1️⃣ 檢查檔案大小..."
FILE_SIZE=$(stat -f%z "$DMG_PATH" 2>/dev/null || stat -c%s "$DMG_PATH" 2>/dev/null)
FILE_SIZE_MB=$((FILE_SIZE / 1024 / 1024))
FILE_SIZE_HUMAN=$(ls -lh "$DMG_PATH" | awk '{print $5}')

echo "   大小: $FILE_SIZE_HUMAN ($FILE_SIZE_MB MB)"
if [ $FILE_SIZE_MB -lt 100 ]; then
    echo "   ❌ 檔案太小（< 100 MB），可能有問題"
    ERRORS=$((ERRORS + 1))
elif [ $FILE_SIZE_MB -gt 200 ]; then
    echo "   ⚠️  檔案太大（> 200 MB），可能包含不必要的檔案"
    WARNINGS=$((WARNINGS + 1))
else
    echo "   ✅ 檔案大小正常"
fi
echo ""

# 2. 檢查簽名（注意：codesign / stapler 有時會回非 0 exit code，但輸出仍顯示有效；因此用輸出文字判斷）
echo "2️⃣ 檢查 DMG 簽名..."
CODESIGN_OUT="$(codesign -vv "$DMG_PATH" 2>&1 || true)"
if echo "$CODESIGN_OUT" | grep -q "valid on disk"; then
    echo "   ✅ DMG 簽名有效"
    echo "$CODESIGN_OUT" | grep -E "(valid on disk|satisfies)" | sed 's/^/   /'
else
    echo "   ❌ DMG 簽名無效或不存在"
    echo "$CODESIGN_OUT" | head -5 | sed 's/^/   /'
    ERRORS=$((ERRORS + 1))
fi
echo ""

# 3. 檢查公證狀態
echo "3️⃣ 檢查 DMG 公證狀態..."
SPCTL_OUTPUT=$(spctl -a -t open --context context:primary-signature -v "$DMG_PATH" 2>&1)
if echo "$SPCTL_OUTPUT" | grep -q "accepted"; then
    echo "   ✅ DMG 已通過公證"
    echo "$SPCTL_OUTPUT" | grep "accepted" | sed 's/^/   /'
else
    echo "   ❌ DMG 未通過公證"
    echo "$SPCTL_OUTPUT" | head -3 | sed 's/^/   /'
    ERRORS=$((ERRORS + 1))
fi
echo ""

# 4. 檢查 Staple 狀態
echo "4️⃣ 檢查 DMG Staple 狀態..."
STAPLE_OUTPUT="$(xcrun stapler validate "$DMG_PATH" 2>&1 || true)"
if echo "$STAPLE_OUTPUT" | grep -Eq "validated|The validate action worked"; then
    echo "   ✅ DMG 已正確 stapled"
    echo "$STAPLE_OUTPUT" | head -3 | sed 's/^/   /'
else
    echo "   ❌ DMG 未正確 stapled"
    echo "$STAPLE_OUTPUT" | head -3 | sed 's/^/   /'
    ERRORS=$((ERRORS + 1))
fi
echo ""

# 5. 檢查 Quarantine 屬性
echo "5️⃣ 檢查 Quarantine 屬性..."
XATTR_OUTPUT=$(xattr -l "$DMG_PATH" 2>&1)
if echo "$XATTR_OUTPUT" | grep -q "com.apple.quarantine"; then
    echo "   ⚠️  發現 quarantine 屬性"
    echo "$XATTR_OUTPUT" | grep "quarantine" | sed 's/^/   /'
    echo "   建議移除: xattr -d com.apple.quarantine \"$DMG_PATH\""
    WARNINGS=$((WARNINGS + 1))
else
    echo "   ✅ 沒有 quarantine 屬性"
fi
echo ""

# 6. 掛載並檢查 App
echo "6️⃣ 掛載 DMG 並檢查 App..."
MOUNT_POINT=$(hdiutil attach "$DMG_PATH" -nobrowse -noverify -noautoopen 2>&1 | grep -o '/Volumes/[^ ]*' | head -1)

if [ -z "$MOUNT_POINT" ]; then
    echo "   ❌ 無法掛載 DMG"
    hdiutil attach "$DMG_PATH" -nobrowse -noverify -noautoopen 2>&1 | head -5 | sed 's/^/   /'
    ERRORS=$((ERRORS + 1))
else
    echo "   ✅ DMG 已掛載到: $MOUNT_POINT"
    
    APP_PATH=$(find "$MOUNT_POINT" -name "*.app" -type d | head -1)
    
    if [ -z "$APP_PATH" ]; then
        echo "   ❌ 未找到 App"
        ERRORS=$((ERRORS + 1))
    else
        echo "   ✅ 找到 App: $APP_PATH"
        echo ""
        
        # 6.1 檢查 App 簽名
        echo "   6.1 檢查 App 簽名..."
        APP_CODESIGN_OUT="$(codesign -vv "$APP_PATH" 2>&1 || true)"
        if echo "$APP_CODESIGN_OUT" | grep -q "valid on disk"; then
            echo "      ✅ App 簽名有效"
        else
            echo "      ❌ App 簽名無效"
            echo "$APP_CODESIGN_OUT" | head -3 | sed 's/^/      /'
            ERRORS=$((ERRORS + 1))
        fi
        echo ""
        
        # 6.2 檢查 App 公證狀態
        echo "   6.2 檢查 App 公證狀態..."
        APP_SPCTL_OUTPUT=$(spctl -a -t open --context context:primary-signature -v "$APP_PATH" 2>&1)
        if echo "$APP_SPCTL_OUTPUT" | grep -q "accepted"; then
            echo "      ✅ App 已通過公證"
        else
            echo "      ❌ App 未通過公證"
            echo "$APP_SPCTL_OUTPUT" | head -3 | sed 's/^/      /'
            ERRORS=$((ERRORS + 1))
        fi
        echo ""
        
        # 6.3 檢查 App Staple 狀態
        echo "   6.3 檢查 App Staple 狀態..."
        APP_STAPLE_OUTPUT="$(xcrun stapler validate "$APP_PATH" 2>&1 || true)"
        if echo "$APP_STAPLE_OUTPUT" | grep -Eq "validated|The validate action worked"; then
            echo "      ✅ App 已正確 stapled"
        else
            echo "      ❌ App 未正確 stapled"
            echo "$APP_STAPLE_OUTPUT" | head -3 | sed 's/^/      /'
            ERRORS=$((ERRORS + 1))
        fi
        echo ""
        
        # 6.4 檢查 App Quarantine 屬性
        echo "   6.4 檢查 App Quarantine 屬性..."
        APP_XATTR_OUTPUT=$(xattr -l "$APP_PATH" 2>&1)
        if echo "$APP_XATTR_OUTPUT" | grep -q "com.apple.quarantine"; then
            echo "      ⚠️  發現 quarantine 屬性"
            echo "$APP_XATTR_OUTPUT" | grep "quarantine" | sed 's/^/      /'
            WARNINGS=$((WARNINGS + 1))
        else
            echo "      ✅ 沒有 quarantine 屬性"
        fi
        echo ""
        
        # 6.5 檢查 Python 架構
        echo "   6.5 檢查 Python 架構..."
        if [ -d "$APP_PATH/Contents/Resources/python_arm64" ]; then
            echo "      ✅ 找到 arm64 Python"
        else
            echo "      ⚠️  未找到 arm64 Python"
            WARNINGS=$((WARNINGS + 1))
        fi
        
        if [ -d "$APP_PATH/Contents/Resources/python_x86_64" ]; then
            echo "      ✅ 找到 x86_64 Python"
        else
            echo "      ⚠️  未找到 x86_64 Python"
            WARNINGS=$((WARNINGS + 1))
        fi
    fi
    
    # 卸載 DMG
    echo ""
    echo "   卸載 DMG..."
    hdiutil detach "$MOUNT_POINT" >/dev/null 2>&1
    echo "   ✅ DMG 已卸載"
fi

echo ""
echo "=========================================="
echo "📊 驗證結果總結"
echo "=========================================="
echo "錯誤: $ERRORS"
echo "警告: $WARNINGS"
echo ""

if [ $ERRORS -eq 0 ] && [ $WARNINGS -eq 0 ]; then
    echo "✅ 所有檢查通過！DMG 可以安全發布。"
    exit 0
elif [ $ERRORS -eq 0 ]; then
    echo "⚠️  有 $WARNINGS 個警告，但沒有錯誤。建議修復警告後再發布。"
    exit 0
else
    echo "❌ 發現 $ERRORS 個錯誤！請修復後重新打包。"
    exit 1
fi
