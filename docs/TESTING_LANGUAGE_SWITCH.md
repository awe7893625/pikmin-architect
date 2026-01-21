# 語言切換測試文檔

**版本**: 2.0  
**更新時間**: 2025-01-XX

---

## 最小可重現測試步驟

### 前置條件
1. 確保 App 已編譯並運行
2. 確保所有語言檔案存在：
   - `PikminArchitect/locales/zh-TW.json`
   - `PikminArchitect/locales/en.json`
   - `PikminArchitect/locales/ja.json`
   - `PikminArchitect/locales/ko.json`

---

## 測試步驟

### 步驟 1: 打開 App 並檢查初始語言

1. **啟動 App**
2. **打開開發者控制台** (Cmd+Option+I)
3. **檢查初始語言**:
   - 應該顯示繁體中文（zh-TW）
   - 檢查控制台日誌：應該看到 `✅ [語言] 語言檔案載入成功`

### 步驟 2: 切換到 English (en)

1. **點擊右下角設定按鈕** (🔑)
2. **在語言下拉選單中選擇 "English"**
3. **立即檢查以下元素是否已更新**:

#### 必須立即更新的元素：
- ✅ **搜索框 placeholder**: 應顯示 "🔍 Search location..."
- ✅ **模式標籤**:
  - "瞬移" → "Teleport"
  - "散花" → "Route"
  - "最愛" → "Favorites"
- ✅ **初始化連線文字**: " 點擊初始化連線" → "Tap to Initialize Connection"
- ✅ **按鈕文字**:
  - "GO" → "GO" (不變)
  - "STOP" → "STOP" (不變)
  - "＋ 加入目前位置" → "＋ Add Current Location"
- ✅ **授權相關文字**:
  - "🎁 剩餘免費次數" → "🎁 Remaining Free Trials"
  - "🔍 檢查授權" → "🔍 Check Authorization"
  - "💳 購買授權" → "💳 Purchase License"
  - "輸入授權碼" → "Enter License Code"
  - "✅ 激活授權碼" → "✅ Activate License"

4. **檢查控制台日誌**:
   - 應該看到 `🌐 [語言] 切換語言: en`
   - 應該看到 `✅ [語言] 語言檔案載入成功`
   - 應該看到 `✅ [語言] 翻譯應用完成: 更新 X 個元素`
   - 應該看到 `✅ [語言] UI 重新渲染完成（WKWebView 已更新）`
   - 應該看到 `✅ [語言] 驗證成功: 翻譯已正確應用`

### 步驟 3: 切換到日本語 (ja)

1. **在語言下拉選單中選擇 "日本語"**
2. **立即檢查以下元素是否已更新**:

#### 必須立即更新的元素：
- ✅ **搜索框 placeholder**: 應顯示 "🔍 場所を検索..."
- ✅ **模式標籤**:
  - "Teleport" → "テレポート"
  - "Route" → "ルート"
  - "Favorites" → "お気に入り"
- ✅ **初始化連線文字**: "Tap to Initialize Connection" → "タップして接続を初期化"
- ✅ **按鈕文字**:
  - "＋ Add Current Location" → "＋ 現在地を追加"
  - "🎁 Remaining Free Trials" → "🎁 残り無料トライアル"
  - "🔍 Check Authorization" → "🔍 認証を確認"
  - "💳 Purchase License" → "💳 ライセンスを購入"
  - "Enter License Code" → "ライセンスコードを入力"
  - "✅ Activate License" → "✅ ライセンスを有効化"

3. **檢查控制台日誌**:
   - 應該看到 `🌐 [語言] 切換語言: ja`
   - 應該看到 `✅ [語言] 驗證成功: 翻譯已正確應用`

### 步驟 4: 切換到 한국어 (ko)

1. **在語言下拉選單中選擇 "한국어"**
2. **立即檢查以下元素是否已更新**:

#### 必須立即更新的元素：
- ✅ **搜索框 placeholder**: 應顯示 "🔍 위치 검색..."
- ✅ **模式標籤**:
  - "お気に入り" → "즐겨찾기"
  - "ルート" → "경로"
  - "テレポート" → "순간이동"
- ✅ **初始化連線文字**: "タップして接続を初期化" → "탭하여 연결 초기화"
- ✅ **按鈕文字**:
  - "＋ 現在地を追加" → "＋ 현재 위치 추가"
  - "🎁 残り無料トライアル" → "🎁 남은 무료 체험"
  - "🔍 認証を確認" → "🔍 인증 확인"
  - "💳 ライセンスを購入" → "💳 라이선스 구매"
  - "ライセンスコードを入力" → "라이선스 코드 입력"
  - "✅ ライセンスを有効化" → "✅ 라이선스 활성화"

3. **檢查控制台日誌**:
   - 應該看到 `🌐 [語言] 切換語言: ko`
   - 應該看到 `✅ [語言] 驗證成功: 翻譯已正確應用`

### 步驟 5: 驗證重啟後語言保持

1. **關閉 App** (完全退出)
2. **重新啟動 App**
3. **檢查語言**:
   - 應該保持最後選擇的語言（ko）
   - 所有 UI 元素應該立即顯示正確的翻譯
   - 不應該出現「載入中...」或部分翻譯的情況

4. **檢查控制台日誌**:
   - 應該看到 `🌐 [語言] 載入語言: ko`
   - 應該看到 `✅ [語言] 語言檔案載入成功`
   - 應該看到 `✅ [語言] 翻譯應用完成`

