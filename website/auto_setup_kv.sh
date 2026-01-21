#!/bin/bash
# 自動設定 Vercel KV 環境變數並創建授權的完整腳本

VERCEL_TOKEN="4Lcg8iu6Zp70xSFCCqS2ijeY"
PROJECT_NAME="pikmin-architect"
TEAM_ID="team_aDZBTaEejPcweAPfcMYF63rs"
ADMIN_KEY="Hc0_Vwke0-m1_YKpVtvJ3sswAYi1senrJf_by_LcBSo"
DEVICE_ID="C308FD05-B2F6-5F9B-BEA2-BB7A6E5F59CF"

echo "🔧 自動設定 Vercel KV 和授權系統"
echo ""

# 檢查是否提供了 KV 資訊
if [ -z "$1" ] || [ -z "$2" ]; then
    echo "⚠️  使用方法："
    echo "  ./auto_setup_kv.sh <KV_REST_API_URL> <KV_REST_API_TOKEN>"
    echo ""
    echo "📝 如何獲取 KV 資訊："
    echo "  1. 前往：https://vercel.com/dashboard"
    echo "  2. 選擇專案「pikmin-architect」"
    echo "  3. 進入「Storage」標籤"
    echo "  4. 如果還沒有 KV Store，點擊「Create Database」→ 選擇「KV」"
    echo "  5. 創建後，在 KV 的「Settings」中複製："
    echo "     - REST API URL → KV_REST_API_URL"
    echo "     - REST API Token → KV_REST_API_TOKEN"
    echo ""
    exit 1
fi

KV_REST_API_URL="$1"
KV_REST_API_TOKEN="$2"

echo "設定 KV 環境變數..."

# 設定 KV_REST_API_URL
echo "設定 KV_REST_API_URL..."
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
    echo "⚠️  KV_REST_API_URL 已存在，跳過"
else
    echo "⚠️  設定 KV_REST_API_URL 時發生錯誤："
    echo "$RESULT1" | python3 -m json.tool 2>/dev/null || echo "$RESULT1"
fi

# 設定 KV_REST_API_TOKEN
echo "設定 KV_REST_API_TOKEN..."
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
    echo "⚠️  KV_REST_API_TOKEN 已存在，跳過"
else
    echo "⚠️  設定 KV_REST_API_TOKEN 時發生錯誤："
    echo "$RESULT2" | python3 -m json.tool 2>/dev/null || echo "$RESULT2"
fi

echo ""
echo "✅ 環境變數設定完成！"
echo ""
echo "⏳ 等待 Vercel 重新部署（約 60 秒）..."
sleep 60

echo ""
echo "測試 Admin Console API..."
TEST_RESULT=$(curl -s -X GET "https://konggoo.vercel.app/api/admin/licenses" \
  -H "x-admin-key: $ADMIN_KEY")

if echo "$TEST_RESULT" | grep -q '"items"'; then
    echo "✅ Admin Console API 正常運作！"
    echo ""
    echo "創建永久授權並綁定到您的設備..."
    
    # 創建永久授權
    LICENSE_RESPONSE=$(curl -s -X POST "https://konggoo.vercel.app/api/admin/license/create" \
      -H "x-admin-key: $ADMIN_KEY" \
      -H "Content-Type: application/json" \
      -d '{"planType":"lifetime","note":"開發者永久授權 - 自動創建"}')
    
    LICENSE_KEY=$(echo "$LICENSE_RESPONSE" | python3 -c "import sys, json; data = json.load(sys.stdin); print(data.get('licenseKey', ''))" 2>/dev/null)
    
    if [ -n "$LICENSE_KEY" ]; then
        echo "✅ 永久授權已創建: $LICENSE_KEY"
        echo ""
        echo "綁定授權到您的設備..."
        REBIND_RESULT=$(curl -s -X POST "https://konggoo.vercel.app/api/admin/license/rebind" \
          -H "x-admin-key: $ADMIN_KEY" \
          -H "Content-Type: application/json" \
          -d "{\"licenseKey\":\"$LICENSE_KEY\",\"newDeviceId\":\"$DEVICE_ID\"}")
        
        if echo "$REBIND_RESULT" | grep -q '"success"'; then
            echo "✅ 授權已成功綁定到您的設備！"
            echo ""
            echo "📋 授權資訊："
            echo "  License Key: $LICENSE_KEY"
            echo "  Device ID: $DEVICE_ID"
            echo "  類型: 永久授權 (lifetime)"
        else
            echo "⚠️  綁定失敗，嘗試直接授權設備..."
            GRANT_RESULT=$(curl -s -X POST "https://konggoo.vercel.app/api/admin/device/grant" \
              -H "x-admin-key: $ADMIN_KEY" \
              -H "Content-Type: application/json" \
              -d "{\"deviceId\":\"$DEVICE_ID\",\"note\":\"開發者永久授權\"}")
            
            if echo "$GRANT_RESULT" | grep -q '"success"'; then
                echo "✅ 設備已直接授權！"
            fi
        fi
    else
        echo "⚠️  創建授權失敗，嘗試直接授權設備..."
        GRANT_RESULT=$(curl -s -X POST "https://konggoo.vercel.app/api/admin/device/grant" \
          -H "x-admin-key: $ADMIN_KEY" \
          -H "Content-Type: application/json" \
          -d "{\"deviceId\":\"$DEVICE_ID\",\"note\":\"開發者永久授權\"}")
        
        if echo "$GRANT_RESULT" | grep -q '"success"'; then
            echo "✅ 設備已直接授權！"
        fi
    fi
else
    echo "⚠️  Admin Console API 尚未就緒，請稍後再試"
    echo "   或訪問：https://konggoo.vercel.app/admin"
fi

echo ""
echo "🌐 Admin Console: https://konggoo.vercel.app/admin"
echo "🔑 Admin Key: $ADMIN_KEY"
echo "💻 Device ID: $DEVICE_ID"
