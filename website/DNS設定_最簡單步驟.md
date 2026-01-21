# DNS 設定 - 最簡單步驟（只需要 2 筆記錄）

## 📋 需要設定的記錄

在你的域名註冊商後台，設定以下 **2 筆記錄**：

### 1. A 記錄（根域名）
- **類型**：`A`
- **名稱**：`@` 或留空
- **值**：`216.198.79.1`
- **TTL**：3600（或預設值）

### 2. CNAME 記錄（www 子域名）
- **類型**：`CNAME`
- **名稱**：`www`
- **值**：`15af0f712efc3b8a.vercel-dns-017.com.`（注意最後有個點）
- **TTL**：3600（或預設值）

---

## 🎯 設定完成後

- 等待 **5-30 分鐘**讓 DNS 生效
- `https://konggoo.tw` 就可以正常訪問了！
- `https://pikmin-architect.vercel.app` 會自動 301 轉到 `https://konggoo.tw`

---

## 💡 常見註冊商的設定位置

### 網路中文 (Net-Chinese)
1. 登入：https://www.net-chinese.com.tw/
2. 我的域名 → 選擇 `konggoo.tw` → DNS 管理

### PChome 域名
1. 登入：https://myname.pchome.com.tw/
2. 域名管理 → 選擇 `konggoo.tw` → DNS 設定

### Gandi
1. 登入：https://www.gandi.net/
2. 域名 → 選擇 `konggoo.tw` → DNS 記錄

### Cloudflare
1. 登入：https://dash.cloudflare.com/
2. 選擇域名 `konggoo.tw` → DNS → 記錄

---

## ⚠️ 注意事項

- CNAME 值的最後一個點很重要：`15af0f712efc3b8a.vercel-dns-017.com.`
- 設定後需要等待 5-30 分鐘才會生效
- 可以用 `dig konggoo.tw A` 檢查是否生效
