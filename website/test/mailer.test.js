/**
 * lib/mailer.js 單元測試（不會真的寄信 —— fetch 全程 stub）
 * 跑法：node website/test/mailer.test.js
 */
const assert = require('assert');
const mailer = require('../lib/mailer');

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

const realFetch = global.fetch;
const realEnv = { key: process.env.RESEND_API_KEY, from: process.env.RESEND_FROM_EMAIL };

function withMailerEnv() {
    process.env.RESEND_API_KEY = 're_test_key';
    process.env.RESEND_FROM_EMAIL = 'KongGoo <noreply@konggoo.uk>';
}

function clearMailerEnv() {
    delete process.env.RESEND_API_KEY;
    delete process.env.RESEND_FROM_EMAIL;
}

function restore() {
    global.fetch = realFetch;
    if (realEnv.key === undefined) delete process.env.RESEND_API_KEY;
    else process.env.RESEND_API_KEY = realEnv.key;
    if (realEnv.from === undefined) delete process.env.RESEND_FROM_EMAIL;
    else process.env.RESEND_FROM_EMAIL = realEnv.from;
}

(async () => {
    // ---- 渲染 ----
    await test('授權碼與到期日出現在 HTML，且套用房規配色', () => {
        const html = mailer.renderLicenseEmailHtml({
            licenseKey: 'KGOO-AAAA-BBBB-CCCC',
            planType: 'annual',
            expiresAt: '2027-08-17T00:00:00.000Z'
        });
        assert.ok(html.includes('KGOO-AAAA-BBBB-CCCC'), '缺授權碼');
        assert.ok(html.includes('2027-08-17'), '缺到期日');
        assert.ok(html.includes('#f5f5f7') && html.includes('#ffffff') && html.includes('#F5A623'), '配色不符');
        assert.ok(!/linear-gradient/i.test(html), '不得使用漸層');
        assert.ok(!/background-color:\s*#(0|1|2)/i.test(html), '不得使用深色底');
    });

    await test('lifetime 顯示永久有效、不顯示到期日', () => {
        const html = mailer.renderLicenseEmailHtml({
            licenseKey: 'KGOO-1111-2222-3333',
            planType: 'lifetime',
            expiresAt: null
        });
        assert.ok(html.includes('永久有效'));
        assert.ok(!html.includes('到期後需重新購買'));
    });

    await test('annual 尚未啟用時說明到期日從啟用起算', () => {
        const html = mailer.renderLicenseEmailHtml({
            licenseKey: 'KGOO-1111-2222-3333',
            planType: 'annual',
            expiresAt: null
        });
        assert.ok(html.includes('啟用後起算一年'));
    });

    await test('補寄版標題不同於首次寄送', () => {
        const first = mailer.renderLicenseEmailHtml({ licenseKey: 'K', planType: 'annual' });
        const again = mailer.renderLicenseEmailHtml({ licenseKey: 'K', planType: 'annual', isResend: true });
        assert.ok(again.includes('補寄'));
        assert.ok(!first.includes('補寄'));
    });

    await test('動態值有 HTML escape（不可被注入）', () => {
        const html = mailer.renderLicenseEmailHtml({
            licenseKey: '<script>alert(1)</script>',
            planType: 'annual'
        });
        assert.ok(!html.includes('<script>alert(1)</script>'));
        assert.ok(html.includes('&lt;script&gt;'));
    });

    await test('純文字版含授權碼', () => {
        const text = mailer.renderLicenseEmailText({ licenseKey: 'KGOO-X', planType: 'annual' });
        assert.ok(text.includes('KGOO-X'));
    });

    // ---- 寄送 ----
    await test('未設定 RESEND 環境變數時安全跳過，不當成失敗炸掉流程', async () => {
        clearMailerEnv();
        const result = await mailer.sendLicenseEmail({ to: 'a@b.com', licenseKey: 'K', planType: 'annual' });
        assert.strictEqual(result.sent, false);
        assert.strictEqual(result.skipped, true);
        assert.strictEqual(result.error, 'MAILER_NOT_CONFIGURED');
    });

    await test('成功時回傳 Resend id，且 payload 欄位正確', async () => {
        withMailerEnv();
        let captured = null;
        global.fetch = async (url, options) => {
            captured = { url, options };
            return { ok: true, status: 200, json: async () => ({ id: 'em_123' }) };
        };
        const result = await mailer.sendLicenseEmail({
            to: 'buyer@example.com',
            licenseKey: 'KGOO-AAAA-BBBB-CCCC',
            planType: 'annual',
            expiresAt: '2027-08-17T00:00:00.000Z'
        });
        assert.strictEqual(result.sent, true);
        assert.strictEqual(result.id, 'em_123');
        assert.strictEqual(captured.url, 'https://api.resend.com/emails');
        const body = JSON.parse(captured.options.body);
        assert.deepStrictEqual(body.to, ['buyer@example.com']);
        assert.strictEqual(body.from, 'KongGoo <noreply@konggoo.uk>');
        assert.ok(body.subject.includes('KongGoo'));
        assert.ok(body.html.includes('KGOO-AAAA-BBBB-CCCC'));
        assert.ok(body.text.includes('KGOO-AAAA-BBBB-CCCC'));
        assert.strictEqual(captured.options.headers.Authorization, 'Bearer re_test_key');
    });

    await test('Resend 回錯誤碼時回 sent:false 但不 throw', async () => {
        withMailerEnv();
        global.fetch = async () => ({
            ok: false,
            status: 422,
            json: async () => ({ message: 'domain not verified' })
        });
        const result = await mailer.sendLicenseEmail({ to: 'a@b.com', licenseKey: 'K', planType: 'annual' });
        assert.strictEqual(result.sent, false);
        assert.ok(result.error.includes('422'));
        assert.ok(result.error.includes('domain not verified'));
    });

    await test('網路爆炸時回 sent:false 但不 throw（發 key 流程不能被寄信拖垮）', async () => {
        withMailerEnv();
        global.fetch = async () => { throw new Error('ECONNRESET'); };
        const result = await mailer.sendLicenseEmail({ to: 'a@b.com', licenseKey: 'K', planType: 'annual' });
        assert.strictEqual(result.sent, false);
        assert.strictEqual(result.error, 'ECONNRESET');
    });

    await test('已寄出但回應 body 壞掉，仍算 sent（避免重複寄送）', async () => {
        withMailerEnv();
        global.fetch = async () => ({ ok: true, status: 200, json: async () => { throw new Error('bad json'); } });
        const result = await mailer.sendLicenseEmail({ to: 'a@b.com', licenseKey: 'K', planType: 'annual' });
        assert.strictEqual(result.sent, true);
    });

    restore();
    console.log(`\nmailer: ${passed} passed, ${failed} failed`);
    process.exit(failed > 0 ? 1 : 0);
})();
