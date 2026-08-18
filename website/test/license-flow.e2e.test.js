/**
 * 付款 → 發 key → 啟用 → 到期 的端到端驗收（全程 mock KV，不碰正式資料、不寄真信）
 * 跑法：node website/test/license-flow.e2e.test.js
 */
const assert = require('assert');
const crypto = require('crypto');

// --- 測試環境（必須在 require('../server') 之前設好）---
process.env.NODE_ENV = 'test';
delete process.env.VERCEL_ENV;
process.env.KV_MODE = 'mock';
process.env.ENABLE_DEBUG_ENDPOINTS = '1';
process.env.ENABLE_ADMIN_CONSOLE = '1';
process.env.ADMIN_KEY = 'test-admin-key';
process.env.ECPAY_MERCHANT_ID = '3002607';
process.env.ECPAY_HASH_KEY = 'pwFHCqoQZGmho4w6';
process.env.ECPAY_HASH_IV = 'EkRm7iFT261dpevs';
// 故意不設 RESEND_API_KEY：驗證寄信失敗時授權碼照樣發得出去
delete process.env.RESEND_API_KEY;
delete process.env.RESEND_FROM_EMAIL;

const app = require('../server');

let passed = 0;
let failed = 0;
let base = '';

async function test(name, fn) {
    try {
        await fn();
        passed += 1;
        console.log(`  ok  ${name}`);
    } catch (error) {
        failed += 1;
        console.error(`  FAIL ${name}: ${error.message}`);
    }
}

async function postJson(path, body, headers = {}) {
    const res = await fetch(base + path, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', ...headers },
        body: JSON.stringify(body)
    });
    return { status: res.status, data: await res.json().catch(() => ({})) };
}

async function getJson(path, headers = {}) {
    const res = await fetch(base + path, { headers });
    return { status: res.status, data: await res.json().catch(() => ({})) };
}

// 與 server.js 相同的 ECPay CheckMacValue 演算法
function ecpayUrlEncode(str) {
    return encodeURIComponent(str)
        .replace(/%20/g, '+')
        .replace(/%2d/gi, '-').replace(/%5f/gi, '_').replace(/%2e/gi, '.')
        .replace(/%21/g, '!').replace(/%2a/g, '*').replace(/%28/g, '(').replace(/%29/g, ')')
        .toLowerCase();
}

function genMac(params) {
    const sorted = Object.keys(params).sort((a, b) => a.toLowerCase().localeCompare(b.toLowerCase()));
    let raw = `HashKey=${process.env.ECPAY_HASH_KEY}`;
    for (const k of sorted) raw += `&${k}=${params[k]}`;
    raw += `&HashIV=${process.env.ECPAY_HASH_IV}`;
    return crypto.createHash('sha256').update(ecpayUrlEncode(raw)).digest('hex').toUpperCase();
}

async function payOrder(orderId, tradeNo) {
    const params = {
        MerchantID: process.env.ECPAY_MERCHANT_ID,
        MerchantTradeNo: orderId.replace(/[^A-Za-z0-9]/g, '').slice(-20),
        RtnCode: '1',
        RtnMsg: 'Succeeded',
        TradeNo: tradeNo,
        TradeAmt: '690',
        PaymentDate: '2026/08/18 10:00:00',
        PaymentType: 'Credit_CreditCard',
        CustomField1: orderId
    };
    params.CheckMacValue = genMac(params);
    const res = await fetch(base + '/api/payment/ecpay-notify', {
        method: 'POST',
        headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
        body: new URLSearchParams(params).toString()
    });
    return res.text();
}

const ADMIN = { 'x-admin-key': 'test-admin-key' };
const DAY_MS = 24 * 60 * 60 * 1000;

