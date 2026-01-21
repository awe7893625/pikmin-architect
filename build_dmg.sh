#!/bin/bash

# iOS定位模擬器 - Ad-hoc 簽名 DMG 打包腳本
# 此腳本使用 Ad-hoc 簽名，不需要 Developer ID 證書

set -e  # 遇到錯誤立即停止

# 顏色定義
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 配置變數
SCHEME="Pikmin_Dev_Portable"
CONFIGURATION="Debug"
# Xcode 產物名稱（目前專案顯示為 KongGoo.app）
APP_NAME="KongGoo"
DMG_NAME="ios-location-simulator-mac"
OUTPUT_DIR="website/downloads"
BACKGROUND_IMAGE="website/downloads/.background/dmg-background.png"

# 獲取腳本所在目錄
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$SCRIPT_DIR"

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}  iOS定位模擬器 - DMG 打包腳本${NC}"
echo -e "${BLUE}  (使用 Ad-hoc 簽名)${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

# 步驟 1: 檢查依賴
echo -e "${YELLOW}[1/7] 檢查依賴...${NC}"
if ! command -v xcodebuild &> /dev/null; then
    echo -e "${RED}❌ 錯誤：找不到 xcodebuild，請確保已安裝 Xcode${NC}"
    exit 1
fi
if ! command -v hdiutil &> /dev/null; then
    echo -e "${RED}❌ 錯誤：找不到 hdiutil${NC}"
    exit 1
fi
echo -e "${GREEN}✅ 依賴檢查完成${NC}"
echo ""

# 步驟 2: 建置 App
echo -e "${YELLOW}[2/7] 建置 App...${NC}"
DERIVED_DATA_PATH="$HOME/Library/Developer/Xcode/DerivedData/Pikmin_Dev_Portable-build"
BUILD_PATH="$DERIVED_DATA_PATH/Build/Products/$CONFIGURATION/${APP_NAME}.app"

# 清理舊的建置
echo "清理舊的建置..."
xcodebuild clean -scheme "$SCHEME" -configuration "$CONFIGURATION" -derivedDataPath "$DERIVED_DATA_PATH" > /dev/null 2>&1 || true

# 建置 App
echo "正在建置 App..."
xcodebuild -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    build

# 查找建置後的 App
if [ ! -d "$BUILD_PATH" ]; then
    ACTUAL_BUILD_PATH=$(find "$DERIVED_DATA_PATH" -name "${APP_NAME}.app" -type d | head -1)
    if [ -z "$ACTUAL_BUILD_PATH" ]; then
        echo -e "${RED}❌ 錯誤：找不到建置後的 App${NC}"
        echo "請檢查 Xcode 建置是否成功"
        exit 1
    fi
    BUILD_PATH="$ACTUAL_BUILD_PATH"
fi

echo -e "${GREEN}✅ App 建置完成：$BUILD_PATH${NC}"
echo ""

# 步驟 3: 創建臨時工作目錄
echo -e "${YELLOW}[3/7] 準備打包環境...${NC}"
TEMP_DIR=$(mktemp -d)
echo "臨時目錄：$TEMP_DIR"

# 複製 App 到臨時目錄
APP_COPY="$TEMP_DIR/${APP_NAME}.app"
cp -R "$BUILD_PATH" "$APP_COPY"
echo -e "${GREEN}✅ App 已複製到臨時目錄${NC}"
echo ""

# 步驟 4: 清理屬性
echo -e "${YELLOW}[4/7] 清理 App 屬性...${NC}"
echo "移除所有擴充屬性（quarantine）..."
xattr -cr "$APP_COPY" 2>/dev/null || true

echo "移除舊的簽名..."
codesign --remove-signature "$APP_COPY" 2>/dev/null || true

echo "設置正確的權限..."
chmod -R 755 "$APP_COPY"

echo -e "${GREEN}✅ 屬性清理完成${NC}"
echo ""

# 步驟 5: Ad-hoc 簽名
echo -e "${YELLOW}[5/7] 進行 Ad-hoc 簽名...${NC}"
echo "使用 Ad-hoc 簽名（不需要 Developer ID 證書）..."

# 先簽名所有內部框架和可執行文件
find "$APP_COPY" -type f -name "*.dylib" -exec codesign --force --sign - {} \; 2>/dev/null || true
find "$APP_COPY" -type f -perm +111 -exec codesign --force --sign - {} \; 2>/dev/null || true

# 然後簽名整個 App
codesign --force --deep --sign - --options runtime --timestamp=none "$APP_COPY"
if [ $? -eq 0 ]; then
    echo -e "${GREEN}✅ Ad-hoc 簽名完成${NC}"
    # 驗證簽名
    codesign -vv "$APP_COPY" 2>&1 | head -3
else
    echo -e "${RED}❌ 簽名失敗${NC}"
    rm -rf "$TEMP_DIR"
    exit 1
fi
echo ""

# 步驟 6: 準備 DMG 內容
echo -e "${YELLOW}[6/7] 準備 DMG 內容...${NC}"
# 創建 Applications 連結
ln -s /Applications "$TEMP_DIR/Applications"

# 複製背景圖片（如果存在）
if [ -f "$BACKGROUND_IMAGE" ]; then
    mkdir -p "$TEMP_DIR/.background"
    cp "$BACKGROUND_IMAGE" "$TEMP_DIR/.background/"
    echo -e "${GREEN}✅ 背景圖片已複製${NC}"
