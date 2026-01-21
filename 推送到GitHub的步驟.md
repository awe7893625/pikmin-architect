# 📤 推送代碼到 GitHub 的步驟

## ✅ 已完成
- ✅ Git 倉庫已初始化
- ✅ 代碼已提交到本地

---

## 📝 現在請執行以下步驟

### 步驟 1：在 GitHub 創建新倉庫

1. **前往 GitHub**
   - 打開瀏覽器：https://github.com/new
   - 登入您的 GitHub 帳號（如果沒有，先註冊，完全免費）

2. **創建新倉庫**
   - **Repository name**：輸入 `pikmin-architect`（或您喜歡的名稱）
   - **Description**：`Pikmin Architect - GPS 位置模擬工具`
   - **選擇 Public 或 Private**：
     - Public：所有人都能看到代碼（免費）
     - Private：只有您能看到（免費，但建議選擇這個）
   - **重要**：**不要**勾選以下選項：
     - ❌ Add a README file
     - ❌ Add .gitignore
     - ❌ Choose a license
   - 點擊綠色的 **"Create repository"** 按鈕

3. **記下倉庫 URL**
   - 創建完成後，會顯示類似這樣的 URL：
     - `https://github.com/您的帳號/pikmin-architect.git`
   - **複製這個 URL**，等一下會用到

---

### 步驟 2：將代碼推送到 GitHub

**在終端執行以下命令**（我會幫您執行）：

```bash
cd "/Users/rain/Pikmin_Dev_Portable/PikminArchitect＿繼續開發版本"

# 添加 GitHub 遠端倉庫（替換為您的實際 URL）
git remote add origin https://github.com/您的帳號/pikmin-architect.git

# 推送到 GitHub
git branch -M main
git push -u origin main
```

**注意**：
- 將 `您的帳號` 替換為您的 GitHub 用戶名
- 第一次推送會要求輸入 GitHub 帳號密碼（或使用 Personal Access Token）

---

### 步驟 3：在 Vercel 導入 GitHub 倉庫

1. **在 Vercel 控制台**
   - 您現在應該在 Vercel 的 "Add New Project" 頁面
   - 點擊 **"Import Git Repository"**

2. **連接 GitHub（如果還沒連接）**
   - 如果看到 "Install the GitHub application"，點擊 **"Install"**
   - 選擇您的 GitHub 帳號
   - 授權 Vercel 訪問您的倉庫
   - 可以選擇 "All repositories" 或只選擇 `pikmin-architect`

3. **選擇倉庫**
   - 在列表中找到 `pikmin-architect`
   - 點擊 **"Import"**

4. **設定項目**
   - **Project Name**：`pikmin-architect`（或自訂）
   - **Root Directory**：**選擇 `website`** ⚠️ 這很重要！
   - **Framework Preset**：選擇 `Other`
   - **Build Command**：留空
   - **Output Directory**：留空
   - **Install Command**：`npm install`

5. **點擊 "Deploy"**

6. **等待部署完成**
   - 部署通常需要 1-2 分鐘
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

## 🎯 快速檢查清單

- [ ] 在 GitHub 創建新倉庫
- [ ] 記下倉庫 URL
- [ ] 執行 `git remote add origin` 命令
- [ ] 執行 `git push` 命令
- [ ] 在 Vercel 導入 GitHub 倉庫
- [ ] 設定 Root Directory 為 `website`
- [ ] 記下部署後的 Vercel URL
- [ ] 在 Vercel 設定環境變數
- [ ] 重新部署網站
- [ ] 測試付款流程

---

## 💡 提示

### 如果推送時要求輸入密碼

GitHub 現在不支援密碼登入，需要使用 **Personal Access Token**：

1. 前往：https://github.com/settings/tokens
2. 點擊 **"Generate new token"** → **"Generate new token (classic)"**
3. 設定：
   - Note：`Vercel Deployment`
   - Expiration：選擇期限（建議 90 天或 No expiration）
   - Scopes：勾選 `repo`
4. 點擊 **"Generate token"**
5. **複製 token**（只會顯示一次！）
6. 在終端輸入密碼時，貼上這個 token

---

## ✅ 完成後

1. ✅ 代碼已上傳到 GitHub
2. ✅ 網站已部署到 Vercel
3. ✅ 綠界金流已設定
4. ✅ 可以開始接受訂單！
