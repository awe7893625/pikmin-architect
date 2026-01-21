# Vercel 環境變數快速設定指南

## 方法 1：通過 Vercel Dashboard（推薦）

1. 登入 https://vercel.com/dashboard
2. 選擇專案：**pikmin-architect**
3. 進入 **Settings** > **Environment Variables**
4. 添加以下環境變數：

### 環境變數列表：

**POLAR_ACCESS_TOKEN**
- Value: `請從 Polar 後台獲取您的 Access Token`
- Environment: Production, Preview, Development (全部勾選)
- ⚠️ 注意：請勿將真實 Token 寫入此文件

**POLAR_PRODUCT_PRICE_ID_ANNUAL**
- Value: `3c450333-7ba3-4d6a-a93a-b4cb0a9b8aa2`
- Environment: Production, Preview, Development (全部勾選)

**POLAR_PRODUCT_PRICE_ID_LIFETIME**
- Value: `4e7ccc7a-c4ef-4f55-b296-5c0f81d0af60`
- Environment: Production, Preview, Development (全部勾選)

**SUCCESS_URL**
- Value: `https://konggoo.tw/payment/success`
- Environment: Production, Preview, Development (全部勾選)
- ⚠️ 注意：部署完成後，將 URL 替換為實際的部署地址

5. 點擊 **Save** 保存每個環境變數
6. 完成後，進入 **Deployments** 頁面
7. 點擊最新的部署，選擇 **Redeploy** 重新部署

## 方法 2：使用 Vercel CLI

```bash
cd website
vercel env add POLAR_ACCESS_TOKEN production
# 輸入: 請從 Polar 後台獲取您的 Access Token（不要在此文件中寫入真實 Token）

vercel env add POLAR_PRODUCT_PRICE_ID_ANNUAL production
# 輸入: 3c450333-7ba3-4d6a-a93a-b4cb0a9b8aa2

vercel env add POLAR_PRODUCT_PRICE_ID_LIFETIME production
# 輸入: 4e7ccc7a-c4ef-4f55-b296-5c0f81d0af60

vercel env add SUCCESS_URL production
# 輸入: https://konggoo.tw/payment/success

# 重新部署
vercel --prod
```

## 檢查環境變數

設定完成後，可以在 Vercel Dashboard 的 **Settings** > **Environment Variables** 中查看所有已設定的環境變數。
