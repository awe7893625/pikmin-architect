# Claude Code Security Review：誤報過濾規則

## 團隊通用家規

- 僅綁定 `127.0.0.1` 或 tailnet／私有網路的服務，若沒有公開 ingress，不視為本身的網路曝險。
- secrets 若只透過 macOS Keychain、Windows Credential Manager 或環境變數注入，不因「沒有寫在程式碼裡」而報警；但程式碼內仍出現 hardcoded secret、token、私鑰或可直接使用的憑證時，一律要報。
- 已知且有明確 ask-gate／人工確認的外發行為，不因外發本身報警；仍要檢查 ask-gate 是否可被繞過，以及資料是否越權外發。
- 面向公開網路的 webhook、bot、API 若缺少 rate limit、body／資源上限或重放保護，不得排除；至少以 Medium 報告資源耗盡或濫用風險。

## 本 repo 專屬脈絡

- Pikmin Architect 是桌面 app，另有 license server；桌面端與本機 helper 的 loopback／受控 IPC 可視為預期設計，但不能因此排除 IPC 權限繞過、任意命令執行或跨使用者存取。
- license activation、付款與下載端點是外部曝險面；簽章、到期日、裝置綁定、重放與伺服器端授權檢查缺失仍須報告。
