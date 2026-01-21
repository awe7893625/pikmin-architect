# 運行 App 說明

## ✅ 授權功能已就緒

所有授權相關功能已經實現並修復完成：

1. ✅ **授權檢查**：`tp` 和 `startRoute` 操作已添加授權檢查
2. ✅ **試用次數顯示**：UI 會顯示剩餘免費次數
3. ✅ **試用次數消耗**：每次使用功能會自動減少次數
4. ✅ **鎖定功能**：3 次用完後會鎖定並顯示激活 UI
5. ✅ **激活碼功能**：可以輸入激活碼解鎖
6. ✅ **授權服務器**：正在運行在 `http://localhost:3000`

## 🚀 運行 App 步驟

### 方法 1：在 Xcode 中運行（推薦）

1. **打開 Xcode 專案**
   ```bash
   open "/Users/rain/Pikmin_Dev_Portable/PikminArchitect＿繼續開發版本/Pikmin_Dev_Portable.xcodeproj"
   ```

2. **選擇目標**
   - 在 Xcode 頂部選擇 "My Mac" 作為運行目標

3. **運行 App**
   - 按 `⌘R` (Command + R) 或點擊運行按鈕

### 方法 2：使用命令行構建

```bash
cd "/Users/rain/Pikmin_Dev_Portable/PikminArchitect＿繼續開發版本"
xcodebuild -project Pikmin_Dev_Portable.xcodeproj \
  -scheme Pikmin_Dev_Portable \
  -configuration Debug \
  -destination 'platform=macOS' \
  build
```

然後在 `DerivedData` 目錄中找到構建好的 App。

## 🧪 測試授權功能

### 1. 檢查剩餘次數顯示
- App 啟動後，應該在頂部看到「🎁 剩餘免費次數: 3」
- 如果顯示「載入中...」，等待幾秒讓 App 連接到授權服務器

### 2. 測試使用功能
1. 點擊地圖選擇一個位置
2. 點擊「GO」按鈕執行瞬移
3. 觀察剩餘次數是否減少（3 → 2 → 1 → 0）

### 3. 測試鎖定功能
- 使用 3 次後，應該顯示「0 次（請購買授權）」
- 激活 UI 應該自動顯示
- 再次點擊「GO」時，應該顯示錯誤提示

### 4. 測試激活碼
- 輸入測試激活碼：`PKM-9A0EF1DD632BBC1D`
- 點擊「✅ 激活授權碼」
- 應該顯示「✅ 授權激活成功！」
- 剩餘次數應該顯示「已購買，無限制使用」

## 📋 測試激活碼列表

每個激活碼只能使用一次：

1. `PKM-9A0EF1DD632BBC1D`
2. `PKM-CF711BA7A0DBC80C`
3. `PKM-2CA9C96C3A8AB6E8`
4. `PKM-FE6C8F8CB7F37339`
5. `PKM-F7EC3C6305756F6C`

## ⚠️ 重要提示

1. **授權服務器必須運行**：
   ```bash
   cd "/Users/rain/Pikmin_Dev_Portable/PikminArchitect＿繼續開發版本/server"
   npm start
   ```

2. **檢查 API 連接**：
   - App 需要連接到 `http://localhost:3000/api`
   - 確認 `AuthManager.swift` 中的 `apiBaseURL` 設置正確

3. **如果沒有顯示剩餘次數**：
   - 打開瀏覽器開發者工具（在 App 中按 `⌥⌘I`）
   - 檢查 Console 是否有 JavaScript 錯誤
   - 確認授權服務器正在運行

## 🔍 故障排除

### App 無法運行
- 檢查 Xcode 是否有編譯錯誤
- 確認所有依賴項已正確導入
- 檢查 `PythonManager.swift` 和 `AuthManager.swift` 是否在專案中

### 授權功能不工作
- 確認授權服務器正在運行
- 檢查網路連接（App 需要連接到 localhost:3000）
- 查看 Xcode 控制台的錯誤訊息

### 試用次數不減少
- 檢查 `userContentController` 中的授權檢查是否正確
- 確認 `performActionWithAuth` 是否被調用
- 查看授權服務器的日誌
