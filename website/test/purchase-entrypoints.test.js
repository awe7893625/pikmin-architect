/**
 * 購買入口靜態檢查
 *
 * 背景：email 改必填後，首頁付款彈窗仍自己打 /api/payment/create，
 * 直接讓主要購買路徑 400 卡死。這支測試釘死「只有一個入口會建單，
 * 而且那個入口一定帶 email」，避免再有第二條路悄悄長出來。
 *
 * 跑法：node website/test/purchase-entrypoints.test.js
 */
const assert = require('assert');
const fs = require('fs');
const path = require('path');

const publicDir = path.join(__dirname, '..', 'public');

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

function htmlFiles(dir) {
    const out = [];
    for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
        const full = path.join(dir, entry.name);
        if (entry.isDirectory()) out.push(...htmlFiles(full));
        else if (entry.name.endsWith('.html')) out.push(full);
    }
    return out;
}

const files = htmlFiles(publicDir);

test('全站只有 payment.html 會呼叫 /api/payment/create', () => {
    const callers = files.filter((f) => /fetch\(\s*['"`]\/api\/payment\/create/.test(fs.readFileSync(f, 'utf8')));
    const names = callers.map((f) => path.relative(publicDir, f)).sort();
    assert.deepStrictEqual(names, ['payment.html'],
        `建單入口不只一個：${names.join(', ')}（新入口必須先收 Email，否則會被 400 擋死）`);
});

test('payment.html 建單時一定帶 email', () => {
    const html = fs.readFileSync(path.join(publicDir, 'payment.html'), 'utf8');
    const body = html.match(/fetch\(\s*'\/api\/payment\/create'[\s\S]{0,400}?\)\s*\}\)/);
    assert.ok(body, '找不到建單的 fetch 區塊');
    assert.ok(/email/.test(body[0]), '建單 payload 沒有帶 email');
});

test('payment.html 有 email 輸入欄位與前端格式驗證', () => {
    const html = fs.readFileSync(path.join(publicDir, 'payment.html'), 'utf8');
    assert.ok(/id="email"[\s\S]{0,120}type="email"|type="email"[\s\S]{0,120}id="email"/.test(html), '缺 email 欄位');
    assert.ok(/\[\^\\s@\]\+@\[\^\\s@\]\+/.test(html), '缺前端 email 格式驗證');
});

test('首頁購買鈕導向 /payment（而不是自己建單）', () => {
    const html = fs.readFileSync(path.join(publicDir, 'index.html'), 'utf8');
    const fn = html.match(/function redirectToPayment[\s\S]{0,400}?\n\}/);
    assert.ok(fn, '找不到 redirectToPayment');
    assert.ok(/\/payment\?planType=/.test(fn[0]), '首頁購買鈕沒有導到 /payment');
    assert.ok(!/fetch\(/.test(fn[0]), '首頁購買鈕不該自己建單');
});

test('/license 頁面有補寄授權碼的入口（API 不能沒有門）', () => {
    const html = fs.readFileSync(path.join(publicDir, 'license.html'), 'utf8');
    assert.ok(/id="resendEmail"/.test(html), '缺補寄 email 欄位');
    assert.ok(/\/api\/license\/resend/.test(html), '缺補寄 API 呼叫');
});

test('購買頁沒有留給客人看的 TODO', () => {
    const html = fs.readFileSync(path.join(publicDir, 'payment.html'), 'utf8');
    assert.ok(!/TODO/.test(html), 'payment.html 還有 TODO 字樣會被客人看到');
});

// ── 下載連結一致性 ─────────────────────────────────────────────
// 背景：下載連結硬編碼在 server.js / index.html / license.html 共 13 處，
// 每次發版都得手動改。過去就發生過只改了首頁、忘了 API 與授權頁，
// 客人從不同入口拿到不同版本。這裡釘死：全站所有 release 下載連結只能指向同一個 tag。
test('全站下載連結指向同一個 release tag', () => {
    const files = [
        path.join(publicDir, '..', 'server.js'),
        path.join(publicDir, 'index.html'),
        path.join(publicDir, 'license.html')
    ];
    const tags = new Map();
    for (const f of files) {
        const text = fs.readFileSync(f, 'utf8');
        // 只認真正的 repo 連結；server.js 註解裡有 OWNER/REPO/TAG 的格式範例，不能算進來
            for (const m of text.matchAll(/awe7893625\/pikmin-architect\/releases\/download\/([^/]+)\//g)) {
            if (!tags.has(m[1])) tags.set(m[1], []);
            tags.get(m[1]).push(path.basename(f));
        }
    }
    assert.ok(tags.size > 0, '找不到任何下載連結，選擇器可能失效了');
    assert.strictEqual(tags.size, 1,
        '下載連結指向多個版本：' + [...tags].map(([t, fs_]) => `${t}(${[...new Set(fs_)].join(',')})`).join(' / '));
});

test('三個平台的下載連結都在（macOS arm64 / macOS x64 / Windows）', () => {
    const text = fs.readFileSync(path.join(publicDir, '..', 'server.js'), 'utf8');
    for (const needle of ['arm64.dmg', 'x64.dmg', 'win-x64.exe']) {
        assert.ok(text.includes(needle), `server.js 少了 ${needle} 的下載連結`);
    }
});

console.log(`\npurchase entrypoints: ${passed} passed, ${failed} failed`);
process.exit(failed > 0 ? 1 : 0);
