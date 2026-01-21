# 授權/試用系統現況盤點報告

**生成時間**: 2025-01-XX  
**範圍**: 前端 (macOS App) + 後端 (Vercel Server)

---

## 1. 涉及授權狀態的檔案與函數清單

### 1.1 後端 (Backend)

#### `website/server.js`
- **行 15-39**: 持久化存儲層初始化（Vercel KV + 內存 Map fallback）
  - `devicesCache` (Map): 設備快取
  - `licensesCache` (Map): 授權碼快取
  - `ordersCache` (Map): 訂單快取
- **行 44-77**: `getDevice(deviceId)`, `setDevice(deviceId, deviceData)` - 設備數據操作
- **行 79-113**: `getLicense(licenseKey)`, `setLicense(licenseKey, licenseData)` - 授權碼操作
- **行 115-149**: `getOrder(orderId)`, `setOrder(orderId, orderData)` - 訂單操作
- **行 315-373**: `POST /api/auth/check` - **核心授權檢查 API**（Single Source of Truth）
  - 從持久化存儲讀取設備數據
  - 驗證 `device.licenseKey` 是否存在於 `licenses` Map 中
  - 返回 `{ trialCount, licenseKey, isActivated }`
- **行 376-444**: `POST /api/trial/consume` - 消耗試用次數
  - 檢查 `isActivated`，如果已激活則不消耗試用次數
- **行 454-549**: `POST /api/license/activate` - 激活授權碼
  - 驗證授權碼有效性
  - 綁定 `licenseKey` 到 `deviceId`
  - 更新設備和授權碼記錄

#### `server/auth_server.js` (舊版，可能已廢棄)
- **行 11-12**: 內存 Map 定義
  - `devices` (Map): `deviceId -> { trialCount, licenseKey, activatedAt }`
  - `licenses` (Map): `licenseKey -> { deviceId, paidAt, isValid, createdAt }`
- **行 59-83**: `POST /api/auth/check` - 舊版授權檢查（僅內存，無持久化）

### 1.2 前端 (Frontend)

#### `PikminArchitect/ContentView.swift`
- **行 1387-1530**: `checkAuthStatus()` - **核心授權檢查函數**
  - 發送 POST 請求到 `/api/auth/check`
  - 解析響應中的 `isActivated` 和 `trialCount`
  - **行 1460-1462**: 關鍵判斷邏輯
    ```swift
    // ⚠️ 修正：僅依賴 server 返回的 isActivated 作為唯一判斷依據
    let isPaid = isActivated
    ```
  - 調用 JavaScript `updateTrialStatus(remaining, isPaid)` 更新 UI
- **行 1215-1384**: `activateLicense(licenseKey: String)` - 激活授權碼
  - 發送 POST 請求到 `/api/license/activate`
  - 成功後清除 `localStorage` 並更新 UI
- **行 1533-1536**: `getDeviceId() -> String` - 獲取 Mac 硬體 UUID
- **行 1600-1650**: `userContentController` - WKWebView 消息處理器
  - `case "checkAuth"`: 調用 `checkAuthStatus()`
  - `case "activateLicense"`: 調用 `activateLicense(licenseKey:)`
  - `case "openPayment"`: 打開付款 URL

#### `PikminArchitect/index.html`
- **行 234-238**: `globalAuthState` 全局變數定義
  ```javascript
  var globalAuthState = {
      isPaid: false,
      remaining: 3,
      lastCheck: null
  };
  ```
- **行 270-272**: `checkAuthStatus()` - JavaScript 函數
  - 通過 `window.webkit.messageHandlers.bridge.postMessage({ act: 'checkAuth' })` 觸發 Swift 端檢查
- **行 371-443**: `updateTrialStatus(remaining, isPaid)` - **核心 UI 更新函數**
  - **行 381-385**: 更新 `globalAuthState`
    ```javascript
    if (typeof globalAuthState !== 'undefined') {
        globalAuthState.isPaid = isPaid;
        globalAuthState.remaining = remaining;
        globalAuthState.lastCheck = new Date().toISOString();
    }
    ```
  - 根據 `isPaid` 和 `remaining` 更新 UI 顯示