### 步驟 6: 快速切換測試（壓力測試）

1. **快速連續切換語言**: en → ja → ko → en → zh-TW
2. **每次切換後立即檢查**:
   - 所有元素應該立即更新
   - 不應該出現「一半中文一半英文」的情況
   - 不應該出現 placeholder 未更新的情況

3. **檢查控制台日誌**:
   - 每次切換都應該看到完整的日誌
   - 不應該出現錯誤或警告

---

## 驗證檢查清單

### 功能驗證
- [ ] 切換到 en 後，所有 UI 元素立即更新為英文
- [ ] 切換到 ja 後，所有 UI 元素立即更新為日文
- [ ] 切換到 ko 後，所有 UI 元素立即更新為韓文
- [ ] 搜索框 placeholder 正確更新
- [ ] 模式標籤（瞬移/散花/最愛）正確更新
- [ ] 所有按鈕文字正確更新
- [ ] 所有輸入框 placeholder 正確更新
- [ ] 重啟 App 後語言保持不變

### 技術驗證
- [ ] 控制台日誌顯示完整的載入和應用過程
- [ ] 沒有「缺少翻譯鍵」的警告
- [ ] 沒有「驗證失敗」的警告
- [ ] WKWebView 完全更新（沒有部分更新）
- [ ] 沒有 async/caching 導致的延遲更新

### 邊界情況驗證
- [ ] 快速連續切換語言不會導致錯誤
- [ ] 重複選擇同一語言不會觸發更新
- [ ] 語言檔案載入失敗時顯示錯誤訊息

---

## 常見問題排查

### 問題 1: 部分元素未更新

**症狀**: 切換語言後，部分元素仍顯示舊語言

**可能原因**:
1. 元素缺少 `data-i18n` 或 `data-i18n-placeholder` 屬性
2. 語言檔案中缺少對應的翻譯鍵
3. WKWebView 緩存問題

**解決方法**:
1. 檢查控制台日誌，查看缺少的翻譯鍵
2. 檢查 HTML 元素是否正確添加了 `data-i18n` 屬性
3. 檢查語言檔案是否包含所有必要的翻譯鍵

### 問題 2: Placeholder 未更新

**症狀**: 切換語言後，輸入框的 placeholder 未更新

**可能原因**:
1. 元素缺少 `data-i18n-placeholder` 屬性
2. 語言檔案中缺少 `searchPlaceholder` 或 `licenseInput` 等鍵

**解決方法**:
1. 確保所有輸入框都有 `data-i18n-placeholder` 屬性
2. 確保語言檔案中包含所有 placeholder 翻譯鍵

### 問題 3: 重啟後語言重置

**症狀**: 重啟 App 後，語言重置為預設值（zh-TW）

**可能原因**:
1. `localStorage` 未正確保存
2. `localStorage` 被清除

**解決方法**:
1. 檢查控制台日誌，確認 `localStorage.setItem('language', lang)` 被調用
2. 檢查 `localStorage.getItem('language')` 是否返回正確的值

### 問題 4: WKWebView 緩存導致部分更新

**症狀**: 切換語言後，部分元素更新，部分未更新

**可能原因**:
1. WKWebView 的渲染緩存
2. `requestAnimationFrame` 未正確觸發

**解決方法**:
1. 檢查 `applyTranslations()` 是否使用了雙重 `requestAnimationFrame`
2. 檢查是否強制觸發了 reflow
3. 檢查是否批次更新所有元素（確保原子性）

---

## 測試腳本

### 自動化測試（瀏覽器控制台）

在 App 的開發者控制台中執行以下腳本：

```javascript
// 測試語言切換
async function testLanguageSwitch() {
    const languages = ['en', 'ja', 'ko', 'zh-TW'];
    const testElements = [
        { selector: '#search', attr: 'placeholder' },
        { selector: '#t1', attr: 'textContent' },
        { selector: '#t2', attr: 'textContent' },
        { selector: '#t3', attr: 'textContent' },
        { selector: '#st-text', attr: 'textContent' }
    ];
    
    for (const lang of languages) {
        console.log(`\n🧪 測試語言: ${lang}`);
        await setLanguageFromSelect(lang);
        
        // 等待更新完成
        await new Promise(resolve => setTimeout(resolve, 500));
        
        // 驗證元素
        for (const { selector, attr } of testElements) {
            const el = document.querySelector(selector);
            if (el) {
                const value = attr === 'textContent' ? el.textContent : el[attr];
                console.log(`  ${selector}: ${value}`);
            }
        }
    }
    
    console.log('\n✅ 測試完成');
}

// 執行測試
testLanguageSwitch();
```

---

## 預期結果

### 成功標準
1. ✅ 切換語言後，**所有** UI 元素在 **500ms 內**完全更新
2. ✅ 沒有部分更新或混合語言的情況
3. ✅ 重啟 App 後語言保持不變
4. ✅ 控制台日誌顯示完整的更新過程，沒有錯誤或警告

### 失敗標準
1. ❌ 切換語言後，部分元素未更新
2. ❌ Placeholder 未更新
3. ❌ 出現「一半中文一半英文」的情況
4. ❌ 重啟 App 後語言重置
5. ❌ 控制台出現錯誤或大量警告

---

**文檔結束**
