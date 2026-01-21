# 授權/試用系統流程文檔

**版本**: 2.0 (持久化存儲重構版)  
**更新時間**: 2025-01-XX  
**存儲**: Vercel KV / Upstash Redis (優先) 或 內存 Map (開發模式)

---

## 系統架構

### 存儲層

#### 1. 持久化存儲（生產環境）
- **Vercel KV** (優先): 使用 `@vercel/kv` SDK
- **Upstash Redis**: 兼容 Redis 協議，可作為 Vercel KV 的替代
- **環境變數**:
  - `KV_REST_API_URL`: KV REST API URL
  - `KV_REST_API_TOKEN`: KV REST API Token

#### 2. 內存快取（開發模式）
- 僅在未配置 KV 時使用
- **警告**: 服務器重啟後數據會丟失
- 僅用於本地開發和測試

### 數據結構

#### Device (設備)
```javascript
{
  trialCount: 3,              // 剩餘試用次數（初始值：3）
  licenseKey: "PKM-...",      // 授權碼（null 表示未激活）
  activatedAt: "2025-01-XX...", // 激活時間（ISO 8601）
  registeredAt: "2025-01-XX...", // 註冊時間（ISO 8601）
  updatedAt: "2025-01-XX..."    // 最後更新時間（ISO 8601）
}
```

**KV Key**: `device:{deviceId}`

#### License (授權碼)
```javascript
{
  deviceId: "UUID-...",       // 綁定的設備 ID（null 表示未使用）
  paidAt: "2025-01-XX...",     // 付款時間（ISO 8601）
  isValid: true,               // 是否有效
  createdAt: "2025-01-XX...",  // 創建時間（ISO 8601）
  activatedAt: "2025-01-XX...", // 激活時間（ISO 8601，null 表示未激活）
  planType: "annual" | "lifetime" | "test"  // 方案類型
}
```

**KV Key**: `license:{licenseKey}`

---

## API 端點

### 1. `/api/auth/check` - 檢查授權狀態

**方法**: `POST`  
**用途**: 檢查設備的授權狀態和剩餘試用次數  
**Single Source of Truth**: 所有授權判斷必須依賴此 API 的 `isActivated`

#### 請求
```json
{
  "deviceId": "UUID-..."
}
```

#### 響應
```json
{
  "trialCount": 3,
  "licenseKey": "PKM-..." | null,
  "isActivated": true | false,
  "serverTime": "2025-01-XX..."
}
```

#### 流程
1. **強制從 KV 讀取設備數據** (`getDeviceFromKV`)
   - 如果 KV 未配置，fallback 到內存快取（僅開發模式）
2. **如果設備不存在**:
   - 創建新設備記錄: `trialCount = 3`, `licenseKey = null`
   - **保存到持久化存儲** (`setDevice`)
3. **檢查是否已激活**:
   - 如果 `device.licenseKey` 存在:
     - **強制從 KV 讀取授權碼** (`getLicenseFromKV`)
     - 驗證 `license.isValid === true` 且 `license.deviceId === deviceId`
     - 如果驗證通過，`isActivated = true`
     - 如果驗證失敗，清除設備上的 `licenseKey` 並保存
4. **返回結果**

#### 關鍵特性
- ✅ **強制從 KV 讀取**: 確保 redeploy/cold start 後授權仍存在
- ✅ **自動初始化**: device 不存在時自動創建並保存
- ✅ **授權驗證**: 驗證授權碼在持久化存儲中的有效性

---

### 2. `/api/trial/consume` - 消耗試用次數

**方法**: `POST`  
**用途**: 消耗一次試用次數（僅在未激活時）

#### 請求
```json
{
  "deviceId": "UUID-...",
  "feature": "teleport" | "route" | "favorite"  // 可選
}
```

#### 響應（成功）
```json
{
  "success": true,
  "trialCount": 2,
  "isActivated": false
}
```

#### 響應（已激活）
```json
{
  "success": true,
  "trialCount": 3,
  "isActivated": true,
  "message": "已激活，無需消耗試用次數"
}
```

#### 響應（試用次數已用完）
```json
{
  "error": "試用次數已用完，請購買授權",
  "trialCount": 0,
  "isActivated": false
}
```

#### 流程
1. **強制從 KV 讀取設備數據** (`getDeviceFromKV`)
2. **如果設備不存在**:
   - 創建新設備記錄: `trialCount = 3`, `licenseKey = null`
   - **保存到持久化存儲** (`setDevice`)
3. **檢查是否已激活**:
   - **強制從 KV 讀取授權碼** (`getLicenseFromKV`)
   - 如果已激活 (`isActivated === true`):
     - **不消耗試用次數**，直接返回成功
4. **檢查試用次數**:
   - 如果 `trialCount <= 0`，返回錯誤
5. **消耗試用次數**:
   - `trialCount--`
   - **保存到持久化存儲** (`setDevice`)
6. **返回結果**

