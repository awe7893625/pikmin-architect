# 🚀 在 Vercel 導入並部署（代碼已上傳到 GitHub）

## ✅ 已完成
- ✅ 代碼已推送到 GitHub
- ✅ 倉庫 URL：https://github.com/awe7893625/pikmin-architect

---

## 📝 現在在 Vercel 執行以下步驟

### 步驟 1：導入 GitHub 倉庫

1. **在 Vercel 控制台**
   - 您現在應該在 Vercel 的 "Add New Project" 頁面
   - 點擊 **"Import Git Repository"**

2. **連接 GitHub（如果還沒連接）**
   - 如果看到 "Install the GitHub application"，點擊 **"Install"**
   - 選擇您的 GitHub 帳號（awe7893625）
   - 授權 Vercel 訪問您的倉庫
   - 可以選擇 "All repositories" 或只選擇 `pikmin-architect`

3. **選擇倉庫**
   - 在列表中找到 **`pikmin-architect`**
   - 點擊 **"Import"**

---

### 步驟 2：設定項目配置 ⚠️ 重要！

在設定頁面，請確認以下設定：

1. **Project Name**
   - 輸入：`pikmin-architect`（或自訂）

2. **Root Directory** ⚠️ **這很重要！**
   - 點擊 **"Edit"**
   - 輸入：`website`
   - 這告訴 Vercel 網站代碼在 `website` 目錄中

3. **Framework Preset**
   - 選擇：`Other`

4. **Build Command**
   - 留空（或輸入：`npm install`）

5. **Output Directory**
   - 留空

6. **Install Command**
   - 輸入：`npm install`

7. **Environment Variables**
   - 先留空，部署完成後再設定

8. **點擊 "Deploy"**

---

### 步驟 3：等待部署完成

- 部署通常需要 1-2 分鐘
- 您會看到部署進度
- 完成後會顯示您的網站 URL（建議最終對外使用自訂網域：`https://konggoo.tw`，並設定 `PRIMARY_HOST=konggoo.tw` 讓舊域名 301 導向）
- **記下這個 URL**，等一下設定環境變數會用到

---

### 步驟 4：設定綠界金流環境變數

1. **在 Vercel 控制台**
   - 選擇您的項目
   - 點擊 **Settings** → **Environment Variables**

2. **添加環境變數**
   - 點擊 **"Add New"**，逐一添加：

```
Key: ECPAY_MERCHANT_ID
Value: 3487294
Environment: Production, Preview, Development（全部勾選）

Key: ECPAY_HASH_KEY
Value: GeneRPCVs#TCB570
Environment: Production, Preview, Development（全部勾選）

Key: ECPAY_HASH_IV
Value: 0LYW9hnDtehDd2te
Environment: Production, Preview, Development（全部勾選）

Key: ECPAY_API_URL
Value: https://payment.ecpay.com.tw/Cashier/AioCheckOut/V5
Environment: Production, Preview, Development（全部勾選）

Key: ECPAY_RETURN_URL
Value: https://您的網站.vercel.app/api/payment/return
Environment: Production, Preview, Development（全部勾選）
（將「您的網站.vercel.app」替換為步驟 3 取得的實際 URL）

Key: ECPAY_ORDER_RESULT_URL
Value: https://您的網站.vercel.app/payment/success
Environment: Production, Preview, Development（全部勾選）
（將「您的網站.vercel.app」替換為步驟 3 取得的實際 URL）

Key: PORT
Value: 3001
Environment: Production, Preview, Development（全部勾選）

Key: NODE_ENV
Value: production
Environment: Production（只勾選 Production）
```

3. **重新部署**
   - 前往 **Deployments**
   - 找到最新的部署
   - 點擊右側的 **⋯**（三個點）
   - 選擇 **Redeploy**

---

### 步驟 5：測試網站

1. **訪問您的網站**
   - 打開 Vercel 提供的 URL

2. **測試購買流程**
   - 點擊「立即購買」
   - 選擇付款方式（信用卡）
   - 使用測試卡號：`4311-9522-2222-2222`
   - 有效期限：`12/25`
   - 安全碼：`123`

3. **確認功能**
   - ✅ 付款頁面正常顯示
   - ✅ 付款成功後跳轉回網站
   - ✅ 授權碼正常生成

---

## 📋 檢查清單

- [ ] 在 Vercel 導入 GitHub 倉庫
- [ ] 設定 Root Directory 為 `website` ⚠️ 重要！
- [ ] 記下部署後的 Vercel URL
- [ ] 在 Vercel 設定環境變數
- [ ] 更新 ReturnURL 和 OrderResultURL
- [ ] 重新部署網站
- [ ] 測試付款流程

---

## ⚠️ 重要提醒

### Root Directory 設定

**必須設定為 `website`**，否則 Vercel 找不到 `server.js` 文件！

如果忘記設定，可以：
1. 前往 Settings → General
2. 找到 "Root Directory"
3. 點擊 "Edit"
4. 輸入 `website`
5. 重新部署

---

## ✅ 完成後

1. ✅ 代碼已上傳到 GitHub
2. ✅ 網站已部署到 Vercel
3. ✅ 綠界金流已設定
4. ✅ 可以開始接受訂單！

---

## 📞 需要幫助？

如果遇到問題：
1. 檢查 Vercel 部署日誌
2. 確認 Root Directory 設定為 `website`
3. 檢查環境變數是否正確
4. 確認綠界後台的設定
