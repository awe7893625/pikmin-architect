/**
 * lib/order-flow.js 測試（全部用假 KV / 假寄信，不碰真 KV、不寄真信）
 * 跑法：node website/test/order-flow.test.js
 */
const assert = require('assert');
const Module = require('module');

// --- 攔截 ./mailer，讓 sendLicenseEmail 可控 ---
const mailStub = { calls: [], result: { sent: true, id: 'em_stub' } };
const originalLoad = Module._load;
Module._load = function (request, parent, isMain) {
    if (request === './mailer' || request === '../lib/mailer') {
        return {
            sendLicenseEmail: async (payload) => {
                mailStub.calls.push(payload);
                if (mailStub.result instanceof Error) throw mailStub.result;
                return mailStub.result;
            },
            isMailerConfigured: () => true
        };
    }
    return originalLoad.apply(this, arguments);
};

const { createOrderFlow, RESEND_LIMIT } = require('../lib/order-flow');

let passed = 0;
let failed = 0;

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

function makeHarness(options = {}) {
    const store = new Map();
    const orders = new Map();
    const licenses = new Map();
    let keySeq = 0;
    const fakeKV = {
        get: async (key) => {
            if (options.kvThrows) throw new Error('KV down');
            return store.has(key) ? store.get(key) : null;
        },
        set: async (key, value) => {
            if (options.kvThrows) throw new Error('KV down');
            store.set(key, value);
        }
    };
    const flow = createOrderFlow({
        getKV: () => fakeKV,
        generateLicenseKey: () => {
            keySeq += 1;
            return `KGOO-TEST-0000-${String(keySeq).padStart(4, '0')}`;
        },
        setOrder: async (id, data) => { orders.set(id, JSON.parse(JSON.stringify(data))); },
        setLicense: async (key, data) => { licenses.set(key, JSON.parse(JSON.stringify(data))); },
        now: options.now
    });
    return { flow, store, orders, licenses };
}

function baseOrder(overrides = {}) {
    return {
        planType: 'annual',
        amount: 690,
        status: 'pending',
        licenseKey: null,
        gateway: 'ecpay',
        email: 'buyer@example.com',
        emailSentAt: null,
        emailError: null,
        createdAt: '2026-08-17T00:00:00.000Z',
        paidAt: null,
        ...overrides
    };
}

