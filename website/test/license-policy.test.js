/**
 * lib/license-policy.js 單元測試
 * 跑法：node website/test/license-policy.test.js
 */
const assert = require('assert');
const {
    PLAN_DURATION_DAYS,
    planDurationDays,
    computeExpiresAt,
    isLicenseExpired,
    normalizeEmail,
    isValidEmail,
    maskEmail
} = require('../lib/license-policy');

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

const DAY_MS = 24 * 60 * 60 * 1000;

// ---- 方案期限 ----
test('annual 是 365 天、lifetime 是永久', () => {
    assert.strictEqual(PLAN_DURATION_DAYS.annual, 365);
    assert.strictEqual(planDurationDays('annual'), 365);
    assert.strictEqual(planDurationDays('lifetime'), null);
});

test('未知方案回 null（不會誤套年限）', () => {
    assert.strictEqual(planDurationDays('weekly'), null);
    assert.strictEqual(planDurationDays(undefined), null);
    // 原型鏈汙染防護
    assert.strictEqual(planDurationDays('toString'), null);
});

// ---- 到期日計算 ----
test('annual 從啟用當下起算 365 天', () => {
    const activatedAt = '2026-08-17T00:00:00.000Z';
    const expiresAt = computeExpiresAt({ durationDays: 365 }, activatedAt);
    assert.strictEqual(
        new Date(expiresAt).getTime() - new Date(activatedAt).getTime(),
        365 * DAY_MS
    );
});

test('沒有 durationDays 的舊授權不會被算出到期日（grandfather）', () => {
    assert.strictEqual(computeExpiresAt({}, '2026-08-17T00:00:00.000Z'), null);
    assert.strictEqual(computeExpiresAt({ durationDays: null }, '2026-08-17T00:00:00.000Z'), null);
    assert.strictEqual(computeExpiresAt(null, '2026-08-17T00:00:00.000Z'), null);
});

test('啟用時間無效時回 null，不產生 Invalid Date', () => {
    assert.strictEqual(computeExpiresAt({ durationDays: 365 }, 'not-a-date'), null);
    assert.strictEqual(computeExpiresAt({ durationDays: 365 }, undefined), null);
});

// ---- 到期判定 ----
test('無 expiresAt = 永久授權，永不過期', () => {
    assert.strictEqual(isLicenseExpired({}), false);
    assert.strictEqual(isLicenseExpired({ expiresAt: null }), false);
    assert.strictEqual(isLicenseExpired(null), false);
});

test('既有兩筆付費客戶的記錄形狀不會被判過期', () => {
    // 2026-08 兩筆真實 license：有 planType annual、但無 durationDays / expiresAt
    const grandfathered = {
        planType: 'annual',
        issuedBy: 'payment',
        activatedAt: '2026-08-10T15:53:06.745Z',
        isValid: true
    };
    assert.strictEqual(isLicenseExpired(grandfathered), false);
    assert.strictEqual(computeExpiresAt(grandfathered, grandfathered.activatedAt), null);
});

test('到期日在過去 = 過期；在未來 = 未過期', () => {
    const now = new Date('2026-08-17T00:00:00.000Z');
    assert.strictEqual(isLicenseExpired({ expiresAt: '2026-08-16T23:59:59.000Z' }, now), true);
    assert.strictEqual(isLicenseExpired({ expiresAt: '2026-08-17T00:00:01.000Z' }, now), false);
});

test('到期當下那一秒即視為過期（邊界不放行）', () => {
    const now = new Date('2026-08-17T00:00:00.000Z');
    assert.strictEqual(isLicenseExpired({ expiresAt: '2026-08-17T00:00:00.000Z' }, now), true);
});

test('expiresAt 壞掉時不誤鎖客戶（fail open 到永久）', () => {
    assert.strictEqual(isLicenseExpired({ expiresAt: 'garbage' }), false);
});

// ---- Email ----
test('normalizeEmail 去空白轉小寫', () => {
    assert.strictEqual(normalizeEmail('  Rain@Example.COM '), 'rain@example.com');
    assert.strictEqual(normalizeEmail(null), '');
});

test('isValidEmail 擋掉明顯無效值', () => {
    assert.strictEqual(isValidEmail('rain@example.com'), true);
    assert.strictEqual(isValidEmail('rain+tag@sub.example.co.jp'), true);
    assert.strictEqual(isValidEmail(''), false);
    assert.strictEqual(isValidEmail('rain'), false);
    assert.strictEqual(isValidEmail('rain@example'), false);
    assert.strictEqual(isValidEmail('rain @example.com'), false);
    assert.strictEqual(isValidEmail('a@b.c'), false); // TLD 至少 2 碼
    assert.strictEqual(isValidEmail(`${'a'.repeat(250)}@example.com`), false);
});

test('maskEmail 不洩漏完整帳號，且一定有遮罩字元', () => {
    assert.strictEqual(maskEmail('rain@example.com'), 'ra**@example.com');
    assert.strictEqual(maskEmail('ab@example.com'), 'ab*@example.com');
    assert.strictEqual(maskEmail('a@example.com'), 'a*@example.com');
    assert.strictEqual(maskEmail('not-an-email'), '***');
    assert.strictEqual(maskEmail('@example.com'), '***');
});

console.log(`\nlicense-policy: ${passed} passed, ${failed} failed`);
process.exit(failed > 0 ? 1 : 0);
