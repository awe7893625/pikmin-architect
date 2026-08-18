# KongGoo 授權交付 + 年繳到期 — Spec

Date: 2026-08-17
Owner: Claude (Opus 5) / Rain 拍板
Repos: `pikmin-architect`（server, 部署 konggoo.uk）、`konggoo/electron`（桌面 App）

## 問題（實測證據，非推測）

1. **授權碼沒有寄信，也沒有補寄路徑。** `website/server.js` 全檔零寄信程式碼（Vercel 上 `RESEND_API_KEY` / `RESEND_FROM_EMAIL` 是死變數）。訂單記錄沒有 email 欄位。客人只要在複製授權碼前關掉成功頁，就永久失聯——你不知道他是誰，他也拿不回授權碼。
   - 既有 rebind 端點已經在讀 `license.purchaseEmail`，但這個欄位從來沒有被寫入過，所以換機驗證形同虛設。
2. **賣「年繳 NT$690」但實際發出永久授權。** KV 實錄：兩筆付費 license `ttl = -1`、無 `expiresAt` 欄位；`activate` / `verify` 完全沒有到期判斷；App 端 `checkLicense()` 對已啟用狀態是純本地判斷、啟用後永不回頭問伺服器。

## Rain 拍板

**真的做成年繳**（三選項中工程量最大的一條），並接受：
- App 必須加定期線上覆核並發新版；**舊版安裝檔永遠擋不到**（已啟用的舊版不會回頭問伺服器）。
- 既有 2 位付費客戶 **grandfather 成永久，不追溯**。

## 範圍

### A. 授權交付（email）
- A1 `POST /api/payment/create` 新增 **email 必填**（格式驗證），寫入 order。
- A2 付款成功發 key 時，同時寫 `purchaseEmail` 到 license record，並用 Resend 寄授權信；`emailSentAt` / `emailError` 記在 order 上，重送具冪等性。
- A3 三條發 key 路徑（ECPay notify / ECPay OrderResultURL POST / Polar confirm）收斂成單一 `finalizePaidOrder()`，避免三份邏輯各自漂移。
- A4 新增 `POST /api/license/resend`（依 email 補寄，rate limit，回應不洩漏 email 是否存在）。
- A5 email → licenses 索引（KV `email:index:<normalized>`）。
- A6 Admin `/api/admin/licenses` 列表補上 email / expiresAt。

### B. 年繳到期
- B1 發 key 時寫 `durationDays`（annual=365、lifetime=null）。
- B2 **啟用時**才起算：`expiresAt = activatedAt + durationDays`（未啟用的 key 不會在抽屜裡自己過期）。同機重複啟用不展延。
- B3 `activate` 對已過期 license 回 403 `LICENSE_EXPIRED`。
- B4 `verify` 回傳 `expiresAt` / `expired`；過期回 `valid:false` + `LICENSE_EXPIRED`。
- B5 新增 `POST /api/license/status { licenseKey, deviceId }`（唯讀）供 App 定期覆核：檢查存在、isValid、裝置綁定相符、未過期。
- B6 **Grandfather**：沒有 `durationDays` 也沒有 `expiresAt` 的舊 license 一律視為永久。既有 2 筆付費 + Rain 自己的 key 都屬此類，零資料遷移。

### C. App（konggoo/electron）
- C1 啟用後保存 `expiresAt` / `planType` / `lastValidatedAt`。
- C2 `checkLicense()` 加本地到期判斷 → `license-expired`。
- C3 每 7 天線上覆核一次（`/api/license/status`）；離線寬限 30 天；超過寬限 → `revalidate-required`。
- C4 `main.js` 處理新狀態，顯示對應視窗與訊息。

### D. 文案
- D1 `payment.html` 加 email 欄位 + 「授權碼會寄到此信箱」說明；年費方案標示一年後需續購。
- D2 五語系 locale 補上新 key。

## 不在範圍

- 續費 / 自動扣款流程（本次只做「會到期」，續購走重新購買）。
- 舊版已安裝 App 的追溯管控（技術上不可能，已向 Rain 明示）。
- 客服信箱 TODO、English FAQ TODO（既有債，不在本次動）。

## 驗收閘門（交差前逐項實測，不得以「應該會動」代替）

| # | 閘門 | 判定方式 |
|---|------|----------|
| G1 | 無 email 建單被擋 | `POST /api/payment/create` 無 email → 400 `MISSING_EMAIL` |
| G2 | 付款成功寫入 email + durationDays | 模擬 ECPay notify（真 CheckMacValue）→ 讀 KV 驗欄位 |
| G3 | 授權信真的寄出 | Resend API 回 id；收件匣實收（需 Rain 授權一次外發） |
| G4 | 補寄可用 | `POST /api/license/resend` → 再收到一封；不存在的 email 也回一般性成功 |
| G5 | 啟用起算到期 | activate 後 `expiresAt ≈ activatedAt + 365d` |
| G6 | 重複啟用不展延 | 同機 activate 兩次，`expiresAt` 不變 |
| G7 | 過期擋下 | 造一把 `expiresAt` 在過去的測試 key → activate 403 / status invalid |
| G8 | Grandfather 不受影響 | 兩筆既有付費 license 跑 status/verify → 仍 valid、無 expiresAt |
| G9 | App 本地到期判定 | 造 license.dat（expiresAt 過去）→ `checkLicense()` 回 `license-expired` |
| G10 | App 離線寬限 | server 不可達 + lastValidatedAt 在寬限內 → 仍 activated；超過 → `revalidate-required` |
| G11 | 既有測試不退步 | `node electron/license.test.js` 全綠 |
| G12 | 測試資料清乾淨 | KV 內測試 order/license/device/email index 全數刪除，`/api/admin/licenses` 只剩真實資料 |

## 已知限制（Rain 已知悉並接受）

- 舊版 App（v20260622 以前）已啟用者永不到期。年繳實質從新版釋出後才開始生效。
- Windows 版新版需 Beaver PC 才能 build；Mac 版需簽章 + 公證。
- Polar（非繁中語系）路徑同樣套用，但目前 `payment.html` 未傳 `lang`，實務上不會走到。