- **行 1062-1120**: `consumeTrialAndRun(feature)` - 消耗試用次數並執行功能
  - **行 1072**: 檢查 `globalAuthState.isPaid`
    ```javascript
    if (globalAuthState.isPaid) {
        console.log('✅ [功能使用] 設備已激活，直接執行功能:', feature);
        executeFeature(feature);
        return;
    }
    ```
  - 如果未付費，發送 POST 請求到 `/api/trial/consume`
  - **行 1098-1100**: 更新 `globalAuthState`
    ```javascript
    globalAuthState.remaining = data.trialCount;
    globalAuthState.isPaid = data.isActivated || false;
    globalAuthState.lastCheck = new Date().toISOString();
    ```
- **行 274-281**: `activateLicense()` - JavaScript 激活函數
  - 通過 bridge 調用 Swift 端的 `activateLicense`

---

## 2. localStorage / globalAuthState / in-memory Map 使用位置

### 2.1 localStorage 使用位置

#### `PikminArchitect/index.html`
- **行 585, 642, 674, 687, 709, 741, 779, 837, 932, 951, 1006, 1017, 1211, 1228, 1386**: `localStorage.getItem('favLocs')` / `localStorage.setItem('favLocs', ...)`
  - 用途：存儲用戶的最愛地點（**與授權無關**）
- **行 1156, 1167**: `localStorage.getItem('deviceId')` / `localStorage.setItem('deviceId', ...)`
  - 用途：快取設備 ID（**與授權無關**）
- **行 1251, 1270**: `localStorage.getItem('language')` / `localStorage.setItem('language', ...)`
  - 用途：存儲用戶選擇的語言（**與授權無關**）
- **行 1290-1293** (ContentView.swift 中的 JavaScript 注入): `localStorage.removeItem('favLocs')`, `localStorage.removeItem('tpLocs')`
  - 用途：激活成功後清除本地存儲（**與授權無關**，僅清理用戶數據）

**⚠️ 重要發現**: `localStorage` **不存儲授權狀態**，僅用於用戶偏好設置（最愛地點、語言）和設備 ID 快取。

### 2.2 globalAuthState 使用位置

#### `PikminArchitect/index.html`
- **行 234-238**: 定義
  ```javascript
  var globalAuthState = {
      isPaid: false,
      remaining: 3,
      lastCheck: null
  };
  ```
- **行 381-385**: 在 `updateTrialStatus()` 中更新
  ```javascript
  if (typeof globalAuthState !== 'undefined') {
      globalAuthState.isPaid = isPaid;
      globalAuthState.remaining = remaining;
      globalAuthState.lastCheck = new Date().toISOString();
  }
  ```
- **行 1064-1069**: 在 `consumeTrialAndRun()` 中檢查是否已初始化
  ```javascript
  if (typeof globalAuthState === 'undefined' || !globalAuthState.lastCheck) {
      console.warn('⚠️ [功能使用] 授權狀態未初始化，先檢查授權');
      checkAuthStatus();
      await new Promise(resolve => setTimeout(resolve, 1000));
  }
  ```
- **行 1072**: 在 `consumeTrialAndRun()` 中檢查 `isPaid`
  ```javascript
  if (globalAuthState.isPaid) {
      console.log('✅ [功能使用] 設備已激活，直接執行功能:', feature);
      executeFeature(feature);
      return;
  }
  ```
- **行 1079**: 在 `consumeTrialAndRun()` 中檢查 `remaining`
  ```javascript
  if (globalAuthState.remaining <= 0) {
      alert('試用次數已用完，請購買授權');
      return;
  }
  ```
- **行 1098-1100**: 在 `consumeTrialAndRun()` 中更新（從 `/api/trial/consume` 響應）
  ```javascript
  globalAuthState.remaining = data.trialCount;
  globalAuthState.isPaid = data.isActivated || false;
  globalAuthState.lastCheck = new Date().toISOString();
  ```

**用途**: `globalAuthState` 是前端 JavaScript 的**內存狀態**，用於：
1. 快速判斷功能是否可用（避免每次都要發送 API 請求）
2. 在 `consumeTrialAndRun()` 中決定是否直接執行功能或消耗試用次數

**⚠️ 問題**: `globalAuthState` 是**易失性**的，App 重啟後會重置為初始值。必須在 App 啟動時調用 `checkAuthStatus()` 來初始化。

### 2.3 in-memory Map 使用位置

