#!/bin/bash
# 創建 KongGoo 安裝器 App

INSTALLER_NAME="KongGoo安裝器.app"
INSTALLER_DIR="build_direct/installer"
APP_NAME="KongGoo.app"
SOURCE_APP="build_direct/export/$APP_NAME"

echo "🔧 創建簡單安裝器..."
echo ""

# 創建安裝器目錄結構
mkdir -p "$INSTALLER_DIR/$INSTALLER_NAME/Contents/MacOS"
mkdir -p "$INSTALLER_DIR/$INSTALLER_NAME/Contents/Resources"

# 創建 Info.plist
cat > "$INSTALLER_DIR/$INSTALLER_NAME/Contents/Info.plist" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>installer</string>
    <key>CFBundleIdentifier</key>
    <string>com.konggoo.installer</string>
    <key>CFBundleName</key>
    <string>KongGoo安裝器</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>10.15</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
EOF

# 創建安裝腳本
cat > "$INSTALLER_DIR/$INSTALLER_NAME/Contents/MacOS/installer" << 'INSTALLER_SCRIPT'
#!/bin/bash
# KongGoo 自動安裝器

APP_NAME="KongGoo.app"
INSTALLER_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
SOURCE_APP="$INSTALLER_DIR/Resources/$APP_NAME"
TARGET_DIR="/Applications"
TARGET_APP="$TARGET_DIR/$APP_NAME"

# 顯示安裝視窗
osascript << 'APPLESCRIPT'
tell application "System Events"
    activate
    display dialog "歡迎使用 KongGoo 安裝器！

將自動為您：
1. 清除安全限制
2. 安裝到 Applications 資料夾
3. 打開應用程式

點擊「安裝」開始。" buttons {"取消", "安裝"} default button "安裝" with icon note
    if button returned of result is "取消" then
        return "cancel"
    end if
end tell
APPLESCRIPT

if [ $? -ne 0 ]; then
    exit 0
fi

# 檢查來源 App 是否存在
if [ ! -d "$SOURCE_APP" ]; then
    osascript -e 'display dialog "錯誤：找不到安裝檔案" buttons {"確定"} default button "確定" with icon stop'
    exit 1
fi

# 顯示進度
osascript << 'APPLESCRIPT'
tell application "System Events"
    display dialog "正在安裝，請稍候..." buttons {} default button "確定" giving up after 2
end tell
APPLESCRIPT

# 1. 清除 quarantine 屬性
echo "清除安全限制..."
xattr -cr "$SOURCE_APP" 2>/dev/null || true
xattr -d com.apple.quarantine "$SOURCE_APP" 2>/dev/null || true

# 如果還是不行，嘗試使用 sudo
if xattr -l "$SOURCE_APP" 2>/dev/null | grep -q "com.apple.quarantine"; then
    # 請求管理員權限
    osascript << 'APPLESCRIPT'
tell application "System Events"
    activate
    display dialog "需要管理員權限來清除安全限制。

請輸入您的 Mac 密碼。" buttons {"取消", "繼續"} default button "繼續" with icon caution
end tell
APPLESCRIPT
    
    if [ $? -eq 0 ]; then
        sudo xattr -cr "$SOURCE_APP" 2>/dev/null || true
        sudo xattr -d com.apple.quarantine "$SOURCE_APP" 2>/dev/null || true
    fi
fi

# 2. 複製到 Applications
echo "安裝到 Applications..."
if [ -d "$TARGET_APP" ]; then
    rm -rf "$TARGET_APP"
fi

cp -R "$SOURCE_APP" "$TARGET_APP"

# 3. 再次清除 Applications 中的 App 的 quarantine
xattr -cr "$TARGET_APP" 2>/dev/null || true
xattr -d com.apple.quarantine "$TARGET_APP" 2>/dev/null || true

# 4. 打開 App
echo "打開應用程式..."
sleep 1
open "$TARGET_APP"

# 顯示完成訊息
osascript << 'APPLESCRIPT'
tell application "System Events"
    activate
    display dialog "✅ 安裝完成！

KongGoo 已安裝到 Applications 資料夾並已打開。

如果 App 顯示「已損毀」，請：
1. 右鍵點擊 Applications 中的 KongGoo
2. 選擇「打開」
3. 在彈出視窗中點擊「打開」" buttons {"確定"} default button "確定" with icon note
end tell
APPLESCRIPT

exit 0
INSTALLER_SCRIPT

chmod +x "$INSTALLER_DIR/$INSTALLER_NAME/Contents/MacOS/installer"

# 複製 KongGoo.app 到安裝器的 Resources
echo "複製 KongGoo.app 到安裝器..."
cp -R "$SOURCE_APP" "$INSTALLER_DIR/$INSTALLER_NAME/Contents/Resources/"

# 簽名安裝器
echo "簽名安裝器..."
SIGN_IDENTITY=$(security find-identity -v -p codesigning | grep "Developer ID" | head -1 | sed 's/.*"\(.*\)".*/\1/')
if [ -n "$SIGN_IDENTITY" ]; then
    codesign --force --deep --sign "$SIGN_IDENTITY" --options runtime --timestamp "$INSTALLER_DIR/$INSTALLER_NAME"
    echo "✅ 安裝器已簽名"
else
    echo "⚠️  未找到 Developer ID 證書，跳過簽名"
fi

echo ""
echo "✅ 安裝器已創建：$INSTALLER_DIR/$INSTALLER_NAME"
echo ""
echo "📦 下一步：將安裝器打包成 ZIP 供下載"
