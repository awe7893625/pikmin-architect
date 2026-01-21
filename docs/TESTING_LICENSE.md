# 授權/試用系統測試文檔

**版本**: 2.0 (持久化存儲重構版)  
**更新時間**: 2025-01-XX

---

## 測試環境準備

### 1. 本地測試（使用內存快取）

```bash
cd website
npm install
npm start
```

**注意**: 未配置 KV 時，系統會使用內存快取（僅開發模式）。

### 2. 生產環境測試（使用 Vercel KV）

確保 Vercel 項目已配置：
- `KV_REST_API_URL`
- `KV_REST_API_TOKEN`

---

## 測試用例

### 測試 1: 新設備註冊和初始化

**目標**: 驗證 device 不存在時自動初始化 `trialCount=3` 並保存到 KV

#### 步驟
1. 使用新的 `deviceId` 調用 `/api/auth/check`
2. 檢查響應中的 `trialCount` 是否為 `3`
3. 檢查響應中的 `isActivated` 是否為 `false`
4. 檢查響應中的 `licenseKey` 是否為 `null`

#### 請求
```bash
curl -X POST http://localhost:3001/api/auth/check \
  -H "Content-Type: application/json" \
  -d '{"deviceId": "TEST-DEVICE-001"}'
```

#### 預期響應
```json
{
  "trialCount": 3,
  "licenseKey": null,
  "isActivated": false,
  "serverTime": "2025-01-XX..."
}
```

#### 驗證點
- ✅ `trialCount === 3`
- ✅ `isActivated === false`
- ✅ `licenseKey === null`
- ✅ 服務器日誌顯示 "新設備，創建記錄（3 次試用）並保存到持久化存儲"
- ✅ 服務器日誌顯示 "新設備已保存到持久化存儲"

---

### 測試 2: 試用次數消耗

**目標**: 驗證試用次數正確消耗，且保存到 KV

#### 步驟
1. 使用已註冊的 `deviceId` 調用 `/api/trial/consume`
2. 檢查響應中的 `trialCount` 是否減少 1
3. 再次調用 `/api/auth/check`，驗證 `trialCount` 是否已更新

#### 請求 1: 消耗試用
```bash
curl -X POST http://localhost:3001/api/trial/consume \
  -H "Content-Type: application/json" \
  -d '{"deviceId": "TEST-DEVICE-001", "feature": "teleport"}'
```

#### 預期響應 1
```json
{
  "success": true,
  "trialCount": 2,
  "isActivated": false
}
```

#### 請求 2: 檢查狀態
```bash
curl -X POST http://localhost:3001/api/auth/check \
  -H "Content-Type: application/json" \
  -d '{"deviceId": "TEST-DEVICE-001"}'
```

#### 預期響應 2
```json
{
  "trialCount": 2,
  "licenseKey": null,
  "isActivated": false,
  "serverTime": "2025-01-XX..."
}
```

#### 驗證點
- ✅ 第一次消耗後 `trialCount === 2`
- ✅ 第二次檢查時 `trialCount === 2`（狀態已保存）
- ✅ 服務器日誌顯示 "試用次數: 3 -> 2"

---

### 測試 3: 授權後不扣 trial

**目標**: 驗證已激活設備不消耗試用次數

#### 步驟
1. 激活授權碼（見測試 4）
2. 調用 `/api/trial/consume`
3. 檢查響應中的 `trialCount` 是否保持不變
4. 檢查響應中的 `isActivated` 是否為 `true`

#### 請求
```bash
curl -X POST http://localhost:3001/api/trial/consume \
  -H "Content-Type: application/json" \
  -d '{"deviceId": "TEST-DEVICE-001", "feature": "teleport"}'
```

#### 預期響應
```json
{
  "success": true,
  "trialCount": 2,
  "isActivated": true,
  "message": "已激活，無需消耗試用次數"
}
```

#### 驗證點
- ✅ `isActivated === true`
- ✅ `trialCount` 保持不變（不消耗）
- ✅ 服務器日誌顯示 "設備已激活，無需消耗試用次數"

---

### 測試 4: 授權碼激活

**目標**: 驗證授權碼激活流程，確保保存到 KV

#### 步驟
1. 使用測試授權碼激活設備
2. 檢查響應中的 `isActivated` 是否為 `true`
3. 調用 `/api/auth/check`，驗證授權狀態

#### 請求
```bash
curl -X POST http://localhost:3001/api/license/activate \
  -H "Content-Type: application/json" \
  -d '{
    "deviceId": "TEST-DEVICE-001",
    "licenseKey": "PKM-9A0EF1DD632BBC1D"
  }'
```

#### 預期響應
```json
{
  "success": true,
  "message": "授權碼激活成功，設備已永久激活",
  "licenseKey": "PKM-9A0EF1DD632BBC1D",
  "isActivated": true,
  "trialCount": 2,
  "activatedAt": "2025-01-XX..."
}
```

#### 驗證點
- ✅ `isActivated === true`
- ✅ `licenseKey` 正確返回
- ✅ `activatedAt` 不為 null
- ✅ 服務器日誌顯示 "設備記錄已保存到持久化存儲"
- ✅ 服務器日誌顯示 "授權碼記錄已保存到持久化存儲"

