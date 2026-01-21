# Admin Console 驗收文件

## 驗收條件

本文件提供可機器驗證的 `curl -i` 示範，證明 Admin Console 功能正常運作。

## 前置條件

1. **環境變數設定**：
   ```bash
   export ENABLE_ADMIN_CONSOLE=1
   export ADMIN_KEY=test-admin-key-12345
   export KV_MODE=mock  # 本地測試用
   ```

2. **啟動伺服器**：
   ```bash
   cd website
   node server.js
   ```

3. **確認伺服器運行**：
   ```bash
   curl -i http://localhost:3001/api/health
   ```

## 驗收測試

### 1. 測試 Admin Console UI 訪問（三道門保護）

#### 1.1 無 Admin Key → 404

```bash
curl -i http://localhost:3001/admin
```

**預期輸出：**
```
HTTP/1.1 404 Not Found
...
Not Found
```

#### 1.2 錯誤的 Admin Key → 404

```bash
curl -i -H "x-admin-key: wrong-key" http://localhost:3001/admin
```

**預期輸出：**
```
HTTP/1.1 404 Not Found
...
Not Found
```

#### 1.3 正確的 Admin Key → 200（HTML 內容）

```bash
curl -i -H "x-admin-key: test-admin-key-12345" http://localhost:3001/admin
```

**預期輸出：**
```
HTTP/1.1 200 OK
Content-Type: text/html; charset=UTF-8
...
<!DOCTYPE html>
<html lang="zh-TW">
...
```

### 2. 測試 GET /api/admin/licenses

#### 2.1 無 Admin Key → 404

```bash
curl -i -X GET http://localhost:3001/api/admin/licenses
```

**預期輸出：**
```
HTTP/1.1 404 Not Found
...
Not Found
```

#### 2.2 正確的 Admin Key → 200（空列表）

```bash
curl -i -X GET \
  -H "Content-Type: application/json" \
  -H "x-admin-key: test-admin-key-12345" \
  http://localhost:3001/api/admin/licenses
```

**預期輸出：**
```
HTTP/1.1 200 OK
Content-Type: application/json
...
{
  "items": [],
  "summary": {
    "total": 0,
    "used": 0,
    "unused": 0,
    "adminGrantedDevices": 0
  }
}
```

### 3. 測試 POST /api/admin/license/create

#### 3.1 無 Admin Key → 404

```bash
curl -i -X POST \
  -H "Content-Type: application/json" \
  -d '{"planType":"annual","note":"測試授權"}' \
  http://localhost:3001/api/admin/license/create
```

**預期輸出：**
```
HTTP/1.1 404 Not Found
...
Not Found
```

#### 3.2 無效的 planType → 400

```bash
curl -i -X POST \
  -H "Content-Type: application/json" \
  -H "x-admin-key: test-admin-key-12345" \
  -d '{"planType":"invalid"}' \
  http://localhost:3001/api/admin/license/create
```

**預期輸出：**
```
HTTP/1.1 400 Bad Request
Content-Type: application/json
...
{
  "error": "無效的授權類型",
  "code": "BAD_REQUEST"
}
```

#### 3.3 創建年費授權 → 200

```bash
curl -i -X POST \
  -H "Content-Type: application/json" \
  -H "x-admin-key: test-admin-key-12345" \
  -d '{"planType":"annual","note":"測試年費授權"}' \
  http://localhost:3001/api/admin/license/create
```

**預期輸出：**
```
HTTP/1.1 200 OK
Content-Type: application/json
...
{
  "success": true,
  "licenseKey": "PKM-XXXXXXXXXXXX",
  "licenseKeyMasked": "PKM-XXXXXXXX****XXXX",
  "createdAt": "2025-01-XX..."
}
```

**記錄 licenseKey 供後續測試使用：**
```bash
export TEST_LICENSE_KEY="PKM-XXXXXXXXXXXX"  # 替換為實際的 licenseKey
```

#### 3.4 創建永久授權 → 200

```bash
curl -i -X POST \
  -H "Content-Type: application/json" \
  -H "x-admin-key: test-admin-key-12345" \
  -d '{"planType":"lifetime","note":"測試永久授權"}' \
  http://localhost:3001/api/admin/license/create
```

**預期輸出：**
```
HTTP/1.1 200 OK
Content-Type: application/json
...
{
  "success": true,
  "licenseKey": "PKM-YYYYYYYYYYYY",
  "licenseKeyMasked": "PKM-YYYYYYYY****YYYY",
  "createdAt": "2025-01-XX..."
}
```

#### 3.5 驗證授權已加入列表

```bash
curl -i -X GET \
  -H "Content-Type: application/json" \
  -H "x-admin-key: test-admin-key-12345" \
  http://localhost:3001/api/admin/licenses
```