#### `website/server.js`
- **行 37-39**: 定義（作為快取層）
  ```javascript
  const devicesCache = new Map(); // deviceId -> { trialCount, licenseKey, activatedAt }
  const licensesCache = new Map(); // licenseKey -> { deviceId, paidAt, isValid, createdAt }
  const ordersCache = new Map(); // orderId -> { planType, amount, status, licenseKey, createdAt, paidAt }
  ```
- **行 44-77**: `getDevice()` / `setDevice()` - 同時更新 KV 和快取
  - 如果 `useKV && kv`，從 Vercel KV 讀取，並更新快取
  - 如果沒有 KV，僅使用快取（開發模式）
- **行 79-113**: `getLicense()` / `setLicense()` - 同時更新 KV 和快取
- **行 115-149**: `getOrder()` / `setOrder()` - 同時更新 KV 和快取

**用途**: 
- **生產環境（Vercel KV 已配置）**: 快取層，提高讀取性能
- **開發環境（Vercel KV 未配置）**: 主要存儲，但**易失性**（服務器重啟後數據丟失）

#### `server/auth_server.js` (舊版，可能已廢棄)
- **行 11-12**: 定義（僅內存，無持久化）
  ```javascript
  const devices = new Map(); // deviceId -> { trialCount, licenseKey, activatedAt }
  const licenses = new Map(); // licenseKey -> { deviceId, paidAt, isValid, createdAt }
  ```

**⚠️ 問題**: 如果 `server/auth_server.js` 仍在被使用，且未配置 Vercel KV，所有授權數據會在服務器重啟後丟失。

---

## 3. isPaid 判斷邏輯（以 licenseKey 存在性判斷）

### 3.1 後端判斷邏輯

#### `website/server.js` - `POST /api/auth/check` (行 315-373)
```javascript
// 行 342-356: 檢查是否已激活
let isActivated = false;
if (device.licenseKey) {  // ⚠️ 檢查 licenseKey 是否存在
    const license = await getLicense(device.licenseKey);  // 從持久化存儲讀取
    if (license && license.isValid && license.deviceId === deviceId) {
        isActivated = true;
        console.log('✅ [授權檢查] 設備已激活，授權碼有效');
    } else {
        // 授權碼無效或被其他設備使用，清除設備上的 licenseKey
        console.warn('⚠️ [授權檢查] 授權碼無效或已被其他設備使用，清除設備授權碼');
        device.licenseKey = null;
        device.activatedAt = null;
        device.updatedAt = serverTime;
        await setDevice(deviceId, device);
    }
}
```

**判斷邏輯**:
1. 檢查 `device.licenseKey` 是否存在（非 null）
2. 如果存在，從持久化存儲讀取 `license` 對象
3. 驗證 `license.isValid === true` 且 `license.deviceId === deviceId`
4. 如果驗證通過，`isActivated = true`

**⚠️ 關鍵**: 僅有 `device.licenseKey` 存在**不足以**判斷 `isPaid`，還需要驗證授權碼在持久化存儲中的有效性。

#### `website/server.js` - `POST /api/trial/consume` (行 402-407)
```javascript
// 行 402-407: 檢查是否已激活
let isActivated = false;
if (device.licenseKey) {  // ⚠️ 檢查 licenseKey 是否存在
    const license = await getLicense(device.licenseKey);
    isActivated = license && license.isValid && license.deviceId === deviceId;
}
```

**判斷邏輯**: 與 `/api/auth/check` 相同。

### 3.2 前端判斷邏輯

#### `PikminArchitect/ContentView.swift` - `checkAuthStatus()` (行 1453-1462)
```swift
if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
    let trialCount = json["trialCount"] as? Int ?? 0
    let isActivated = json["isActivated"] as? Bool ?? false
    let licenseKey = json["licenseKey"] as? String
    
    print("✅ [授權檢查] 服務器返回: trialCount=\(trialCount), isActivated=\(isActivated), licenseKey=\(licenseKey ?? "nil")")
    
    // ⚠️ 修正：僅依賴 server 返回的 isActivated 作為唯一判斷依據
    // 不可使用 licenseKey 存在性檢查，因為 server 可能已重啟，licenseKey 在 server 端已遺失
    let isPaid = isActivated  // ⚠️ 關鍵：直接使用 server 的 isActivated
    
    print("💰 [授權檢查] 最終判斷: isPaid=\(isPaid) (僅依賴 server 的 isActivated，這是唯一真實來源)")
```

