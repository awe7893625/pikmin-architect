# iOS 定位工具比較說明

## 工具對比

### 1. **idevicesetlocation** (libimobiledevice)

**優點：**
- ✅ 簡單直接，無需建立隧道
- ✅ 命令簡單：`idevicesetlocation -- <LAT> <LONG>`
- ✅ 不需要 Python 環境
- ✅ 啟動速度快（無需等待隧道）

**缺點：**
- ❌ 需要啟用「開發者模式」（首次需要 Xcode）
- ❌ 部分設備/版本可能不支援（如 iPhone 14 系列 iOS 16.1+）
- ❌ 部分應用可能仍使用真實 GPS
- ❌ 功能較單一，只能設定位置

**使用方式：**
```bash
# 設定位置
idevicesetlocation -- 25.0330 121.5654

# 重置為真實定位
idevicesetlocation reset
```

### 2. **pymobiledevice3** (我們目前使用的)

**優點：**
- ✅ 功能完整，支援多種操作
- ✅ 不需要開發者模式
- ✅ 兼容性較好
- ✅ 支援隧道模式，可以遠程操作

**缺點：**
- ❌ 需要建立隧道（需要時間，約 1-3 秒）
- ❌ 需要 Python 環境
- ❌ 需要管理員權限啟動隧道
- ❌ 命令較複雜：`pymobiledevice3 developer dvt simulate-location set --tunnel <UDID> -- <LAT> <LON>`

**使用方式：**
```bash
# 需要先建立隧道
sudo python3 -m pymobiledevice3 remote tunneld

# 然後設定位置
python3 -m pymobiledevice3 developer dvt simulate-location set --tunnel <UDID> -- <LAT> <LON>
```

## 定位修改的限制

### 共同限制

1. **應用程式限制：**
   - 部分應用（如 Google Maps、某些導航 App）可能仍使用真實 GPS
   - 主要用於測試與開發
   - 遊戲類應用（如 Pikmin Bloom）通常可以正常使用

2. **系統限制：**
   - iOS 系統會定期驗證位置
   - 某些系統服務可能仍使用真實 GPS
   - 位置更新有延遲（通常 1-3 秒）

3. **設備限制：**
   - 需要 USB 連接（或已配對的無線連接）
   - 設備必須解鎖
   - 設備必須信任此電腦

### idevicesetlocation 特定限制

1. **開發者模式：**
   - 必須在 iPhone 上啟用「開發者模式」
   - 首次啟用需要透過 Xcode
   - 啟用後需要重啟設備

2. **設備兼容性：**
   - iPhone 14 系列 iOS 16.1+ 可能不支援
   - 某些較新的 iOS 版本可能有限制

### pymobiledevice3 特定限制

1. **隧道建立：**
   - 需要時間建立隧道（1-3 秒）
   - 需要管理員權限
   - 隧道可能不穩定，需要重新建立

2. **Python 環境：**
   - 需要安裝 Python 3
   - 需要安裝 pymobiledevice3 套件
   - macOS 26.2 可能需要更新套件

## 建議

### 如果追求速度：
- 使用 `idevicesetlocation`（如果已啟用開發者模式）
- 無需等待隧道建立
- 命令簡單快速

### 如果追求兼容性：
- 使用 `pymobiledevice3`（目前使用的方法）
- 不需要開發者模式
- 兼容性較好

### 混合方案：
- 可以同時支援兩種方法
- 優先嘗試 `idevicesetlocation`（如果可用）
- 如果失敗，回退到 `pymobiledevice3`