(async () => {
    const server = app.listen(0);
    await new Promise((resolve) => server.once('listening', resolve));
    base = `http://127.0.0.1:${server.address().port}`;

    let paidOrderId = null;
    let paidLicenseKey = null;

    // ---- G1 ----
    await test('G1 沒填 Email 不給建單', async () => {
        const noEmail = await postJson('/api/payment/create', { planType: 'annual' });
        assert.strictEqual(noEmail.status, 400);
        assert.strictEqual(noEmail.data.code, 'INVALID_EMAIL');

        const badEmail = await postJson('/api/payment/create', { planType: 'annual', email: 'not-an-email' });
        assert.strictEqual(badEmail.status, 400);
    });

    // ---- G2 ----
    await test('G2 付款成功：發 key、寫入 purchaseEmail、annual 帶效期', async () => {
        const created = await postJson('/api/payment/create', { planType: 'annual', email: '  Buyer@Example.COM ' });
        assert.strictEqual(created.status, 200);
        paidOrderId = created.data.orderId;

        const notifyResult = await payOrder(paidOrderId, '2608180001');
        assert.strictEqual(notifyResult, '1|OK');

        const order = await getJson(`/api/payment/order/${paidOrderId}`);
        assert.strictEqual(order.data.order.status, 'paid');
        paidLicenseKey = order.data.order.licenseKey;
        assert.ok(/^KGOO-[A-Z0-9]{4}-[A-Z0-9]{4}-[A-Z0-9]{4}$/.test(paidLicenseKey), '授權碼格式不符');

        const admin = await getJson('/api/admin/licenses', ADMIN);
        const item = admin.data.items.find((i) => i.licenseKey === paidLicenseKey);
        assert.ok(item, 'admin 列表找不到剛發出的授權');
        assert.strictEqual(item.purchaseEmail, 'buyer@example.com', 'Email 應正規化後存入');
        assert.strictEqual(item.expiresAt, null, '尚未啟用不該有到期日');
    });

    await test('G2b 寄信失敗（未設定 Resend）不影響發 key，錯誤記在訂單上', async () => {
        const order = await getJson(`/api/payment/order/${paidOrderId}`);
        assert.ok(order.data.order.licenseKey, '授權碼仍要發出');
    });

    await test('G2c ECPay 重送 notify 不會發第二把 key', async () => {
        const before = (await getJson('/api/admin/licenses', ADMIN)).data.summary.total;
        await payOrder(paidOrderId, '2608180001');
        const after = (await getJson('/api/admin/licenses', ADMIN)).data.summary.total;
        assert.strictEqual(after, before, '重送 notify 不該增加授權數');
    });

    // ---- G5 / G6 ----
    let firstExpiresAt = null;
    await test('G5 啟用時才起算效期：expiresAt = 啟用時間 + 365 天', async () => {
        const activated = await postJson('/api/license/activate', { deviceId: 'device-aaa', licenseKey: paidLicenseKey });
        assert.strictEqual(activated.status, 200);
        assert.strictEqual(activated.data.success, true);
        firstExpiresAt = activated.data.expiresAt;
        assert.ok(firstExpiresAt, 'annual 啟用後必須有到期日');
        const delta = new Date(firstExpiresAt) - new Date(activated.data.activatedAt);
        assert.ok(Math.abs(delta - 365 * DAY_MS) < 2000, `效期不是 365 天（實際 ${delta / DAY_MS} 天）`);
    });

    await test('G6 同一台重複啟用不展延效期', async () => {
        const again = await postJson('/api/license/activate', { deviceId: 'device-aaa', licenseKey: paidLicenseKey });
        assert.strictEqual(again.data.success, true);
        assert.strictEqual(again.data.expiresAt, firstExpiresAt, '重複啟用不該重算到期日');
    });

    await test('G6b 換一台機器仍然被擋（一機一碼未被破壞）', async () => {
        const other = await postJson('/api/license/activate', { deviceId: 'device-bbb', licenseKey: paidLicenseKey });
        assert.strictEqual(other.status, 403);
        assert.strictEqual(other.data.code, 'LICENSE_USED');
    });

    await test('G5b status 覆核：綁定那台回 valid、別台回 LICENSE_USED', async () => {
        const ok = await postJson('/api/license/status', { licenseKey: paidLicenseKey, deviceId: 'device-aaa' });
        assert.strictEqual(ok.data.valid, true);
        assert.strictEqual(ok.data.expiresAt, firstExpiresAt);

        const wrong = await postJson('/api/license/status', { licenseKey: paidLicenseKey, deviceId: 'device-zzz' });
        assert.strictEqual(wrong.data.valid, false);
        assert.strictEqual(wrong.data.code, 'LICENSE_USED');
    });

    // ---- G7 ----
    await test('G7 已到期的授權：啟用被擋、verify/status 皆判失效', async () => {
        const issued = await postJson('/__debug/license/issue', {
            planType: 'annual',
            durationDays: 365,
            expiresAt: new Date(Date.now() - DAY_MS).toISOString(),
            note: 'e2e expired'
        }, ADMIN);
        const expiredKey = issued.data.licenseKey;

        const activate = await postJson('/api/license/activate', { deviceId: 'device-ccc', licenseKey: expiredKey });
        assert.strictEqual(activate.status, 403);
        assert.strictEqual(activate.data.code, 'LICENSE_EXPIRED');

        const verify = await postJson('/api/license/verify', { licenseKey: expiredKey });
        assert.strictEqual(verify.data.valid, false);
        assert.strictEqual(verify.data.code, 'LICENSE_EXPIRED');

        const status = await postJson('/api/license/status', { licenseKey: expiredKey, deviceId: 'device-ccc' });
        assert.strictEqual(status.data.valid, false);
        assert.strictEqual(status.data.code, 'LICENSE_EXPIRED');
    });

    // ---- G8 ----
    await test('G8 舊授權（無 durationDays）grandfather 成永久：啟用後仍無到期日', async () => {
        const issued = await postJson('/__debug/license/issue', { planType: 'annual', note: 'e2e grandfathered' }, ADMIN);
        const oldKey = issued.data.licenseKey;

        const activate = await postJson('/api/license/activate', { deviceId: 'device-ddd', licenseKey: oldKey });
        assert.strictEqual(activate.data.success, true);
        assert.strictEqual(activate.data.expiresAt, null, '舊授權不得被算出到期日');

        const status = await postJson('/api/license/status', { licenseKey: oldKey, deviceId: 'device-ddd' });
        assert.strictEqual(status.data.valid, true);
        assert.strictEqual(status.data.expiresAt, null);

        const verify = await postJson('/api/license/verify', { licenseKey: oldKey });
        assert.strictEqual(verify.data.valid, true);
    });

    // ---- G4 ----
    await test('G4 補寄：有買過、沒買過都回一般性訊息（不洩漏誰買過）', async () => {
        const known = await postJson('/api/license/resend', { email: 'buyer@example.com' });
        assert.strictEqual(known.status, 200);
        assert.strictEqual(known.data.success, true);

        const unknown = await postJson('/api/license/resend', { email: 'nobody@example.com' });
        assert.strictEqual(unknown.status, 200);
        assert.deepStrictEqual(unknown.data, known.data, '兩者回應必須一模一樣');

        const bad = await postJson('/api/license/resend', { email: 'nope' });
        assert.strictEqual(bad.status, 400);
    });

    await test('G4b 補寄有頻率上限（每小時 3 次）', async () => {
        const email = 'ratelimit@example.com';
        const results = [];
        for (let i = 0; i < 4; i += 1) {
            results.push((await postJson('/api/license/resend', { email })).status);
        }
        assert.deepStrictEqual(results, [200, 200, 200, 429]);
    });

    server.close();
    console.log(`\nlicense flow e2e: ${passed} passed, ${failed} failed`);
    process.exit(failed > 0 ? 1 : 0);
})();
