# 🚀 上傳到 GitHub 並部署到 Vercel

## 📋 步驟說明

### 步驟 1：在 GitHub 創建新倉庫

1. **前往 GitHub**
   - 打開：https://github.com/new
   - 登入您的 GitHub 帳號（如果沒有，先註冊，免費）

2. **創建新倉庫**
   - Repository name：`pikmin-architect`（或自訂名稱）
   - Description：`Pikmin Architect - GPS 位置模擬工具`
   - 選擇 **Public** 或 **Private**（建議 Private）
   - **不要**勾選 "Initialize this repository with a README"
   - 點擊 **"Create repository"**

3. **記下倉庫 URL**
   - 會顯示類似：`https://github.com/您的帳號/pikmin-architect.git`
   - 複製這個 URL

---

### 步驟 2：將代碼推送到 GitHub

在終端執行以下命令：

```bash
cd "/Users/rain/Pikmin_Dev_Portable/PikminArchitect＿繼續開發版本"

# 1. 初始化 git（如果還沒初始化）
git init

# 2. 添加所有文件
git add .

# 3. 提交
git commit -m "Initial commit: Pikmin Architect website and app"

# 4. 添加 GitHub 遠端倉庫（替換為您的實際 URL）
git remote add origin https://github.com/您的帳號/pikmin-architect.git

# 5. 推送到 GitHub
git branch -M main
git push -u origin main
```

**注意**：將 `您的帳號` 替換為您的 GitHub 用戶名。

---

### 步驟 3：在 Vercel 導入 GitHub 倉庫

1. **在 Vercel 控制台**
   - 點擊 **"Add New..."** → **"Project"**

2. **選擇 "Import Git Repository"**
   - 如果還沒連接 GitHub，點擊 **"Install"** 連接 GitHub
   - 選擇您的 GitHub 帳號
   - 授權 Vercel 訪問您的倉庫

3. **選擇倉庫**
   - 在列表中選擇 `pikmin-architect`
   - 點擊 **"Import"**

4. **設定項目**
   - **Project Name**：`pikmin-architect`（或自訂）
   - **Root Directory**：選擇 `website`（重要！）
   - **Framework Preset**：選擇 `Other` 或 `Express`
   - **Build Command**：留空（或 `npm install`）
   - **Output Directory**：留空
   - **Install Command**：`npm install`

5. **點擊 "Deploy"**

6. **記下部署 URL**
   - 部署完成後會顯示（建議最終對外使用自訂網域：`https://konggoo.tw`，並設定 `PRIMARY_HOST=konggoo.tw` 讓舊域名 301 導向）

---

### 步驟 4：設定環境變數

1. **在 Vercel 控制台**
   - 選擇您的項目 → **Settings** → **Environment Variables**

2. **添加環境變數**
   - 點擊 **"Add New"**，添加以下變數：

```
ECPAY_MERCHANT_ID = 3487294
ECPAY_HASH_KEY = GeneRPCVs#TCB570
ECPAY_HASH_IV = 0LYW9hnDtehDd2te
ECPAY_API_URL = https://payment.ecpay.com.tw/Cashier/AioCheckOut/V5
ECPAY_RETURN_URL = https://您的網站.vercel.app/api/payment/return
ECPAY_ORDER_RESULT_URL = https://您的網站.vercel.app/payment/success
PORT = 3001
NODE_ENV = production
```

**重要**：將 `您的網站.vercel.app` 替換為步驟 3 取得的實際 URL。

3. **重新部署**
   - 前往 **Deployments** → 選擇最新部署 → **Redeploy**

---

## 🎯 快速指令（我會幫您執行）

讓我幫您執行這些步驟！
