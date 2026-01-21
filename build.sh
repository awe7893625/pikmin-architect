#!/bin/bash

PROJECT_NAME="Pikmin_Dev_Portable"
SCHEME="Pikmin_Dev_Portable"
BUILD_DIR="./build"
OUTPUT_DIR="./dist"

echo "🧹 清理舊的建置..."
rm -rf "$BUILD_DIR"
rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"

echo "🔨 開始編譯..."
xcodebuild -project "${PROJECT_NAME}.xcodeproj" \
  -scheme "$SCHEME" \
  -configuration Release \
  -derivedDataPath "$BUILD_DIR" \
  clean build

APP_PATH="$BUILD_DIR/Build/Products/Release/${PROJECT_NAME}.app"

if [ -d "$APP_PATH" ]; then
  echo "✅ 編譯成功！"
  echo "📦 複製 App..."
  cp -R "$APP_PATH" "$OUTPUT_DIR/"
  
  echo "📦 創建 DMG..."
  DMG_NAME="PikminArchitect-v1.0.dmg"
  hdiutil create -volname "Pikmin Architect" \
    -srcfolder "$OUTPUT_DIR/${PROJECT_NAME}.app" \
    -ov -format UDZO "$OUTPUT_DIR/$DMG_NAME" 2>/dev/null
  
  if [ -f "$OUTPUT_DIR/$DMG_NAME" ]; then
    echo "✅ DMG 已創建：$OUTPUT_DIR/$DMG_NAME"
    echo "📁 檔案大小：$(du -h "$OUTPUT_DIR/$DMG_NAME" | cut -f1)"
  else
    echo "⚠️  DMG 創建失敗，但 App 已複製到：$OUTPUT_DIR/${PROJECT_NAME}.app"
  fi
  
  echo ""
  echo "🎉 打包完成！"
  echo "📂 輸出目錄：$OUTPUT_DIR"
else
  echo "❌ 找不到編譯好的 App"
  echo "請檢查編譯錯誤訊息"
  exit 1
fi
