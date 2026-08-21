# Pikmin Architect 安全審查指示

每個 finding 必須包含以下欄位，不能只寫結論：

`attacker`、`precondition`、`action`、`result`、`impact`、`file:line`、`evidence`、`fix`。

請優先審查：

1. Swift／Windows／Electron 桌面端與 Python helper 的 IPC、preload、命令執行、檔案路徑與權限邊界。
2. license server 的 activation、device binding、expiry、重放保護、管理端點與錯誤回應。
3. 付款／回呼、下載與更新端點的簽章驗證、SSRF、任意檔案寫入、rate limit 與資源上限。
4. 網站與 server-side route 是否把授權決策留在客戶端、是否誤記錄 API key／license token，以及公開 API 是否有認證與最小權限。

若沒有可重現的資料流，請降低 confidence 而不是猜測；若是可利用問題，指出完整 attacker → precondition → action → result 鏈，並給出精確檔案與行號。
