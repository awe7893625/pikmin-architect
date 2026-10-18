const assert = require('assert');
const fs = require('fs');
const http = require('http');

process.env.NODE_ENV = 'test';
delete process.env.VERCEL_ENV;
process.env.KV_MODE = 'mock';

const app = require('../server');
let passed = 0;
let failed = 0;
let base = '';
async function test(name, fn) {
    try { await fn(); passed += 1; console.log(`  ok  ${name}`); }
    catch (error) { failed += 1; console.error(`  FAIL ${name}: ${error.message}`); }
}
async function request(path, options = {}) {
    return new Promise((resolve, reject) => {
        const url = new URL(path, base);
        const req = http.request({ hostname: url.hostname, port: url.port, path: url.pathname + url.search,
            method: options.method || 'GET', headers: options.headers || {} }, (res) => {
            let body = '';
            res.setEncoding('utf8');
            res.on('data', (chunk) => { body += chunk; });
            res.on('end', () => resolve({ status: res.statusCode, headers: res.headers, body }));
        });
        req.on('error', reject);
        if (options.body) req.write(options.body);
        req.end();
    });
}

(async () => {
    const server = app.listen(0);
    await new Promise((resolve) => server.once('listening', resolve));
    base = `http://127.0.0.1:${server.address().port}`;

    await test('locale API rejects traversal and unsupported language, and serves the whitelist', async () => {
        for (const path of ['/api/locale/..%2Fpackage', '/api/locale/xx']) {
            const response = await request(path);
            assert.strictEqual(response.status, 404);
            assert.deepStrictEqual(JSON.parse(response.body), { error: 'Not Found', code: 'LOCALE_NOT_FOUND' });
        }
        for (const lang of ['zh-TW', 'ja', 'ko', 'en', 'zh-CN']) {
            const response = await request(`/api/locale/${lang}`);
            assert.strictEqual(response.status, 200);
            assert.ok(JSON.parse(response.body) && typeof JSON.parse(response.body) === 'object');
        }
    });

    await test('ECPay trade date uses Taipei time including midnight', async () => {
        assert.strictEqual(app.formatTaipeiTradeDate(new Date('2026-01-01T16:30:05Z')), '2026/01/02 00:30:05');
        assert.strictEqual(app.formatTaipeiTradeDate(new Date('2026-06-30T15:59:59Z')), '2026/06/30 23:59:59');
        assert.strictEqual(app.formatTaipeiTradeDate(new Date('2026-01-01T16:00:00Z')), '2026/01/02 00:00:00');
    });

    await test('unknown route returns a path-safe 404 JSON response', async () => {
        const response = await request('/missing-hardening-route');
        assert.strictEqual(response.status, 404);
        assert.strictEqual(JSON.parse(response.body).error, 'Not Found');
        assert.ok(!response.body.includes(__dirname));
        assert.ok(!response.body.includes('/Users'));
        assert.ok(!response.body.includes('website'));
    });

    await test('malformed API JSON returns BAD_JSON without console.error', async () => {
        const originalError = console.error;
        const errors = [];
        console.error = (...args) => errors.push(args);
        let response;
        try {
            response = await request('/api/device/register', { method: 'POST',
                headers: { 'Content-Type': 'application/json' }, body: '{bad' });
        } finally { console.error = originalError; }
        assert.strictEqual(response.status, 400);
        assert.match(response.headers['content-type'], /application\/json/);
        assert.strictEqual(JSON.parse(response.body).code, 'BAD_JSON');
        assert.strictEqual(errors.length, 0);
    });

    await test('www host redirects GET with 301 and POST with 308; apex and localhost do not redirect', async () => {
        const get = await request('/ja/?x=1', { headers: { Host: 'www.konggoo.uk' } });
        assert.strictEqual(get.status, 301);
        assert.strictEqual(get.headers.location, 'https://konggoo.uk/ja/?x=1');
        const post = await request('/api/payment/ecpay-notify', { method: 'POST', headers: { Host: 'www.konggoo.uk' } });
        assert.strictEqual(post.status, 308);
        assert.strictEqual(post.headers.location, 'https://konggoo.uk/api/payment/ecpay-notify');
        for (const host of ['konggoo.uk', 'localhost']) {
            const response = await request('/missing-hardening-route', { headers: { Host: host } });
            assert.strictEqual(response.status, 404);
        }
    });

    await test('latest release metadata matches the public download links', async () => {
        const response = await request('/api/app/latest');
        assert.strictEqual(response.status, 200);
        assert.match(response.headers['cache-control'], /public, max-age=300/);
        const data = JSON.parse(response.body);
        assert.strictEqual(data.version, '1.2.0');
        for (const lang of ['zh-TW', 'ja', 'ko', 'en']) assert.ok(data.notes[lang].trim());
        const html = fs.readFileSync(require.resolve('../public/index.html'), 'utf8');
        for (const key of ['macArm64', 'macX64', 'winX64']) {
            const url = data.downloads[key];
            assert.ok(url.includes('/v1.2.0/') && url.includes('1.2.0'));
            assert.ok(html.includes(url), `${key} URL missing from public/index.html`);
        }
    });

    await test('server source no longer honors MAC_DMG_URL', async () => {
        assert.ok(!fs.readFileSync(require.resolve('../server'), 'utf8').includes('MAC_DMG_URL'));
    });

    await new Promise((resolve) => server.close(resolve));
    console.log(`\nhardening: ${passed} passed, ${failed} failed`);
    process.exit(failed > 0 ? 1 : 0);
})();