**判斷邏輯**:
- **行 1462**: `let isPaid = isActivated` - **直接使用 server 返回的 `isActivated`**
- **⚠️ 重要**: 註釋明確說明**不使用 `licenseKey` 存在性檢查**，因為服務器可能已重啟，`licenseKey` 在服務器端可能已遺失（如果使用內存 Map 且未配置 KV）

**歷史問題**: 之前的代碼可能使用 `let isPaid = isActivated || (licenseKey != nil && !licenseKey!.isEmpty)`，這會導致：
- 如果服務器重啟，內存 Map 清空，`device.licenseKey` 仍存在但 `license` 不存在
- 前端收到 `isActivated: false` 但 `licenseKey: "PKM-..."`，前端錯誤地判斷為 `isPaid = true`

#### `PikminArchitect/index.html` - `updateTrialStatus()` (行 371-443)
```javascript
function updateTrialStatus(remaining, isPaid) {
    // 行 381-385: 更新全局授權狀態
    if (typeof globalAuthState !== 'undefined') {
        globalAuthState.isPaid = isPaid;  // ⚠️ 直接使用傳入的 isPaid 參數
        globalAuthState.remaining = remaining;
        globalAuthState.lastCheck = new Date().toISOString();
    }
    
    // 行 389-415: 根據 isPaid 更新 UI
    if(isPaid) {
        // 已付費用戶：隱藏所有授權相關 UI
        countEl.textContent = translations.unlimitedUse || '已購買，無限制使用';
        // ...
    } else {
        // 未付費用戶
        // ...
    }
}
```

**判斷邏輯**: 直接使用傳入的 `isPaid` 參數，不進行額外判斷。

#### `PikminArchitect/index.html` - `consumeTrialAndRun()` (行 1072, 1099)
```javascript
// 行 1072: 檢查 globalAuthState.isPaid
if (globalAuthState.isPaid) {
    console.log('✅ [功能使用] 設備已激活，直接執行功能:', feature);
    executeFeature(feature);
    return;
}

// 行 1098-1100: 從 API 響應更新 globalAuthState
globalAuthState.remaining = data.trialCount;
globalAuthState.isPaid = data.isActivated || false;  // ⚠️ 使用 server 返回的 isActivated
globalAuthState.lastCheck = new Date().toISOString();
```

**判斷邏輯**: 
- **行 1072**: 使用 `globalAuthState.isPaid`（由 `updateTrialStatus()` 更新）
- **行 1099**: 從 `/api/trial/consume` 響應中更新 `globalAuthState.isPaid = data.isActivated || false`

---

## 4. Vercel 冷啟動/多實例導致的授權狀態亂跳問題

### 4.1 問題根源

#### 場景 1: Vercel KV 未配置（僅使用內存 Map）
- **問題**: `website/server.js` 中的 `devicesCache` 和 `licensesCache` 是**內存 Map**，在服務器重啟後會清空
- **觸發條件**:
  1. Vercel 冷啟動（長時間無請求後，實例被銷毀）
  2. 代碼部署（新版本部署時，舊實例被替換）
  3. 服務器錯誤導致進程重啟
- **影響**:
  - 設備記錄 (`device.trialCount`, `device.licenseKey`) 丟失
  - 授權碼記錄 (`license.deviceId`, `license.isValid`) 丟失
  - 用戶已激活的設備會被重置為「未激活」狀態

#### 場景 2: Vercel 多實例（即使配置了 KV）
- **問題**: Vercel 可能同時運行多個實例，每個實例都有自己的**快取層** (`devicesCache`, `licensesCache`)
- **觸發條件**:
  1. 高流量時，Vercel 自動擴展多個實例
  2. 不同實例的快取可能不同步
- **影響**:
  - 實例 A 更新了設備記錄並寫入 KV，但實例 B 的快取仍是舊數據
  - 用戶請求可能被路由到實例 B，讀取到過期的快取數據
  - 導致 `isActivated` 判斷不一致

### 4.2 具體代碼位置

#### `website/server.js` - 快取層邏輯 (行 44-77, 79-113)
```javascript
// 行 44-62: getDevice()
async function getDevice(deviceId) {
    if (useKV && kv) {
        try {
            const key = `device:${deviceId}`;
            const data = await kv.get(key);  // ⚠️ 從 KV 讀取
            if (data) {
                // 同時更新快取
                devicesCache.set(deviceId, data);  // ⚠️ 更新本地快取
                return data;
            }
            return null;
        } catch (error) {
            console.error('❌ [KV] 讀取設備失敗:', error);
            // Fallback 到快取
            return devicesCache.get(deviceId) || null;  // ⚠️ 如果 KV 失敗，使用快取
        }
    }
    return devicesCache.get(deviceId) || null;  // ⚠️ 如果沒有 KV，僅使用快取
}
```

