#!/bin/bash

# Pikmin Architect 網站啟動腳本

echo "🚀 正在啟動 Pikmin Architect 網站..."
echo ""

# 進入 website 目錄
cd "$(dirname "$0")"

# 檢查 Node.js 是否安裝
if ! command -v node &> /dev/null; then
    echo "❌ 錯誤：未找到 Node.js，請先安裝 Node.js"
    exit 1
fi

# 檢查依賴是否安裝
if [ ! -d "node_modules" ]; then
    echo "📦 正在安裝依賴..."
    npm install
fi

# 啟動服務器
echo "✅ 服務器啟動中..."
echo "📍 網站地址：http://localhost:3001"
echo "按 Ctrl+C 停止服務器"
echo ""

node server.js
