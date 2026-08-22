/**
 * 購買流程文案檢查
 *
 * 背景：付款頁的 i18n key 以前五個語系檔全缺，英日韓買家一路看到中文；
 * 另有「（TODO）」「不提供自動轉移」等過時字樣直接露給客人看。
 * 這支測試釘死購買流程用到的 key 在五個語系都在，且全站沒有 TODO 外洩。
 *
 * 跑法：node website/test/locales.test.js
 */
const assert = require('assert');
const fs = require('fs');
const path = require('path');

const root = path.join(__dirname, '..');
const LANGS = ['zh-TW', 'zh-CN', 'en', 'ja', 'ko'];

// 首頁與購買流程頁面：這些頁面的 i18n key 必須五語系齊全
const FLOW_PAGES = [
    path.join(root, 'public', 'index.html'),
    path.join(root, 'public', 'payment.html'),
    path.join(root, 'public', 'payment', 'success.html')
];

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

function keysUsedIn(file) {
    const html = fs.readFileSync(file, 'utf8');
    const keys = new Set();
    for (const m of html.matchAll(/data-i18n(?:-html)?="([^"]+)"/g)) keys.add(m[1]);
    for (const m of html.matchAll(/translations\.([A-Za-z_][A-Za-z0-9_]*)/g)) keys.add(m[1]);
    return [...keys];
}

function formatMissing(lang, missing) {
    const preview = missing.slice(0, 5).join(', ');
    const suffix = missing.length > 5 ? `…等共 ${missing.length} 個` : '';
    return `${lang} 缺 ${missing.length} 個，前 5 個：${preview}${suffix}`;
}

function gapsFor(used) {
    return LANGS.flatMap((lang) => {
        const missing = used.filter((key) => !(key in locales[lang]));
        return missing.length ? [formatMissing(lang, missing)] : [];
    });
}

const locales = Object.fromEntries(
    LANGS.map((l) => [l, JSON.parse(fs.readFileSync(path.join(root, 'locales', `${l}.json`), 'utf8'))])
);

for (const page of FLOW_PAGES) {
    const name = path.relative(path.join(root, 'public'), page);
    const used = keysUsedIn(page);
    test(`${name} 的 ${used.length} 個文案 key 五語系齊全`, () => {
        const gaps = gapsFor(used);
        assert.strictEqual(gaps.length, 0, gaps.join(' / '));
    });
}

const FLOW_KEYS = [...new Set(FLOW_PAGES.flatMap(keysUsedIn))];
test(`首頁與購買流程頁用到的 ${FLOW_KEYS.length} 個 key 五語系齊全`, () => {
    const gaps = gapsFor(FLOW_KEYS);
    assert.strictEqual(gaps.length, 0, gaps.join(' / '));
});

test('語系檔沒有 TODO 或過時的「不提供自動轉移」政策字樣', () => {
    const bad = [];
    for (const lang of LANGS) {
        for (const [k, v] of Object.entries(locales[lang])) {
            if (typeof v !== 'string') continue;
            if (/TODO|不提供自动转移|不提供自動轉移|自動移行なし/.test(v)) bad.push(`${lang}.${k}`);
        }
    }
    assert.strictEqual(bad.length, 0, bad.join(', '));
});

test('語系檔是合法 JSON 且沒有空字串文案', () => {
    for (const lang of LANGS) {
        for (const [k, v] of Object.entries(locales[lang])) {
            assert.ok(typeof v !== 'string' || v.trim().length > 0, `${lang}.${k} 是空字串`);
        }
    }
});

console.log(`\nlocales: ${passed} passed, ${failed} failed`);
process.exit(failed > 0 ? 1 : 0);