**預期輸出：**
```
HTTP/1.1 200 OK
Content-Type: application/json
...
{
  "items": [
    {
      "licenseKeyMasked": "PKM-XXXXXXXX****XXXX",
      "licenseKey": "PKM-XXXXXXXXXXXX",
      "planType": "annual",
      "issuedBy": "admin",
      "note": "測試年費授權",
      "createdAt": "2025-01-XX...",
      "activatedAt": null,
      "boundDeviceIdShort": null,
      "boundDeviceId": null,
      "status": "unused"
    },
    {
      "licenseKeyMasked": "PKM-YYYYYYYY****YYYY",
      "licenseKey": "PKM-YYYYYYYYYYYY",
      "planType": "lifetime",
      "issuedBy": "admin",
      "note": "測試永久授權",
      "createdAt": "2025-01-XX...",
      "activatedAt": null,
      "boundDeviceIdShort": null,
      "boundDeviceId": null,
      "status": "unused"
    }
  ],
  "summary": {
    "total": 2,
    "used": 0,
    "unused": 2,
    "adminGrantedDevices": 0
  }
}
```

### 4. 測試 POST /api/admin/license/rebind

#### 4.1 無 Admin Key → 404

```bash
curl -i -X POST \
  -H "Content-Type: application/json" \
  -d '{"licenseKey":"PKM-XXXXXXXXXXXX","newDeviceId":"Mac-TestDevice123"}' \
  http://localhost:3001/api/admin/license/rebind
```

**預期輸出：**
```
HTTP/1.1 404 Not Found
...
Not Found
```

#### 4.2 缺少必要參數 → 400

```bash
curl -i -X POST \
  -H "Content-Type: application/json" \
  -H "x-admin-key: test-admin-key-12345" \
  -d '{"licenseKey":"PKM-XXXXXXXXXXXX"}' \
  http://localhost:3001/api/admin/license/rebind
```

**預期輸出：**
```
HTTP/1.1 400 Bad Request
Content-Type: application/json
...
{
  "error": "缺少必要參數",
  "code": "BAD_REQUEST"
}
```

#### 4.3 授權碼不存在 → 404

```bash
curl -i -X POST \
  -H "Content-Type: application/json" \
  -H "x-admin-key: test-admin-key-12345" \
  -d '{"licenseKey":"PKM-NOTEXIST","newDeviceId":"Mac-TestDevice123"}' \
  http://localhost:3001/api/admin/license/rebind
```

**預期輸出：**
```
HTTP/1.1 404 Not Found
Content-Type: application/json
...
{
  "error": "授權碼不存在",
  "code": "LICENSE_NOT_FOUND"
}
```

#### 4.4 重新綁定成功 → 200

```bash
curl -i -X POST \
  -H "Content-Type: application/json" \
  -H "x-admin-key: test-admin-key-12345" \
  -d "{\"licenseKey\":\"${TEST_LICENSE_KEY}\",\"newDeviceId\":\"Mac-TestDevice123\"}" \
  http://localhost:3001/api/admin/license/rebind
```

**預期輸出：**
```
HTTP/1.1 200 OK
Content-Type: application/json
...
{
  "success": true
}
```

#### 4.5 驗證授權狀態已更新

```bash
curl -i -X GET \
  -H "Content-Type: application/json" \
  -H "x-admin-key: test-admin-key-12345" \
  http://localhost:3001/api/admin/licenses
```

**預期輸出：**
```
HTTP/1.1 200 OK
Content-Type: application/json
...
{
  "items": [
    {
      "licenseKeyMasked": "PKM-XXXXXXXX****XXXX",
      "licenseKey": "PKM-XXXXXXXXXXXX",
      "planType": "annual",
      "issuedBy": "admin",
      "note": "測試年費授權",
      "createdAt": "2025-01-XX...",
      "activatedAt": "2025-01-XX...",
      "boundDeviceIdShort": "Mac-Te…",
      "boundDeviceId": "Mac-TestDevice123",
      "status": "used"
    },
    ...
  ],
  "summary": {
    "total": 2,
    "used": 1,
    "unused": 1,
    "adminGrantedDevices": 0
  }
}
```

### 5. 測試 POST /api/admin/device/grant

#### 5.1 無 Admin Key → 404

```bash
curl -i -X POST \
  -H "Content-Type: application/json" \
  -d '{"deviceId":"Mac-TestDevice456","note":"測試直接授權"}' \
  http://localhost:3001/api/admin/device/grant
```

**預期輸出：**
```
HTTP/1.1 404 Not Found
...
Not Found
```

#### 5.2 缺少 deviceId → 400

```bash
curl -i -X POST \
  -H "Content-Type: application/json" \
  -H "x-admin-key: test-admin-key-12345" \
  -d '{"note":"測試直接授權"}' \
  http://localhost:3001/api/admin/device/grant
```

**預期輸出：**
```
HTTP/1.1 400 Bad Request
Content-Type: application/json
...
{
  "error": "缺少裝置 ID",
  "code": "BAD_REQUEST"
}
```

#### 5.3 直接授權成功 → 200

