#!/bin/bash

# Pikmin Architect 網站部署腳本
# 使用方式：./deploy.sh

echo "🚀 開始部署 Pikmin Architect 網站..."
echo ""

# 檢查是否在正確的目錄
if [ ! -f "server.js" ]; then
    echo "❌ 錯誤：請在 website 目錄中執行此腳本"
    exit 1
fi

# 檢查 Node.js
if ! command -v node &> /dev/null; then
    echo "❌ 錯誤：未找到 Node.js，請先安裝 Node.js"
    exit 1
fi

# 檢查 npm
if ! command -v npm &> /dev/null; then
    echo "❌ 錯誤：未找到 npm，請先安裝 npm"
    exit 1
fi

echo "✅ Node.js 版本：$(node --version)"
echo "✅ npm 版本：$(npm --version)"
echo ""

# 安裝依賴
echo "📦 安裝依賴..."
npm install

if [ $? -ne 0 ]; then
    echo "❌ 依賴安裝失敗"
    exit 1
fi

echo "✅ 依賴安裝完成"
echo ""

# 檢查 Vercel CLI
if ! command -v vercel &> /dev/null; then
    echo "📦 安裝 Vercel CLI..."
    npm i -g vercel
    
    if [ $? -ne 0 ]; then
        echo "❌ Vercel CLI 安裝失敗"
        exit 1
    fi
fi

echo "✅ Vercel CLI 已安裝"
echo ""

# 提示用戶
echo "⚠️  注意事項："
echo "1. 如果這是首次部署，會要求您登入 Vercel"
echo "2. 部署完成後，請前往 Vercel 控制台設定環境變數"
echo "3. 金流 API 審查通過後，記得更新環境變數"
echo ""
read -p "按 Enter 繼續部署，或按 Ctrl+C 取消..."

# 執行部署
echo ""
echo "🚀 開始部署到 Vercel..."
vercel --prod

if [ $? -eq 0 ]; then
    echo ""
    echo "✅ 部署完成！"
    echo ""
    echo "📝 下一步："
    echo "1. 前往 Vercel 控制台：https://vercel.com/dashboard"
    echo "2. 選擇您的項目"
    echo "3. 前往 Settings → Environment Variables"
    echo "4. 添加環境變數（參考 README_DEPLOY.md）"
    echo "5. 重新部署：vercel --prod"
else
    echo ""
    echo "❌ 部署失敗，請檢查錯誤訊息"
    exit 1
fi
