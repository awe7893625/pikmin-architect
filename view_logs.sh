#!/bin/bash

# 快速查看日誌腳本

echo "🔍 快速查看日誌..."
echo ""

# 1. 查看隧道日誌檔案
if [ -f /tmp/pymobiledevice3_tunnel.log ]; then
    echo "📄 pymobiledevice3_tunnel.log（最後 30 行）："
    echo "────────────────────────────────────────────────────────"
    tail -30 /tmp/pymobiledevice3_tunnel.log
    echo "────────────────────────────────────────────────────────"
else
    echo "⚠️  日誌檔案不存在"
fi

echo ""
echo "📊 端口 49151 狀態："
lsof -i tcp:49151 2>&1 | head -5 || echo "✅ 端口未被佔用"

echo ""
echo "📊 相關進程："
ps aux | grep -E "pymobiledevice3|Python.*tunnel" | grep -v grep || echo "✅ 沒有相關進程"
