#!/bin/bash
set -euo pipefail

# 直發（Developer ID + Notarize + Staple）一鍵打包 DMG
#
# 前置條件：
# 1) Keychain 內必須有「Developer ID Application」憑證
# 2) 已建立 notarytool profile（建議用 setup_notarytool_api_key.sh）
#
# 使用：
#   PROFILE_NAME=konggoo-notary ./release_macos_direct_dmg.sh
#

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

PROJECT="Pikmin_Dev_Portable.xcodeproj"
SCHEME="Pikmin_Dev_Portable"
CONFIG="Release"
APP_NAME="KongGoo"

PROFILE_NAME="${PROFILE_NAME:-konggoo-notary}"

BUILD_DIR="$ROOT_DIR/build_direct"
ARCHIVE_PATH="$BUILD_DIR/${APP_NAME}.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
APP_PATH="$EXPORT_DIR/${APP_NAME}.app"
ZIP_PATH="$BUILD_DIR/${APP_NAME}.zip"

DMG_OUT_DIR="$ROOT_DIR/website/downloads"
DMG_PATH="$DMG_OUT_DIR/ios-location-simulator-mac.dmg"

echo "🔎 檢查 Developer ID Application 憑證..."
if ! security find-identity -v -p codesigning | grep -q "Developer ID Application"; then
  echo "❌ 你的 Keychain 沒有 Developer ID Application 憑證"
  echo "請先到 Apple Developer → Certificates 建立並安裝 Developer ID Application"
  exit 1
fi
SIGN_IDENTITY=$(security find-identity -v -p codesigning | sed -n 's/.*"Developer ID Application: \(.*\)"/\1/p' | head -n 1)
if [[ -z "${SIGN_IDENTITY:-}" ]]; then
  echo "❌ 找不到 Developer ID Application 簽章識別"
  exit 1
fi

echo "🔎 檢查 notarytool profile：$PROFILE_NAME"
if ! xcrun notarytool history --keychain-profile "$PROFILE_NAME" >/dev/null 2>&1; then
  echo "❌ 找不到 notarytool profile：$PROFILE_NAME"
  echo "先執行：./setup_notarytool_api_key.sh <ISSUER_ID> <KEY_ID> /path/to/AuthKey_XXXX.p8"
  exit 1
fi

rm -rf "$BUILD_DIR"
mkdir -p "$EXPORT_DIR" "$DMG_OUT_DIR"

echo "📦 Archive（macOS / Developer ID）..."
xcodebuild archive \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIG" \
  -destination "generic/platform=macOS" \
  -archivePath "$ARCHIVE_PATH" \
  SKIP_INSTALL=NO \
  BUILD_LIBRARY_FOR_DISTRIBUTION=YES

echo "🧾 產出 exportOptions.plist（Developer ID）..."
EXPORT_PLIST="$BUILD_DIR/exportOptions.plist"
cat > "$EXPORT_PLIST" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key>
  <string>developer-id</string>
  <key>signingStyle</key>
  <string>automatic</string>
  <key>destination</key>
  <string>export</string>
</dict>
</plist>
PLIST

echo "📤 Export（signed .app）..."
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist "$EXPORT_PLIST"

if [[ ! -d "$APP_PATH" ]]; then
  echo "❌ 找不到輸出的 app：$APP_PATH"
  ls -la "$EXPORT_DIR" || true
  exit 1
fi

echo "📦 內嵌 Python / pymobiledevice3 / libimobiledevice..."
bash "$ROOT_DIR/scripts/bundle_python_deps.sh" "$APP_PATH"

echo "🔏 重新簽署（包含內嵌依賴）..."
if [[ -d "$APP_PATH/Contents/Resources/lib" ]]; then
  find "$APP_PATH/Contents/Resources/lib" -type f -name "*.dylib" -print0 | \
    xargs -0 -I{} codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "{}"
fi
if [[ -d "$APP_PATH/Contents/Resources/bin" ]]; then
  find "$APP_PATH/Contents/Resources/bin" -type f -perm -111 -print0 | \
    xargs -0 -I{} codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "{}"
