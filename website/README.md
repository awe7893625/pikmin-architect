# Pikmin Architect 網站

## 🚀 快速啟動

### 方法 1：使用啟動腳本（最簡單）

在終端執行：
```bash
cd "/Users/rain/Pikmin_Dev_Portable/PikminArchitect＿繼續開發版本/website"
./start.sh
```

### 方法 2：手動啟動

1. 打開終端（Terminal）

2. 進入 website 目錄：
```bash
cd "/Users/rain/Pikmin_Dev_Portable/PikminArchitect＿繼續開發版本/website"
```

3. 啟動服務器：
```bash
npm start
```

4. 打開瀏覽器訪問：
http://localhost:3001

## 📝 設定金流（可選）

在開始銷售之前，您需要：

1. 申請金流帳號（綠界科技或藍新金流）
2. 取得 API 金鑰
3. 創建 `.env` 檔案並填入金鑰

詳細說明請參考：`金流串接說明.md`

**注意**：即使沒有設定金流，網站也可以正常運行，只是付款功能無法使用。

## 📁 檔案說明

- `index.html` - 網站首頁
- `server.js` - 後端服務器（處理付款和授權）
- `package.json` - Node.js 依賴配置
- `start.sh` - 快速啟動腳本
- `金流串接說明.md` - 詳細的金流申請和設定指南
- `網站部署指南.md` - 部署到雲端的說明

## 🛠️ 故障排除

### 問題：找不到 website 目錄

**解決方案**：使用完整路徑
```bash
cd "/Users/rain/Pikmin_Dev_Portable/PikminArchitect＿繼續開發版本/website"
```

### 問題：npm 命令找不到

**解決方案**：確保已安裝 Node.js
```bash
# 檢查 Node.js 是否安裝
node -v
npm -v

# 如果沒有安裝，請前往 https://nodejs.org/ 下載安裝
```

### 問題：端口 3001 已被占用

**解決方案**：修改 `server.js` 中的 PORT 變數，或關閉占用端口的程序

## 📞 需要幫助？

請查看以下文件：
- `金流串接說明.md` - 金流相關問題
- `網站部署指南.md` - 部署相關問題
- `費用與跨平台說明.md` - 費用和平台支援問題
