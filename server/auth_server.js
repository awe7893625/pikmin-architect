const express = require('express');
const cors = require('cors');

const app = express();

// 中間件
app.use(cors());
app.use(express.json());

// 內存存儲（生產環境應使用數據庫）
const devices = new Map(); // deviceId -> { trialCount, licenseKey, activatedAt }
const licenses = new Map(); // licenseKey -> { deviceId, paidAt, isValid, createdAt }

// 管理員密鑰（從環境變數讀取）
const ADMIN_KEY = process.env.ADMIN_KEY || 'default-admin-key-change-in-production';

// 初始化一些測試授權碼（可選）
if (licenses.size === 0) {
    // 可以手動添加測試授權碼
    // licenses.set('KGOO-TEST-0000-0001', { deviceId: null, paidAt: new Date().toISOString(), isValid: true, createdAt: new Date().toISOString() });
}

// API 端點

// 1. 註冊設備
app.post('/api/device/register', (req, res) => {
    const { deviceId, deviceInfo } = req.body;
    
    if (!deviceId) {
        return res.status(400).json({ error: 'deviceId 是必需的' });
    }
    
    // 如果設備已存在，返回現有狀態
    if (devices.has(deviceId)) {
        const device = devices.get(deviceId);
        return res.json({
            trialCount: device.trialCount,
            licenseKey: device.licenseKey || null,
            isActivated: !!device.licenseKey
        });
    }
    
    // 新設備，初始化 3 次免費試用
    devices.set(deviceId, {
        trialCount: 3,
        licenseKey: null,
        activatedAt: null,
        registeredAt: new Date().toISOString()
    });
    
    res.json({
        trialCount: 3,
        licenseKey: null,
        isActivated: false
    });
});

// 2. 檢查授權狀態
app.post('/api/auth/check', (req, res) => {
    const { deviceId } = req.body;
    
    if (!deviceId) {
        return res.status(400).json({ error: 'deviceId 是必需的' });
    }
    
    // 如果設備未註冊，自動註冊
    if (!devices.has(deviceId)) {
        devices.set(deviceId, {
            trialCount: 3,
            licenseKey: null,
            activatedAt: null,
            registeredAt: new Date().toISOString()
        });
    }
    
    const device = devices.get(deviceId);
    
    res.json({
        trialCount: device.trialCount || 0,
        licenseKey: device.licenseKey || null,
        isActivated: !!device.licenseKey
    });
});

// 3. 使用試用次數
app.post('/api/trial/use', (req, res) => {
    const { deviceId } = req.body;
    
    if (!deviceId) {
        return res.status(400).json({ error: 'deviceId 是必需的' });
    }
    
    // 如果設備未註冊，自動註冊
    if (!devices.has(deviceId)) {
        devices.set(deviceId, {
            trialCount: 3,
            licenseKey: null,
            activatedAt: null,
            registeredAt: new Date().toISOString()
        });
    }
    
    const device = devices.get(deviceId);
    
    // 如果已激活，不需要消耗試用次數
    if (device.licenseKey) {
        return res.json({
            success: true,
            trialCount: device.trialCount,
            message: '已激活，無需消耗試用次數'
        });
    }
    
    // 檢查試用次數
    if (device.trialCount <= 0) {
        return res.status(403).json({
            error: '試用次數已用完，請購買授權',
            trialCount: 0
        });
    }
    
    // 消耗一次試用
    device.trialCount--;
    devices.set(deviceId, device);
    
    res.json({
        success: true,
        trialCount: device.trialCount
    });
});