---

### 測試 5: Redeploy/Cold Start 後授權仍存在

**目標**: 驗證服務器重啟後授權狀態保持不變（僅在配置 KV 時有效）

#### 前置條件
- Vercel KV 已配置
- 設備已激活授權碼

#### 步驟
1. 激活授權碼（見測試 4）
2. **重啟服務器**（或等待冷啟動）
3. 調用 `/api/auth/check`
4. 檢查響應中的 `isActivated` 是否仍為 `true`

#### 請求
```bash
# 重啟服務器後
curl -X POST http://localhost:3001/api/auth/check \
  -H "Content-Type: application/json" \
  -d '{"deviceId": "TEST-DEVICE-001"}'
```

#### 預期響應
```json
{
  "trialCount": 2,
  "licenseKey": "PKM-9A0EF1DD632BBC1D",
  "isActivated": true,
  "serverTime": "2025-01-XX..."
}
```

#### 驗證點
- ✅ `isActivated === true`（重啟後仍為 true）
- ✅ `licenseKey` 正確返回
- ✅ 服務器日誌顯示 "存儲: KV"
- ✅ 服務器日誌顯示 "設備已激活，授權碼有效"

#### 注意
- 如果未配置 KV，此測試會失敗（內存快取在重啟後清空）
- 生產環境**必須配置 KV**才能通過此測試

---

### 測試 5.1: Vercel Redeploy 後授權仍存在（P1 建議）

**目標**: 驗證 Vercel 重新部署後授權狀態保持不變

#### 前置條件
- Vercel KV 已配置並通過 preflight 檢查
- 設備已激活授權碼
- 已部署到 Vercel

#### 步驟
1. **激活授權碼**（使用測試授權碼）
   ```bash
   curl -X POST https://your-vercel-app.vercel.app/api/license/activate \
     -H "Content-Type: application/json" \
     -d '{
       "deviceId": "TEST-DEVICE-REDEPLOY",
       "licenseKey": "PKM-9A0EF1DD632BBC1D"
     }'
   ```

2. **驗證激活成功**
   ```bash
   curl -X POST https://your-vercel-app.vercel.app/api/auth/check \
     -H "Content-Type: application/json" \
     -d '{"deviceId": "TEST-DEVICE-REDEPLOY"}'
   ```
   預期: `isActivated: true`

3. **觸發 Vercel Redeploy**
   - 在 Vercel Dashboard 點擊 "Redeploy"
   - 或推送一個無關的 commit 觸發自動部署
   - 等待部署完成（通常 1-2 分鐘）

4. **重新檢查授權狀態**（部署完成後）
   ```bash
   curl -X POST https://your-vercel-app.vercel.app/api/auth/check \
     -H "Content-Type: application/json" \
     -d '{"deviceId": "TEST-DEVICE-REDEPLOY"}'
   ```

#### 預期響應（Redeploy 後）
```json
{
  "trialCount": 2,
  "licenseKey": "PKM-9A0EF1DD632BBC1D",
  "isActivated": true,
  "serverTime": "2025-01-XX..."
}
```

#### 驗證點
- ✅ `isActivated === true`（redeploy 後仍為 true）
- ✅ `licenseKey` 正確返回
- ✅ `trialCount` 保持不變
- ✅ 服務器日誌顯示 "✅ [KV Preflight] 讀取測試成功"
- ✅ 服務器日誌顯示 "✅ [KV] Preflight 檢查通過，授權系統可用"

#### 失敗情況（KV 未配置）
如果 KV 未配置，應返回 503 錯誤：
```json
{
  "error": "授權系統暫時不可用",
  "message": "授權系統不可用：KV 環境變數未設定。請檢查 KV 配置。",
  "code": "KV_UNAVAILABLE"
}
```

#### 注意
- 此測試必須在 Vercel 生產環境執行
- 本地測試無法模擬 Vercel redeploy 場景
- 確保 Vercel 環境變數已正確配置 `KV_REST_API_URL` 和 `KV_REST_API_TOKEN`

---

### 測試 6: 授權碼單次使用限制

**目標**: 驗證每個激活碼只能使用一次

#### 步驟
1. 使用測試授權碼激活設備 A
2. 嘗試使用同一授權碼激活設備 B
3. 檢查是否返回錯誤

#### 請求 1: 激活設備 A
```bash
curl -X POST http://localhost:3001/api/license/activate \
  -H "Content-Type: application/json" \
  -d '{
    "deviceId": "TEST-DEVICE-A",
    "licenseKey": "PKM-CF711BA7A0DBC80C"
  }'
```

#### 請求 2: 嘗試激活設備 B（應失敗）
```bash
curl -X POST http://localhost:3001/api/license/activate \
  -H "Content-Type: application/json" \
  -d '{
    "deviceId": "TEST-DEVICE-B",
    "licenseKey": "PKM-CF711BA7A0DBC80C"
  }'
```

#### 預期響應 2
```json
{
  "error": "授權碼已被其他設備使用，每個激活碼只能使用一次"
}
```

