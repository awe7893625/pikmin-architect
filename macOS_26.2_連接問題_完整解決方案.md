# macOS 26.2 連接問題完整解決方案

## 🔍 問題診斷

### 系統資訊
- **macOS 版本**：26.2 (Tahoe)
- **問題**：連接兩個設備都無法偵測到
- **pymobiledevice3**：已安裝但可能版本較舊

## 🔧 解決步驟

### 步驟 1: 更新 pymobiledevice3

由於 macOS 26.2 的新安全機制，需要使用特殊標誌：

```bash
/opt/homebrew/bin/python3 -m pip install --break-system-packages --upgrade pymobiledevice3
```

⚠️ **注意**：`--break-system-packages` 標誌會繞過 macOS 26.2 的安全限制。對於 pymobiledevice3 這種開發工具來說通常是安全的，但請謹慎使用。

### 步驟 2: 重新信任設備（最重要！）

系統更新後，**每個設備都需要重新信任**：

#### 在 iPhone/iPad 上：
1. 前往「設定」>「一般」>「傳輸或重置 iPhone」
2. 點擊「重置」>「重置位置與隱私」
3. 重新連接 USB 線
4. 當彈出「信任此電腦？」時，點擊「信任」
5. 輸入設備密碼確認

#### 如果沒有彈出信任提示：
- 嘗試重新插拔 USB 線
- 確認設備已解鎖
- 確認 USB 線可以傳輸數據（不只是充電）

### 步驟 3: 檢查系統權限

1. **系統設定** > **隱私權與安全性**：
   - 確認「完整取用磁碟」已授權
   - 確認終端機或 iTerm 已授權

2. **開發者工具權限**（如果有）：
   - 系統設定 > 隱私權與安全性 > 開發者工具
   - 確認相關應用已授權

### 步驟 4: 清除舊連接並重試

在終端機執行：
```bash
# 結束所有舊的進程
sudo killall -9 pymobiledevice3

# 清除端口佔用
sudo lsof -i tcp:49151 -t | xargs sudo kill -9

# 等待 2 秒
sleep 2
```

然後：
1. 重新打開 App
2. 點擊「初始化連線」
3. 輸入管理員密碼（如果需要）

### 步驟 5: 手動測試連接

在終端機執行：
```bash
# 測試設備是否被系統識別
system_profiler SPUSBDataType | grep -i "serial number"

# 測試 pymobiledevice3 是否能列出設備
sudo /opt/homebrew/bin/python3 -m pymobiledevice3 list-devices
```

## 🆘 如果仍然無法連接

### 檢查系統日誌：
```bash
# 查看 USB 連接相關的系統日誌
log show --predicate 'eventMessage contains "USB" or eventMessage contains "iPhone" or eventMessage contains "iPad"' --last 10m
```

### 檢查 pymobiledevice3 日誌：
```bash
# 查看 pymobiledevice3 的錯誤訊息
sudo /opt/homebrew/bin/python3 -m pymobiledevice3 list-devices 2>&1
```

### 替代方案：使用 libimobiledevice
```bash
# 安裝 libimobiledevice
brew install libimobiledevice

# 列出設備
idevice_id -l
```

## 📝 macOS 26.2 特定問題

### 已知問題：
1. **系統權限更嚴格**：需要更多授權
2. **USB 驅動更新**：可能需要重新信任設備
3. **pymobiledevice3 兼容性**：可能需要最新版本
4. **Python 環境管理**：無法直接使用 pip 安裝

### 建議順序：
1. ✅ 先重新信任所有設備（最重要！）
2. ✅ 更新 pymobiledevice3（使用 --break-system-packages）
3. ✅ 檢查系統權限
4. ✅ 清除舊連接並重試
5. ✅ 查看 Xcode 控制台的詳細日誌

## 💡 快速檢查清單

- [ ] iPhone/iPad 已用 USB 連接
- [ ] 設備已解鎖
- [ ] 已點擊「信任此電腦」
- [ ] 已更新 pymobiledevice3
- [ ] 已檢查系統權限
- [ ] 已清除舊連接
- [ ] 已重新啟動 App
