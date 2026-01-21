# Pikmin Architect Windows 版本

## 🚀 快速開始

### 1. 安裝依賴

```bash
cd Windows版本
npm install
```

### 2. 開發模式運行

```bash
npm start
```

### 3. 打包為 Windows 安裝程式

```bash
npm run build:win
```

打包完成後，會在 `dist/` 目錄生成：
- `Pikmin Architect Setup.exe` - 安裝程式
- `Pikmin Architect.exe` - 可執行檔

---

## 📋 專案結構

```
Windows版本/
├── main.js              # Electron 主進程
├── preload.js           # 預載入腳本（橋接）
├── package.json         # 專案配置
├── renderer/
│   └── index.html       # 重用現有的 HTML 介面
├── src/                 # 源代碼（待實現）
│   ├── location-engine.js
│   └── auth-manager.js
└── build/
    └── icon.ico         # Windows 圖標
```

---

## 🔧 開發狀態

### ✅ 已完成
- [x] Electron 專案結構
- [x] 基本窗口設置
- [x] 重用現有 HTML 介面
- [x] IPC 通信橋接
- [x] 設備 ID 獲取（Windows）

### ⚠️ 待實現
- [ ] GPS 模擬功能（需要 Windows 版本的 libimobiledevice）
- [ ] 授權系統完整實現
- [ ] 真實軌跡功能
- [ ] Windows 圖標（需要轉換為 .ico 格式）

---

## 📝 下一步

1. **實現 GPS 模擬功能**：
   - 安裝 Windows 版本的 libimobiledevice
   - 或使用 node-ios-device 套件

2. **完善授權系統**：
   - 實現 AuthManager（重用 macOS 版本的邏輯）
   - 連接授權服務器

3. **測試和打包**：
   - 測試所有功能
   - 打包為 .exe

---

## 🎯 注意事項

- Windows 版本需要連接 iOS 設備才能使用 GPS 模擬功能
- 需要安裝 iTunes 或 Apple Mobile Device Support
- 授權系統與 macOS 版本共用同一個服務器
