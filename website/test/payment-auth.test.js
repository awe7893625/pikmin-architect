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
const crypto = require('crypto');
const http = require('http');

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

// 假的綠界 QueryTradeInfo：讓測試能操控「綠界說這筆付款成功了沒」
let fakeEcpayReply = null;   // null = 回 500（模擬查詢失敗）
const ecpayFake = http.createServer((req, res) => {
    let body = '';
    req.on('data', (c) => { body += c; });
    req.on('end', () => {
        if (fakeEcpayReply === null) { res.writeHead(500); return res.end('error'); }
        res.writeHead(200, { 'Content-Type': 'text/plain' });
        res.end(fakeEcpayReply);
    });
});
ecpayFake.listen(0);
process.env.ECPAY_QUERY_URL = `http://127.0.0.1:${ecpayFake.address().port}/query`;

const app = require('../server');

function ecpayUrlEncode(str) {
    return encodeURIComponent(str)
        .replace(/%20/g, '+')
        .replace(/%2d/gi, '-').replace(/%5f/gi, '_').replace(/%2e/gi, '.')
        .replace(/%21/g, '!').replace(/%2a/g, '*').replace(/%28/g, '(').replace(/%29/g, ')')
        .toLowerCase();
}

// 與 server.js 相同的 CheckMacValue 演算法：模擬「攻擊者已經有 HashKey/HashIV」
function genMac(params) {
    const sorted = Object.keys(params).sort((a, b) => a.toLowerCase().localeCompare(b.toLowerCase()));
    let raw = `HashKey=${process.env.ECPAY_HASH_KEY}`;
    for (const k of sorted) raw += `&${k}=${params[k]}`;
    raw += `&HashIV=${process.env.ECPAY_HASH_IV}`;
    return crypto.createHash('sha256').update(ecpayUrlEncode(raw)).digest('hex').toUpperCase();
}

function tradeReply({ status, amt }) {
    return `HandlingCharge=0&ItemName=&MerchantID=${process.env.ECPAY_MERCHANT_ID}` +
        `&MerchantTradeNo=X&PaymentDate=&PaymentType=&PaymentTypeChargeFee=0` +
        `&TradeAmt=${amt}&TradeDate=&TradeNo=T123&TradeStatus=${status}&CheckMacValue=X`;
}