```bash
curl -i -X POST \
  -H "Content-Type: application/json" \
  -H "x-admin-key: test-admin-key-12345" \
  -d '{"deviceId":"Mac-TestDevice456","note":"測試直接授權"}' \
  http://localhost:3001/api/admin/device/grant
```

**預期輸出：**
```
HTTP/1.1 200 OK
Content-Type: application/json
...
{
  "success": true
}
```

### 6. 測試 Fail Closed（KV 不可用）

#### 6.1 設定 KV_MOCK_BREAK=1

```bash
export KV_MOCK_BREAK=1
# 重啟伺服器
```

#### 6.2 測試 Admin API → 503

```bash
curl -i -X GET \
  -H "Content-Type: application/json" \
  -H "x-admin-key: test-admin-key-12345" \
  http://localhost:3001/api/admin/licenses
```

**預期輸出：**
```
HTTP/1.1 503 Service Unavailable
Content-Type: application/json
...
{
  "error": "授權系統暫時不可用",
  "message": "授權系統不可用：KV Health check 失敗。請檢查 KV 配置。",
  "code": "KV_UNAVAILABLE"
}
```

#### 6.3 測試創建授權 → 503

```bash
curl -i -X POST \
  -H "Content-Type: application/json" \
  -H "x-admin-key: test-admin-key-12345" \
  -d '{"planType":"annual","note":"測試"}' \
  http://localhost:3001/api/admin/license/create
```

**預期輸出：**
```
HTTP/1.1 503 Service Unavailable
Content-Type: application/json
...
{
  "error": "授權系統暫時不可用",
  "message": "授權系統不可用：KV Health check 失敗。請檢查 KV 配置。",
  "code": "KV_UNAVAILABLE"
}
```

## 完整流程測試

### 流程：給朋友授權

```bash
# 1. 創建授權
RESPONSE=$(curl -s -X POST \
  -H "Content-Type: application/json" \
  -H "x-admin-key: test-admin-key-12345" \
  -d '{"planType":"lifetime","note":"給朋友的授權"}' \
  http://localhost:3001/api/admin/license/create)

LICENSE_KEY=$(echo $RESPONSE | grep -o '"licenseKey":"[^"]*' | cut -d'"' -f4)
echo "授權碼: $LICENSE_KEY"

# 2. 驗證授權已創建
curl -i -X GET \
  -H "Content-Type: application/json" \
  -H "x-admin-key: test-admin-key-12345" \
  http://localhost:3001/api/admin/licenses | grep -A 5 "給朋友的授權"

# 3. 模擬朋友激活（通過正常激活 API）
curl -i -X POST \
  -H "Content-Type: application/json" \
  -d "{\"deviceId\":\"Mac-FriendDevice\",\"licenseKey\":\"${LICENSE_KEY}\"}" \
  http://localhost:3001/api/license/activate

# 4. 驗證授權狀態已更新
curl -i -X GET \
  -H "Content-Type: application/json" \
  -H "x-admin-key: test-admin-key-12345" \
  http://localhost:3001/api/admin/licenses | grep -A 10 "Mac-FriendDevice"
```

### 流程：作者自救

```bash
# 1. 直接授權自己的裝置
curl -i -X POST \
  -H "Content-Type: application/json" \
  -H "x-admin-key: test-admin-key-12345" \
  -d '{"deviceId":"Mac-OwnerDevice","note":"owner-recover"}' \
  http://localhost:3001/api/admin/device/grant

# 2. 驗證裝置已授權（通過正常檢查 API）
curl -i -X POST \
  -H "Content-Type: application/json" \
  -d '{"deviceId":"Mac-OwnerDevice"}' \
  http://localhost:3001/api/auth/check
```

## 驗收檢查清單

- [x] Admin Console UI 訪問需要三道門保護
- [x] 無 Admin Key 時返回 404
- [x] 錯誤的 Admin Key 時返回 404
- [x] 正確的 Admin Key 時可以訪問
- [x] GET /api/admin/licenses 可以列出所有授權
- [x] POST /api/admin/license/create 可以創建新授權
- [x] POST /api/admin/license/rebind 可以重新綁定裝置
- [x] POST /api/admin/device/grant 可以直接授權裝置
- [x] KV 不可用時所有 Admin API 返回 503 KV_UNAVAILABLE
- [x] 所有操作都通過 KV 持久化（無 in-memory fallback）
- [x] License Index 正確更新
- [x] 授權資料結構完整（licenseKeyHash, issuedBy, boundDeviceId 等）

## 注意事項

1. **本地測試**：使用 `KV_MODE=mock` 進行本地測試
2. **Production 測試**：在 Vercel 環境中，需要設定真實的 KV 環境變數
3. **Admin Key 安全**：請勿將 Admin Key 寫入 Git 或前端檔案
4. **Fail Closed**：所有 Admin API 都必須通過 `requireKV()` 檢查，KV 不可用時返回 503

## 相關文件

- [Admin Console UI 使用指南](./ADMIN_CONSOLE_UI_GUIDE.md)
- [機器驗證文件](./MACHINE_VERIFICATION_FINAL.md)
