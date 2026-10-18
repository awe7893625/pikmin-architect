const assert = require('assert');
const crypto = require('crypto');
const http = require('http');
const Module = require('module');

process.env.NODE_ENV = 'test';
delete process.env.VERCEL_ENV;
process.env.KV_MODE = 'mock';
process.env.POLAR_ACCESS_TOKEN = 'test-token';
process.env.POLAR_WEBHOOK_SECRET = 'test-webhook-secret';
process.env.POLAR_PRODUCT_PRICE_ID_ANNUAL = 'price-annual';
delete process.env.RESEND_API_KEY;

const mailStub = { calls: [] };
const originalLoad = Module._load;
Module._load = function (request, parent, isMain) {
    if (request === './mailer' || request === '../lib/mailer') return {
        sendLicenseEmail: async (payload) => { mailStub.calls.push(payload); return { sent: true, id: 'mail-test' }; },
        isMailerConfigured: () => true
    };
    return originalLoad.apply(this, arguments);
};

let fakeStatus = 'succeeded';
let fakeMetadata = {};
const fakePolar = http.createServer((req, res) => {
    let body = '';
    req.on('data', (chunk) => { body += chunk; });
    req.on('end', () => {
        res.setHeader('Content-Type', 'application/json');
        if (req.method === 'POST') {
            const parsed = JSON.parse(body || '{}');
            fakeMetadata = parsed.metadata || {};
            res.end(JSON.stringify({ id: 'checkout-test', url: 'https://checkout.test/' }));
        } else {
            res.end(JSON.stringify({ id: 'checkout-test', status: fakeStatus, metadata: fakeMetadata }));
        }
    });
});
fakePolar.listen(0);
process.env.POLAR_API_BASE = `http://127.0.0.1:${fakePolar.address().port}`;

const app = require('../server');
Module._load = originalLoad;
const { verifyWebhookSignature } = require('../lib/polar-webhook');

let passed = 0;
let failed = 0;
let base = '';
async function test(name, fn) {
    try { await fn(); passed += 1; console.log(`  ok  ${name}`); }
    catch (error) { failed += 1; console.error(`  FAIL ${name}: ${error.message}`); }
}
function sign(secret, id, timestamp, body, keyMode = 'plain') {
    const key = keyMode === 'decoded' ? Buffer.from(secret.slice(6), 'base64') : Buffer.from(secret, 'utf8');
    return `v1,${crypto.createHmac('sha256', key).update(`${id}.${timestamp}.${body}`).digest('base64')}`;
}
async function createOrder() {
    const response = await fetch(`${base}/api/payment/create`, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ planType: 'annual', lang: 'en', email: `buyer-${Date.now()}-${Math.random()}@example.com` }) });
    const data = await response.json();
    assert.strictEqual(data.gateway, 'polar');
    return data.orderId;
}
async function getOrder(id) {
    const response = await fetch(`${base}/api/payment/order/${encodeURIComponent(id)}`);
    return (await response.json()).order;
}
async function deliver(event, options = {}) {
    const raw = options.raw || JSON.stringify(event);
    const id = options.id || `evt-${Date.now()}`;
    const timestamp = String(options.timestamp ?? Math.floor(Date.now() / 1000));
    const headers = { 'Content-Type': 'application/json' };
    if (!options.noHeaders) {
        headers['webhook-id'] = id;
        headers['webhook-timestamp'] = timestamp;
        headers['webhook-signature'] = options.signature || sign(options.secret || process.env.POLAR_WEBHOOK_SECRET, id, timestamp, raw, options.keyMode);
    }
    const response = await fetch(`${base}/api/payment/polar-webhook`, { method: 'POST', headers, body: raw });
    return { status: response.status, data: await response.json() };
}
function eventFor(type, orderId, status = 'succeeded') {
    return type === 'order.paid' ? { type, data: { checkout_id: 'checkout-test', metadata: { orderId } } } : { type, data: { id: 'checkout-test', status, metadata: { orderId } } };
}

