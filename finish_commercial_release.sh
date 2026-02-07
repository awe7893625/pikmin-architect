#!/bin/bash
# 公證通過後執行：Staple DMG 並上傳為商用穩定版 Release
set -e
cd "$(dirname "$0")"
DMG_PATH="website/public/downloads/ios-location-simulator-mac.dmg"
SUB_ID="de92441b-a595-4f9c-983b-30ea0901e115"
APPLE_ID="awe7893625@gmail.com"
APP_PASSWORD="rdqz-vuhc-urqy-swqj"
TEAM_ID="PGP6W5JT82"

echo "🔍 檢查公證狀態..."
status=$(xcrun notarytool info "$SUB_ID" --apple-id "$APPLE_ID" --password "$APP_PASSWORD" --team-id "$TEAM_ID" 2>&1 | grep "status:" | sed 's/.*status: *//')
echo "   status: $status"

if [ "$status" != "Accepted" ]; then
  echo "⏳ 尚未通過，請稍後再執行此腳本。"
  exit 1
fi

echo "📌 Staple 公證票據..."
xcrun stapler staple "$DMG_PATH"
echo "✅ Staple 完成"

echo "📤 刪除舊 Release 並上傳商用穩定版..."
gh release delete v20260207-commercial --repo awe7893625/pikmin-architect --yes 2>/dev/null || true

gh release create v20260207-commercial \
  --repo awe7893625/pikmin-architect \
  --title "KongGoo v3.0 - 商用穩定版（已公證）" \
  --notes "## 商用穩定版

- 已通過 Apple 公證，雙擊即可開啟
- 連線穩定性：隧道斷線自動重啟、Watchdog 10 秒、helper 自動恢復
- 速度滑桿 5–20 km/h、循環路線、走路跟隨
- 客服改為「點擊聯絡客服」（信箱不顯示）
- 大小約 88MB，含完整 Python + pymobiledevice3

安裝：下載 DMG → 拖到 Applications → 開啟即可。" \
  --latest \
  "$DMG_PATH"

echo "✅ 完成！下載連結："
echo "   https://github.com/awe7893625/pikmin-architect/releases/tag/v20260207-commercial"
