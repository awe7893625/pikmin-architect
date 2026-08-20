#!/bin/bash

# ⚠️ 2026-08-20：這裡原本硬編碼了 VERCEL_TOKEN / ADMIN_KEY，而本 repo 是 public，
# 等於把正式環境金鑰公開了七個月。兩把都已作廢並輪換。金鑰一律從環境變數讀，
# 不要再寫回檔案裡。
#   export VERCEL_TOKEN=...            # vercel.com/account/tokens
#   export ADMIN_KEY="$(cat ~/.konggoo-admin-key)"
# Vercel 重新部署腳本

VERCEL_TOKEN="${VERCEL_TOKEN:?請先 export VERCEL_TOKEN（見上方說明）}"
PROJECT_ID="prj_Ryy4nn9t3KR5sNEByq62JVO3TAlt"
TEAM_ID="team_aDZBTaEejPcweAPfcMYF63rs"

echo "🚀 觸發 Vercel 重新部署..."
echo ""

# 獲取最新的部署 ID
LATEST_DEPLOYMENT=$(curl -s -X GET "https://api.vercel.com/v6/deployments?projectId=$PROJECT_ID&teamId=$TEAM_ID&limit=1" \
  -H "Authorization: Bearer $VERCEL_TOKEN" | jq -r '.deployments[0].uid')

if [ -z "$LATEST_DEPLOYMENT" ] || [ "$LATEST_DEPLOYMENT" = "null" ]; then
  echo "❌ 無法獲取部署 ID"
  exit 1
fi

echo "📦 最新部署 ID: $LATEST_DEPLOYMENT"
echo ""

# 獲取 repoId
REPO_ID=$(curl -s -X GET "https://api.vercel.com/v9/projects/$PROJECT_ID?teamId=$TEAM_ID" \
  -H "Authorization: Bearer $VERCEL_TOKEN" | jq -r '.link.repoId')

if [ -z "$REPO_ID" ] || [ "$REPO_ID" = "null" ]; then
  echo "❌ 無法獲取 repoId"
  exit 1
fi

echo "📦 Repo ID: $REPO_ID"
echo ""

# 使用 Vercel API 觸發重新部署
echo "🔄 觸發重新部署..."
DEPLOY_RESPONSE=$(curl -s -X POST "https://api.vercel.com/v13/deployments?teamId=$TEAM_ID" \
  -H "Authorization: Bearer $VERCEL_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{
    \"name\": \"pikmin-architect\",
    \"project\": \"$PROJECT_ID\",
    \"target\": \"production\",
    \"source\": \"cli\",
    \"gitSource\": {
      \"type\": \"github\",
      \"repoId\": \"$REPO_ID\",
      \"ref\": \"main\"
    }
  }")

NEW_DEPLOYMENT_ID=$(echo "$DEPLOY_RESPONSE" | jq -r '.uid // empty')

if [ -n "$NEW_DEPLOYMENT_ID" ]; then
  echo "✅ 部署已觸發！"
  echo "📋 新部署 ID: $NEW_DEPLOYMENT_ID"
  echo ""
  echo "🔗 部署狀態: https://vercel.com/rains-projects-21400817/pikmin-architect"
  echo ""
  echo "⏳ 等待部署完成（約 1-2 分鐘）..."
else
  echo "❌ 部署觸發失敗"
  echo "$DEPLOY_RESPONSE" | jq '.' 2>/dev/null || echo "$DEPLOY_RESPONSE"
  echo ""
  echo "💡 請手動到 Vercel Dashboard 觸發重新部署："
  echo "   https://vercel.com/rains-projects-21400817/pikmin-architect"
  exit 1
fi