else
    echo -e "${YELLOW}⚠️  背景圖片不存在，跳過${NC}"
fi
echo ""

# 步驟 7: 創建 DMG
echo -e "${YELLOW}[7/7] 創建 DMG 文件...${NC}"
mkdir -p "$OUTPUT_DIR"
DMG_PATH="$OUTPUT_DIR/${DMG_NAME}.dmg"

# 移除舊的 DMG
rm -f "$DMG_PATH"

# 創建 DMG
echo "正在創建 DMG..."
hdiutil create -volname "$APP_NAME" \
    -fs HFS+ \
    -srcfolder "$TEMP_DIR" \
    -format UDZO \
    -ov "$DMG_PATH" 2>&1 | tail -1

if [ ! -f "$DMG_PATH" ]; then
    echo -e "${RED}❌ 錯誤：DMG 創建失敗${NC}"
    rm -rf "$TEMP_DIR"
    exit 1
fi

echo -e "${GREEN}✅ DMG 創建完成${NC}"
echo ""

# 步驟 8: 自定義 DMG 視窗樣式
echo -e "${YELLOW}[8/8] 自定義 DMG 視窗樣式...${NC}"
MOUNT_POINT=$(mktemp -d)
hdiutil attach "$DMG_PATH" -mountpoint "$MOUNT_POINT" -noverify -noautofsck 2>&1 | tail -1

if [ -d "$MOUNT_POINT" ]; then
    sleep 2
    osascript << APPLESCRIPT
tell application "Finder"
    try
        set theDisk to disk "$APP_NAME"
        open theDisk
        delay 1
        set theWindow to container window of theDisk
        if theWindow exists then
            set current view of theWindow to icon view
            set toolbar visible of theWindow to false
            set statusbar visible of theWindow to false
            set bounds of theWindow to {400, 200, 880, 450}
            set opts to icon view options of theWindow
            set arrangement of opts to not arranged
            set icon size of opts to 72
            try
                set bgFile to file ".background:dmg-background.png" of theDisk
                set background picture of opts to bgFile
            end try
            set position of item "${APP_NAME}.app" of theWindow to {420, 120}
            set position of item "Applications" of theWindow to {120, 120}
            close theWindow
            delay 1
            open theWindow
            delay 1
            update theDisk without registering applications
        end if
    end try
end tell
APPLESCRIPT
    echo -e "${GREEN}✅ 視窗樣式設置完成${NC}"
    sleep 1
    hdiutil detach "$MOUNT_POINT" 2>/dev/null || hdiutil detach disk* 2>/dev/null || true
    rm -rf "$MOUNT_POINT"
fi
echo ""

# 步驟 9: 最終清理和驗證
echo -e "${YELLOW}[9/9] 最終清理和驗證...${NC}"
# 移除 DMG 的擴充屬性
xattr -cr "$DMG_PATH" 2>/dev/null || true

# 設置正確的權限
chmod 644 "$DMG_PATH"

# 驗證 DMG 完整性
echo "驗證 DMG 完整性..."
hdiutil verify "$DMG_PATH" 2>&1 | tail -3 || echo "⚠️  DMG 驗證完成（可能有警告，但不影響使用）"

# 清理臨時目錄
rm -rf "$TEMP_DIR"

echo -e "${GREEN}✅ 清理完成${NC}"
echo ""

# 顯示結果
DMG_SIZE=$(du -h "$DMG_PATH" | cut -f1)
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  ✅ DMG 打包完成！${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "${BLUE}📦 DMG 文件資訊：${NC}"
echo "   路徑：$DMG_PATH"
echo "   大小：$DMG_SIZE"
echo ""

# 顯示用戶指引
echo -e "${YELLOW}========================================${NC}"
echo -e "${YELLOW}  📋 用戶下載後的使用指引${NC}"
echo -e "${YELLOW}========================================${NC}"
echo ""
echo -e "${BLUE}由於使用 Ad-hoc 簽名，用戶需要按照以下步驟打開：${NC}"
echo ""
echo -e "${GREEN}步驟 1：打開 DMG${NC}"
echo "   • 右鍵點擊 DMG 文件"
echo "   • 選擇「打開」（不要直接雙擊）"
echo "   • 系統提示時，點擊「打開」按鈕"
echo ""
echo -e "${GREEN}步驟 2：打開 App${NC}"
echo "   • DMG 打開後，右鍵點擊 App 圖標"
echo "   • 選擇「打開」"
echo "   • 如果系統提示「無法驗證開發者」，請："
echo "     1. 前往「系統設定」>「隱私權與安全性」"
echo "     2. 找到「已阻擋使用 ${APP_NAME}，因為無法驗證開發者」"
echo "     3. 點擊「仍要開啟」按鈕"
echo ""
echo -e "${YELLOW}💡 提示：${NC}"
echo "   • 這是 macOS 的安全機制，不是文件損壞"
echo "   • 只需要第一次打開時確認，之後就可以正常使用"
echo "   • 如果還是無法打開，請檢查 macOS 版本（需要 macOS 12.0+）"
echo ""
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}  下一步：將 DMG 上傳到網站${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""
echo "1. DMG 文件已準備好：$DMG_PATH"
echo "2. 提交到 Git："
echo "   git add $OUTPUT_DIR/${DMG_NAME}.dmg"
echo "   git commit -m \"更新 macOS 版本（Ad-hoc 簽名）\""
echo "   git push"
echo ""
echo "3. Vercel 會自動部署，用戶就可以下載了"
echo ""
