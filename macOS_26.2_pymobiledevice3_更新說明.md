# macOS 26.2 更新 pymobiledevice3 說明

## ⚠️ 錯誤訊息
```
error: externally-managed-environment
```

這是 macOS 26.2 的新安全機制，防止直接修改系統 Python 環境。

## ✅ 解決方案

### 方法 1: 使用 --user 標誌（推薦）
```bash
/opt/homebrew/bin/python3 -m pip install --user --upgrade pymobiledevice3
```

這會將 pymobiledevice3 安裝到用戶目錄，不會影響系統 Python。

### 方法 2: 使用 --break-system-packages（不推薦）
```bash
/opt/homebrew/bin/python3 -m pip install --break-system-packages --upgrade pymobiledevice3
```

⚠️ 警告：這可能會破壞 Homebrew 安裝，不建議使用。

### 方法 3: 使用 pipx（適合應用程序）
```bash
brew install pipx
pipx install pymobiledevice3
```

## 🔍 驗證安裝

安裝完成後，測試是否正常工作：
```bash
/opt/homebrew/bin/python3 -m pymobiledevice3 list-devices
```

## 📝 注意事項

1. 使用 `--user` 標誌後，pymobiledevice3 會安裝到 `~/.local/bin/`
2. 確保 `~/.local/bin/` 在 PATH 中，或者使用完整路徑
3. App 中使用的 Python 路徑是 `/opt/homebrew/bin/python3`，應該可以正常使用

## 🆘 如果仍然無法連接

1. 確認設備已信任此電腦
2. 檢查系統權限設定
3. 查看 Xcode 控制台的詳細日誌
