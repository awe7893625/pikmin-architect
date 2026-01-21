# DNS 設定步驟 - konggoo.tw

## 📋 需要設定的 DNS 記錄

根據 Vercel 的要求，你需要設定以下兩筆記錄：

### 1. 根域名 (konggoo.tw)
- **類型**：`A`
- **名稱**：`@` 或留空
- **值**：`216.198.79.1`
- **TTL**：3600（或預設值）

### 2. www 子域名 (www.konggoo.tw)
- **類型**：`CNAME`
- **名稱**：`www`
- **值**：`15af0f712efc3b8a.vercel-dns-017.com.`（注意最後有個點）
- **TTL**：3600（或預設值）

---

## 🔍 如何找到你的域名註冊商？

### 方法 1：檢查你購買域名的信箱
查看你註冊 `konggoo.tw` 時收到的確認信，通常會顯示註冊商名稱。

### 方法 2：常見的台灣域名註冊商
- **網路中文 (Net-Chinese)**
- **PChome 域名**
- **Gandi**
- **GoDaddy**
- **Namecheap**
- **Cloudflare**

---

## 📝 各註冊商的設定步驟

### 網路中文 (Net-Chinese)
1. 登入：https://www.net-chinese.com.tw/
2. 進入「我的域名」→ 選擇 `konggoo.tw`
3. 點擊「DNS 管理」或「DNS 設定」
4. 新增記錄：
   - A 記錄：名稱 `@`，值 `216.198.79.1`
   - CNAME 記錄：名稱 `www`，值 `15af0f712efc3b8a.vercel-dns-017.com.`

### PChome 域名
1. 登入：https://myname.pchome.com.tw/
2. 選擇「域名管理」→ `konggoo.tw`
3. 點擊「DNS 設定」
4. 新增記錄（同上）

### Gandi
1. 登入：https://www.gandi.net/
2. 進入「域名」→ 選擇 `konggoo.tw`
3. 點擊「DNS 記錄」
4. 新增記錄（同上）

### Cloudflare（如果域名在 Cloudflare）
1. 登入：https://dash.cloudflare.com/
2. 選擇域名 `konggoo.tw`
3. 進入「DNS」→「記錄」
4. 新增記錄（同上）

### GoDaddy
1. 登入：https://www.godaddy.com/
2. 進入「我的產品」→ 選擇 `konggoo.tw`
3. 點擊「DNS」或「管理 DNS」
4. 新增記錄（同上）

---

## ⚠️ 注意事項

1. **CNAME 值的最後一個點**：`15af0f712efc3b8a.vercel-dns-017.com.`（最後有個點）
2. **等待生效時間**：設定後通常需要 5-30 分鐘才會生效
3. **檢查設定**：設定完成後，可以在終端機執行：
   ```bash
   dig konggoo.tw A
   dig www.konggoo.tw CNAME
   ```
   應該會看到你設定的值

---

## ✅ 設定完成後

1. 回到 Vercel Dashboard → Domains
2. 點擊「Refresh」按鈕
3. 「Invalid Configuration」應該會變成「Valid Configuration」
4. 訪問 `https://konggoo.tw` 應該可以正常顯示
5. `https://pikmin-architect.vercel.app` 會自動 301 轉到 `https://konggoo.tw`

---

## 🆘 如果還是不會設定

請告訴我：
1. 你的域名註冊商是哪一家？
2. 或者截圖你的 DNS 管理後台畫面

我可以給你更詳細的步驟說明。
