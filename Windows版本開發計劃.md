# Windows 版本開發計劃

## 🎯 目標

將 macOS 版本的 Pikmin Architect 移植到 Windows，使用 Electron 框架。

---

## 📋 技術方案

### 使用 Electron（推薦）

**優點**：
- ✅ 可以重用現有的 `index.html` 介面
- ✅ 開發速度快（1-2 週）
- ✅ 跨平台支援好
- ✅ 維護成本低

---

## 🚀 開發步驟

### 步驟 1：創建 Electron 專案結構

```
PikminArchitect_Windows/
├── package.json
├── main.js              # Electron 主進程
├── preload.js           # 預載入腳本
├── renderer/
│   └── index.html       # 重用現有的 HTML
├── src/
│   ├── location-engine.js  # GPS 模擬功能（Node.js 版本）
│   └── auth-manager.js     # 授權管理
└── build/
    └── icon.ico         # Windows 圖標
```

### 步驟 2：安裝依賴

```bash
npm init -y
npm install electron --save-dev
npm install electron-builder --save-dev
npm install axios
npm install express
```

### 步驟 3：創建 main.js

```javascript
const { app, BrowserWindow, ipcMain } = require('electron');
const path = require('path');

let mainWindow;

function createWindow() {
    mainWindow = new BrowserWindow({
        width: 1200,
        height: 800,
        icon: path.join(__dirname, 'build/icon.ico'),
        webPreferences: {
            preload: path.join(__dirname, 'preload.js'),
            nodeIntegration: false,
            contextIsolation: true
        }
    });

    mainWindow.loadFile('renderer/index.html');
    
    // 開發時打開 DevTools
    if (process.env.NODE_ENV === 'development') {
        mainWindow.webContents.openDevTools();
    }
}

app.whenReady().then(() => {
    createWindow();

    app.on('activate', () => {
        if (BrowserWindow.getAllWindows().length === 0) {
            createWindow();
        }
    });
});

app.on('window-all-closed', () => {
    if (process.platform !== 'darwin') {
        app.quit();
    }
});
```

### 步驟 4：創建 preload.js

```javascript
const { contextBridge, ipcRenderer } = require('electron');

// 暴露安全的 API 給渲染進程
contextBridge.exposeInMainWorld('electronAPI', {
    // GPS 模擬相關
    teleport: (lat, lon) => ipcRenderer.invoke('teleport', lat, lon),
    startRoute: (points) => ipcRenderer.invoke('startRoute', points),
    
    // 授權相關
    checkAuth: () => ipcRenderer.invoke('checkAuth'),
    activateLicense: (key) => ipcRenderer.invoke('activateLicense', key),
    
    // 設備相關
    getDeviceId: () => ipcRenderer.invoke('getDeviceId')
});
```

### 步驟 5：移植 GPS 模擬功能

需要將 Swift 的 GPS 模擬功能改為 Node.js：

**macOS 版本使用**：
- `pymobiledevice3` (Python)

**Windows 版本使用**：
- `node-ios-device` 或直接使用 `libimobiledevice` 的 Windows 版本
- 或使用 `usbmuxd` 的 Node.js 綁定

### 步驟 6：重用現有的 HTML/JavaScript

直接複製 `index.html` 到 `renderer/index.html`，並修改：

```javascript
// 原本使用 window.webkit.messageHandlers.bridge.postMessage
// 改為使用 electronAPI

// 舊代碼：
window.webkit.messageHandlers.bridge.postMessage({ act: 'tp', la: lat, lo: lon });

// 新代碼：
window.electronAPI.teleport(lat, lon);
```

### 步驟 7：打包配置

在 `package.json` 中添加：

```json
{
  "main": "main.js",
  "scripts": {
    "start": "electron .",
    "build": "electron-builder",
    "build:win": "electron-builder --win"
  },
  "build": {
    "appId": "com.pikmin.architect",
    "productName": "Pikmin Architect",
    "win": {
      "target": "nsis",
      "icon": "build/icon.ico"
    },
    "nsis": {
      "oneClick": false,
      "allowToChangeInstallationDirectory": true
    }
  }
}
```

---

## 📦 打包步驟

### 1. 安裝依賴

```bash
npm install
```

### 2. 測試運行

```bash
npm start
```

### 3. 打包為 .exe

```bash
npm run build:win
```

會生成：
- `dist/Pikmin Architect Setup.exe`（安裝程式）
- `dist/Pikmin Architect.exe`（可執行檔）

---

## 🔧 需要解決的問題

### 1. GPS 模擬功能

**macOS 使用**：`pymobiledevice3` (Python)

**Windows 選項**：
- 選項 A：使用 `libimobiledevice` 的 Windows 版本
- 選項 B：使用 `node-ios-device` (Node.js 綁定)
- 選項 C：使用 `usbmuxd` 的 Node.js 綁定

### 2. 設備識別

**macOS**：使用硬體 UUID

**Windows**：使用 `wmic csproduct get uuid` 或 `machine-id`

### 3. 授權系統

可以完全重用現有的授權服務器，只需要修改 `AuthManager` 的實現。

---

## 📝 開發時間表

### 第 1 週：框架搭建
- [ ] 創建 Electron 專案
- [ ] 設置基本結構
- [ ] 重用現有 HTML 介面
- [ ] 測試基本功能

### 第 2 週：功能移植
- [ ] 移植 GPS 模擬功能
- [ ] 移植授權系統
- [ ] 測試所有功能

### 第 3 週：打包和測試
- [ ] 打包為 .exe
- [ ] 測試安裝和運行
- [ ] 修復問題

---

## 🎯 完成標準

- [ ] App 可以正常啟動
- [ ] 可以連接 iOS 設備
- [ ] GPS 模擬功能正常
- [ ] 授權系統正常
- [ ] 可以打包為 .exe
- [ ] 安裝程式正常

---

## 📚 參考資源

- [Electron 官方文檔](https://www.electronjs.org/)
- [electron-builder 文檔](https://www.electron.build/)
- [libimobiledevice Windows](https://github.com/libimobiledevice-win32/libimobiledevice-win32)
