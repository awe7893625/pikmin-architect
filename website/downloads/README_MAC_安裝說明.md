# KongGoo macOS 安裝說明

## 如果遇到「已損毀，無法打開」的錯誤

這是 macOS Gatekeeper 的安全機制。請按照以下步驟解決：

### 方法 1：移除 quarantine 屬性（推薦）

1. 打開「終端機」（Terminal）
2. 執行以下命令：
   ```bash
   xattr -cr ~/Downloads/KongGoo.app
   ```
   或如果已經拖到 Applications：
   ```bash
   xattr -cr /Applications/KongGoo.app
   ```

3. 然後就可以正常打開 App 了

### 方法 2：在「系統設定」中允許

1. 打開「系統設定」>「隱私權與安全性」
2. 找到「已阻擋的 App」區塊
3. 點擊「仍要打開」按鈕
4. 確認打開

### 方法 3：右鍵打開（適用於舊版 macOS）

1. 在 Finder 中找到 KongGoo.app
2. **按住 Option 鍵**，然後右鍵點擊 App
3. 選擇「打開」
4. 在彈出的對話框中點擊「打開」

## 為什麼會出現這個錯誤？

- macOS 會檢查下載的 App 是否經過 Apple 認證（Notarization）
- 如果 App 剛更新，可能需要一些時間讓 Apple 完成認證
- 這是正常的安全機制，不是 App 真的有問題

## 需要幫助？

如果以上方法都無法解決，請聯繫：awe7893625@gmail.com