// 4. 激活授權碼
app.post('/api/license/activate', (req, res) => {
    const { deviceId, licenseKey } = req.body;
    
    if (!deviceId || !licenseKey) {
        return res.status(400).json({ error: 'deviceId 和 licenseKey 都是必需的' });
    }
    
    // 檢查授權碼是否存在
    if (!licenses.has(licenseKey)) {
        return res.status(404).json({ error: '授權碼不存在' });
    }
    
    const license = licenses.get(licenseKey);
    
    // 檢查授權碼是否有效
    if (!license.isValid) {
        return res.status(403).json({ error: '授權碼已失效' });
    }
    
    // 檢查授權碼是否已被使用
    if (license.deviceId && license.deviceId !== deviceId) {
        return res.status(403).json({ error: '授權碼已被其他設備使用' });
    }
    
    // 如果設備未註冊，自動註冊
    if (!devices.has(deviceId)) {
        devices.set(deviceId, {
            trialCount: 0,
            licenseKey: null,
            activatedAt: null,
            registeredAt: new Date().toISOString()
        });
    }
    
    // 激活授權碼
    const device = devices.get(deviceId);
    device.licenseKey = licenseKey;
    device.activatedAt = new Date().toISOString();
    devices.set(deviceId, device);
    
    // 標記授權碼為已使用
    license.deviceId = deviceId;
    license.activatedAt = new Date().toISOString();
    licenses.set(licenseKey, license);
    
    res.json({
        success: true,
        message: '授權碼激活成功',
        licenseKey: licenseKey,
        activatedAt: device.activatedAt
    });
});

// 5. 創建授權碼（管理員）
app.post('/api/admin/create-license', (req, res) => {
    const { adminKey, deviceId } = req.body;
    
    if (adminKey !== ADMIN_KEY) {
        return res.status(401).json({ error: '無效的管理員密鑰' });
    }
    
    const crypto = require('crypto');
    const _hex = crypto.randomBytes(6).toString('hex').toUpperCase();
    const licenseKey = `KGOO-${_hex.slice(0, 4)}-${_hex.slice(4, 8)}-${_hex.slice(8, 12)}`;
    
    licenses.set(licenseKey, {
        deviceId: deviceId || null,
        paidAt: new Date().toISOString(),
        isValid: true,
        createdAt: new Date().toISOString(),
        activatedAt: deviceId ? new Date().toISOString() : null
    });
    
    // 如果指定了 deviceId，直接激活
    if (deviceId) {
        if (!devices.has(deviceId)) {
            devices.set(deviceId, {
                trialCount: 0,
                licenseKey: licenseKey,
                activatedAt: new Date().toISOString(),
                registeredAt: new Date().toISOString()
            });
        } else {
            const device = devices.get(deviceId);
            device.licenseKey = licenseKey;
            device.activatedAt = new Date().toISOString();
            devices.set(deviceId, device);
        }
    }
    
    res.json({
        success: true,
        licenseKey: licenseKey,
        deviceId: deviceId || null
    });
});

// 6. 查看統計（管理員）
app.get('/api/admin/stats', (req, res) => {
    const { adminKey } = req.query;
    
    if (adminKey !== ADMIN_KEY) {
        return res.status(401).json({ error: '無效的管理員密鑰' });
    }
    
    const totalDevices = devices.size;
    const activatedDevices = Array.from(devices.values()).filter(d => d.licenseKey).length;
    const totalLicenses = licenses.size;
    const usedLicenses = Array.from(licenses.values()).filter(l => l.deviceId).length;
    
    res.json({
        devices: {
            total: totalDevices,
            activated: activatedDevices,
            trial: totalDevices - activatedDevices
        },
        licenses: {
            total: totalLicenses,
            used: usedLicenses,
            available: totalLicenses - usedLicenses
        }
    });
});

// 7. 創建付款連結（用於購買授權）
app.post('/api/payment/create', (req, res) => {
    const { planType } = req.body;
    
    // 這裡應該整合實際的金流系統（綠界、Stripe 等）
    // 目前返回一個測試 URL
    const paymentUrl = `https://kòng-koo.vercel.app/payment?planType=${planType || 'annual'}`;
    
    res.json({
        success: true,
        paymentUrl: paymentUrl,
        message: '請前往付款頁面完成購買'
    });
});

// 健康檢查
app.get('/api/health', (req, res) => {
    res.json({ status: 'ok', timestamp: new Date().toISOString() });
});

// 錯誤處理
app.use((err, req, res, next) => {
    console.error('錯誤:', err);
    res.status(500).json({ error: '服務器內部錯誤' });
});

// 啟動服務器
const PORT = process.env.PORT || 3000;
app.listen(PORT, () => {
    console.log(`授權服務器運行在端口 ${PORT}`);
    console.log(`管理員密鑰: ${ADMIN_KEY}`);
});

// 導出給 Vercel 使用
module.exports = app;
