# CI 授權/試用驗證（GitHub Actions）

本文件說明如何使用 GitHub Actions 自動驗證授權/試用流程，並產出「可機器驗證」的 `curl -i` transcript artifact。

## Workflow

- 檔案：`PikminArchitect＿繼續開發版本/.github/workflows/license-verification.yml`
- 名稱：`license-verification`
- 觸發：
  - `pull_request`
  - `workflow_dispatch`

## 必要 Secrets

在 GitHub Repo → Settings → Secrets and variables → Actions → Secrets 新增：

- `VERIFY_BASE_URL`
  - 例：`https://<your-vercel-preview-or-prod-domain>`（不要包含結尾 `/`）
- `VERIFY_ADMIN_KEY`
  - 用於呼叫 `__debug/*`（請勿寫進任何公開文件）
- `TEST_DEVICE_ID`
  - 固定字串，例如：`CI-DEVICE-001`

## Vercel 環境需求（讓 __debug 可用）

`/__debug/*` 在 server 端有「三道門」限制：任一不符會是 404（不暴露存在性）。

- `NODE_ENV !== 'production'`
- `ENABLE_DEBUG_ENDPOINTS === '1'`
- `x-admin-key` 必須等於 `ADMIN_KEY`

因此要讓 CI 能在某個環境跑完「issue license → activate」流程，該環境需要設定：

- `ADMIN_KEY`：值必須與 `VERIFY_ADMIN_KEY` 相同
- `ENABLE_DEBUG_ENDPOINTS=1`
- `NODE_ENV`：必須不是 `production`

## Artifact（驗收證據）

workflow 會上傳 artifact：

- 名稱：`verification_transcript`
- 檔案：`verification_transcript.txt`

內容包含：

- `curl -i /__debug/routes`（header 會以 `<REDACTED>` 顯示）
- `curl -i /api/auth/check`
- `curl -i /__debug/license/issue`
- `curl -i /api/license/activate`
- `curl -i /api/auth/check`（重複檢查，用於簡易持久化驗證）