#### 驗證點
- ✅ 設備 A 激活成功
- ✅ 設備 B 激活失敗，返回 403
- ✅ 錯誤訊息正確

---

### 測試 7: 重複激活同一設備

**目標**: 驗證同一設備重複激活同一授權碼不會報錯

#### 步驟
1. 激活授權碼
2. 再次使用同一授權碼激活同一設備
3. 檢查是否返回成功（不需要重複激活）

#### 請求 1: 首次激活
```bash
curl -X POST http://localhost:3001/api/license/activate \
  -H "Content-Type: application/json" \
  -d '{
    "deviceId": "TEST-DEVICE-001",
    "licenseKey": "PKM-2CA9C96C3A8AB6E8"
  }'
```

#### 請求 2: 重複激活（應成功）
```bash
curl -X POST http://localhost:3001/api/license/activate \
  -H "Content-Type: application/json" \
  -d '{
    "deviceId": "TEST-DEVICE-001",
    "licenseKey": "PKM-2CA9C96C3A8AB6E8"
  }'
```

#### 預期響應 2
```json
{
  "success": true,
  "message": "授權碼已激活（此設備已使用過此授權碼）",
  "licenseKey": "PKM-2CA9C96C3A8AB6E8",
  "isActivated": true,
  "trialCount": 2,
  "activatedAt": "2025-01-XX..."
}
```

#### 驗證點
- ✅ 重複激活返回成功
- ✅ `isActivated === true`
- ✅ 服務器日誌顯示 "設備已激活過此授權碼，直接返回成功"

---

## 測試腳本

### 完整測試流程

創建 `test_license_flow.sh`:

```bash
#!/bin/bash

API_BASE="http://localhost:3001/api"
DEVICE_ID="TEST-DEVICE-$(date +%s)"

echo "🧪 開始測試授權流程..."
echo "設備 ID: $DEVICE_ID"
echo ""

# 測試 1: 新設備註冊
echo "📝 測試 1: 新設備註冊"
RESPONSE=$(curl -s -X POST $API_BASE/auth/check \
  -H "Content-Type: application/json" \
  -d "{\"deviceId\": \"$DEVICE_ID\"}")
echo "響應: $RESPONSE"
echo ""

# 測試 2: 消耗試用
echo "🎯 測試 2: 消耗試用次數"
RESPONSE=$(curl -s -X POST $API_BASE/trial/consume \
  -H "Content-Type: application/json" \
  -d "{\"deviceId\": \"$DEVICE_ID\", \"feature\": \"teleport\"}")
echo "響應: $RESPONSE"
echo ""

# 測試 3: 激活授權碼
echo "🔑 測試 3: 激活授權碼"
RESPONSE=$(curl -s -X POST $API_BASE/license/activate \
  -H "Content-Type: application/json" \
  -d "{\"deviceId\": \"$DEVICE_ID\", \"licenseKey\": \"PKM-FE6C8F8CB7F37339\"}")
echo "響應: $RESPONSE"
echo ""

# 測試 4: 授權後不扣 trial
echo "✅ 測試 4: 授權後不扣 trial"
RESPONSE=$(curl -s -X POST $API_BASE/trial/consume \
  -H "Content-Type: application/json" \
  -d "{\"deviceId\": \"$DEVICE_ID\", \"feature\": \"teleport\"}")
echo "響應: $RESPONSE"
echo ""

# 測試 5: 檢查授權狀態
echo "🔍 測試 5: 檢查授權狀態"
RESPONSE=$(curl -s -X POST $API_BASE/auth/check \
  -H "Content-Type: application/json" \
  -d "{\"deviceId\": \"$DEVICE_ID\"}")
echo "響應: $RESPONSE"
echo ""

echo "✅ 測試完成"
```

**使用**:
```bash
chmod +x test_license_flow.sh
./test_license_flow.sh
```

---

## 測試檢查清單

### 功能測試
- [ ] 新設備自動初始化 `trialCount=3`
- [ ] 試用次數正確消耗
- [ ] 試用次數保存到 KV
- [ ] 授權後不扣 trial
- [ ] 授權碼激活成功
- [ ] 授權狀態保存到 KV
- [ ] 授權碼單次使用限制
- [ ] 重複激活同一設備不報錯

### 持久化測試（需配置 KV）
- [ ] 服務器重啟後授權仍存在
- [ ] 服務器重啟後試用次數仍正確
- [ ] 多實例環境數據一致性

### 錯誤處理測試
- [ ] 無效授權碼返回 404
- [ ] 已失效授權碼返回 403
- [ ] 已被其他設備使用的授權碼返回 403
- [ ] 試用次數用完時返回 403

---

## 測試授權碼

以下測試授權碼已在系統初始化時自動創建：

- `PKM-9A0EF1DD632BBC1D`
- `PKM-CF711BA7A0DBC80C`
- `PKM-2CA9C96C3A8AB6E8`
- `PKM-FE6C8F8CB7F37339`
- `PKM-F7EC3C6305756F6C`

**注意**: 這些授權碼僅用於測試，每個只能使用一次。

---

**文檔結束**