// 帶著「正確簽章」的 notify —— 金鑰外洩後攻擊者做得到的事
async function signedNotify(orderId) {
    const params = {
        MerchantID: process.env.ECPAY_MERCHANT_ID,
        MerchantTradeNo: String(orderId).replace(/[^A-Za-z0-9]/g, '').slice(0, 20),
        RtnCode: '1',
        RtnMsg: 'Succeeded',
        TradeNo: 'FORGED' + Date.now(),
        TradeAmt: '690',
        PaymentDate: '2026/08/20 10:00:00',
        PaymentType: 'Credit_CreditCard',
        CustomField1: orderId
    };
    params.CheckMacValue = genMac(params);
    const res = await fetch(base + '/api/payment/ecpay-notify', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(params)
    });
    return res.text();
}

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

    await test('簽章正確但綠界查無此筆 → 拒發授權（金鑰外洩也偽造不了）', async () => {
        fakeEcpayReply = tradeReply({ status: '10200047', amt: 0 });
        const orderId = await createOrder();
        const text = await signedNotify(orderId);
        assert.ok(text.includes('Trade not verified'), `應拒發，實得：${text}`);
        const { data } = await getJson(`/api/payment/order/${encodeURIComponent(orderId)}`);
        assert.notStrictEqual(data.order && data.order.status, 'paid', '偽造 notify 竟讓訂單變 paid');
    });

    await test('綠界確認已付款且金額相符 → 正常發授權', async () => {
        fakeEcpayReply = tradeReply({ status: '1', amt: 690 });
        const orderId = await createOrder();
        const text = await signedNotify(orderId);
        assert.ok(text.includes('1|OK'), `應放行，實得：${text}`);
        const { data } = await getJson(`/api/payment/order/${encodeURIComponent(orderId)}`);
        assert.strictEqual(data.order && data.order.status, 'paid');
        assert.ok(data.order.licenseKey, '真實付款應該拿到授權碼');
    });

    await test('綠界說已付款但金額對不上 → 拒發授權', async () => {
        fakeEcpayReply = tradeReply({ status: '1', amt: 1 });
        const orderId = await createOrder();
        const text = await signedNotify(orderId);
        assert.ok(text.includes('Amount mismatch'), `應拒發，實得：${text}`);
    });

    await test('對帳查詢失敗 → fail open 放行（不卡真實客戶，但會記錄）', async () => {
        fakeEcpayReply = null;   // 假伺服器回 500
        const orderId = await createOrder();
        const text = await signedNotify(orderId);
        assert.ok(text.includes('1|OK'), `查詢失敗時應放行，實得：${text}`);
        const { data } = await getJson(`/api/payment/order/${encodeURIComponent(orderId)}`);
        assert.strictEqual(data.order && data.order.status, 'paid');
    });

    // ── OrderResultURL（瀏覽器導回）這條路 ──────────────────────
    // 這支端點原本連 CheckMacValue 都沒驗，只看 RtnCode=1 就發授權碼，
    // 比 notify 更好利用（不需要任何金鑰）。

    async function postForm(path, params) {
        const res = await fetch(base + path, {
            method: 'POST',
            headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
            body: new URLSearchParams(params).toString(),
            redirect: 'manual'
        });
        return res.status;
    }

    async function postFormRedirect(path, params) {
        const res = await fetch(base + path, {
            method: 'POST',
            headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
            body: new URLSearchParams(params).toString(),
            redirect: 'manual'
        });
        return { status: res.status, location: res.headers.get('location') };
    }

    function resultParams(orderId, withMac) {
        const params = {
            MerchantID: process.env.ECPAY_MERCHANT_ID,
            MerchantTradeNo: String(orderId).replace(/[^A-Za-z0-9]/g, '').slice(0, 20),
            RtnCode: '1',
            RtnMsg: 'Succeeded',
            TradeNo: 'RESULT' + Date.now(),
            TradeAmt: '690',
            PaymentDate: '2026/08/20 10:00:00',
            PaymentType: 'Credit_CreditCard',
            CustomField1: orderId
        };
        if (withMac) params.CheckMacValue = genMac(params);
        return params;
    }

    await test('OrderResultURL 沒帶 CheckMacValue → 不發授權（原本會發）', async () => {
        fakeEcpayReply = tradeReply({ status: '1', amt: 690 });
        const orderId = await createOrder();
        await postForm('/payment/success', resultParams(orderId, false));
        const { data } = await getJson(`/api/payment/order/${encodeURIComponent(orderId)}`);
        assert.ok(!(data.order && data.order.licenseKey), '沒簽章竟拿到授權碼');
        assert.notStrictEqual(data.order && data.order.status, 'paid');
    });

    await test('OrderResultURL 簽章正確但綠界查無此筆 → 不發授權', async () => {
        fakeEcpayReply = tradeReply({ status: '10200047', amt: 0 });
        const orderId = await createOrder();
        await postForm('/payment/success', resultParams(orderId, true));
        const { data } = await getJson(`/api/payment/order/${encodeURIComponent(orderId)}`);
        assert.ok(!(data.order && data.order.licenseKey), '偽造付款竟拿到授權碼');
    });

    await test('OrderResultURL 綠界確認已付款 → 正常發授權', async () => {
        fakeEcpayReply = tradeReply({ status: '1', amt: 690 });
        const orderId = await createOrder();
        await postForm('/payment/success', resultParams(orderId, true));
        const { data } = await getJson(`/api/payment/order/${encodeURIComponent(orderId)}`);
        assert.strictEqual(data.order && data.order.status, 'paid');
        assert.ok(data.order.licenseKey, '真實付款應該拿到授權碼');
    });

    await test('OrderResultURL 訂單未發碼時 redirect 的 Location 含 orderId', async () => {
        fakeEcpayReply = tradeReply({ status: '10200047', amt: 0 });
        const orderId = await createOrder();
        const { status, location } = await postFormRedirect('/payment/success', resultParams(orderId, true));
        assert.ok(status >= 300 && status < 400, `應 redirect，實得 ${status}`);
        assert.ok(location, '應有 Location');
        const url = new URL(location, base);
        assert.strictEqual(url.pathname, '/payment/success');
        assert.strictEqual(url.searchParams.get('orderId'), orderId);
        assert.ok(!url.searchParams.get('licenseKey'), '未發碼不該帶 licenseKey');
    });

    await test('admin create-license 產生的 license 帶有 durationDays=365', async () => {
        const created = await postJson('/api/admin/create-license', {
            adminKey: process.env.ADMIN_KEY
        });
        assert.strictEqual(created.status, 200, JSON.stringify(created.data));
        assert.ok(created.data.licenseKey, '應回傳 licenseKey');
        const deviceId = 'admin-create-' + Date.now();
        const activated = await postJson('/api/license/activate', {
            deviceId,
            licenseKey: created.data.licenseKey
        });
        assert.strictEqual(activated.status, 200, JSON.stringify(activated.data));
        assert.ok(activated.data.expiresAt, '缺 durationDays 時啟用會變成永久');
        const DAY_MS = 24 * 60 * 60 * 1000;
        const delta = new Date(activated.data.expiresAt) - new Date(activated.data.activatedAt);
        assert.ok(Math.abs(delta - 365 * DAY_MS) < 2000, `效期不是 365 天（實際 ${delta / DAY_MS} 天）`);
    });

    server.close();
    ecpayFake.close();
    console.log(`\npayment auth: ${passed} passed, ${failed} failed`);
    process.exit(failed > 0 ? 1 : 0);
})();
