#!/bin/bash
# 設定單一入口網址：只保留 konggoo.tw，舊網址自動 301 轉向

VERCEL_TOKEN="vck_0XpZDyIhETst81ArRYiDMM4TYb9TBvV5DnVPUpRoFF3nhgYm1J4TjJVD"
TEAM_ID="team_aDZBTaEejPcweAPfcMYF63rs"

# 請填入你的 Vercel 專案名稱（例如：pikmin-architect）
read -p "請輸入你的 Vercel 專案名稱（例如：pikmin-architect）: " PROJECT_NAME

if [ -z "$PROJECT_NAME" ]; then
    echo "❌ 專案名稱不能為空"
    exit 1
fi

echo "🔧 正在為專案 '$PROJECT_NAME' 設定環境變數..."

# 設定 PRIMARY_HOST 環境變數（Production）
RESULT=$(curl -s -X POST \
  -H "Authorization: Bearer $VERCEL_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "key": "PRIMARY_HOST",
    "value": "konggoo.tw",
    "type": "encrypted",
    "target": ["production"]
  }' \
  "https://api.vercel.com/v10/projects/$PROJECT_NAME/env?teamId=$TEAM_ID")

if echo "$RESULT" | grep -q '"uid"'; then
    echo "✅ PRIMARY_HOST 環境變數已設定"
else
    echo "⚠️  設定 PRIMARY_HOST 時發生錯誤："
    echo "$RESULT" | python3 -m json.tool 2>/dev/null || echo "$RESULT"
fi

# 設定 SUCCESS_URL 環境變數（Production）
RESULT2=$(curl -s -X POST \
  -H "Authorization: Bearer $VERCEL_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "key": "SUCCESS_URL",
    "value": "https://konggoo.tw",
    "type": "encrypted",
    "target": ["production"]
  }' \
  "https://api.vercel.com/v10/projects/$PROJECT_NAME/env?teamId=$TEAM_ID")

if echo "$RESULT2" | grep -q '"uid"'; then
    echo "✅ SUCCESS_URL 環境變數已設定"
else
    echo "⚠️  設定 SUCCESS_URL 時發生錯誤（可能已存在）："
    echo "$RESULT2" | python3 -m json.tool 2>/dev/null || echo "$RESULT2"
fi

echo ""
echo "📋 下一步："
echo "1. 前往 Vercel Dashboard → $PROJECT_NAME → Settings → Domains"
echo "2. 新增域名：konggoo.tw（以及 www.konggoo.tw，如果需要）"
echo "3. 按照 Vercel 指示設定 DNS（A/CNAME 記錄）"
echo "4. 等待 DNS 生效後，重新部署一次專案"
echo ""
echo "✅ 完成後，所有對 https://pikmin-architect.vercel.app 的訪問都會自動 301 轉到 https://konggoo.tw"
