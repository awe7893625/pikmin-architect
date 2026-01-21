#!/bin/bash
# 使用 Vercel Token 部署的腳本

VERCEL_TOKEN="${VERCEL_TOKEN}"
PROJECT_ID="prj_Ryy4nn9t3KR5sNEByq62JVO3TAlt"
ORG_ID="team_aDZBTaEejPcweAPfcMYF63rs"

if [ -z "$VERCEL_TOKEN" ]; then
    echo "請設定 VERCEL_TOKEN 環境變數"
    exit 1
fi

# 設定環境變數
echo "設定環境變數..."

curl -X POST "https://api.vercel.com/v10/projects/$PROJECT_ID/env" \
  -H "Authorization: Bearer $VERCEL_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "key": "POLAR_ACCESS_TOKEN",
    "value": "${POLAR_ACCESS_TOKEN}",
    "type": "encrypted",
    "target": ["production", "preview", "development"]
  }'

# 觸發部署
echo "觸發部署..."
curl -X POST "https://api.vercel.com/v13/deployments" \
  -H "Authorization: Bearer $VERCEL_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{
    \"name\": \"pikmin-architect\",
    \"project\": \"$PROJECT_ID\"
  }"
