/**
 * 付款端點鑑權回歸測試
 *
 * 背景（2026-08-20）：/api/payment/polar-confirm 原本只要帶得出 orderId 就直接發授權碼，
 * 把「使用者被導回 success_url」當成付款證明。但 orderId 是 /api/payment/create 直接
 * 回傳給呼叫端的，任何人建個單就能免費領授權。這支測試釘死：
 *   沒有經過金流方驗證的請求，一律拿不到授權碼。
 *
 * 跑法：node website/test/payment-auth.test.js
 */
const assert = require('assert');

process.env.NODE_ENV = 'test';
delete process.env.VERCEL_ENV;
process.env.KV_MODE = 'mock';
process.env.ADMIN_KEY = 'test-admin-key';
process.env.ECPAY_MERCHANT_ID = '3002607';
process.env.ECPAY_HASH_KEY = 'pwFHCqoQZGmho4w6';
process.env.ECPAY_HASH_IV = 'EkRm7iFT261dpevs';
// 不設 POLAR_ACCESS_TOKEN：訂單會走 ECPay，polar-confirm 必須拒絕
delete process.env.POLAR_ACCESS_TOKEN;
delete process.env.RESEND_API_KEY;

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

async function postJson(path, body) {
    const res = await fetch(base + path, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(body)
    });
    return { status: res.status, data: await res.json().catch(() => ({})) };
}

async function getJson(path) {
    const res = await fetch(base + path);
    return { status: res.status, data: await res.json().catch(() => ({})) };
}

async function createOrder() {
    const { data } = await postJson('/api/payment/create', {
        planType: 'annual',
        email: `attacker+${Date.now()}@example.com`,
        lang: 'zh-TW'
    });
    return data.orderId || (data.paymentUrl || '').match(/ORD-[\w-]+/)?.[0];
}

(async () => {
    const server = app.listen(0);
    await new Promise((resolve) => server.once('listening', resolve));
    base = `http://127.0.0.1:${server.address().port}`;

    await test('建單後直接打 polar-confirm 不會發授權碼', async () => {
        const orderId = await createOrder();
        assert.ok(orderId, '建單應回傳 orderId');
        const { data } = await getJson(`/api/payment/polar-confirm?orderId=${encodeURIComponent(orderId)}`);
        assert.notStrictEqual(data.success, true, '未付款卻回 success:true');
        assert.ok(!data.licenseKey, `不該給出授權碼，卻拿到 ${data.licenseKey}`);
    });

    await test('polar-confirm 拒絕非 Polar 訂單（GATEWAY_MISMATCH）', async () => {
        const orderId = await createOrder();
        const { status, data } = await getJson(`/api/payment/polar-confirm?orderId=${encodeURIComponent(orderId)}`);
        assert.strictEqual(status, 400);
        assert.strictEqual(data.code, 'GATEWAY_MISMATCH');
    });

    await test('polar-confirm 對不存在的訂單回 404，不洩漏資訊', async () => {
        const { status, data } = await getJson('/api/payment/polar-confirm?orderId=ORD-does-not-exist');
        assert.strictEqual(status, 404);
        assert.ok(!data.licenseKey);
    });

    await test('CheckMacValue 錯誤的 ECPay notify 不會發授權碼', async () => {
        const orderId = await createOrder();
        const res = await fetch(base + '/api/payment/ecpay-notify', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({
                MerchantID: process.env.ECPAY_MERCHANT_ID,
                RtnCode: '1',
                TradeNo: 'FORGED123',
                CustomField1: orderId,
                CheckMacValue: 'DEADBEEF'
            })
        });
        const text = await res.text();
        assert.ok(text.includes('CheckMacValue Error'), `應擋下偽造 notify，實得：${text}`);
        const { data } = await getJson(`/api/payment/order/${encodeURIComponent(orderId)}`);
        assert.notStrictEqual(data.order && data.order.status, 'paid', '偽造 notify 竟讓訂單變成 paid');
    });

    server.close();
    console.log(`\npayment auth: ${passed} passed, ${failed} failed`);
    process.exit(failed > 0 ? 1 : 0);
})();
