#!/bin/bash

echo "🧪 測試隧道建立..."
echo ""

# 1. 清除所有舊進程
echo "1. 清除舊進程..."
sudo killall -9 pymobiledevice3 Python osascript 2>/dev/null
sudo lsof -i tcp:49151 -t 2>/dev/null | xargs -r sudo kill -9 2>/dev/null
sleep 2
echo "✅ 已清除"
echo ""

# 2. 檢查設備
echo "2. 檢查設備連接..."
DEVICE_ID=$(/opt/homebrew/bin/idevice_id -l 2>&1 | head -1)
if [ -z "$DEVICE_ID" ]; then
    echo "❌ 未找到設備"
    exit 1
fi
echo "✅ 找到設備: $DEVICE_ID"
echo ""

# 3. 清除日誌檔案
echo "3. 清除舊日誌..."
sudo rm -f /tmp/pymobiledevice3_tunnel.log
sudo touch /tmp/pymobiledevice3_tunnel.log
sudo chmod 666 /tmp/pymobiledevice3_tunnel.log
echo "✅ 已清除"
echo ""

# 4. 啟動隧道（使用後台執行並重定向輸出）
echo "4. 啟動隧道..."
sudo /opt/homebrew/bin/python3 -m pymobiledevice3 remote tunneld > /tmp/pymobiledevice3_tunnel.log 2>&1 &
TUNNEL_PID=$!
echo "✅ 隧道進程已啟動 (PID: $TUNNEL_PID)"
sleep 2
echo ""

# 5. 等待並檢查
echo "5. 等待隧道啟動（最多 10 秒）..."
for i in {1..20}; do
    sleep 0.5
    PORT_CHECK=$(lsof -i tcp:49151 2>&1 | grep LISTEN)
    if [ ! -z "$PORT_CHECK" ]; then
        echo "✅ 隧道已成功啟動！"
        echo "📋 端口資訊:"
        echo "$PORT_CHECK"
        echo ""
        echo "📋 進程資訊:"
        ps aux | grep pymobiledevice3 | grep -v grep
        echo ""
        echo "📋 日誌內容:"
        cat /tmp/pymobiledevice3_tunnel.log
        echo ""
        echo "✅ 驗收通過：隧道已成功建立！"
        exit 0
    fi
    
    # 檢查進程是否還在運行
    if ! ps -p $TUNNEL_PID > /dev/null 2>&1; then
        echo "❌ 隧道進程已退出"
        echo "📋 日誌內容:"
        cat /tmp/pymobiledevice3_tunnel.log
        exit 1
    fi
    
    echo "⏳ 等待中... ($i/20)"
done

echo "❌ 隧道啟動超時"
echo "📋 日誌內容:"
cat /tmp/pymobiledevice3_tunnel.log
exit 1
