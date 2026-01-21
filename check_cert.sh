#!/bin/bash
echo "🔍 檢查 Developer ID Application 證書..."
echo ""
if security find-identity -v -p codesigning | grep -q "Developer ID Application"; then
    echo "✅ 成功！Developer ID Application 證書已安裝！"
    echo ""
    security find-identity -v -p codesigning | grep "Developer ID Application"
    echo ""
    echo "🎉 現在可以運行打包腳本了："
    echo "   ./build_dmg.sh"
else
    echo "❌ 尚未找到 Developer ID Application 證書"
    echo ""
    echo "請按照以下步驟創建證書："
    echo "1. 前往：https://developer.apple.com/account/resources/certificates/list"
    echo "2. 點擊「+」按鈕"
    echo "3. 選擇「Software」>「Developer ID Application」"
    echo "4. 上傳桌面的 CSR 文件"
    echo "5. 下載並安裝證書"
    echo ""
    echo "詳細指引請查看：詳細創建證書指引.md"
fi