#### 關鍵特性
- ✅ **授權後不扣 trial**: 已激活設備不消耗試用次數
- ✅ **強制從 KV 讀取**: 確保狀態一致性
- ✅ **自動初始化**: device 不存在時自動創建並保存

---

### 3. `/api/license/activate` - 激活授權碼

**方法**: `POST`  
**用途**: 激活授權碼，綁定到設備（永久激活）

#### 請求
```json
{
  "deviceId": "UUID-...",
  "licenseKey": "PKM-..."
}
```

#### 響應（成功）
```json
{
  "success": true,
  "message": "授權碼激活成功，設備已永久激活",
  "licenseKey": "PKM-...",
  "isActivated": true,
  "trialCount": 3,
  "activatedAt": "2025-01-XX..."
}
```

#### 響應（錯誤）
```json
{
  "error": "授權碼不存在" | "授權碼已失效" | "授權碼已被其他設備使用，每個激活碼只能使用一次"
}
```

#### 流程
1. **強制從 KV 讀取授權碼** (`getLicenseFromKV`)
   - 如果不存在，返回 404
   - 如果 `isValid === false`，返回 403
2. **檢查授權碼是否已被其他設備使用**:
   - 如果 `license.deviceId` 存在且不等於當前 `deviceId`，返回 403
3. **如果已激活過（同一個設備）**:
   - 直接返回成功（不需要重複激活）
4. **強制從 KV 讀取設備數據** (`getDeviceFromKV`)
   - 如果不存在，創建新設備記錄
5. **綁定授權碼到設備**:
   - `device.licenseKey = licenseKey`
   - `device.activatedAt = serverTime`
   - **保存到持久化存儲** (`setDevice`)
6. **綁定設備到授權碼**:
   - `license.deviceId = deviceId`
   - `license.activatedAt = serverTime`
   - **保存到持久化存儲** (`setLicense`)
7. **返回結果**

#### 關鍵特性
- ✅ **單次使用**: 每個激活碼只能使用一次（綁定到一個設備）
- ✅ **永久激活**: 激活後設備永久可用（不消耗試用次數）
- ✅ **強制保存到 KV**: 確保 redeploy/cold start 後授權仍存在
- ✅ **重複激活保護**: 同一個設備重複激活同一授權碼不會報錯

---

## 數據持久化保證

### 關鍵 API 強制從 KV 讀取

以下 API 使用 `getDeviceFromKV()` 和 `getLicenseFromKV()` 強制從 KV 讀取：
- `/api/auth/check`
- `/api/trial/consume`
- `/api/license/activate`

**目的**: 確保多實例環境下數據一致性，避免快取不一致問題。

### 寫入保證

所有 `setDevice()` 和 `setLicense()` 調用都會：
1. 更新本地快取（用於性能優化）
2. **強制寫入 KV**（如果配置了 KV）
3. 如果 KV 寫入失敗，拋出錯誤（生產環境）

---

## 冷啟動/Redeploy 後的行為

### 場景 1: Vercel KV 已配置

1. **服務器重啟**:
   - 內存快取清空
   - 從 KV 讀取設備和授權碼數據
   - **授權狀態保持不變** ✅

2. **代碼部署**:
   - 新實例啟動
   - 從 KV 讀取最新數據
   - **授權狀態保持不變** ✅

3. **多實例環境**:
   - 每個實例從 KV 讀取最新數據
   - **數據一致性保證** ✅

### 場景 2: Vercel KV 未配置（僅開發模式）

1. **服務器重啟**:
   - 內存快取清空
   - **所有數據丟失** ⚠️
   - 設備需要重新註冊（獲得 3 次試用）
   - 授權需要重新激活

2. **警告**:
   - 生產環境**必須配置 KV**
   - 未配置 KV 時，系統會記錄警告日誌

---

## 錯誤處理

### KV 讀取失敗

- **關鍵 API**: 拋出錯誤，返回 500
- **非關鍵 API**: 可能 fallback 到快取（僅開發模式）

### KV 寫入失敗

- **所有 API**: 拋出錯誤，返回 500
- **數據不會部分更新**（保證一致性）

---

## 環境變數配置

### 生產環境（Vercel）

在 Vercel 項目設置中添加：
```
KV_REST_API_URL=https://xxx.upstash.io
KV_REST_API_TOKEN=xxx
```

### 本地開發

創建 `.env` 文件（可選，用於測試 KV）：
```
KV_REST_API_URL=https://xxx.upstash.io
KV_REST_API_TOKEN=xxx
```

**注意**: 如果未配置，系統會使用內存快取（僅開發模式）。

---

## 日誌

所有關鍵操作都會記錄日誌，包括：
- 存儲來源（KV 或 Memory）
- 設備狀態變化
- 授權碼激活
- 試用次數消耗

**日誌格式**:
```
🔍 [授權檢查] 設備 ID: xxx, 時間: xxx, 存儲: KV
✅ [KV] 設備已保存到持久化存儲: xxx
```

---

**文檔結束**
