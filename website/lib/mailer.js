const RESEND_API_URL = 'https://api.resend.com/emails';
const REQUEST_TIMEOUT_MS = 10000;

function isMailerConfigured() {
  return typeof process.env.RESEND_API_KEY === 'string' &&
         process.env.RESEND_API_KEY.length > 0 &&
         typeof process.env.RESEND_FROM_EMAIL === 'string' &&
         process.env.RESEND_FROM_EMAIL.length > 0;
}

function formatDate(iso) {
  if (!iso) return '';
  const date = new Date(iso);
  if (isNaN(date.getTime())) return '';
  return date.toISOString().slice(0, 10);
}

function escapeHtml(text) {
  if (typeof text !== 'string') return '';
  return text
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#x27;');
}

function renderLicenseEmailHtml({ licenseKey, planType, expiresAt, isResend }) {
  const title = isResend ? '您的 KongGoo 授權碼（補寄）' : '感謝購買 KongGoo — 這是您的授權碼';
  const planText = planType === 'lifetime' ? '永久授權' : '年度授權（一年）';
  const expiresText = planType === 'lifetime'
    ? '永久有效'
    : formatDate(expiresAt) 
      ? `${formatDate(expiresAt)}（到期後需重新購買）`
      : '啟用後起算一年';

  return `<!DOCTYPE html>
<html>
<head>
  <meta charset="UTF-8">
</head>
<body style="margin:0; padding:0; background-color:#f5f5f7; font-family:-apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;">
  <table align="center" cellpadding="0" cellspacing="0" style="max-width:600px; margin:20px auto; background-color:#f5f5f7;">
    <tr>
      <td style="padding:20px;">
        <table cellpadding="0" cellspacing="0" style="width:100%; background-color:#ffffff; border-radius:12px; overflow:hidden;">
          <tr>
            <td style="padding:30px;">
              <h1 style="color:#1d1d1f; font-size:24px; margin-bottom:20px;">${escapeHtml(title)}</h1>

              <div style="margin:20px 0;">
                <p style="color:#1d1d1f; margin:10px 0;">授權碼：</p>
                <div style="border-left:4px solid #F5A623; background-color:#faf8f4; padding:15px; font-family:monospace; font-size:24px; letter-spacing:2px; margin-bottom:20px;">
                  ${escapeHtml(licenseKey)}
                </div>
              </div>

              <p style="color:#1d1d1f; margin:10px 0;">方案：${escapeHtml(planText)}</p>
              <p style="color:#1d1d1f; margin:10px 0;">到期：${escapeHtml(expiresText)}</p>

              <p style="color:#1d1d1f; margin:20px 0;"><strong>啟用步驟：</strong></p>
              <ol style="color:#1d1d1f; padding-left:20px;">
                <li>下載並開啟 KongGoo</li>
                <li>點選啟用並貼上授權碼</li>
                <li>完成</li>
              </ol>

              <p style="color:#6e6e73; font-size:14px; margin-top:20px;">授權碼一機一碼，啟用後綁定該台電腦；換機請到官網申請解綁。</p>

              <p style="color:#6e6e73; font-size:14px; margin-top:20px;">此信由系統自動發送<br>konggoo.uk</p>
            </td>
          </tr>
        </table>
      </td>
    </tr>
  </table>
</body>
</html>`;
}

function renderLicenseEmailText({ licenseKey, planType, expiresAt, isResend }) {
  const title = isResend ? '您的 KongGoo 授權碼（補寄）' : '感謝購買 KongGoo — 這是您的授權碼';
  const planText = planType === 'lifetime' ? '永久授權' : '年度授權（一年）';
  const expiresText = planType === 'lifetime'
    ? '永久有效'
    : formatDate(expiresAt) 
      ? `${formatDate(expiresAt)}（到期後需重新購買）`
      : '啟用後起算一年';

  return `${title}

授權碼：${licenseKey}

方案：${planText}
到期：${expiresText}

啟用步驟：
1. 下載並開啟 KongGoo
2. 點選啟用並貼上授權碼
3. 完成

重要提醒：
授權碼一機一碼，啟用後綁定該台電腦；換機請到官網申請解綁。

此信由系統自動發送
konggoo.uk`;
}

async function sendLicenseEmail({ to, licenseKey, planType, expiresAt, isResend }) {
  if (!isMailerConfigured()) {
    return { sent: false, skipped: true, error: 'MAILER_NOT_CONFIGURED' };
  }

  const subject = isResend ? 'KongGoo 授權碼補寄' : 'KongGoo 授權碼 — 感謝您的購買';
  const html = renderLicenseEmailHtml({ licenseKey, planType, expiresAt, isResend });
  const text = renderLicenseEmailText({ licenseKey, planType, expiresAt, isResend });

  const controller = new AbortController();
  const timeoutId = setTimeout(() => controller.abort(), REQUEST_TIMEOUT_MS);

  try {
    const response = await fetch(RESEND_API_URL, {
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${process.env.RESEND_API_KEY}`,
        'Content-Type': 'application/json'
      },
      body: JSON.stringify({
        from: process.env.RESEND_FROM_EMAIL,
        to: [to],
        subject,
        html,
        text
      }),
      signal: controller.signal
    });
    
    clearTimeout(timeoutId);
    
    if (response.ok) {
      // 已經寄出去了，body 解析失敗不能反過來報 sent:false（會害呼叫端重寄）
      const data = await response.json().catch(() => ({}));
      return { sent: true, id: data.id };
    } else {
      const data = await response.json().catch(() => ({ message: '' }));
      return { sent: false, error: 'HTTP ' + response.status + ' ' + (data.message || '') };
    }
  } catch (error) {
    clearTimeout(timeoutId);
    return { sent: false, error: error.message || 'UNKNOWN_ERROR' };
  }
}

module.exports = { isMailerConfigured, formatDate, renderLicenseEmailHtml, renderLicenseEmailText, sendLicenseEmail };