(async () => {
    const server = app.listen(0);
    await new Promise((resolve) => server.once('listening', resolve));
    base = `http://127.0.0.1:${server.address().port}`;
    await test('valid order.paid verifies with Polar and issues license', async () => {
        fakeStatus = 'succeeded';
        const orderId = await createOrder();
        const result = await deliver(eventFor('order.paid', orderId));
        assert.strictEqual(result.status, 200);
        assert.strictEqual(result.data.finalized, true);
        const order = await getOrder(orderId);
        assert.strictEqual(order.status, 'paid');
        assert.ok(order.licenseKey);
    });
    await test('missing and incorrect signatures are rejected', async () => {
        const orderId = await createOrder();
        assert.strictEqual((await deliver(eventFor('order.paid', orderId), { noHeaders: true })).status, 401);
        assert.strictEqual((await deliver(eventFor('order.paid', orderId), { signature: 'v1,AAAA' })).status, 401);
        assert.strictEqual((await getOrder(orderId)).status, 'pending');
    });
    await test('stale timestamp rejected without issuing license', async () => {
        const orderId = await createOrder();
        const result = await deliver(eventFor('order.paid', orderId), { timestamp: Math.floor(Date.now() / 1000) - 360 });
        assert.strictEqual(result.status, 400);
        assert.strictEqual((await getOrder(orderId)).status, 'pending');
    });
    await test('webhook cannot finalize if Polar still reports open', async () => {
        fakeStatus = 'open';
        const orderId = await createOrder();
        const result = await deliver(eventFor('order.paid', orderId));
        assert.deepStrictEqual(result.data, { received: true, ignored: true, code: 'NOT_PAID' });
        assert.strictEqual((await getOrder(orderId)).status, 'pending');
        fakeStatus = 'succeeded';
    });
    await test('duplicate webhook and later confirm return one license and send one email', async () => {
        mailStub.calls = [];
        const orderId = await createOrder();
        const evt = eventFor('order.paid', orderId);
        const a = await deliver(evt);
        const b = await deliver(evt);
        const confirm = await fetch(`${base}/api/payment/polar-confirm?orderId=${encodeURIComponent(orderId)}`).then((r) => r.json());
        assert.strictEqual(a.data.finalized, true);
        assert.strictEqual(b.data.finalized, true);
        assert.strictEqual(confirm.success, true);
        assert.strictEqual((await getOrder(orderId)).licenseKey, confirm.licenseKey);
        assert.strictEqual(mailStub.calls.length, 1);
    });
    await test('concurrent webhook and confirm share finalization', async () => {
        mailStub.calls = [];
        const orderId = await createOrder();
        const [hook, confirm] = await Promise.all([
            deliver(eventFor('order.paid', orderId)),
            fetch(`${base}/api/payment/polar-confirm?orderId=${encodeURIComponent(orderId)}`).then((r) => r.json())
        ]);
        assert.strictEqual(hook.status, 200);
        assert.strictEqual(confirm.success, true);
        assert.ok((await getOrder(orderId)).licenseKey);
        assert.strictEqual(mailStub.calls.length, 1);
    });
    await test('checkout.updated paid succeeds; open and unknown events are ignored', async () => {
        const orderId = await createOrder();
        assert.strictEqual((await deliver(eventFor('checkout.updated', orderId))).data.finalized, true);
        const pendingId = await createOrder();
        assert.strictEqual((await deliver(eventFor('checkout.updated', pendingId, 'open'))).data.ignored, true);
        assert.strictEqual((await deliver({ type: 'other.event', data: {} })).data.ignored, true);
    });
    await test('signature verifier covers timestamp, tampering, multiple and whsec keys', async () => {
        const nowMs = 1800000000000, timestamp = String(Math.floor(nowMs / 1000)), id = 'evt-unit', rawBody = '{"a":1}', secret = 'unit-secret';
        const headers = { 'Webhook-Id': id, 'Webhook-Timestamp': timestamp, 'Webhook-Signature': `v1,AAAA ${sign(secret, id, timestamp, rawBody)}` };
        assert.deepStrictEqual(verifyWebhookSignature({ secret, headers, rawBody, nowMs }), { ok: true });
        assert.strictEqual(verifyWebhookSignature({ secret, headers, rawBody: '{"a":2}', nowMs }).reason, 'BAD_SIGNATURE');
        assert.strictEqual(verifyWebhookSignature({ secret, headers: {}, rawBody, nowMs }).reason, 'MISSING_HEADERS');
        assert.strictEqual(verifyWebhookSignature({ secret, headers: { 'webhook-id': id, 'webhook-timestamp': 'nope', 'webhook-signature': headers['Webhook-Signature'] }, rawBody, nowMs }).reason, 'BAD_TIMESTAMP');
        assert.strictEqual(verifyWebhookSignature({ secret, headers: { 'webhook-id': id, 'webhook-timestamp': String(Number(timestamp) - 360), 'webhook-signature': headers['Webhook-Signature'] }, rawBody, nowMs }).reason, 'STALE');
        assert.strictEqual(verifyWebhookSignature({ secret, headers: { 'webhook-id': id, 'webhook-timestamp': String(Number(timestamp) + 360), 'webhook-signature': headers['Webhook-Signature'] }, rawBody, nowMs }).reason, 'STALE');
        const encodedSecret = `whsec_${Buffer.from('decoded-key').toString('base64')}`;
        const decodedHeaders = { 'webhook-id': id, 'webhook-timestamp': timestamp, 'webhook-signature': sign(encodedSecret, id, timestamp, rawBody, 'decoded') };
        assert.deepStrictEqual(verifyWebhookSignature({ secret: encodedSecret, headers: decodedHeaders, rawBody, nowMs }), { ok: true });
    });
    await new Promise((resolve) => server.close(resolve));
    await new Promise((resolve) => fakePolar.close(resolve));
    Module._load = originalLoad;
    console.log(`\npolar-webhook: ${passed} passed, ${failed} failed`);
    process.exit(failed > 0 ? 1 : 0);
})();
