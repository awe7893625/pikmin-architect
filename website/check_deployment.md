# 部署檢查清單

## ✅ 環境變數確認

從截圖看，以下環境變數已經添加：
- ✅ POLAR_ACCESS_TOKEN
- ✅ POLAR_PRODUCT_PRICE_ID_ANNUAL  
- ✅ POLAR_PRODUCT_PRICE_ID_LIFETIME
- ✅ SUCCESS_URL

## ⚠️ 重要檢查項目

1. **環境變數的值是否正確？**
   - 點擊每個環境變數旁邊的眼睛圖標，確認值是否正確

2. **環境變數的環境範圍是否正確？**
   - 應該勾選：Production、Preview、Development
   - 如果只勾選了部分環境，可能導致某些環境無法使用

3. **是否需要重新部署？**
   - 環境變數設定後，需要重新部署才能生效
   - 在 Deployments 頁面點擊「Redeploy」

## 🔄 觸發重新部署

已推送新的提交來觸發自動部署。如果沒有自動部署：

1. 進入 Deployments 頁面
2. 找到最新的部署（Fhzd4VY7w 或更新的）
3. 點擊三個點（...）> 「Redeploy」
4. 等待部署完成

## ✅ 部署完成後驗證

1. 訪問部署的網站 URL
2. 測試付款功能
3. 確認可以正常創建 checkout link
