// 創建測試激活碼腳本
const crypto = require('crypto');

// 生成 5 組測試激活碼
const testLicenses = [];
for (let i = 0; i < 5; i++) {
    const licenseKey = 'PKM-' + crypto.randomBytes(8).toString('hex').toUpperCase();
    testLicenses.push(licenseKey);
}

console.log('=== 測試激活碼（5 組）===');
console.log('');
testLicenses.forEach((key, index) => {
    console.log(`${index + 1}. ${key}`);
});
console.log('');
console.log('=== 使用說明 ===');
console.log('這些激活碼可以手動添加到 auth_server.js 的 licenses Map 中，');
console.log('或通過 /api/admin/create-license API 創建。');
console.log('');
console.log('每個激活碼只能使用一次，綁定到一個設備。');

// 輸出可以直接使用的 JSON 格式
console.log('');
console.log('=== JSON 格式（可直接複製）===');
const licensesObj = {};
testLicenses.forEach(key => {
    licensesObj[key] = {
        deviceId: null,
        paidAt: new Date().toISOString(),
        isValid: true,
        createdAt: new Date().toISOString()
    };
});
console.log(JSON.stringify(licensesObj, null, 2));
