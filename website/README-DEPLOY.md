
## 部署（2026-08-20 訂正）

**一定要從 repo 根目錄部署：**

```bash
cd ~/Projects/pikmin-architect
vercel --prod --yes      # 會 alias 到 konggoo.uk
```

`konggoo.uk` 屬於 Vercel 專案 **pikmin-architect**（`prj_Ryy4nn9t3KR5sNEByq62JVO3TAlt`）。

`website/` 底下曾經有一份 `.vercel` 連到另一個叫 `website` 的**廢棄專案**
（無網域、155 天沒動），在那裡跑 `vercel --prod` 會「部署成功」但 konggoo.uk
完全沒變——已於 2026-08-20 移除該連結。部署後務必實抓線上頁面確認，
不要只看 CLI 回的 Production URL。
