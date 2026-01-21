# Pikmin Architect 授權服務器

## 安裝

```bash
npm install
```

## 運行

```bash
# 設置管理員密鑰（可選）
export ADMIN_KEY=your-secret-key

# 啟動服務器
npm start
```

## API 端點

### 1. 註冊設備
`POST /api/device/register`
```json
{
  "deviceId": "設備唯一ID",
  "deviceInfo": {}
}
```

### 2. 檢查授權
`POST /api/auth/check`
```json
{
  "deviceId": "設備唯一ID",
  "licenseKey": "授權碼（可選）"
}
```

### 3. 使用試用次數
`POST /api/trial/use`
```json
{
  "deviceId": "設備唯一ID"
}
```

### 4. 激活授權碼
`POST /api/license/activate`
```json
{
  "deviceId": "設備唯一ID",
  "licenseKey": "授權碼"
}
```

### 5. 創建授權碼（管理員）
`POST /api/admin/create-license`
```json
{
  "adminKey": "管理員密鑰",
  "deviceId": "設備ID（可選）"
}
```

## 部署建議

1. 使用 PM2 管理進程
2. 使用 Nginx 反向代理
3. 使用數據庫（MongoDB/PostgreSQL）替代 Map
4. 添加 HTTPS
5. 添加日誌記錄
