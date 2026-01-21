# 📱 App 修改和測試激活碼說明

## ✅ 已完成的修改

### 1. 移除工具列的「授權」標籤
- ✅ 已從模式選擇標籤中移除「授權」選項
- ✅ 現在只有「瞬移」、「散花」、「最愛」三個標籤

### 2. 激活碼 UI 只在次數用完時顯示
- ✅ 修改了 `updateTrialStatus()` 函數
- ✅ 當剩餘次數為 0 時，自動顯示激活 UI
- ✅ 當還有剩餘次數或已購買時，隱藏激活 UI
- ✅ 激活 UI 會顯示在主要操作區域下方

### 3. 激活碼只能使用一次的確認
- ✅ **已確認**：在 `auth_server.js` 的 `/api/license/activate` 端點中
- ✅ 檢查邏輯：
  ```javascript
  // 如果授權碼已綁定到其他設備
  if (license.deviceId && license.deviceId !== deviceId) {
      return res.status(403).json({ error: '授權碼已綁定到其他設備' });
  }
  ```
- ✅ 激活後會將 `license.deviceId` 設為當前設備 ID
- ✅ 同一個激活碼無法在其他設備使用

---

## 🎁 測試激活碼（5 組）

```
1. PKM-9A0EF1DD632BBC1D
2. PKM-CF711BA7A0DBC80C
3. PKM-2CA9C96C3A8AB6E8
4. PKM-FE6C8F8CB7F37339
5. PKM-F7EC3C6305756F6C
```

### 如何添加到系統

#### 方法 1：手動添加到 auth_server.js

在 `server/auth_server.js` 中找到 `licenses` 的初始化，添加：

```javascript
// 在文件開頭，licenses Map 初始化處
const licenses = new Map();

// 添加測試激活碼
licenses.set('PKM-9A0EF1DD632BBC1D', {
    deviceId: null,
    paidAt: new Date().toISOString(),
    isValid: true,
    createdAt: new Date().toISOString()
});
licenses.set('PKM-CF711BA7A0DBC80C', {
    deviceId: null,
    paidAt: new Date().toISOString(),
    isValid: true,
    createdAt: new Date().toISOString()
});
// ... 其他 3 個激活碼
```

#### 方法 2：使用 API 創建（需要 ADMIN_KEY）

```bash
curl -X POST http://localhost:3000/api/admin/create-license \
  -H "Content-Type: application/json" \
  -d '{"adminKey": "YOUR_ADMIN_KEY"}'
```

---

## 💻 跨平台支援確認

### macOS ✅ 已完成
- **狀態**：✅ 完全支援
- **技術**：SwiftUI + WebKit
- **要求**：
  - macOS 10.15 或更高版本
  - 需要開啟「開發者模式」
  - 需要 Python 3 和 pymobiledevice3（App 會自動安裝）

### Windows ⚠️ 尚未完成
- **狀態**：⚠️ 目前只有 macOS 版本
- **技術方案**：
  1. **Electron**（推薦）- 使用 Web 技術，開發快速
  2. **.NET MAUI** - 跨平台框架
  3. **Flutter Desktop** - Google 的跨平台框架
- **建議**：使用 Electron 重新實現，因為現有的 `index.html` 可以直接使用

### 跨平台實現建議

#### 方案 1：Electron（最快）
```bash
# 優點：
- 可以重用現有的 index.html
- 開發速度快
- 跨平台支援好

# 缺點：
- 檔案較大（約 100-200MB）
- 效能略低於原生
```

#### 方案 2：.NET MAUI
```bash
# 優點：
- 原生效能
- 微軟官方支援

# 缺點：
- 需要重寫 UI
- 學習曲線較陡
```

#### 方案 3：Flutter Desktop
```bash
# 優點：
- 跨平台統一程式碼
- 效能好

# 缺點：
- 需要重寫 UI
- 生態系統較小
```

---

## 🚀 如何運行 App

### 在 Xcode 中運行

1. **打開專案**
   ```bash
   cd "/Users/rain/Pikmin_Dev_Portable/PikminArchitect＿繼續開發版本"
   open Pikmin_Dev_Portable.xcodeproj
   ```

2. **選擇目標**
   - 在 Xcode 中選擇 `PikminArchitect` scheme
   - 選擇 `My Mac` 作為運行目標

3. **編譯和運行**
   - 按 `Cmd + R` 運行
   - 或點擊左上角的「播放」按鈕

4. **測試功能**
   - 測試免費試用功能
   - 測試剩餘次數顯示
   - 測試激活碼輸入（需要先將次數用完）

---

## 📋 測試檢查清單

### 功能測試
- [ ] App 可以正常啟動
- [ ] 模式選擇只有「瞬移」、「散花」、「最愛」三個標籤
- [ ] 免費試用功能正常
- [ ] 剩餘次數正確顯示
- [ ] 次數用完時，激活 UI 自動顯示
- [ ] 激活碼輸入功能正常
- [ ] 激活成功後，狀態更新為「已購買」

### 激活碼測試
- [ ] 激活碼可以成功激活
- [ ] 同一個激活碼無法在第二個設備使用
- [ ] 激活後設備狀態正確更新
- [ ] 激活後可以無限制使用功能

---

## ⚠️ 注意事項

1. **激活碼安全性**
   - 每個激活碼只能使用一次
   - 激活後會綁定到設備 UUID
   - 無法轉移到其他設備

2. **測試環境**
   - 確保 `auth_server.js` 正在運行
   - 確保 App 可以連接到授權服務器
   - 測試時使用測試激活碼，不要使用正式激活碼

3. **Windows 版本**
   - 目前只有 macOS 版本
   - Windows 版本需要重新開發
   - 建議使用 Electron 實現

---

**最後更新**：2026-01-13
