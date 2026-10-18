const assert = require('assert');
const fs = require('fs');
const path = require('path');
const http = require('http');
const { parseSitemap, findKey, buildPayload } = require('../scripts/indexnow-submit');
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

(async () => {
    const server = app.listen(0);
    await new Promise((resolve) => server.once('listening', resolve));
    base = `http://127.0.0.1:${server.address().port}`;
    await test('server.js serves IndexNow key as plain text', async () => {
        const key = fs.readFileSync(path.join(__dirname, '..', 'public', '5d70fd83609fd4741131e52f03d4a068.txt'), 'utf8');
        const response = await fetch(`${base}/5d70fd83609fd4741131e52f03d4a068.txt`);
        assert.strictEqual(response.status, 200);
        assert.match(response.headers.get('content-type'), /^text\/plain/);
        assert.strictEqual(await response.text(), key);
    });
    await test('parseSitemap extracts every loc', async () => {
        assert.deepStrictEqual(parseSitemap('<urlset><url><loc>https://a.test/</loc></url><url><loc> https://b.test/x </loc></url></urlset>'), ['https://a.test/', 'https://b.test/x']);
    });
    await test('findKey scans public key filename and honors override', async () => {
        assert.strictEqual(findKey(path.join(__dirname, '..', 'public'), ''), '5d70fd83609fd4741131e52f03d4a068');
        assert.strictEqual(findKey('/missing', 'override'), 'override');
    });
    await test('buildPayload creates IndexNow schema', async () => {
        assert.deepStrictEqual(buildPayload(['https://konggoo.uk/'], 'abc'), { host: 'konggoo.uk', key: 'abc', keyLocation: 'https://konggoo.uk/abc.txt', urlList: ['https://konggoo.uk/'] });
    });
    await new Promise((resolve) => server.close(resolve));
    console.log(`\nindexnow: ${passed} passed, ${failed} failed`);
    process.exit(failed > 0 ? 1 : 0);
})();