fi
if [[ -d "$APP_PATH/Contents/Resources/python" ]]; then
  while IFS= read -r -d '' f; do
    if file "$f" | grep -q "Mach-O"; then
      codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$f"
    fi
  done < <(find "$APP_PATH/Contents/Resources/python/bin" -type f -perm -111 -print0)
  find "$APP_PATH/Contents/Resources/python" -type f \( -name "*.so" -o -name "*.dylib" \) -print0 | \
    xargs -0 -I{} codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "{}"
fi
codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" --deep "$APP_PATH"

echo "🔍 codesign 驗證..."
codesign -vv "$APP_PATH" >/dev/null
spctl -a -vv "$APP_PATH" || true

echo "🗜️ 打包 zip 送 notarize..."
rm -f "$ZIP_PATH"
/usr/bin/ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"

echo "🧾 Notarize（提交中）..."
SUBMIT_OUTPUT=$(xcrun notarytool submit "$ZIP_PATH" --keychain-profile "$PROFILE_NAME" 2>&1)
SUBMIT_ID=$(echo "$SUBMIT_OUTPUT" | grep -i "id:" | head -1 | awk -F': ' '{print $2}' | xargs)

if [ -z "$SUBMIT_ID" ]; then
  echo "❌ 無法取得 submission ID"
  echo "$SUBMIT_OUTPUT"
  exit 1
fi

echo "📋 Submission ID: $SUBMIT_ID"
echo "⏳ 等待 notarization 完成（這可能需要幾分鐘）..."

# 輪詢檢查狀態，最多等待 30 分鐘（大型 App 可能需要更久）
MAX_WAIT=1800
ELAPSED=0
while [ $ELAPSED -lt $MAX_WAIT ]; do
  # 使用 info 而不是 log（log 只在完成時才有內容）
  STATUS_OUTPUT=$(xcrun notarytool info "$SUBMIT_ID" --keychain-profile "$PROFILE_NAME" --output-format json 2>&1)
  STATUS=$(echo "$STATUS_OUTPUT" | python3 -c "import sys, json; d=json.load(sys.stdin); print(d.get('status', 'Unknown'))" 2>/dev/null || echo "Unknown")
  
  if [ "$STATUS" = "Accepted" ]; then
    echo ""
    echo "✅ Notarization 成功！"
    break
  elif [ "$STATUS" = "Invalid" ] || [ "$STATUS" = "Rejected" ]; then
    echo ""
    echo "❌ Notarization 失敗：$STATUS"
    echo "檢查詳細日誌："
    xcrun notarytool log "$SUBMIT_ID" --keychain-profile "$PROFILE_NAME" 2>&1
    exit 1
  fi
  # 每 30 秒顯示進度
  if [ $((ELAPSED % 60)) -eq 0 ]; then
    echo ""
    echo "[$((ELAPSED/60))/$((MAX_WAIT/60)) 分鐘] 狀態: $STATUS"
  else
    echo -n "."
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
TMP_DMG_DIR="$(mktemp -d)"
cp -R "$APP_PATH" "$TMP_DMG_DIR/${APP_NAME}.app"
ln -s /Applications "$TMP_DMG_DIR/Applications"
# 清除臨時目錄中 App 的 quarantine
sudo xattr -cr "$TMP_DMG_DIR/${APP_NAME}.app" 2>/dev/null || xattr -cr "$TMP_DMG_DIR/${APP_NAME}.app" 2>/dev/null || true
rm -f "$DMG_PATH"
hdiutil create -volname "$APP_NAME" -srcfolder "$TMP_DMG_DIR" -ov -format UDZO "$DMG_PATH" >/dev/null
rm -rf "$TMP_DMG_DIR"

echo "🔐 簽名 DMG 本身（防止下載後被標記為已損毀）..."
codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$DMG_PATH" 2>&1 | head -3 || echo "⚠️  DMG 簽名失敗（繼續）"
# 清除 DMG 本身的 quarantine
xattr -cr "$DMG_PATH" 2>/dev/null || true
xattr -d com.apple.quarantine "$DMG_PATH" 2>/dev/null || true

echo "✅ 完成：$DMG_PATH"
echo "下一步：把 DMG 推送到 GitHub 讓網站更新下載（或我可以幫你一鍵 commit/push）。"

