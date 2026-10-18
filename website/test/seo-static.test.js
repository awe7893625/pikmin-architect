const assert = require('assert');
const fs = require('fs');
const path = require('path');

const root = path.join(__dirname, '..');
const sitemap = fs.readFileSync(path.join(root, 'public', 'sitemap.xml'), 'utf8');
const robots = fs.readFileSync(path.join(root, 'public', 'robots.txt'), 'utf8');
const llms = fs.readFileSync(path.join(root, 'public', 'llms.txt'), 'utf8');

let passed = 0;
let failed = 0;

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

const alternates = {
    'zh-TW': 'https://konggoo.uk/',
    ja: 'https://konggoo.uk/ja/',
    ko: 'https://konggoo.uk/ko/',
    en: 'https://konggoo.uk/en/',
    'zh-CN': 'https://konggoo.uk/zh-CN/',
    'x-default': 'https://konggoo.uk/'
};
const languageUrls = Object.values(alternates).slice(0, 5);
const urlBlocks = [...sitemap.matchAll(/<url>([\s\S]*?)<\/url>/g)].map((m) => m[1]);

test('sitemap includes all five language locations', () => {
    for (const url of languageUrls) assert.ok(sitemap.includes(`<loc>${url}</loc>`), `missing ${url}`);
});

test('each language URL block has all six correct hreflang alternates', () => {
    for (const url of languageUrls) {
        const block = urlBlocks.find((item) => item.includes(`<loc>${url}</loc>`));
        assert.ok(block, `missing URL block for ${url}`);
        for (const [lang, href] of Object.entries(alternates)) {
            const link = new RegExp(`<xhtml:link\\s+rel="alternate"\\s+hreflang="${lang}"\\s+href="${href.replace(/[.*+?^${}()|[\\]\\\\]/g, '\\$&')}"\\s*/>`);
            assert.match(block, link, `${url} missing ${lang} alternate`);
        }
    }
});

const namedBots = ['GPTBot', 'ClaudeBot', 'PerplexityBot', 'Google-Extended', 'CCBot', 'Bingbot', 'Yeti'];
test('robots allows requested crawler groups and blocks protected paths', () => {
    for (const bot of namedBots) assert.ok(new RegExp(`User-agent: ${bot}\\nAllow: /`).test(robots), `missing allow group for ${bot}`);
    assert.ok(robots.includes('Disallow: /admin'));
    assert.ok(robots.includes('Disallow: /api/'));
    assert.ok(robots.includes('Sitemap: https://konggoo.uk/sitemap.xml'));
});

test('each named robots group repeats the admin exclusion', () => {
    const groups = robots.split(/(?=^User-agent: )/m);
    for (const bot of namedBots) {
        const group = groups.find((item) => item.startsWith(`User-agent: ${bot}`));
        assert.ok(group && /^Disallow: \/admin$/m.test(group), `${bot} group missing Disallow: /admin`);
    }
});

test('llms.txt includes requested languages, downloads, and pricing', () => {
    assert.ok(llms.startsWith('# KongGoo'));
    for (const url of ['https://konggoo.uk/ja/', 'https://konggoo.uk/ko/', 'https://konggoo.uk/en/', 'https://konggoo.uk/zh-CN/']) {
        assert.ok(llms.includes(url), `missing ${url}`);
    }
    for (const url of [
        'https://github.com/awe7893625/pikmin-architect/releases/download/v1.1.2/KongGoo-1.1.2-arm64.dmg',
        'https://github.com/awe7893625/pikmin-architect/releases/download/v1.1.2/KongGoo-1.1.2-x64.dmg',
        'https://github.com/awe7893625/pikmin-architect/releases/download/v1.1.2/KongGoo-1.1.2-win-x64.exe'
    ]) assert.ok(llms.includes(url), `missing ${url}`);
    assert.ok(llms.includes('NT$690'));
    assert.ok(llms.includes('US$22'));
    assert.ok(llms.includes('US$55'));
});

console.log(`\nseo-static: ${passed} passed, ${failed} failed`);
process.exit(failed > 0 ? 1 : 0);