**問題**:
1. **快取不一致**: 實例 A 更新了 KV 和快取，但實例 B 的快取仍是舊數據
2. **Fallback 風險**: 如果 KV 讀取失敗，會 fallback 到快取，可能返回過期數據

#### `website/server.js` - `POST /api/auth/check` (行 326, 344)
```javascript
// 行 326: 從持久化存儲讀取設備數據
let device = await getDevice(deviceId);  // ⚠️ 可能從快取讀取（如果 KV 失敗或未配置）

// 行 344: 從持久化存儲讀取授權碼
const license = await getLicense(device.licenseKey);  // ⚠️ 可能從快取讀取
```

**問題**:
- 如果 `getDevice()` 或 `getLicense()` 從快取讀取，且快取未同步，可能返回過期數據
- 導致 `isActivated` 判斷錯誤

### 4.3 解決方案建議

#### 方案 1: 強制從 KV 讀取（跳過快取）
```javascript
async function getDeviceFromKV(deviceId) {
    if (useKV && kv) {
        try {
            const key = `device:${deviceId}`;
            const data = await kv.get(key);
            return data;
        } catch (error) {
            console.error('❌ [KV] 讀取設備失敗:', error);
            return null;
        }
    }
    return null;  // 如果沒有 KV，返回 null（不 fallback 到快取）
}
```

**優點**: 確保每次讀取都是最新數據  
**缺點**: 增加 KV 讀取延遲，可能影響性能

#### 方案 2: 快取失效機制
```javascript
// 在更新設備記錄時，清除所有實例的快取（通過 KV 事件或 TTL）
async function setDevice(deviceId, deviceData) {
    devicesCache.set(deviceId, deviceData);  // 更新本地快取
    
    if (useKV && kv) {
        try {
            const key = `device:${deviceId}`;
            await kv.set(key, deviceData);
            // ⚠️ 可以設置 TTL 或發布事件通知其他實例清除快取
        } catch (error) {
            console.error('❌ [KV] 保存設備失敗:', error);
        }
    }
}
```

**優點**: 平衡性能和一致性  
**缺點**: 需要實現快取失效機制（TTL 或事件通知）

#### 方案 3: 僅在關鍵 API 中強制從 KV 讀取
```javascript
app.post('/api/auth/check', async (req, res) => {
    // ⚠️ 關鍵 API：強制從 KV 讀取，不使用快取
    let device = null;
    if (useKV && kv) {
        try {
            const key = `device:${deviceId}`;
            device = await kv.get(key);
        } catch (error) {
            console.error('❌ [KV] 讀取設備失敗:', error);
        }
    }
    
    // 如果 KV 讀取失敗，才 fallback 到快取
    if (!device) {
        device = devicesCache.get(deviceId) || null;
    }
    
    // ... 後續邏輯
});
```

**優點**: 關鍵 API 保證一致性，其他 API 仍可使用快取提高性能  
**缺點**: 需要識別哪些 API 是「關鍵」的

---

## 5. 總結與建議

### 5.1 當前狀態
- ✅ **前端**: 已修正為僅依賴 server 返回的 `isActivated`，不使用 `licenseKey` 存在性判斷
- ✅ **後端**: `/api/auth/check` 會驗證 `license` 在持久化存儲中的有效性
- ⚠️ **快取層**: 存在多實例快取不一致的風險
- ⚠️ **持久化**: 如果未配置 Vercel KV，所有數據會在服務器重啟後丟失

### 5.2 建議改進
1. **強制配置 Vercel KV**: 確保生產環境必須配置 `KV_REST_API_URL` 和 `KV_REST_API_TOKEN`
2. **關鍵 API 強制從 KV 讀取**: `/api/auth/check` 和 `/api/license/activate` 應強制從 KV 讀取，不使用快取
3. **快取失效機制**: 實現 TTL 或事件通知，確保多實例快取同步
4. **監控與日誌**: 記錄每次授權檢查的存儲來源（KV 或快取），便於排查問題

---

**報告結束**
