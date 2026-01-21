#!/bin/bash
# 設定 Admin Console 環境變數

VERCEL_TOKEN="4Lcg8iu6Zp70xSFCCqS2ijeY"
PROJECT_NAME="pikmin-architect"
TEAM_ID="team_aDZBTaEejPcweAPfcMYF63rs"
ADMIN_KEY="Hc0_Vwke0-m1_YKpVtvJ3sswAYi1senrJf_by_LcBSo"

echo "🔧 正在為專案 '$PROJECT_NAME' 設定 Admin Console 環境變數..."

# 設定 ENABLE_ADMIN_CONSOLE 環境變數
echo "設定 ENABLE_ADMIN_CONSOLE..."
RESULT1=$(curl -s -X POST \
  -H "Authorization: Bearer $VERCEL_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "key": "ENABLE_ADMIN_CONSOLE",
    "value": "1",
    "type": "encrypted",
    "target": ["production", "preview", "development"]
  }' \
  "https://api.vercel.com/v10/projects/$PROJECT_NAME/env?teamId=$TEAM_ID")

if echo "$RESULT1" | grep -q '"uid"'; then
    echo "✅ ENABLE_ADMIN_CONSOLE 環境變數已設定"
elif echo "$RESULT1" | grep -q "already exists"; then
    echo "⚠️  ENABLE_ADMIN_CONSOLE 已存在，跳過"
else
    echo "⚠️  設定 ENABLE_ADMIN_CONSOLE 時發生錯誤："
    echo "$RESULT1" | python3 -m json.tool 2>/dev/null || echo "$RESULT1"
fi

# 設定 ADMIN_KEY 環境變數
echo ""
echo "設定 ADMIN_KEY..."
RESULT2=$(curl -s -X POST \
  -H "Authorization: Bearer $VERCEL_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{
    \"key\": \"ADMIN_KEY\",
    \"value\": \"$ADMIN_KEY\",
    \"type\": \"encrypted\",
    \"target\": [\"production\", \"preview\", \"development\"]
  }" \
  "https://api.vercel.com/v10/projects/$PROJECT_NAME/env?teamId=$TEAM_ID")

if echo "$RESULT2" | grep -q '"uid"'; then
    echo "✅ ADMIN_KEY 環境變數已設定"
elif echo "$RESULT2" | grep -q "already exists"; then
    echo "⚠️  ADMIN_KEY 已存在，跳過"
else
    echo "⚠️  設定 ADMIN_KEY 時發生錯誤："
    echo "$RESULT2" | python3 -m json.tool 2>/dev/null || echo "$RESULT2"
fi

# 驗證環境變數
echo ""
echo "驗證環境變數..."
curl -s -X GET "https://api.vercel.com/v10/projects/$PROJECT_NAME/env?teamId=$TEAM_ID" \
  -H "Authorization: Bearer $VERCEL_TOKEN" | python3 -c "
import sys, json
envs = json.load(sys.stdin).get('envs', [])
admin = [e for e in envs if e.get('key') in ['ENABLE_ADMIN_CONSOLE', 'ADMIN_KEY']]
if admin:
    print('✅ 環境變數狀態：')
    for e in admin:
        status = '✅' if e.get('value') else '❌'
        targets = ', '.join(e.get('target', []))
        print(f'  {status} {e.get(\"key\")}: {\"已設定\" if e.get(\"value\") else \"未設定\"} (targets: {targets})')
else:
    print('❌ 未找到 ENABLE_ADMIN_CONSOLE 或 ADMIN_KEY')
"

echo ""
echo "📋 完成！"
echo ""
echo "🌐 訪問 Admin Console："
echo "  https://konggoo.vercel.app/admin"
echo ""
echo "🔑 Admin Key："
echo "  $ADMIN_KEY"
echo ""
echo "⚠️  如果 API 設定失敗，請手動到 Vercel Dashboard 設定："
echo "  1. 前往 https://vercel.com/dashboard"
echo "  2. 選擇專案「pikmin-architect」"
echo "  3. Settings → Environment Variables"
echo "  4. 新增 ENABLE_ADMIN_CONSOLE = 1"
echo "  5. 新增 ADMIN_KEY = $ADMIN_KEY"
