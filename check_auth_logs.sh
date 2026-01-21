#!/bin/bash

echo "🔍 檢查授權相關日誌..."
echo ""

# 顏色定義
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📋 1. 檢查設備 UUID"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
DEVICE_UUID=$(system_profiler SPHardwareDataType | grep 'Hardware UUID' | awk '{print $3}')
echo -e "${GREEN}設備 UUID: ${DEVICE_UUID}${NC}"
echo ""

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📋 2. 檢查服務器授權狀態"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
AUTH_RESPONSE=$(curl -s -X POST "http://localhost:3001/api/auth/check" \
  -H "Content-Type: application/json" \
  -d "{\"deviceId\":\"${DEVICE_UUID}\"}" 2>&1)

if [ $? -eq 0 ]; then
    echo -e "${GREEN}✅ 服務器響應成功${NC}"
    echo "$AUTH_RESPONSE" | python3 -m json.tool 2>/dev/null || echo "$AUTH_RESPONSE"
    
    # 檢查是否已激活
    if echo "$AUTH_RESPONSE" | grep -q '"isActivated":true'; then
        echo ""
        echo -e "${GREEN}✅ 設備已激活！${NC}"
        LICENSE_KEY=$(echo "$AUTH_RESPONSE" | grep -o '"licenseKey":"[^"]*"' | cut -d'"' -f4)
        if [ -n "$LICENSE_KEY" ]; then
            echo -e "${GREEN}   授權碼: ${LICENSE_KEY}${NC}"
        fi
    else
        echo ""
        echo -e "${YELLOW}⚠️  設備未激活${NC}"
    fi
else
    echo -e "${RED}❌ 無法連接到服務器${NC}"
    echo "請確保本地服務器正在運行：cd website && npm start"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📋 3. 檢查 KongGoo App 進程"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
KONGGOO_PID=$(ps aux | grep -i "KongGoo.app" | grep -v grep | awk '{print $2}' | head -1)
if [ -n "$KONGGOO_PID" ]; then
    echo -e "${GREEN}✅ KongGoo App 正在運行 (PID: ${KONGGOO_PID})${NC}"
    echo ""
    echo "📋 4. 查看 App 控制台輸出（最近 2 分鐘）"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "正在查看系統日誌中的授權相關訊息..."
    echo ""
    # 使用 log stream 查看實時日誌
    log show --predicate "process == 'KongGoo'" --last 2m --style syslog 2>&1 | \
        grep -iE "授權|auth|license|激活|deviceId|UUID|isActivated|isPaid|updateTrialStatus|checkAuth|\[授權" | \
        tail -30 || echo "未找到相關日誌"
else
    echo -e "${YELLOW}⚠️  KongGoo App 未運行${NC}"
    echo "請先啟動 App"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📋 5. 實時監控授權日誌（按 Ctrl+C 停止）"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "正在監控 KongGoo App 的授權相關日誌..."
echo "（這會持續運行，按 Ctrl+C 停止）"
echo ""
log stream --predicate "process == 'KongGoo' AND (message contains '授權' OR message contains 'auth' OR message contains 'license' OR message contains '激活' OR message contains 'deviceId' OR message contains 'UUID' OR message contains 'isActivated' OR message contains 'isPaid' OR message contains 'updateTrialStatus' OR message contains 'checkAuth' OR message contains '[授權')" --level debug 2>&1
