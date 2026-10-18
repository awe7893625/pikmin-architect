const assert = require('assert');
const fs = require('fs');
const path = require('path');

const root = path.join(__dirname, '..');
const indexHtml = fs.readFileSync(path.join(root, 'public', 'index.html'), 'utf8');
const locales = Object.fromEntries(['zh-TW', 'ja', 'ko', 'en', 'zh-CN'].map((code) => [
    code, JSON.parse(fs.readFileSync(path.join(root, 'locales', `${code}.json`), 'utf8'))
]));
const paths = { 'zh-TW': '/', ja: '/ja/', ko: '/ko/', en: '/en/', 'zh-CN': '/zh-CN/' };
const absolute = Object.fromEntries(Object.entries(paths).map(([code, pathname]) => [code, `https://konggoo.uk${pathname}`]));
const alternateSet = { ...absolute, 'x-default': 'https://konggoo.uk/' };
let passed = 0;
let failed = 0;
let base = '';

function test(name, fn) {
    try {
        fn();
        passed += 1;
        console.log(`  ok  ${name}`);
    } catch (error) {
        failed += 1;
        console.error(`  FAIL ${name}: ${error.message}`);
    }
}
async function get(pathname) {
    const response = await fetch(base + pathname, { redirect: 'manual' });
    return { response, body: await response.text() };
}
function escapeHtml(value) {
    return String(value).replace(/[&<>"']/g, (ch) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[ch]);
}
function attr(html, selector) {
    const match = html.match(selector);
    assert.ok(match, `missing ${selector}`);
    return match[1];
}

(async () => {
    process.env.NODE_ENV = 'test';
    process.env.KV_MODE = 'mock';
    delete process.env.VERCEL_ENV;
    const app = require('../server');
    const server = app.listen(0);
    await new Promise((resolve) => server.once('listening', resolve));
    base = `http://127.0.0.1:${server.address().port}`;

    const pages = {};
    for (const [code, pathname] of Object.entries(paths)) {
        const { response, body } = await get(pathname);
        pages[code] = body;
        test(`${pathname} returns rendered ${code} HTML and SEO metadata`, () => {
            assert.strictEqual(response.status, 200);
            assert.match(response.headers.get('content-type'), /text\/html/);
            assert.match(body, new RegExp(`<html lang="${code.replace('-', '\\-')}">`));
            assert.ok(body.includes(`<title>${escapeHtml(locales[code].meta_title)}</title>`));
            assert.ok(body.includes(`name="description" content="${escapeHtml(locales[code].meta_desc)}"`));
            assert.ok(body.includes(`<link rel="canonical" href="${absolute[code]}">`));
            const ogLocales = { 'zh-TW': 'zh_TW', ja: 'ja_JP', ko: 'ko_KR', en: 'en_US', 'zh-CN': 'zh_CN' };
            assert.ok(body.includes(`property="og:locale" content="${ogLocales[code]}"`));
            assert.strictEqual(response.headers.get('content-language'), code);
            assert.strictEqual(response.headers.get('cache-control'), 'public, max-age=300');
        });
        test(`${code} page has exactly the six expected hreflang links`, () => {
            const links = [...body.matchAll(/<link rel="alternate" hreflang="([^"]+)" href="([^"]+)">/g)].map((m) => [m[1], m[2]]);
            assert.strictEqual(links.length, 6);
            assert.deepStrictEqual(Object.fromEntries(links), alternateSet);
        });
    }

    test('every index data-i18n value is rendered for all five locales', () => {
        const keys = [...indexHtml.matchAll(/data-i18n="([^"]+)"/g)].map((m) => m[1]);
        for (const code of Object.keys(paths)) {
            for (const key of keys) assert.ok(pages[code].includes(escapeHtml(locales[code][key])), `${code}.${key} missing`);
        }
    });
    test('ja and ko do not expose the zh-TW hero title or subtitle strings', () => {
        for (const code of ['ja', 'ko']) {
            assert.ok(!pages[code].includes(locales['zh-TW'].hero_title_2));
            assert.ok(!pages[code].includes(locales['zh-TW'].hero_sub));
        }
    });
    test('all rendered JSON-LD blocks parse and describe localized offers and FAQ', () => {
        for (const [code, body] of Object.entries(pages)) {
            const blocks = [...body.matchAll(/<script type="application\/ld\+json">([\s\S]*?)<\/script>/g)].map((m) => JSON.parse(m[1]));
            const application = blocks.find((item) => item['@type'] === 'SoftwareApplication');
            const faq = blocks.find((item) => item['@type'] === 'FAQPage');
            assert.ok(application && faq, `${code} JSON-LD types missing`);
            assert.strictEqual(application.operatingSystem, 'macOS, Windows');
            assert.strictEqual(application.applicationCategory, 'UtilitiesApplication');
            assert.deepStrictEqual(application.offers.map((offer) => [offer.priceCurrency, offer.price]), code === 'zh-TW' ? [['TWD', '690'], ['TWD', '1750']] : [['USD', '22'], ['USD', '55']]);
            assert.deepStrictEqual(faq.mainEntity.map((item) => item.name), [1,2,3,4,5,6].map((i) => locales[code][`faq_q${i}`]));
            assert.ok(faq.mainEntity[0].acceptedAnswer.text.includes('xattr -cr /Applications/KongGoo.app'));
        }
    });
    test('reference prices and Taiwan prices render in the intended locales', () => {
        assert.ok(pages.ja.includes('≈ ¥3,300') && pages.ja.includes('≈ ¥8,300'));
        assert.ok(pages.ko.includes('≈ ₩30,000') && pages.ko.includes('≈ ₩76,000'));
        for (const code of ['ja', 'ko', 'en', 'zh-CN']) assert.ok(!pages[code].includes('NT$'), `${code} contains NT$`);
        assert.ok(pages['zh-TW'].includes('NT$ 690'));
    });
    test('each page has all five language links with only its own link active', () => {
        for (const [code, body] of Object.entries(pages)) {
            const links = [...body.matchAll(/<a class="lang-btn( active)?" href="([^"]+)"[^>]*data-lang="([^"]+)"[^>]*>([^<]+)<\/a>/g)];
            assert.strictEqual(links.length, 5, `${code}: expected five language links`);
            for (const link of links) assert.strictEqual(Boolean(link[1]), link[3] === code, `${code}: active state for ${link[3]}`);
            for (const href of Object.values(paths)) assert.ok(body.includes(`href="${href}"`));
            assert.ok(body.includes('日本語'));
        }
    });
    test('/ja without slash redirects and preserves query string', async () => {
        const { response } = await get('/ja?source=test');
        assert.strictEqual(response.status, 301);
        assert.strictEqual(response.headers.get('location'), '/ja/?source=test');
    });
    test('static SEO resources are served by Express', async () => {
        const sitemap = await get('/sitemap.xml');
        assert.strictEqual(sitemap.response.status, 200);
        assert.ok(sitemap.body.includes('<loc>https://konggoo.uk/ja/</loc>'));
        assert.ok(sitemap.body.includes('<loc>https://konggoo.uk/ko/</loc>'));
        const robots = await get('/robots.txt');
        assert.strictEqual(robots.response.status, 200);
        assert.ok(robots.body.includes('GPTBot') && robots.body.includes('Sitemap:'));
        const llms = await get('/llms.txt');
        assert.strictEqual(llms.response.status, 200);
        assert.match(llms.response.headers.get('content-type'), /text\/plain/);
    });
    test('every data-i18n element has no nested child markup', () => {
        const elements = [...indexHtml.matchAll(/<([a-z][\w:-]*)\b[^>]*\bdata-i18n="[^"]+"[^>]*>([\s\S]*?)<\/\1\s*>/gi)];
        assert.ok(elements.length > 0);
        for (const [, tag, contents] of elements) assert.ok(!contents.includes('<'), `<${tag} data-i18n> has nested markup`);
    });
    test('source keeps server language, payment language, and static page price hooks', () => {
        assert.ok(indexHtml.includes("'&lang=' + encodeURIComponent(currentLang)"));
        assert.ok(indexHtml.includes("let currentLang = document.documentElement.lang || 'zh-TW'"));
        assert.ok(indexHtml.includes("location.pathname === '/'"));
        assert.ok(indexHtml.includes("return 'ja'"));
        assert.ok(!indexHtml.includes('open.er-api.com'));
        const payment = fs.readFileSync(path.join(root, 'public', 'payment.html'), 'utf8');
        assert.ok(payment.includes('data-i18n="price_annual_amount">NT$ 690'));
        assert.ok(payment.includes('data-i18n="price_lifetime_amount">NT$ 1,750'));
    });
    test('non-Taiwan locale files contain no Taiwan dollar amounts', () => {
        for (const code of ['en', 'ja', 'ko', 'zh-CN']) assert.ok(!JSON.stringify(locales[code]).includes('NT$'), `${code} contains NT$`);
    });

    await new Promise((resolve) => server.close(resolve));
    console.log(`\nseo-i18n: ${passed} passed, ${failed} failed`);
    process.exit(failed > 0 ? 1 : 0);
})().catch((error) => {
    console.error(error);
    process.exit(1);
});
