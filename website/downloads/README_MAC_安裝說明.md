# KongGoo macOS 安裝說明

## 如果遇到「已損毀，無法打開」的錯誤

這是 macOS Gatekeeper 的安全機制。請按照以下步驟解決：

### 方法 1：使用自動修復腳本（最簡單）⭐

1. 下載並執行修復腳本：
   ```bash
   curl -O https://你的網站域名/fix_dmg.sh
   chmod +x fix_dmg.sh
   ./fix_dmg.sh
   ```

### 方法 2：手動移除 quarantine 屬性（推薦）

**重要：先對 DMG 檔案執行，再打開 DMG**

1. 打開「終端機」（Terminal）
2. 執行以下命令（清除 DMG 的 quarantine）：
   ```bash
   xattr -cr ~/Downloads/ios-location-simulator-mac.dmg
   ```
3. 然後雙擊打開 DMG
4. 如果打開 DMG 後 App 還是顯示「已損毀」，對 App 執行：
   ```bash
   xattr -cr ~/Downloads/KongGoo.app
   ```
   或如果已經拖到 Applications：
   ```bash
   xattr -cr /Applications/KongGoo.app
   ```

### 方法 3：在「系統設定」中允許

1. 打開「系統設定」>「隱私權與安全性」
2. 找到「已阻擋的 App」區塊
3. 點擊「仍要打開」按鈕
4. 確認打開

### 方法 4：右鍵打開（適用於舊版 macOS）

1. 在 Finder 中找到 DMG 或 KongGoo.app
2. **按住 Option 鍵**，然後右鍵點擊
3. 選擇「打開」
4. 在彈出的對話框中點擊「打開」

## 為什麼會出現這個錯誤？

- macOS 會檢查下載的 App 是否經過 Apple 認證（Notarization）
- **Safari 下載時會自動添加 quarantine 屬性**
- 這是正常的安全機制，不是 App 真的有問題
- **我們的 App 已經通過 Apple 的 Notarization 認證**

## 快速修復命令（複製貼上即可）

```bash
# 清除 DMG 的 quarantine
xattr -cr ~/Downloads/ios-location-simulator-mac.dmg

# 如果已經打開 DMG，清除 App 的 quarantine
xattr -cr ~/Downloads/KongGoo.app
```

## 需要幫助？

如果以上方法都無法解決，請聯繫：awe7893625@gmail.com
