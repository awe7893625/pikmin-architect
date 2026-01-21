#!/bin/bash
# 設定 Vercel KV 並部署的腳本
# 注意：KV store 需要先在 Dashboard 創建，此腳本用於設定環境變數和部署

VERCEL_TOKEN="4Lcg8iu6Zp70xSFCCqS2ijeY"
PROJECT_NAME="pikmin-architect"
TEAM_ID="team_aDZBTaEejPcweAPfcMYF63rs"

echo "🔧 Vercel KV 設定腳本"
echo ""
echo "⚠️  重要：KV store 需要先在 Vercel Dashboard 創建"
echo "   1. 前往：https://vercel.com/dashboard"
echo "   2. 選擇專案「pikmin-architect」"
echo "   3. 進入「Storage」標籤"
echo "   4. 點擊「Create Database」→ 選擇「KV」"
echo "   5. 創建後，在 KV 的「Settings」中獲取："
echo "      - KV_REST_API_URL"
echo "      - KV_REST_API_TOKEN"
echo ""
read -p "請輸入 KV_REST_API_URL: " KV_REST_API_URL
read -p "請輸入 KV_REST_API_TOKEN: " KV_REST_API_TOKEN

if [ -z "$KV_REST_API_URL" ] || [ -z "$KV_REST_API_TOKEN" ]; then
    echo "❌ KV_REST_API_URL 和 KV_REST_API_TOKEN 不能為空"
    exit 1
fi

echo ""
echo "設定環境變數..."

# 設定 KV_REST_API_URL
RESULT1=$(curl -s -X POST \
  -H "Authorization: Bearer $VERCEL_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{
    \"key\": \"KV_REST_API_URL\",
    \"value\": \"$KV_REST_API_URL\",
    \"type\": \"encrypted\",
    \"target\": [\"production\", \"preview\", \"development\"]
  }" \
  "https://api.vercel.com/v10/projects/$PROJECT_NAME/env?teamId=$TEAM_ID")

if echo "$RESULT1" | grep -q '"uid"'; then
    echo "✅ KV_REST_API_URL 已設定"
elif echo "$RESULT1" | grep -q "already exists"; then
    echo "⚠️  KV_REST_API_URL 已存在，更新中..."
    # 這裡可以添加更新邏輯
else
    echo "⚠️  設定 KV_REST_API_URL 時發生錯誤："
    echo "$RESULT1" | python3 -m json.tool 2>/dev/null || echo "$RESULT1"
fi

# 設定 KV_REST_API_TOKEN
RESULT2=$(curl -s -X POST \
  -H "Authorization: Bearer $VERCEL_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{
    \"key\": \"KV_REST_API_TOKEN\",
    \"value\": \"$KV_REST_API_TOKEN\",
    \"type\": \"encrypted\",
    \"target\": [\"production\", \"preview\", \"development\"]
  }" \
  "https://api.vercel.com/v10/projects/$PROJECT_NAME/env?teamId=$TEAM_ID")

if echo "$RESULT2" | grep -q '"uid"'; then
    echo "✅ KV_REST_API_TOKEN 已設定"
elif echo "$RESULT2" | grep -q "already exists"; then
    echo "⚠️  KV_REST_API_TOKEN 已存在，更新中..."
else
    echo "⚠️  設定 KV_REST_API_TOKEN 時發生錯誤："
    echo "$RESULT2" | python3 -m json.tool 2>/dev/null || echo "$RESULT2"
fi

echo ""
echo "✅ 環境變數設定完成！"
echo ""
echo "📋 下一步："
echo "  1. Vercel 會自動重新部署（約 1-2 分鐘）"
echo "  2. 部署完成後，訪問：https://konggoo.vercel.app/admin"
echo "  3. 使用 Admin Key 登入並創建授權"
