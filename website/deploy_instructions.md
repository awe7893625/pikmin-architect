# Vercel 部署指引

## 快速部署步驟

### 1. 登入 Vercel Dashboard
訪問：https://vercel.com/dashboard

### 2. 找到專案
專案名稱：pikmin-architect
專案 ID：prj_Ryy4nn9t3KR5sNEByq62JVO3TAlt

### 3. 檢查部署狀態
- 如果看到新的部署正在進行，等待完成即可
- 如果沒有自動部署，點擊「Deployments」> 「Redeploy」

### 4. 設定環境變數（重要！）
進入「Settings」> 「Environment Variables」，添加：

**POLAR_ACCESS_TOKEN**
```
請從 Polar 後台獲取您的 Access Token
⚠️ 注意：請勿將真實 Token 寫入此文件或上傳到 GitHub
```

**POLAR_PRODUCT_PRICE_ID_ANNUAL**
```
3c450333-7ba3-4d6a-a93a-b4cb0a9b8aa2
```

**POLAR_PRODUCT_PRICE_ID_LIFETIME**
```
4e7ccc7a-c4ef-4f55-b296-5c0f81d0af60
```

**SUCCESS_URL**
```
https://your-project.vercel.app/payment/success
```
（替換為實際的部署 URL）

### 5. 重新部署
設定環境變數後，點擊「Deployments」> 「Redeploy」重新部署

## 自動部署
如果 Vercel 已連接 GitHub，推送代碼後會自動觸發部署。
