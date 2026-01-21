#!/bin/bash

echo "🔍 檢查 Xcode 和 App 相關日誌..."
echo ""

# 顏色定義
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📋 1. 檢查 pymobiledevice3 隧道日誌檔案"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if [ -f /tmp/pymobiledevice3_tunnel.log ]; then
    echo -e "${GREEN}✅ 日誌檔案存在${NC}"
    echo ""
    echo "📄 日誌內容（最後 50 行）："
    echo "──────────────────────────────────────────────────────────────────────────"
    tail -50 /tmp/pymobiledevice3_tunnel.log
    echo "──────────────────────────────────────────────────────────────────────────"
else
    echo -e "${YELLOW}⚠️  日誌檔案不存在${NC}"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📋 2. 檢查系統日誌中的 KongGoo 相關訊息（最近 5 分鐘）"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log show --predicate 'process == "KongGoo" or process == "pymobiledevice3" or process == "Python" or message contains "隧道" or message contains "tunnel" or message contains "49151"' --last 5m --style compact 2>&1 | tail -100 || echo "無法讀取系統日誌"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📋 3. 檢查當前端口 49151 狀態"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
PORT_CHECK=$(lsof -i tcp:49151 2>&1)
if [ -z "$PORT_CHECK" ] || echo "$PORT_CHECK" | grep -q "cannot identify protocol"; then
    echo -e "${GREEN}✅ 端口 49151 未被佔用${NC}"
else
    echo -e "${RED}❌ 端口 49151 被佔用：${NC}"
    echo "$PORT_CHECK"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📋 4. 檢查 pymobiledevice3 相關進程"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
PROCESSES=$(ps aux | grep -E "pymobiledevice3|Python.*tunnel" | grep -v grep)
if [ -z "$PROCESSES" ]; then
    echo -e "${GREEN}✅ 沒有相關進程在運行${NC}"
else
    echo -e "${YELLOW}⚠️  發現相關進程：${NC}"
    echo "$PROCESSES"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📋 5. 檢查 KongGoo App 進程"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
KONGGOO_PROCESSES=$(ps aux | grep -i "KongGoo" | grep -v grep)
if [ -z "$KONGGOO_PROCESSES" ]; then
    echo -e "${YELLOW}⚠️  KongGoo App 未運行${NC}"
else
    echo -e "${GREEN}✅ KongGoo App 正在運行：${NC}"
    echo "$KONGGOO_PROCESSES"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📋 6. 實時監控日誌（按 Ctrl+C 停止）"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "正在監控系統日誌中的 KongGoo 和隧道相關訊息..."
echo "（這會持續運行，按 Ctrl+C 停止）"
echo ""
log stream --predicate 'process == "KongGoo" or process == "pymobiledevice3" or process == "Python" or message contains "隧道" or message contains "tunnel" or message contains "49151" or message contains "[隧道]"' --level debug 2>&1
