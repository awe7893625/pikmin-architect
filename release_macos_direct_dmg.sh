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

# ✅ 若沒有 keychain profile，也可用 API Key 直接公證（推薦）
# 用法：
#   NOTARY_ISSUER_ID=... NOTARY_KEY_ID=... NOTARY_KEY_PATH=/path/AuthKey_XXXX.p8 ./release_macos_direct_dmg.sh
NOTARY_ISSUER_ID="${NOTARY_ISSUER_ID:-}"
NOTARY_KEY_ID="${NOTARY_KEY_ID:-}"
NOTARY_KEY_PATH="${NOTARY_KEY_PATH:-}"

BUILD_DIR="$ROOT_DIR/build_direct"
ARCHIVE_PATH="$BUILD_DIR/${APP_NAME}.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
APP_PATH="$EXPORT_DIR/${APP_NAME}.app"
ZIP_PATH="$BUILD_DIR/${APP_NAME}.zip"

DMG_OUT_DIR="$ROOT_DIR/website/public/downloads"
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

NOTARY_ARGS=()
if [[ -n "$NOTARY_KEY_PATH" && -n "$NOTARY_KEY_ID" && -n "$NOTARY_ISSUER_ID" ]]; then
  echo "🔎 使用 notarytool API Key（無需 keychain profile）"
  NOTARY_ARGS=(--key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID")
else
  echo "🔎 檢查 notarytool keychain profile：$PROFILE_NAME"
  if ! xcrun notarytool history --keychain-profile "$PROFILE_NAME" >/dev/null 2>&1; then
    echo "❌ 找不到 notarytool profile：$PROFILE_NAME"
    echo "請擇一："
    echo "  A) 設定 keychain profile：./setup_notarytool_api_key.sh <ISSUER_ID> <KEY_ID> /path/to/AuthKey_XXXX.p8"
    echo "  B) 或改用 API Key：NOTARY_ISSUER_ID=... NOTARY_KEY_ID=... NOTARY_KEY_PATH=... ./release_macos_direct_dmg.sh"
    exit 1
  fi
  NOTARY_ARGS=(--keychain-profile "$PROFILE_NAME")
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

echo "🧹 打包瘦身（先清理再簽名，避免簽名失效）..."
# 清除 Python 快取與無用工具套件（不影響實際功能）
PY_SITE="$APP_PATH/Contents/Resources/python/lib/python3.14/site-packages"
if [[ -d "$APP_PATH/Contents/Resources/python" ]]; then
  find "$APP_PATH/Contents/Resources/python" -type d -name "__pycache__" -prune -exec rm -rf {} + 2>/dev/null || true
  find "$APP_PATH/Contents/Resources/python" -type f \( -name "*.pyc" -o -name "*.pyo" \) -delete 2>/dev/null || true
  rm -rf "$PY_SITE/pip" "$PY_SITE/pip-"*.dist-info 2>/dev/null || true
  rm -rf "$PY_SITE/setuptools" "$PY_SITE/setuptools-"*.dist-info 2>/dev/null || true
  rm -rf "$PY_SITE/IPython" "$PY_SITE/ipython-"*.dist-info 2>/dev/null || true
  rm -rf "$PY_SITE/ipython_pygments_lexers"* 2>/dev/null || true
  rm -rf "$PY_SITE/xonsh" "$PY_SITE/xonsh-"*.dist-info 2>/dev/null || true
  rm -rf "$PY_SITE/jedi" "$PY_SITE/jedi-"*.dist-info 2>/dev/null || true
  rm -rf "$PY_SITE/pygments" "$PY_SITE/pygments-"*.dist-info 2>/dev/null || true
  rm -rf "$PY_SITE/matplotlib_inline" "$PY_SITE/matplotlib_inline-"*.dist-info 2>/dev/null || true
fi

echo "🔗 建立 lib/bin 相容性 symlinks..."
# idevice_id 編譯時尋找 @executable_path/../lib/ 的 dylib，
# 但我們實際放在 lib_arm64/bin_arm64，需要 symlink 讓它找到
RES="$APP_PATH/Contents/Resources"
for pair in "lib:lib_arm64" "bin:bin_arm64"; do
  link="${pair%%:*}"
  target="${pair##*:}"
  if [[ -d "$RES/$target" && ! -e "$RES/$link" ]]; then
    ln -s "$target" "$RES/$link"
    echo "  ✅ $link → $target"
  fi
done

echo "🔏 重新簽署（包含內嵌依賴）..."
for LIB_DIR in "$APP_PATH/Contents/Resources/lib" "$APP_PATH/Contents/Resources/lib_arm64" "$APP_PATH/Contents/Resources/lib_x86_64"; do
  if [[ -d "$LIB_DIR" ]]; then
    find "$LIB_DIR" -type f -name "*.dylib" -print0 | \
      xargs -0 -I{} codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "{}"
  fi
done
for BIN_DIR in "$APP_PATH/Contents/Resources/bin" "$APP_PATH/Contents/Resources/bin_arm64" "$APP_PATH/Contents/Resources/bin_x86_64"; do
  if [[ -d "$BIN_DIR" ]]; then
    find "$BIN_DIR" -type f -perm -111 -print0 | \
      xargs -0 -I{} codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "{}"
  fi
done
for PY_DIR in "$APP_PATH/Contents/Resources/python" "$APP_PATH/Contents/Resources/python_arm64" "$APP_PATH/Contents/Resources/python_x86_64"; do
  if [[ -d "$PY_DIR" ]]; then
    while IFS= read -r -d '' f; do
      if file "$f" | grep -q "Mach-O"; then
        codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$f"
      fi
    done < <(find "$PY_DIR/bin" -type f -perm -111 -print0)
    find "$PY_DIR" -type f \( -name "*.so" -o -name "*.dylib" \) -print0 | \
      xargs -0 -I{} codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "{}"
  fi
done
codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" --deep "$APP_PATH"

echo "🔍 codesign 驗證..."
codesign -vv "$APP_PATH" >/dev/null
spctl -a -vv "$APP_PATH" || true

echo "🗜️ 打包 zip 送 notarize..."
rm -f "$ZIP_PATH"
/usr/bin/ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"

echo "🧾 Notarize（提交中）..."
SUBMIT_OUTPUT=$(xcrun notarytool submit "$ZIP_PATH" "${NOTARY_ARGS[@]}" 2>&1)
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
  STATUS_OUTPUT=$(xcrun notarytool info "$SUBMIT_ID" "${NOTARY_ARGS[@]}" --output-format json 2>&1)
  STATUS=$(echo "$STATUS_OUTPUT" | python3 -c "import sys, json; d=json.load(sys.stdin); print(d.get('status', 'Unknown'))" 2>/dev/null || echo "Unknown")
  
  if [ "$STATUS" = "Accepted" ]; then
    echo ""
    echo "✅ Notarization 成功！"
    break
  elif [ "$STATUS" = "Invalid" ] || [ "$STATUS" = "Rejected" ]; then
    echo ""
    echo "❌ Notarization 失敗：$STATUS"
    echo "檢查詳細日誌："
    xcrun notarytool log "$SUBMIT_ID" "${NOTARY_ARGS[@]}" 2>&1
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
hdiutil create -volname "$APP_NAME" -srcfolder "$TMP_DMG_DIR" -ov -format UDZO -imagekey zlib-level=9 "$DMG_PATH" >/dev/null
rm -rf "$TMP_DMG_DIR"

echo "🔐 簽名 DMG 本身（防止下載後被標記為已損毀）..."
codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$DMG_PATH" 2>&1 | head -3 || echo "⚠️  DMG 簽名失敗（繼續）"
# 清除 DMG 本身的 quarantine
xattr -cr "$DMG_PATH" 2>/dev/null || true
xattr -d com.apple.quarantine "$DMG_PATH" 2>/dev/null || true

echo "🧾 Notarize DMG（讓一般使用者下載後更穩）..."
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
    echo "⚠️  驗證檢查發現問題，請檢查上述輸出並修復後再上傳到 GitHub Release"
    exit 1
  }
else
  echo "⚠️  找不到 validate_dmg.sh，跳過驗證"
fi
echo ""
echo "下一步：把 DMG 推送到 GitHub 讓網站更新下載（或我可以幫你一鍵 commit/push）。"