(async () => {
    // ---- 發 key ----
    await test('付款成功發 key：annual 帶 durationDays=365、expiresAt 先留空', async () => {
        mailStub.calls = [];
        const { flow, licenses, orders } = makeHarness();
        const order = baseOrder();
        const key = await flow.finalizePaidOrder('ORD-1', order, { tradeNo: '2608171234567890' });

        const license = licenses.get(key);
        assert.strictEqual(license.durationDays, 365);
        assert.strictEqual(license.expiresAt, null, '未啟用不該有到期日');
        assert.strictEqual(license.planType, 'annual');
        assert.strictEqual(license.purchaseEmail, 'buyer@example.com');
        assert.strictEqual(license.issuedBy, 'payment');
        assert.strictEqual(license.note, 'ECPay TradeNo: 2608171234567890');
        assert.strictEqual(orders.get('ORD-1').status, 'paid');
    });

    await test('lifetime 不帶 durationDays（永久）', async () => {
        mailStub.calls = [];
        const { flow, licenses } = makeHarness();
        const key = await flow.finalizePaidOrder('ORD-L', baseOrder({ planType: 'lifetime' }), {});
        assert.strictEqual(licenses.get(key).durationDays, null);
    });

    await test('email 有寫進 email 索引（補寄查得到）', async () => {
        mailStub.calls = [];
        const { flow } = makeHarness();
        const key = await flow.finalizePaidOrder('ORD-2', baseOrder(), {});
        const found = await flow.getLicensesByEmail('  BUYER@Example.com ');
        assert.deepStrictEqual(found, [key]);
    });

    // ---- 冪等 ----
    await test('ECPay 重送 notify 不會重複發 key、不會重複寄信', async () => {
        mailStub.calls = [];
        const { flow, licenses } = makeHarness();
        const order = baseOrder();
        const first = await flow.finalizePaidOrder('ORD-3', order, { tradeNo: 'T1' });
        const second = await flow.finalizePaidOrder('ORD-3', order, { tradeNo: 'T1' });
        assert.strictEqual(first, second, '第二次不該換一把新 key');
        assert.strictEqual(licenses.size, 1);
        assert.strictEqual(mailStub.calls.length, 1, '不該重複寄信');
    });

    // ---- 寄信 ----
    await test('寄信成功寫 emailSentAt', async () => {
        mailStub.calls = [];
        mailStub.result = { sent: true, id: 'em_1' };
        const { flow, orders } = makeHarness();
        const key = await flow.finalizePaidOrder('ORD-4', baseOrder(), {});
        assert.strictEqual(mailStub.calls[0].to, 'buyer@example.com');
        assert.strictEqual(mailStub.calls[0].licenseKey, key);
        assert.ok(orders.get('ORD-4').emailSentAt);
        assert.strictEqual(orders.get('ORD-4').emailError, null);
    });

    await test('寄信失敗仍然發得出授權碼，錯誤記在訂單上', async () => {
        mailStub.calls = [];
        mailStub.result = { sent: false, error: 'HTTP 422 domain not verified' };
        const { flow, orders, licenses } = makeHarness();
        const key = await flow.finalizePaidOrder('ORD-5', baseOrder(), {});
        assert.ok(licenses.get(key), '授權碼必須照發');
        assert.strictEqual(orders.get('ORD-5').emailSentAt, null);
        assert.ok(orders.get('ORD-5').emailError.includes('422'));
    });

    await test('寄信整個爆炸也不能讓付款流程 throw', async () => {
        mailStub.calls = [];
        mailStub.result = new Error('boom');
        const { flow, licenses } = makeHarness();
        const key = await flow.finalizePaidOrder('ORD-6', baseOrder(), {});
        assert.ok(licenses.get(key));
        mailStub.result = { sent: true, id: 'em_ok' };
    });

    await test('沒有 email 的舊訂單不會嘗試寄信', async () => {
        mailStub.calls = [];
        const { flow } = makeHarness();
        await flow.finalizePaidOrder('ORD-7', baseOrder({ email: null }), {});
        assert.strictEqual(mailStub.calls.length, 0);
    });

    // ---- 補寄頻率限制 ----
    await test(`同一 email 每小時最多補寄 ${RESEND_LIMIT} 次`, async () => {
        const { flow } = makeHarness();
        const results = [];
        for (let i = 0; i < RESEND_LIMIT + 1; i += 1) {
            results.push(await flow.consumeResendQuota('buyer@example.com'));
        }
        assert.deepStrictEqual(results, [...Array(RESEND_LIMIT).fill(true), false]);
    });

    await test('過了時間窗會重置額度', async () => {
        let current = new Date('2026-08-17T00:00:00.000Z');
        const { flow } = makeHarness({ now: () => current });
        for (let i = 0; i < RESEND_LIMIT; i += 1) await flow.consumeResendQuota('a@b.com');
        assert.strictEqual(await flow.consumeResendQuota('a@b.com'), false);
        current = new Date('2026-08-17T01:00:01.000Z');
        assert.strictEqual(await flow.consumeResendQuota('a@b.com'), true);
    });

    await test('KV 抖動時不擋住補寄（fail open）', async () => {
        const { flow } = makeHarness({ kvThrows: true });
        assert.strictEqual(await flow.consumeResendQuota('a@b.com'), true);
        assert.deepStrictEqual(await flow.getLicensesByEmail('a@b.com'), []);
    });

    Module._load = originalLoad;
    console.log(`\norder-flow: ${passed} passed, ${failed} failed`);
    process.exit(failed > 0 ? 1 : 0);
})();
