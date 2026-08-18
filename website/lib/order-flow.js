const crypto = require('crypto');
const { planDurationDays, normalizeEmail, maskEmail } = require('./license-policy');
const { sendLicenseEmail } = require('./mailer');

const RESEND_LIMIT = 3;
const RESEND_WINDOW_MS = 60 * 60 * 1000;

function createOrderFlow(deps) {
  const { getKV, generateLicenseKey, setOrder, setLicense, now = () => new Date() } = deps;

  async function getLicensesByEmail(email) {
    const normalized = normalizeEmail(email);
    if (!normalized) return [];
    const key = 'email:index:' + normalized;
    try {
      const result = await getKV().get(key);
      return result || [];
    } catch (err) {
      console.error('Failed to get license keys from email index:', err);
      return [];
    }
  }

  async function appendToEmailIndex(email, licenseKey) {
    const normalized = normalizeEmail(email);
    if (!normalized || !licenseKey) return;
    const key = 'email:index:' + normalized;
    try {
      const arr = (await getKV().get(key)) || [];
      if (arr.includes(licenseKey)) return;
      arr.push(licenseKey);
      await getKV().set(key, arr);
    } catch (err) {
      console.error('Failed to append license key to email index:', err);
    }
  }

  async function consumeResendQuota(email) {
    const normalized = normalizeEmail(email);
    if (!normalized) return true;
    const key = 'email:resend:' + normalized;
    try {
      let record = await getKV().get(key);
      if (!record) {
        record = { count: 0, windowStart: now().toISOString() };
      } else {
        const windowElapsed = now() - new Date(record.windowStart);
        if (windowElapsed > RESEND_WINDOW_MS) {
          record = { count: 0, windowStart: now().toISOString() };
        }
      }
      if (record.count >= RESEND_LIMIT) return false;
      record.count += 1;
      await getKV().set(key, record);
      return true;
    } catch (err) {
      console.error('Failed to consume resend quota:', err);
      return true;
    }
  }

  async function finalizePaidOrder(orderId, order, options = {}) {
    const { tradeNo = '', gateway = '' } = options;

    let licenseKey = order.licenseKey;

    // 發 key（冪等：已 paid 且已有 key 就不重發）
    if (order.status !== 'paid' || !licenseKey) {
      licenseKey = generateLicenseKey();
      const paidAt = now().toISOString();
      order.status = 'paid';
      order.licenseKey = licenseKey;
      order.paidAt = paidAt;

      if (tradeNo) order.ecpayTradeNo = tradeNo;
      if (gateway) order.gateway = gateway;

      await setOrder(orderId, order);

      await setLicense(licenseKey, {
        licenseKeyHash: crypto.createHash('sha256').update(licenseKey).digest('hex'),
        deviceId: null,
        boundDeviceId: null,
        paidAt,
        isValid: true,
        createdAt: order.createdAt,
        activatedAt: null,
        expiresAt: null,
        durationDays: planDurationDays(order.planType),
        planType: order.planType,
        purchaseEmail: normalizeEmail(order.email) || null,
        issuedBy: 'payment',
        note: tradeNo ? ('ECPay TradeNo: ' + tradeNo) : (gateway ? (gateway + ' order') : '')
      });

      await appendToEmailIndex(order.email, licenseKey);
      console.log(`✅ 付款成功，授權碼已發出: ${licenseKey} 訂單: ${orderId}`);
    }

    // 寄授權信（冪等：已寄過就不重寄；寄信失敗不可影響已完成的付款）
    if (order.email && !order.emailSentAt) {
      try {
        const result = await sendLicenseEmail({
          to: order.email,
          licenseKey,
          planType: order.planType,
          expiresAt: null
        });

        if (result.sent) {
          order.emailSentAt = now().toISOString();
          order.emailError = null;
        } else {
          order.emailError = result.error || 'UNKNOWN';
        }

        await setOrder(orderId, order);
        console.log(result.sent
            ? `📧 授權信已寄出 -> ${maskEmail(order.email)}`
            : `⚠️ 授權信寄送失敗 -> ${maskEmail(order.email)}: ${order.emailError}`);
      } catch (err) {
        console.error('❌ 授權信流程異常（不影響已發出的授權碼）:', orderId, err && err.message);
      }
    }

    return licenseKey;
  }

  return {
    finalizePaidOrder,
    getLicensesByEmail,
    appendToEmailIndex,
    consumeResendQuota
  };
}

module.exports = { createOrderFlow, RESEND_LIMIT, RESEND_WINDOW_MS };
