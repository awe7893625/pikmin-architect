const express = require('express');
const path = require('path');
const fs = require('fs');
const cors = require('cors');
const { execSync } = require('child_process');
const {
    planDurationDays,
    computeExpiresAt,
    isLicenseExpired,
    normalizeEmail,
    isValidEmail,
    maskEmail
} = require('./lib/license-policy');
const { sendLicenseEmail } = require('./lib/mailer');
const app = express();
const PORT = process.env.PORT || 3001;

// 中間件
app.use(cors());
// 需要保留 raw body 以驗證 ECPay 回傳
app.use(
    express.json({
        verify: (req, _res, buf) => {
            req.rawBody = buf;
        }
    })
);
app.use(express.urlencoded({ extended: true }));

// 先處理 API 路由和特殊路由，再處理靜態文件
// 這樣可以確保 /payment 等路由優先被處理

// ========= 啟動資訊（釘死入口 + commit）=========
function resolveCommitSha() {
    const envSha = process.env.VERCEL_GIT_COMMIT_SHA || process.env.GIT_COMMIT_SHA || process.env.COMMIT_SHA;
    if (envSha) return String(envSha);
    try {
        const sha = execSync('git rev-parse HEAD', { cwd: __dirname, stdio: ['ignore', 'pipe', 'ignore'] })
            .toString()
            .trim();
        if (!sha) return 'unknown';
        return sha.length > 12 ? sha.slice(0, 12) : sha;
    } catch (_) {
        return 'unknown';
    }
}
const SERVER_COMMIT = resolveCommitSha();
const SERVER_ENTRY = 'website/server.js';

// License key format: KGOO-XXXX-XXXX-XXXX (must match electron/license.js:116 regex)
function generateLicenseKey() {
    const crypto = require('crypto');
    const hex = crypto.randomBytes(6).toString('hex').toUpperCase();
    return `KGOO-${hex.slice(0, 4)}-${hex.slice(4, 8)}-${hex.slice(8, 12)}`;
}

// ========== 持久化存儲層（Vercel KV）==========
// ⚠️ P0 必修：Fail Closed - KV 必須可用，否則授權系統不可用
let kv = null;
let kvAvailable = false; // 標記 KV 是否可用（通過 preflight 檢查）
let kvHealthCheckFailed = false; // 標記 health check 是否失敗

// KV mock（僅用於本機/非 production 可重現驗收；production 禁止）
const isProd = process.env.NODE_ENV === 'production' || process.env.VERCEL_ENV === 'production';
// 付款測試模式（production 預設關閉，避免被繞過付款拿到授權）
const ALLOW_MOCK_PAYMENT = process.env.ALLOW_MOCK_PAYMENT === '1';
const kvMode = process.env.KV_MODE || '';
const mockKVStore = new Map(); // key -> { value, expiresAtMs|null }
function buildMockKV() {
    return {
        async get(key) {
            if (process.env.KV_MOCK_BREAK === '1') {
                throw new Error('KV_MOCK_BREAK=1: mock KV get() forced failure');
            }
            const entry = mockKVStore.get(key);
            if (!entry) return null;
            if (entry.expiresAtMs && entry.expiresAtMs <= Date.now()) {
                mockKVStore.delete(key);
                return null;
            }
            return entry.value;
        },
        async set(key, value, opts = {}) {
            if (process.env.KV_MOCK_BREAK === '1') {
                throw new Error('KV_MOCK_BREAK=1: mock KV set() forced failure');
            }
            const exSec = opts && typeof opts.ex === 'number' ? opts.ex : null;
            const expiresAtMs = exSec ? Date.now() + exSec * 1000 : null;
            mockKVStore.set(key, { value, expiresAtMs });
            return 'OK';
        }
    };
}

// Upstash REST API 直接實現
function buildUpstashRESTKV() {
    const url = process.env.KV_REST_API_URL;
    const token = process.env.KV_REST_API_TOKEN;
    
    if (!url || !token) {
        throw new Error('KV_REST_API_URL 和 KV_REST_API_TOKEN 必須設定');
    }
    
    return {
        async get(key) {
            try {
                // Upstash REST API: POST with command array
                console.log(`[KV] GET ${key} from ${url}`);
                const response = await fetch(url, {
                    method: 'POST',
                    headers: {
                        'Authorization': `Bearer ${token}`,
                        'Content-Type': 'application/json'
                    },
                    body: JSON.stringify(['GET', key])
                });
                
                const responseText = await response.text();
                console.log(`[KV] GET response status: ${response.status}, body: ${responseText.substring(0, 200)}`);
                
                if (!response.ok) {
                    throw new Error(`Upstash REST API error (${response.status}): ${responseText}`);
                }
                
                const data = JSON.parse(responseText);
                if (data.result === null || data.result === undefined) {
                    console.log(`[KV] GET ${key} returned null`);
                    return null;
                }
                
                // 嘗試解析 JSON，如果失敗則返回原始值
                try {
                    const parsed = JSON.parse(data.result);
                    console.log(`[KV] GET ${key} success, parsed JSON`);
                    return parsed;
                } catch {
                    console.log(`[KV] GET ${key} success, raw value`);
                    return data.result;
                }
            } catch (error) {
                console.error('❌ [KV] Upstash REST API get 失敗:', error.message);
                console.error('❌ [KV] Error stack:', error.stack);
                throw error;
            }
        },
        async set(key, value, opts = {}) {
            try {
                // Upstash REST API: SET key value [EX seconds]
                const args = [key];
                
                // 序列化值（如果已經是字符串則不再次序列化）
                const valueStr = typeof value === 'string' ? value : JSON.stringify(value);
                args.push(valueStr);
                
                // 添加過期時間
                if (opts && typeof opts.ex === 'number') {
                    args.push('EX', opts.ex.toString());
                }
                
                console.log(`[KV] SET ${key} to ${url}`);
                const response = await fetch(url, {
                    method: 'POST',
                    headers: {
                        'Authorization': `Bearer ${token}`,
                        'Content-Type': 'application/json'
                    },
                    body: JSON.stringify(['SET', ...args])
                });
                
                const responseText = await response.text();
                console.log(`[KV] SET response status: ${response.status}, body: ${responseText.substring(0, 200)}`);
                
                if (!response.ok) {
                    throw new Error(`Upstash REST API error (${response.status}): ${responseText}`);
                }
                
                const data = JSON.parse(responseText);
                console.log(`[KV] SET ${key} success`);
                return data.result || 'OK';
            } catch (error) {
                console.error('❌ [KV] Upstash REST API set 失敗:', error.message);
                console.error('❌ [KV] Error stack:', error.stack);
                throw error;
            }
        },
        async ping() {
            try {
                const response = await fetch(`${url}`, {
                    method: 'POST',
                    headers: {
                        'Authorization': `Bearer ${token}`,
                        'Content-Type': 'application/json'
                    },
                    body: JSON.stringify(['PING'])
                });
                return response.ok;
            } catch {
                return false;
            }
        },
        async keys(pattern) {
            try {
                const response = await fetch(`${url}`, {
                    method: 'POST',
                    headers: {
                        'Authorization': `Bearer ${token}`,
                        'Content-Type': 'application/json'
                    },
                    body: JSON.stringify(['KEYS', pattern || '*'])
                });
                if (!response.ok) {
                    throw new Error(`Upstash REST API error: ${response.status}`);
                }
                const data = await response.json();
                return data.result || [];
            } catch (error) {
                console.error('❌ [KV] Upstash REST API keys 失敗:', error.message);
                return [];
            }
        }
    };
}

// 嘗試初始化 Vercel KV / Upstash REST API
try {
    if (!isProd && kvMode === 'mock') {
        kv = buildMockKV();
        console.log('✅ [KV] KV_MODE=mock 已啟用（僅非 production）');
        kvAvailable = true;
    } else if (process.env.KV_REST_API_URL && process.env.KV_REST_API_TOKEN) {
        // 直接使用 Upstash REST API 實現（@vercel/kv 可能不支援 Upstash）
        kv = buildUpstashRESTKV();
        kvAvailable = true;
        console.log('✅ [KV] Upstash REST API 直接實現已啟用');
    } else {
        console.error('❌ [KV] KV 環境變數未設定 - KV_REST_API_URL 或 KV_REST_API_TOKEN 缺失');
        console.error('❌ [KV] 授權系統將不可用（Fail Closed）');
        kvAvailable = false;
    }
} catch (error) {
    console.error('❌ [KV] 初始化過程發生錯誤:', error.message);
    console.error('❌ [KV] 授權系統將不可用（Fail Closed）');
    kvAvailable = false;
}

function getKVProviderName() {
    if (kv && !isProd && kvMode === 'mock') return 'mock';
    if (kv && process.env.KV_REST_API_URL && process.env.KV_REST_API_TOKEN) return 'upstash_rest';
    return 'none';
}

function isKVConfigured() {
    if (kv && !isProd && kvMode === 'mock') return true;
    return Boolean(process.env.KV_REST_API_URL && process.env.KV_REST_API_TOKEN);
}
function logServerFingerprint() {
    console.log(
        `SERVER_ENTRY=${SERVER_ENTRY} COMMIT=${SERVER_COMMIT} KV_PROVIDER=${getKVProviderName()} KV_AVAILABLE=${kvAvailable ? 'true' : 'false'}`
    );
}
// 先印一次（preflight 前通常為 false；驗收會看 preflight 後的 KV_AVAILABLE）
logServerFingerprint();

// TTL Cache（僅作為 read-through cache，KV 是真相來源）
// cache entry: { data, expiresAt }
const devicesCache = new Map(); // deviceId -> { data, expiresAt }
const licensesCache = new Map(); // licenseKey -> { data, expiresAt }
const ordersCache = new Map(); // orderId -> { data, expiresAt }
const CACHE_TTL_MS = 30000; // 30 秒 TTL

// KV Preflight 檢查（啟動時執行）
async function kvPreflightCheck() {
    if (!kv) {
        console.error('❌ [KV Preflight] KV 未初始化，授權系統不可用');
        kvAvailable = false;
        kvHealthCheckFailed = true;
        return false;
    }
    if (!isKVConfigured()) {
        console.error('❌ [KV Preflight] KV 環境變數未設定，授權系統不可用');
        kvAvailable = false;
        kvHealthCheckFailed = true;
        return false;
    }

    try {
        const healthKey = 'kv:health:check';
        const healthValue = { timestamp: new Date().toISOString(), test: true };
        const healthTTL = 10; // 10 秒 TTL

        // 測試寫入
        await kv.set(healthKey, healthValue, { ex: healthTTL });
        console.log('✅ [KV Preflight] 寫入測試成功');

        // 測試讀取
        const readValue = await kv.get(healthKey);
        if (readValue && readValue.test === true) {
            console.log('✅ [KV Preflight] 讀取測試成功');
            kvHealthCheckFailed = false;
            return true;
        } else {
            console.error('❌ [KV Preflight] 讀取測試失敗：數據不匹配');
            kvHealthCheckFailed = true;
            return false;
        }
    } catch (error) {
        console.error('❌ [KV Preflight] Health check 失敗:', error.message);
        kvHealthCheckFailed = true;
        return false;
    } finally {
        // ⚠️ Serverless 冷啟動/瞬斷會讓 preflight false negative。
        // kvAvailable 不作為硬阻擋，只用來打印狀態；真正 Fail Closed 由每次 KV 操作失敗來回 503（KV_UNAVAILABLE）。
        kvAvailable = isKVConfigured();
    }
}

// 執行 preflight 檢查（異步，不阻塞啟動）
kvPreflightCheck().then(success => {
    if (success) {
        console.log('✅ [KV] Preflight 檢查通過，授權系統可用');
    } else {
        console.error('❌ [KV] Preflight 檢查失敗，授權系統不可用（Fail Closed）');
    }
    // preflight 後再印一次（含 KV_AVAILABLE）
    logServerFingerprint();
}).catch(error => {
    console.error('❌ [KV] Preflight 檢查異常:', error);
    kvAvailable = false;
    kvHealthCheckFailed = true;
    logServerFingerprint();
});

// 檢查 KV 是否可用（用於授權相關 API）
function requireKV() {
    // Fail Closed（但避免冷啟動誤判）：只在「完全沒初始化/沒配置」時直接拒絕。
    // 若已配置，則允許進入實際 KV 操作；操作失敗會被 catch 並回 503（KV_UNAVAILABLE）。
    if (!kv || !isKVConfigured()) {
        const reason = !kv ? 'KV 未初始化' : 'KV 環境變數未設定';
        throw new Error(`授權系統不可用：${reason}。請檢查 KV 配置。`);
    }

    // 注意：kvHealthCheckFailed 只代表「啟動時那次 preflight 失敗」。
    // 在 Serverless 環境中，cold start / 瞬時網路抖動可能造成 false negative。
    // 因此不以 kvHealthCheckFailed 作為硬阻擋；後續每次 KV 操作失敗仍會回 503（Fail Closed）。
    if (kvHealthCheckFailed) {
        console.warn('⚠️ [KV] kvHealthCheckFailed=true（可能為瞬時失敗），將以實際 KV 操作結果為準（Fail Closed）。');
    }
}

// ========== 持久化存儲操作函數 ==========

// 設備操作
// ⚠️ P0 必修：KV 是真相來源，cache 只能加速（TTL read-through cache）
async function getDeviceFromKV(deviceId) {
    requireKV(); // Fail Closed：KV 必須可用
    
    const cacheKey = deviceId;
    const cacheEntry = devicesCache.get(cacheKey);
    
    // 檢查 cache 是否有效（TTL）
    if (cacheEntry && cacheEntry.expiresAt > Date.now()) {
        console.log('📦 [Cache] 從 cache 讀取設備:', deviceId);
        return cacheEntry.data;
    }
    
    // Cache miss 或過期，從 KV 讀取
    try {
        const key = `device:${deviceId}`;
        const data = await kv.get(key);
        
        if (data) {
            // 更新 cache（帶 TTL）
            devicesCache.set(cacheKey, {
                data: data,
                expiresAt: Date.now() + CACHE_TTL_MS
            });
            console.log('✅ [KV] 從 KV 讀取設備並更新 cache:', deviceId);
            return data;
        }
        
        return null;
    } catch (error) {
        console.error('❌ [KV] 讀取設備失敗:', error);
        throw new Error(`KV 讀取失敗: ${error.message}`);
    }
}

async function setDevice(deviceId, deviceData) {
    requireKV(); // Fail Closed：KV 必須可用
    
    try {
        const key = `device:${deviceId}`;
        await kv.set(key, deviceData);
        console.log('✅ [KV] 設備已保存到持久化存儲:', deviceId);
        
        // KV 寫入成功後更新 cache
        devicesCache.set(deviceId, {
            data: deviceData,
            expiresAt: Date.now() + CACHE_TTL_MS
        });
    } catch (error) {
        console.error('❌ [KV] 保存設備失敗:', error);
        // 清除可能已更新的 cache（確保一致性）
        devicesCache.delete(deviceId);
        throw new Error(`KV 保存失敗: ${error.message}`);
    }
}

// 授權碼操作
// ⚠️ P0 必修：KV 是真相來源，cache 只能加速（TTL read-through cache）
async function getLicenseFromKV(licenseKey) {
    requireKV(); // Fail Closed：KV 必須可用
    
    const cacheKey = licenseKey;
    const cacheEntry = licensesCache.get(cacheKey);
    
    // 檢查 cache 是否有效（TTL）
    if (cacheEntry && cacheEntry.expiresAt > Date.now()) {
        console.log('📦 [Cache] 從 cache 讀取授權碼:', licenseKey.substring(0, 8) + '...');
        return cacheEntry.data;
    }
    
    // Cache miss 或過期，從 KV 讀取
    try {
        const key = `license:${licenseKey}`;
        const data = await kv.get(key);
        
        if (data) {
            // 更新 cache（帶 TTL）
            licensesCache.set(cacheKey, {
                data: data,
                expiresAt: Date.now() + CACHE_TTL_MS
            });
            console.log('✅ [KV] 從 KV 讀取授權碼並更新 cache:', licenseKey.substring(0, 8) + '...');
            return data;
        }
        
        return null;
    } catch (error) {
        console.error('❌ [KV] 讀取授權碼失敗:', error);
        throw new Error(`KV 讀取失敗: ${error.message}`);
    }
}

async function setLicense(licenseKey, licenseData) {
    requireKV(); // Fail Closed：KV 必須可用
    
    try {
        const key = `license:${licenseKey}`;
        await kv.set(key, licenseData);
        console.log('✅ [KV] 授權碼已保存到持久化存儲:', licenseKey.substring(0, 8) + '...');
        
        // 更新 license index（用於 Admin Console 列表）
        await appendToLicenseIndex(licenseKey, licenseData.createdAt || new Date().toISOString());
        
        // KV 寫入成功後更新 cache
        licensesCache.set(licenseKey, {
            data: licenseData,
            expiresAt: Date.now() + CACHE_TTL_MS
        });
    } catch (error) {
        console.error('❌ [KV] 保存授權碼失敗:', error);
        // 清除可能已更新的 cache（確保一致性）
        licensesCache.delete(licenseKey);
        throw new Error(`KV 保存失敗: ${error.message}`);
    }
}

// License Index 操作（用於 Admin Console 列出所有授權）
async function appendToLicenseIndex(licenseKey, createdAt) {
    requireKV();
    try {
        const indexKey = 'license:index';
        const index = await kv.get(indexKey) || [];
        // 避免重複添加
        if (!index.find(item => item.licenseKey === licenseKey)) {
            index.push({ licenseKey, createdAt });
            // 按 createdAt 降序排序（最新最上）
            index.sort((a, b) => new Date(b.createdAt) - new Date(a.createdAt));
            await kv.set(indexKey, index);
        }
    } catch (error) {
        console.error('❌ [KV] 更新 license index 失敗:', error);
        // 不拋出錯誤，避免影響主要操作
    }
}

async function getLicenseIndex() {
    requireKV();
    try {
        const indexKey = 'license:index';
        return await kv.get(indexKey) || [];
    } catch (error) {
        console.error('❌ [KV] 讀取 license index 失敗:', error);
        throw new Error(`KV 讀取失敗: ${error.message}`);
    }
}

// 訂單操作
// ⚠️ Fail Closed：訂單狀態也不允許 fallback（避免付款狀態錯亂）
async function getOrderFromKV(orderId) {
    requireKV();

    const cacheEntry = ordersCache.get(orderId);
    if (cacheEntry && cacheEntry.expiresAt > Date.now()) {
        console.log('📦 [Cache] 從 cache 讀取訂單:', orderId);
        return cacheEntry.data;
    }

    try {
        const key = `order:${orderId}`;
        const data = await kv.get(key);
        if (data) {
            ordersCache.set(orderId, { data, expiresAt: Date.now() + CACHE_TTL_MS });
            console.log('✅ [KV] 從 KV 讀取訂單並更新 cache:', orderId);
            return data;
        }
        return null;
    } catch (error) {
        console.error('❌ [KV] 讀取訂單失敗:', error);
        throw new Error(`KV 讀取失敗: ${error.message}`);
    }
}

async function setOrder(orderId, orderData) {
    requireKV();
    try {
        const key = `order:${orderId}`;
        await kv.set(key, orderData);
        console.log('✅ [KV] 訂單已保存到持久化存儲:', orderId);
        ordersCache.set(orderId, { data: orderData, expiresAt: Date.now() + CACHE_TTL_MS });
    } catch (error) {
        console.error('❌ [KV] 保存訂單失敗:', error);
        ordersCache.delete(orderId);
        throw new Error(`KV 保存失敗: ${error.message}`);
    }
}

// ========== 持久化存儲層結束 ==========

// 付款成功 → 發 key → 寄授權信：三個金流回調共用同一條路徑，避免各自漂移
const { createOrderFlow } = require('./lib/order-flow');
const orderFlow = createOrderFlow({
    getKV: () => kv,
    generateLicenseKey,
    setOrder,
    setLicense
});

// 管理員密鑰（從環境變數讀取）
const ADMIN_KEY = process.env.ADMIN_KEY || 'default-admin-key-change-in-production';

// 確保路徑正確（Vercel 和本地環境）
const publicDir = path.join(__dirname, 'public');
const paymentProcessDir = path.join(__dirname, 'public', 'payment');

// 可選：統一入口域名（避免使用者看到舊域名並存）
// - 僅在設定 PRIMARY_HOST 時啟用
// - 僅在 production 啟用（避免影響本機開發）
// - 注意：如果 PRIMARY_HOST 需要 DNS 設定，請確保 DNS 已正確配置，否則會導致網站無法訪問
const PRIMARY_HOST = process.env.PRIMARY_HOST; // e.g. "konggoo.vercel.app" 或 "konggoo.tw"
app.use((req, res, next) => {
    try {
        // 暫時禁用 PRIMARY_HOST 重定向，避免 DNS 未設定時網站無法訪問
        // 如果需要啟用，請確保 DNS 已正確配置
        if (false && process.env.NODE_ENV === 'production' && PRIMARY_HOST) {
            // Vercel/反向代理環境請優先用 x-forwarded-*，避免 host 判斷不準
            const xfHostRaw = (req.headers['x-forwarded-host'] || '').toString();
            const hostRaw = xfHostRaw ? xfHostRaw.split(',')[0].trim() : (req.headers.host || '').toString();
            const host = hostRaw.toLowerCase();
            const xfProtoRaw = (req.headers['x-forwarded-proto'] || '').toString();
            const proto = xfProtoRaw ? xfProtoRaw.split(',')[0].trim() : 'https';
            if (host && host !== PRIMARY_HOST.toLowerCase()) {
                return res.redirect(301, `${proto}://${PRIMARY_HOST}${req.originalUrl}`);
            }
        }
    } catch (e) {}
    next();
});

// 主頁面
app.get('/', (req, res) => {
    try {
        const indexPath = path.resolve(publicDir, 'index.html');
        console.log('📄 發送主頁面:', indexPath, '存在:', fs.existsSync(indexPath));
        res.sendFile(indexPath);
    } catch (error) {
        console.error('❌ 主頁面錯誤:', error);
        res.status(500).json({ error: 'Internal Server Error', message: error.message });
    }
});

// 授權/下載自助頁
app.get('/license', (req, res) => {
    try {
        const p = path.resolve(publicDir, 'license.html');
        if (!fs.existsSync(p)) return res.status(404).send('Not Found');
        return res.sendFile(p);
    } catch (e) {
        return res.status(500).send('Internal Server Error');
    }
});

// 付款頁面
app.get('/payment', (req, res) => {
    try {
        // 嘗試多種路徑（Vercel 和本地環境可能不同）
        const possiblePaths = [
            path.resolve(publicDir, 'payment.html'),
            path.join(__dirname, 'public', 'payment.html'),
            path.resolve(__dirname, '..', 'public', 'payment.html')
        ];
        
        let paymentPath = null;
        for (const p of possiblePaths) {
            if (fs.existsSync(p)) {
                paymentPath = p;
                break;
            }
        }
        
        if (!paymentPath) {
            console.error('❌ 付款頁面不存在，嘗試的路徑:', possiblePaths);
            return res.status(404).send(`
                <html>
                <head><title>付款頁面未找到</title></head>
                <body>
                    <h1>付款頁面未找到</h1>
                    <p>嘗試的路徑：</p>
                    <ul>
                        ${possiblePaths.map(p => `<li>${p}</li>`).join('')}
                    </ul>
                    <p>__dirname: ${__dirname}</p>
                    <p>publicDir: ${publicDir}</p>
                </body>
                </html>
            `);
        }
        
        console.log('💰 發送付款頁面:', paymentPath);
        res.sendFile(paymentPath);
    } catch (error) {
        console.error('❌ 付款頁面錯誤:', error);
        res.status(500).send(`
            <html>
            <head><title>服務器錯誤</title></head>
            <body>
                <h1>服務器錯誤</h1>
                <p>${error.message}</p>
                <pre>${error.stack}</pre>
            </body>
            </html>
        `);
    }
});

// 付款成功頁面（GET — 正常跳轉 / 手動訪問）
app.get('/payment/success', (req, res) => {
    try {
        const successPath = path.resolve(paymentProcessDir, 'success.html');
        console.log('✅ 發送付款成功頁面:', successPath, '存在:', fs.existsSync(successPath));
        if (!fs.existsSync(successPath)) {
            return res.status(404).json({ error: 'Success page not found', path: successPath });
        }
        res.sendFile(successPath);
    } catch (error) {
        console.error('❌ 付款成功頁面錯誤:', error);
        res.status(500).json({ error: 'Internal Server Error', message: error.message });
    }
});

// 付款成功頁面（POST — ECPay OrderResultURL 回傳）
app.post('/payment/success', async (req, res) => {
    const body = req.body || {};
    const orderId = body.CustomField1;
    try {
        console.log('📥 ECPay OrderResultURL 收到, orderId:', orderId, 'RtnCode:', body.RtnCode);

        // 若 ECPay notify 已先處理完，order 已是 paid
        // 若 notify 較慢，這裡也嘗試處理
        if (String(body.RtnCode) === '1' && orderId) {
            const order = await getOrderFromKV(orderId);
            if (order) {
                // ⚠️ 2026-08-20：這裡原本只看 RtnCode 就發授權碼，連 CheckMacValue 都沒驗，
                // 任何人 POST {CustomField1, RtnCode:1} 就能免費領授權。現在與 notify 共用
                // 同一套驗證（驗簽章 + 回頭跟綠界對帳）。
                const verdict = await verifyEcpayPayment(body, orderId, order);
                if (verdict.ok) {
                    // 與 notify 走同一條冪等路徑：誰先到誰發 key，另一個不會重發
                    await orderFlow.finalizePaidOrder(orderId, order, {
                        tradeNo: body.TradeNo || '',
                        gateway: 'ecpay'
                    });
                } else {
                    // 不發 key，但仍把使用者導到成功頁；該頁會輪詢訂單狀態顯示「產生中」
                    console.warn('🚨 [ECPay OrderResultURL] 拒發授權:', orderId, verdict.reason, verdict.detail);
                }
            }
        }

        // 讀取 order 拿 licenseKey，重定向到 GET 成功頁面
        if (orderId) {
            const order = await getOrderFromKV(orderId);
            if (order && order.licenseKey) {
                return res.redirect(`/payment/success?licenseKey=${order.licenseKey}&planType=${order.planType}`);
            }
            return res.redirect('/payment/success?orderId=' + encodeURIComponent(orderId));
        }
        // Fallback: 沒有 orderId 才走無參數成功頁
        const successPath = path.resolve(paymentProcessDir, 'success.html');
        if (fs.existsSync(successPath)) return res.sendFile(successPath);
        res.redirect('/payment/success');
    } catch (error) {
        console.error('❌ ECPay OrderResultURL 錯誤:', error);
        if (orderId) {
            return res.redirect('/payment/success?orderId=' + encodeURIComponent(orderId));
        }
        res.redirect('/payment/success');
    }
});

// 語言 API
app.get('/api/locale/:lang', (req, res) => {
    const lang = req.params.lang;
    res.sendFile(path.join(__dirname, 'locales', `${lang}.json`));
});

// 授權 API 端點

// 1. 註冊設備（已廢棄，使用 /api/auth/check 自動註冊）
app.post('/api/device/register', async (req, res) => {
    const { deviceId, deviceInfo } = req.body;
    
    if (!deviceId) {
        return res.status(400).json({ error: 'deviceId 是必需的' });
    }
    
    try {
        requireKV();
        const device = await getDeviceFromKV(deviceId);
    
        if (device) {
            const license = device.licenseKey ? await getLicenseFromKV(device.licenseKey) : null;
            const isActivated = !!(device.licenseKey && license && license.isValid && license.deviceId === deviceId);
            
            return res.json({
                trialExpiresAt: device.trialExpiresAt || null,
                licenseKey: device.licenseKey || null,
                isActivated: isActivated
            });
        }
    
        const trialExpiresAt = new Date(Date.now() + 7 * 24 * 60 * 60 * 1000).toISOString(); // 7 天後到期
        const newDevice = {
            trialExpiresAt: trialExpiresAt,
            licenseKey: null,
            activatedAt: null,
            registeredAt: new Date().toISOString(),
            updatedAt: new Date().toISOString()
        };
    
        await setDevice(deviceId, newDevice);
    
        res.json({
            trialExpiresAt: trialExpiresAt,
            licenseKey: null,
            isActivated: false
        });
    } catch (error) {
        console.error('❌ [註冊設備] 錯誤:', error);
        if (error.message.includes('授權系統不可用') || error.message.includes('KV')) {
            return res.status(503).json({
                error: '授權系統暫時不可用',
                message: error.message,
                code: 'KV_UNAVAILABLE'
            });
        }
        return res.status(500).json({ error: '服務器錯誤', message: error.message });
    }
});

// 2. 檢查授權狀態（根據設備 UUID 自動識別是否已購買）
// ⚠️ 這是 Single Source of Truth，所有授權判斷必須依賴此 API 的 isActivated
// ✅ 重構：強制從 KV 讀取，確保 redeploy/cold start 後授權仍存在
app.post('/api/auth/check', async (req, res) => {
    const { deviceId } = req.body;
    
    if (!deviceId) {
        return res.status(400).json({ error: 'deviceId 是必需的', code: 'BAD_REQUEST' });
    }
    
    const serverTime = new Date().toISOString();
    console.log('🔍 [授權檢查] 設備 ID:', deviceId, '時間:', serverTime);
    
    try {
        // ⚠️ P0 必修：Fail Closed - 檢查 KV 是否可用
        requireKV();
        
        // ✅ 關鍵 API：強制從 KV 讀取，確保一致性
        let device = await getDeviceFromKV(deviceId);
        
        // ✅ 如果設備不存在，創建新設備（免費試用一週）並保存到持久化存儲
        if (!device) {
            console.log('📝 [授權檢查] 新設備，創建記錄（免費試用一週）並保存到持久化存儲');
            const trialExpiresAt = new Date(Date.now() + 7 * 24 * 60 * 60 * 1000).toISOString(); // 7 天後到期
            device = {
                trialExpiresAt: trialExpiresAt,
                licenseKey: null,
                activatedAt: null,
                registeredAt: serverTime,
                updatedAt: serverTime
            };
            await setDevice(deviceId, device);
            console.log('✅ [授權檢查] 新設備已保存到持久化存儲，試用到期時間:', trialExpiresAt);
        }
        
        // ✅ 檢查是否已激活（從持久化存儲驗證授權碼）
        let isActivated = false;
        if (device.licenseKey) {
            // ✅ 強制從 KV 讀取授權碼，確保一致性
            const license = await getLicenseFromKV(device.licenseKey);
            if (license && license.isValid && license.deviceId === deviceId) {
                isActivated = true;
                console.log('✅ [授權檢查] 設備已激活，授權碼有效');
            } else {
                // 授權碼無效或被其他設備使用，清除設備上的 licenseKey
                console.warn('⚠️ [授權檢查] 授權碼無效或已被其他設備使用，清除設備授權碼');
                device.licenseKey = null;
                device.activatedAt = null;
                device.updatedAt = serverTime;
                await setDevice(deviceId, device);
            }
        }
        
        // ✅ 檢查試用是否過期（服務器端驗證，防止破解）
        const now = new Date();
        const trialExpiresAt = device.trialExpiresAt ? new Date(device.trialExpiresAt) : null;
        const isTrialExpired = trialExpiresAt ? now > trialExpiresAt : true; // 沒有到期時間視為已過期
        
        // 如果試用已過期且未激活，需要購買
        if (!isActivated && isTrialExpired) {
            console.log('⚠️ [授權檢查] 試用已過期，需要購買授權');
        }
        
        console.log('📊 [授權檢查] 設備狀態:', {
            deviceId: deviceId,
            trialExpiresAt: trialExpiresAt ? trialExpiresAt.toISOString() : '無',
            isTrialExpired: isTrialExpired,
            licenseKey: device.licenseKey ? `${device.licenseKey.substring(0, 8)}...` : '無',
            isActivated: isActivated,
            activatedAt: device.activatedAt || '無',
            storage: 'KV'
        });
        
        res.json({
            trialExpiresAt: device.trialExpiresAt || null,
            licenseKey: device.licenseKey || null,
            isActivated: isActivated,  // ⚠️ 這是唯一真實來源
            serverTime: serverTime
        });
    } catch (error) {
        console.error('❌ [授權檢查] 錯誤:', error);
        // ⚠️ P0 必修：KV 不可用時返回 503 Service Unavailable
        if (error.message.includes('授權系統不可用') || error.message.includes('KV')) {
            return res.status(503).json({ 
                error: '授權系統暫時不可用', 
                message: error.message,
                code: 'KV_UNAVAILABLE'
            });
        }
        res.status(500).json({ 
            error: '服務器錯誤', 
            message: error.message
        });
    }
});

// 3. 消耗試用次數（新 API：/api/trial/consume）
// ✅ 重構：強制從 KV 讀取，確保授權後不扣 trial，且 redeploy/cold start 後狀態正確
app.post('/api/trial/consume', async (req, res) => {
    const { deviceId, feature } = req.body;
    
    if (!deviceId) {
        return res.status(400).json({ error: 'deviceId 是必需的', code: 'BAD_REQUEST' });
    }
    
    const serverTime = new Date().toISOString();
    console.log('🎯 [試用消耗] 設備 ID:', deviceId, '功能:', feature || 'unknown', '時間:', serverTime);
    
    try {
        // ⚠️ P0 必修：Fail Closed - 檢查 KV 是否可用
        requireKV();
        
        // ✅ 關鍵 API：強制從 KV 讀取，確保一致性
        let device = await getDeviceFromKV(deviceId);
        
        // ✅ 如果設備不存在，創建新設備（默認 3 次試用）並保存到持久化存儲
        if (!device) {
            console.log('📝 [試用消耗] 新設備，創建記錄（免費試用一週）並保存到持久化存儲');
            const trialExpiresAt = new Date(Date.now() + 7 * 24 * 60 * 60 * 1000).toISOString(); // 7 天後到期
            device = {
                trialExpiresAt: trialExpiresAt,
                licenseKey: null,
                activatedAt: null,
                registeredAt: serverTime,
                updatedAt: serverTime
            };
            await setDevice(deviceId, device);
            console.log('✅ [試用消耗] 新設備已保存到持久化存儲，試用到期時間:', trialExpiresAt);
        }
        
        // ✅ 檢查是否已激活（從持久化存儲驗證，強制從 KV 讀取）
        let isActivated = false;
        if (device.licenseKey) {
            // ✅ 強制從 KV 讀取授權碼，確保一致性
            const license = await getLicenseFromKV(device.licenseKey);
            isActivated = license && license.isValid && license.deviceId === deviceId;
        }
        
        // ✅ 如果已激活，不需要檢查試用（關鍵邏輯）
        if (isActivated) {
            console.log('✅ [試用消耗] 設備已激活，無需檢查試用');
            return res.json({
                success: true,
                trialExpiresAt: device.trialExpiresAt || null,
                isActivated: true,
                message: '已激活，無需檢查試用'
            });
        }
        
        // ✅ 檢查試用是否過期（服務器端驗證，防止破解）
        const now = new Date();
        const trialExpiresAt = device.trialExpiresAt ? new Date(device.trialExpiresAt) : null;
        const isTrialExpired = trialExpiresAt ? now > trialExpiresAt : true; // 沒有到期時間視為已過期
        
        if (isTrialExpired) {
            console.log('⚠️ [試用消耗] 試用已過期，需要購買授權');
            return res.status(403).json({
                error: '免費試用已過期，請購買授權',
                code: 'TRIAL_EXPIRED',
                trialExpiresAt: device.trialExpiresAt || null,
                isActivated: false
            });
        }
        
        // ✅ 試用仍在有效期內，允許使用（不需要消耗次數，因為是時間制）
        console.log('✅ [試用消耗] 試用仍在有效期內，允許使用，到期時間:', trialExpiresAt ? trialExpiresAt.toISOString() : '無');
        
        res.json({
            success: true,
            trialExpiresAt: device.trialExpiresAt || null,
            isActivated: false
        });
    } catch (error) {
        console.error('❌ [試用消耗] 錯誤:', error);
        // ⚠️ P0 必修：KV 不可用時返回 503 Service Unavailable
        if (error.message.includes('授權系統不可用') || error.message.includes('KV')) {
            return res.status(503).json({ 
                error: '授權系統暫時不可用', 
                message: error.message,
                code: 'KV_UNAVAILABLE'
            });
        }
        res.status(500).json({ 
            error: '服務器錯誤', 
            message: error.message
        });
    }
});

// 3.1. 舊 API：使用試用次數（向後兼容，內部調用 consume）
app.post('/api/trial/use', async (req, res) => {
    const { deviceId } = req.body;
    req.body.feature = 'legacy';
    return app._router.handle({ ...req, url: '/api/trial/consume', method: 'POST' }, res);
});

// 4. 激活授權碼（每個激活碼只能使用一次，激活後設備永久可用）
// ✅ 重構：強制從 KV 讀取和寫入，確保 redeploy/cold start 後授權仍存在
app.post('/api/license/activate', async (req, res) => {
    const { deviceId, licenseKey } = req.body;
    
    if (!deviceId || !licenseKey) {
        return res.status(400).json({ error: 'deviceId 和 licenseKey 都是必需的', code: 'BAD_REQUEST' });
    }
    
    const serverTime = new Date().toISOString();
    console.log('🔑 [激活] 收到激活請求:', { deviceId, licenseKey: `${licenseKey.substring(0, 8)}...`, time: serverTime });
    
    try {
        // ⚠️ P0 必修：Fail Closed - 檢查 KV 是否可用
        requireKV();
        
        // ✅ 關鍵 API：強制從 KV 讀取授權碼，確保一致性
        const license = await getLicenseFromKV(licenseKey);
        
        if (!license) {
            console.log('❌ [激活] 授權碼不存在:', licenseKey);
            return res.status(404).json({ error: '授權碼不存在', code: 'LICENSE_NOT_FOUND' });
        }
        
        if (!license.isValid) {
            console.log('❌ [激活] 授權碼已失效:', licenseKey);
            return res.status(403).json({ error: '授權碼已失效', code: 'LICENSE_INVALID' });
        }

        // 年繳到期檢查（無 expiresAt 的舊授權 = 永久，不受影響）
        if (isLicenseExpired(license)) {
            console.log('❌ [激活] 授權已到期:', licenseKey, license.expiresAt);
            return res.status(403).json({
                error: '授權已到期，請重新購買',
                code: 'LICENSE_EXPIRED',
                expiresAt: license.expiresAt
            });
        }

        // 檢查授權碼是否已被其他設備使用（每個激活碼只能使用一次）
        if (license.deviceId && license.deviceId !== deviceId) {
            console.log('❌ [激活] 授權碼已被其他設備使用:', { 
                licenseKey: `${licenseKey.substring(0, 8)}...`, 
                currentDevice: deviceId, 
                boundDevice: license.deviceId 
            });
            return res.status(403).json({ error: '授權碼已被其他設備使用，每個激活碼只能使用一次', code: 'LICENSE_USED' });
        }
        
        // 如果已經激活過（同一個設備），直接返回成功（不需要重複激活）
        if (license.deviceId === deviceId && license.activatedAt) {
            console.log('✅ [激活] 設備已激活過此授權碼，直接返回成功');
            // ✅ 強制從 KV 讀取設備數據
            const device = await getDeviceFromKV(deviceId);
            return res.json({
                success: true,
                message: '授權碼已激活（此設備已使用過此授權碼）',
                licenseKey: licenseKey,
                isActivated: true,
                trialExpiresAt: device?.trialExpiresAt || null,
                activatedAt: device?.activatedAt || license.activatedAt,
                // 重複啟用不展延效期，沿用原本算好的到期日
                expiresAt: license.expiresAt || null,
                planType: license.planType || 'annual'
            });
        }
        
        // ✅ 強制從 KV 讀取設備數據
        let device = await getDeviceFromKV(deviceId);
        
        // ✅ 確保設備記錄存在（如果不存在，創建新記錄）
        if (!device) {
            console.log('📝 [激活] 創建新設備記錄:', deviceId);
            device = {
                trialExpiresAt: null,  // 激活後試用不再重要
                licenseKey: null,
                activatedAt: null,
                registeredAt: serverTime,
                updatedAt: serverTime
            };
        }
        
        const beforeTrialExpiresAt = device.trialExpiresAt;
        const beforeActivated = !!device.licenseKey;
        
        // ✅ 綁定授權碼到設備（永久激活），保存到持久化存儲
        device.licenseKey = licenseKey;
        device.activatedAt = serverTime;
        device.updatedAt = serverTime;
        await setDevice(deviceId, device);
        console.log('✅ [激活] 設備記錄已保存到持久化存儲');
        
        // ✅ 綁定設備到授權碼（確保每個激活碼只能使用一次），保存到持久化存儲
        license.deviceId = deviceId;
        license.boundDeviceId = deviceId; // 統一使用 boundDeviceId
        license.activatedAt = serverTime;
        // 年繳效期從「啟用當下」起算；沒有 durationDays 的舊授權維持永久（grandfather）
        license.expiresAt = computeExpiresAt(license, serverTime);
        await setLicense(licenseKey, license);
        console.log('✅ [激活] 授權碼記錄已保存到持久化存儲');
        
        console.log('✅ [激活] 授權碼激活成功:', {
            deviceId: deviceId,
            licenseKey: `${licenseKey.substring(0, 8)}...`,
            activatedAt: device.activatedAt,
            beforeTrialExpiresAt: beforeTrialExpiresAt,
            afterTrialExpiresAt: device.trialExpiresAt,
            beforeActivated: beforeActivated,
            afterActivated: true,
            storage: 'KV'
        });
        
        res.json({
            success: true,
            message: license.expiresAt ? '授權碼激活成功' : '授權碼激活成功，設備已永久激活',
            licenseKey: licenseKey,
            isActivated: true,
            trialExpiresAt: device.trialExpiresAt || null,
            activatedAt: device.activatedAt,
            expiresAt: license.expiresAt || null,
            planType: license.planType || 'annual'
        });
    } catch (error) {
        console.error('❌ [激活] 錯誤:', error);
        // ⚠️ P0 必修：KV 不可用時返回 503 Service Unavailable
        if (error.message.includes('授權系統不可用') || error.message.includes('KV')) {
            return res.status(503).json({ 
                error: '授權系統暫時不可用', 
                message: error.message,
                code: 'KV_UNAVAILABLE'
            });
        }
        res.status(500).json({ 
            error: '服務器錯誤', 
            message: error.message
        });
    }
});

// 4.1 檢查授權碼是否有效（提供網站下載/客服自助用）
app.post('/api/license/verify', async (req, res) => {
    const { licenseKey } = req.body || {};
    if (!licenseKey) {
        return res.status(400).json({ valid: false, error: 'licenseKey 是必需的', code: 'BAD_REQUEST' });
    }

    try {
        requireKV(); // Fail Closed
        const license = await getLicenseFromKV(String(licenseKey).trim());
        if (!license || !license.isValid) {
            return res.json({ valid: false });
        }
        if (isLicenseExpired(license)) {
            return res.json({
                valid: false,
                code: 'LICENSE_EXPIRED',
                planType: license.planType || 'annual',
                expiresAt: license.expiresAt
            });
        }
        return res.json({
            valid: true,
            planType: license.planType || 'annual',
            expiresAt: license.expiresAt || null,
            download: {
                mac: 'https://github.com/awe7893625/pikmin-architect/releases/download/v1.1.0/KongGoo-1.1.0-arm64.dmg',
                macIntel: 'https://github.com/awe7893625/pikmin-architect/releases/download/v1.1.0/KongGoo-1.1.0-x64.dmg',
                windows: 'https://github.com/awe7893625/pikmin-architect/releases/download/v1.1.0/KongGoo-1.1.0-win-x64.exe'
            }
        });
    } catch (error) {
        if (error.message.includes('授權系統不可用') || error.message.includes('KV')) {
            return res.status(503).json({
                error: '授權系統暫時不可用',
                message: error.message,
                code: 'KV_UNAVAILABLE'
            });
        }
        return res.status(500).json({ error: '服務器錯誤', message: error.message, code: 'VERIFY_FAILED' });
    }
});

// 4.1.1 App 定期覆核（唯讀）：授權仍有效？裝置仍是綁定那台？還沒到期？
app.post('/api/license/status', async (req, res) => {
    const { licenseKey, deviceId } = req.body || {};
    if (!licenseKey || !deviceId) {
        return res.status(400).json({ valid: false, code: 'BAD_REQUEST', error: 'licenseKey 與 deviceId 皆為必填' });
    }
    try {
        requireKV();
        const license = await getLicenseFromKV(String(licenseKey).trim());
        if (!license || !license.isValid) {
            return res.json({ valid: false, code: 'LICENSE_INVALID' });
        }
        const bound = license.boundDeviceId || license.deviceId || null;
        if (bound && bound !== deviceId) {
            return res.json({ valid: false, code: 'LICENSE_USED' });
        }
        if (isLicenseExpired(license)) {
            return res.json({ valid: false, code: 'LICENSE_EXPIRED', planType: license.planType || 'annual', expiresAt: license.expiresAt });
        }
        return res.json({ valid: true, planType: license.planType || 'annual', expiresAt: license.expiresAt || null, activatedAt: license.activatedAt || null });
    } catch (error) {
        console.error('❌ [Status] 覆核失敗:', error);
        if (String(error.message || '').includes('KV') || String(error.message || '').includes('授權系統不可用')) {
            return res.status(503).json({ valid: false, code: 'KV_UNAVAILABLE', error: '授權系統暫時不可用' });
        }
        return res.status(500).json({ valid: false, code: 'STATUS_FAILED', error: '服務器錯誤' });
    }
});

// 4.1.2 授權碼補寄：客人關掉付款成功頁也拿得回授權碼
app.post('/api/license/resend', async (req, res) => {
    const { email } = req.body || {};
    if (!isValidEmail(email)) {
        return res.status(400).json({ success: false, code: 'INVALID_EMAIL', error: '請填寫有效的 Email' });
    }
    const normalized = normalizeEmail(email);
    // 一律回一般性成功訊息，避免被拿來探測哪些 Email 買過
    const genericOk = { success: true, message: '如果這個 Email 有購買紀錄，授權碼已重新寄出' };
    try {
        requireKV();
        const allowed = await orderFlow.consumeResendQuota(normalized);
        if (!allowed) {
            return res.status(429).json({ success: false, code: 'RESEND_RATE_LIMIT', error: '補寄次數過於頻繁，請稍後再試' });
        }
        const keys = await orderFlow.getLicensesByEmail(normalized);
        if (!keys.length) {
            return res.json(genericOk);
        }
        let sentCount = 0;
        for (const key of keys) {
            const license = await getLicenseFromKV(key);
            if (!license || !license.isValid) continue;
            const result = await sendLicenseEmail({
                to: normalized,
                licenseKey: key,
                planType: license.planType,
                expiresAt: license.expiresAt || null,
                isResend: true
            });
            if (result.sent) sentCount += 1;
            else console.error('❌ [補寄] 寄送失敗:', maskEmail(normalized), result.error);
        }
        console.log('📧 [補寄]', maskEmail(normalized), sentCount + '/' + keys.length);
        return res.json(genericOk);
    } catch (error) {
        console.error('❌ [補寄] 失敗:', error);
        if (String(error.message || '').includes('KV') || String(error.message || '').includes('授權系統不可用')) {
            return res.status(503).json({ success: false, code: 'KV_UNAVAILABLE', error: '授權系統暫時不可用' });
        }
        return res.status(500).json({ success: false, code: 'RESEND_FAILED', error: '服務器錯誤' });
    }
});

// 4.2 自助換機解綁
// POST /api/license/rebind
// body: { licenseKey, email? }
//
// 設計說明：
//   - 知道完整 licenseKey 本身即為身份證明（對應 Netflix / JetBrains 等 SaaS 慣例）
//   - email 為可選欄位：若 license record 已存有 purchaseEmail，則強制比對；
//     若 record 無此欄位（歷史授權），則跳過 email 比對，僅以 licenseKey 身份驗證
//   - 防濫用：每個 licenseKey 每 30 天最多 3 次解綁（rebindCount + rebindWindowStart 存進 KV）
//   - 解綁後 deviceId / boundDeviceId 清空，讓新裝置可重新 activate
//   - activate 失敗碼維持 LICENSE_USED（前端據此引導解綁流程，不在此變動）
app.post('/api/license/rebind', async (req, res) => {
    const rawInput = req.body || {};
    // ATTACK-1/2 fix: normalize early so substring() is safe and all comparisons/writes use the same value
    const licenseKey = rawInput.licenseKey != null ? String(rawInput.licenseKey).trim() : '';
    const email = rawInput.email != null ? String(rawInput.email).trim().toLowerCase() : '';

    if (!licenseKey) {
        return res.status(400).json({ error: 'licenseKey 是必需的', code: 'BAD_REQUEST' });
    }

    const serverTime = new Date().toISOString();
    console.log('[Rebind] 收到解綁請求:', licenseKey.substring(0, 8) + '...', '時間:', serverTime);

    try {
        requireKV();

        // --- 1. 讀取 license（使用已 trim 的 licenseKey）---
        const license = await getLicenseFromKV(licenseKey);
        if (!license) {
            return res.status(404).json({ error: '授權碼不存在', code: 'LICENSE_NOT_FOUND' });
        }
        if (!license.isValid) {
            return res.status(403).json({ error: '授權碼已失效', code: 'LICENSE_INVALID' });
        }

        // --- 2. 頻率限制計數初始化（ATTACK-12 fix：防 NaN / corrupt KV data）---
        const REBIND_WINDOW_DAYS = 30;
        const REBIND_MAX_COUNT = 3;
        const windowMs = REBIND_WINDOW_DAYS * 24 * 60 * 60 * 1000;
        const now = Date.now();

        let rebindCount = Number.isFinite(Number(license.rebindCount)) ? Math.max(0, Math.floor(Number(license.rebindCount))) : 0;
        const parsedWindowMs = license.rebindWindowStart ? new Date(license.rebindWindowStart).getTime() : NaN;
        let rebindWindowStart = Number.isFinite(parsedWindowMs) ? parsedWindowMs : now;

        // 若超過 window，重置計數器
        if (now - rebindWindowStart > windowMs) {
            rebindCount = 0;
            rebindWindowStart = now;
        }

        if (rebindCount >= REBIND_MAX_COUNT) {
            const resetAt = new Date(rebindWindowStart + windowMs).toISOString();
            console.warn('[Rebind] 頻率限制觸發:', licenseKey.substring(0, 8) + '...', '本週期已嘗試', rebindCount, '次');
            return res.status(429).json({
                error: `此授權碼在 ${REBIND_WINDOW_DAYS} 天內已達解綁上限（${REBIND_MAX_COUNT} 次）。請聯繫客服。`,
                code: 'REBIND_RATE_LIMIT',
                resetAt: resetAt
            });
        }

        // --- 3. Email 驗證（僅當 license record 已有 purchaseEmail 時才強制比對）---
        // ATTACK-5 fix: failed email attempts also consume rebindCount to prevent brute force
        if (license.purchaseEmail) {
            const normalizedRecord = String(license.purchaseEmail).trim().toLowerCase();
            if (!email) {
                // Count this attempt against quota to deter probing
                const attemptLicense = { ...license, rebindCount: rebindCount + 1, rebindWindowStart: new Date(rebindWindowStart).toISOString(), updatedAt: serverTime };
                await setLicense(licenseKey, attemptLicense);
                licensesCache.delete(licenseKey);
                return res.status(400).json({ error: '此授權碼需要提供購買 email 才能解綁', code: 'EMAIL_REQUIRED' });
            }
            if (email !== normalizedRecord) {
                // Count mismatch against quota (ATTACK-5 brute force prevention)
                const attemptLicense = { ...license, rebindCount: rebindCount + 1, rebindWindowStart: new Date(rebindWindowStart).toISOString(), updatedAt: serverTime };
                await setLicense(licenseKey, attemptLicense);
                licensesCache.delete(licenseKey);
                console.warn('[Rebind] email 不符（嘗試計數+1）:', licenseKey.substring(0, 8) + '...');
                return res.status(403).json({ error: 'Email 與購買記錄不符，無法自助解綁。請聯繫客服。', code: 'EMAIL_MISMATCH' });
            }
        }

        // --- 4. ATTACK-10 fix: idempotent guard — already unbound, no quota consumed ---
        const oldDeviceId = license.deviceId || license.boundDeviceId || null;
        if (!oldDeviceId) {
            console.log('[Rebind] 授權碼已是未綁定狀態（idempotent，不計次數）:', licenseKey.substring(0, 8) + '...');
            return res.json({
                success: true,
                message: '授權碼已是未綁定狀態，可直接在新裝置上激活',
                rebindCount: rebindCount,
                rebindRemaining: REBIND_MAX_COUNT - rebindCount
            });
        }

        // --- 5. 清除舊裝置綁定 ---
        try {
            const oldDevice = await getDeviceFromKV(oldDeviceId);
            // Compare against normalized licenseKey (ATTACK-2 fix: raw input was trimmed at top)
            if (oldDevice && oldDevice.licenseKey === licenseKey) {
                await setDevice(oldDeviceId, {
                    ...oldDevice,
                    licenseKey: null,
                    activatedAt: null,
                    updatedAt: serverTime
                });
                devicesCache.delete(oldDeviceId);
                console.log('[Rebind] 舊裝置已解除綁定:', oldDeviceId.substring(0, 6) + '...');
            }
        } catch (deviceError) {
            // 非致命：舊裝置下次 auth/check 會自動發現授權碼已清除
            console.error('[Rebind] 清除舊裝置失敗（非致命）:', deviceError.message);
        }

        // --- 6. 更新 license record（清除 deviceId，更新解綁計數）---
        const updatedLicense = {
            ...license,
            deviceId: null,
            boundDeviceId: null,
            activatedAt: null,        // 允許新裝置重新 activate
            rebindCount: rebindCount + 1,
            rebindWindowStart: new Date(rebindWindowStart).toISOString(),
            lastRebindAt: serverTime,
            updatedAt: serverTime,
            // 若本次附帶 email 且 record 原本無 purchaseEmail，補存（供未來驗證）
            ...(email && !license.purchaseEmail ? { purchaseEmail: email } : {})
        };
        await setLicense(licenseKey, updatedLicense);
        // 清除 license cache，確保後續 activate 從 KV 讀最新狀態
        licensesCache.delete(licenseKey);

        console.log('[Rebind] 解綁成功:', licenseKey.substring(0, 8) + '...', '本週期解綁次數:', rebindCount + 1, '/', REBIND_MAX_COUNT);

        return res.json({
            success: true,
            message: '授權碼已解綁，請在新裝置上重新激活',
            rebindCount: rebindCount + 1,
            rebindRemaining: REBIND_MAX_COUNT - (rebindCount + 1)
        });

    } catch (error) {
        console.error('[Rebind] 錯誤:', error);
        if (error.message.includes('授權系統不可用') || error.message.includes('KV')) {
            return res.status(503).json({
                error: '授權系統暫時不可用',
                message: error.message,
                code: 'KV_UNAVAILABLE'
            });
        }
        return res.status(500).json({ error: '服務器錯誤', message: error.message, code: 'REBIND_FAILED' });
    }
});

// ========== ECPay 綠界金流工具 ==========
const ECPAY_MERCHANT_ID = process.env.ECPAY_MERCHANT_ID || '3487294';
const ECPAY_HASH_KEY = process.env.ECPAY_HASH_KEY || 'GqnzRPCvsBTCB57O';
const ECPAY_HASH_IV = process.env.ECPAY_HASH_IV || '0LYW9hnDtehDd2te';
const ECPAY_AIO_URL = process.env.ECPAY_AIO_URL || 'https://payment.ecpay.com.tw/Cashier/AioCheckOut/V5';

// ========== Polar 國際金流 ==========
const POLAR_ACCESS_TOKEN = process.env.POLAR_ACCESS_TOKEN;
const POLAR_PRICE_IDS = {
    annual: process.env.POLAR_PRODUCT_PRICE_ID_ANNUAL,
    lifetime: process.env.POLAR_PRODUCT_PRICE_ID_LIFETIME
};

function ecpayUrlEncode(str) {
    // ECPay 用 .NET HttpUtility.UrlEncode: 空格→'+', 小寫 hex
    return encodeURIComponent(str)
        .replace(/%20/g, '+')
        .replace(/%2d/gi, '-').replace(/%5f/gi, '_').replace(/%2e/gi, '.')
        .replace(/%21/g, '!').replace(/%2a/g, '*').replace(/%28/g, '(').replace(/%29/g, ')')
        .toLowerCase();
}

function genEcpayCheckMacValue(params) {
    const crypto = require('crypto');
    const sorted = Object.keys(params).sort((a, b) => a.toLowerCase().localeCompare(b.toLowerCase()));
    let raw = `HashKey=${ECPAY_HASH_KEY}`;
    for (const k of sorted) { raw += `&${k}=${params[k]}`; }
    raw += `&HashIV=${ECPAY_HASH_IV}`;
    const encoded = ecpayUrlEncode(raw);
    return crypto.createHash('sha256').update(encoded).digest('hex').toUpperCase();
}

// 跟綠界回頭對帳。
//
// ⚠️ 為什麼需要這個（2026-08-20）：HashKey/HashIV 曾隨 public repo 外洩七個月，
// 拿到它們就能算出合法的 CheckMacValue，對 /api/payment/ecpay-notify 送一封
// 假的「付款成功」→ 免費取得授權碼。光驗簽章已經擋不住了。
// 但攻擊者偽造不出「綠界那邊真的有這筆已付款交易」，所以改成回頭查證。
//
// 實測綠界 QueryTradeInfo V5 行為：
//   簽章正確 + 查無此筆 → HTTP 200，TradeStatus=10200047，TradeAmt=0
//   簽章錯誤            → HTTP 500
// 兩者分得開，所以「綠界說沒付款」和「查詢本身失敗」可以走不同分支。
const ECPAY_QUERY_URL = process.env.ECPAY_QUERY_URL
    || 'https://payment.ecpay.com.tw/Cashier/QueryTradeInfo/V5';

// 測試環境若沒指定假的查詢端點，就跳過對帳（避免單元測試打到綠界正式 API）
function shouldVerifyWithEcpay() {
    if (process.env.ECPAY_QUERY_URL) return true;
    return process.env.NODE_ENV !== 'test';
}

async function queryEcpayTrade(merchantTradeNo) {
    const params = {
        MerchantID: ECPAY_MERCHANT_ID,
        MerchantTradeNo: merchantTradeNo,
        TimeStamp: String(Math.floor(Date.now() / 1000)),
        PlatformID: ''
    };
    params.CheckMacValue = genEcpayCheckMacValue(params);

    const res = await fetch(ECPAY_QUERY_URL, {
        method: 'POST',
        headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
        body: new URLSearchParams(params).toString()
    });
    if (!res.ok) throw new Error(`ECPay query HTTP ${res.status}`);

    const text = await res.text();
    const fields = Object.fromEntries(new URLSearchParams(text));
    if (!('TradeStatus' in fields)) throw new Error(`ECPay query 回應無 TradeStatus: ${text.slice(0, 200)}`);
    return {
        paid: String(fields.TradeStatus) === '1',
        tradeStatus: String(fields.TradeStatus),
        tradeAmt: Number(fields.TradeAmt || 0),
        tradeNo: fields.TradeNo || ''
    };
}

// 由 orderId 推回送單時用的 MerchantTradeNo（與建立付款表單時同一套算法）。
// 一定要從「我們自己的訂單」推導，不能用 notify body 帶進來的值——那是攻擊者可控的。
function merchantTradeNoOf(orderId) {
    return String(orderId).replace(/[^A-Za-z0-9]/g, '').slice(0, 20);
}

/**
 * 綠界付款真偽驗證——notify 與 OrderResultURL 共用同一把尺。
 *
 * 兩道關卡：
 *   (1) CheckMacValue：擋掉沒有金鑰的人
 *   (2) 回頭跟綠界對帳：擋掉「有金鑰但沒真的付錢」的人（金鑰外洩過，所以必要）
 *
 * 回傳 { ok: true } 才可以發授權碼；ok:false 時 reason 供記錄與回應用。
 */
async function verifyEcpayPayment(body, orderId, order) {
    const params = { ...body };
    delete params.CheckMacValue;
    const expectedMac = genEcpayCheckMacValue(params);
    if (body.CheckMacValue !== expectedMac) {
        return { ok: false, reason: 'BAD_MAC', detail: `${body.CheckMacValue} != ${expectedMac}` };
    }

    // 已經發過 key：付款早就驗過了，走冪等路徑，不必再對帳一次
    if (order && order.status === 'paid' && order.licenseKey) return { ok: true, alreadyIssued: true };

    if (!shouldVerifyWithEcpay()) return { ok: true, skipped: true };

    let trade;
    try {
        trade = await queryEcpayTrade(merchantTradeNoOf(orderId));
    } catch (queryError) {
        // 查詢本身失敗（網路/綠界異常）→ fail open，不要卡住真實客戶，
        // 但大聲記錄，因為這是唯一繞得過對帳的路徑。
        console.error('🚨 [ECPay] 對帳查詢失敗，本次放行未經查證的付款:', orderId, queryError.message);
        return { ok: true, failedOpen: true };
    }

    if (!trade.paid) {
        return { ok: false, reason: 'NOT_PAID', detail: 'TradeStatus=' + trade.tradeStatus };
    }
    if (order && order.amount && trade.tradeAmt && Number(order.amount) !== trade.tradeAmt) {
        return { ok: false, reason: 'AMOUNT_MISMATCH', detail: `${order.amount} != ${trade.tradeAmt}` };
    }
    return { ok: true };
}

// 5. 創建付款訂單（自動路由：繁中→ECPay，韓文/英文→Polar）
app.post('/api/payment/create', async (req, res) => {
    const { planType, lang, email } = req.body;

    if (!planType || (planType !== 'annual' && planType !== 'lifetime')) {
        return res.status(400).json({ error: '無效的方案類型', code: 'BAD_REQUEST' });
    }

    // 授權碼要寄得出去，email 是必填（2026-08 之前沒收，客人關掉成功頁就永久失聯）
    if (!isValidEmail(email)) {
        return res.status(400).json({ error: '請填寫有效的 Email，授權碼會寄到這個信箱', code: 'INVALID_EMAIL' });
    }
    const purchaseEmail = normalizeEmail(email);

    const prices = { annual: 690, lifetime: 1750 };
    const planNames = { annual: 'KongGoo 年費方案', lifetime: 'KongGoo 買斷方案' };
    const amount = prices[planType];
    const usePolar = lang && lang !== 'zh-TW' && POLAR_ACCESS_TOKEN && POLAR_PRICE_IDS[planType];

    const crypto = require('crypto');
    const orderId = 'ORD-' + Date.now() + '-' + crypto.randomBytes(4).toString('hex').toUpperCase();

    const orderData = {
        planType, amount,
        status: 'pending',
        licenseKey: null,
        gateway: usePolar ? 'polar' : 'ecpay',
        email: purchaseEmail,
        emailSentAt: null,
        emailError: null,
        createdAt: new Date().toISOString(),
        paidAt: null
    };
    try {
        await setOrder(orderId, orderData);
    } catch (error) {
        console.error('❌ [付款建立] 訂單保存失敗:', error);
        if (error.message.includes('授權系統不可用') || error.message.includes('KV')) {
            return res.status(503).json({ error: '授權系統暫時不可用', message: error.message, code: 'KV_UNAVAILABLE' });
        }
        return res.status(500).json({ error: 'Internal Server Error', message: error.message });
    }

    // 路由：非繁中 → Polar 國際金流
    if (usePolar) {
        try {
            // origin only — strip any accidental path (Codex review fix: prevent
            // SUCCESS_URL=https://konggoo.uk/payment/success doubling the path).
            const baseUrl = new URL(process.env.SUCCESS_URL || 'https://konggoo.uk').origin;
            const polarRes = await fetch('https://api.polar.sh/v1/checkouts/', {
                method: 'POST',
                headers: {
                    'Authorization': `Bearer ${POLAR_ACCESS_TOKEN}`,
                    'Content-Type': 'application/json'
                },
                body: JSON.stringify({
                    product_price_id: POLAR_PRICE_IDS[planType],
                    success_url: `${baseUrl}/payment/success?orderId=${orderId}&gateway=polar`,
                    metadata: { orderId, planType }
                })
            });
            const polarData = await polarRes.json();
            if (polarData.url) {
                // 記下 checkout id：/api/payment/polar-confirm 要拿它回頭跟 Polar
                // 核對「這筆真的付款成功」。沒有這個 id 就不發授權。
                try {
                    await setOrder(orderId, { ...orderData, polarCheckoutId: polarData.id || null });
                } catch (e) {
                    console.warn('⚠️ [Polar] 寫入 checkoutId 失敗:', e.message);
                }
                return res.json({
                    success: true,
                    orderId,
                    gateway: 'polar',
                    paymentUrl: polarData.url,
                    message: 'Redirecting to Polar checkout'
                });
            }
            // Polar 失敗 → fallback 到 ECPay
            console.warn('⚠️ Polar checkout 失敗，fallback 到 ECPay:', JSON.stringify(polarData));
        } catch (polarError) {
            console.warn('⚠️ Polar API 錯誤，fallback 到 ECPay:', polarError.message);
        }
    }

    // 預設：ECPay 綠界信用卡（台灣客戶 or Polar fallback）
    try {
        res.json({
            success: true,
            orderId,
            gateway: 'ecpay',
            paymentUrl: `/payment/ecpay-checkout?orderId=${orderId}`,
            message: '訂單已創建，前往綠界付款'
        });
    } catch (error) {
        console.error('❌ 付款建立錯誤:', error);
        return res.status(500).json({ error: '付款建立失敗', message: error.message });
    }
});

// 5.0.1 ECPay 結帳跳轉頁（自動 POST 表單到綠界）
app.get('/payment/ecpay-checkout', async (req, res) => {
    const { orderId } = req.query;
    if (!orderId) return res.redirect('/');

    const order = await getOrderFromKV(orderId);
    if (!order) return res.status(404).send('訂單不存在');
    if (order.status === 'paid') {
        return res.redirect(`/payment/success?licenseKey=${order.licenseKey}&planType=${order.planType}`);
    }

    // origin only — strip any accidental path (Codex review fix: prevent
    // SUCCESS_URL=https://konggoo.uk/payment/success doubling the path).
    const baseUrl = new URL(process.env.SUCCESS_URL || 'https://konggoo.uk').origin;
    const planNames = { annual: 'KongGoo 年費方案', lifetime: 'KongGoo 買斷方案' };
    const now = new Date();
    const pad = n => String(n).padStart(2, '0');
    const merchantTradeDate = `${now.getFullYear()}/${pad(now.getMonth()+1)}/${pad(now.getDate())} ${pad(now.getHours())}:${pad(now.getMinutes())}:${pad(now.getSeconds())}`;

    const params = {
        MerchantID: ECPAY_MERCHANT_ID,
        MerchantTradeNo: orderId.replace(/[^A-Za-z0-9]/g, '').slice(0, 20),
        MerchantTradeDate: merchantTradeDate,
        PaymentType: 'aio',
        TotalAmount: String(order.amount),
        TradeDesc: ecpayUrlEncode('KongGoo iOS GPS 位置模擬工具授權'),
        ItemName: planNames[order.planType] || 'KongGoo 授權',
        ReturnURL: `${baseUrl}/api/payment/ecpay-notify`,
        OrderResultURL: `${baseUrl}/payment/success`,
        ChoosePayment: 'Credit',
        EncryptType: '1',
        CustomField1: orderId
    };
    params.CheckMacValue = genEcpayCheckMacValue(params);

    // 自動提交表單
    const fields = Object.entries(params).map(([k,v]) => `<input type="hidden" name="${k}" value="${String(v).replace(/"/g, '&quot;')}">`).join('\n');
    res.send(`<!DOCTYPE html><html><head><meta charset="UTF-8"><title>前往付款...</title></head>
<body style="display:flex;align-items:center;justify-content:center;height:100vh;font-family:system-ui;color:#475569;">
<div style="text-align:center"><p style="font-size:1.1rem;font-weight:600;">正在前往綠界付款頁面...</p><p style="color:#94a3b8;font-size:.9rem;">請稍候，若未自動跳轉請點擊下方按鈕</p>
<form id="ecpayForm" method="POST" action="${ECPAY_AIO_URL}">${fields}
<button type="submit" style="margin-top:16px;padding:10px 24px;border-radius:8px;background:#6366f1;color:#fff;border:none;font-weight:600;cursor:pointer;">前往付款</button>
</form></div>
<script>document.getElementById('ecpayForm').submit();</script>
</body></html>`);
});

// 5.1. ECPay 付款回調（Server-to-Server，ReturnURL）
app.post('/api/payment/ecpay-notify', async (req, res) => {
    try {
        const body = req.body;
        console.log('📥 ECPay notify 收到:', JSON.stringify(body));

        const rtnCode = body.RtnCode;
        const orderId = body.CustomField1;

        if (String(rtnCode) === '1' && orderId) {
            const order = await getOrderFromKV(orderId);
            if (order) {
                const verdict = await verifyEcpayPayment(body, orderId, order);
                if (!verdict.ok) {
                    console.warn('🚨 [ECPay notify] 拒發授權:', orderId, verdict.reason, verdict.detail);
                    if (verdict.reason === 'BAD_MAC') return res.send('0|CheckMacValue Error');
                    if (verdict.reason === 'AMOUNT_MISMATCH') return res.send('0|Amount mismatch');
                    // 綠界說沒付款：回 0 讓綠界稍後重送，真付款有延遲時仍會補發
                    return res.send('0|Trade not verified');
                }
                // 冪等：重送 notify 不會重複發 key，也不會重複寄信
                await orderFlow.finalizePaidOrder(orderId, order, {
                    tradeNo: body.TradeNo || '',
                    gateway: 'ecpay'
                });
            }
        }

        // ECPay 要求回傳 1|OK
        res.send('1|OK');
    } catch (error) {
        console.error('❌ ECPay notify 錯誤:', error);
        res.send('0|Error');
    }
});

// 5.1.1 Polar 付款成功回調（success_url redirect 後客戶端輪詢確認）
// Polar 付款確認。
//
// ⚠️ 2026-08-20 安全修補：這支端點原本只要「有這個 orderId」就直接發授權，
// 把「使用者被導回 success_url」當成付款證明。但 orderId 是 /api/payment/create
// 直接回傳給呼叫端的，任何人都能建單拿到 orderId 再打這支，等於免費領授權碼。
// 現在一律回頭跟 Polar 核對該 checkout 的真實狀態，核不過就不發。
const POLAR_PAID_STATUSES = new Set(['succeeded', 'confirmed']);

app.get('/api/payment/polar-confirm', async (req, res) => {
    const { orderId } = req.query;
    if (!orderId) return res.status(400).json({ error: 'Missing orderId' });

    try {
        const order = await getOrderFromKV(orderId);
        if (!order) return res.status(404).json({ error: 'Order not found' });

        // 已經是 paid 的訂單：付款早就驗過了，這裡只補做「發信」等後續（冪等）
        if (order.status === 'paid' && order.licenseKey) {
            const licenseKey = await orderFlow.finalizePaidOrder(orderId, order, { gateway: 'polar' });
            return res.json({ success: true, licenseKey, planType: order.planType });
        }

        if (order.gateway !== 'polar' || !order.polarCheckoutId) {
            return res.status(400).json({ error: 'Not a Polar order', code: 'GATEWAY_MISMATCH' });
        }
        if (!POLAR_ACCESS_TOKEN) {
            console.error('❌ [Polar confirm] 缺 POLAR_ACCESS_TOKEN，無法驗證付款');
            return res.status(503).json({ error: 'Payment verification unavailable', code: 'POLAR_UNCONFIGURED' });
        }

        let checkout;
        try {
            const r = await fetch(`https://api.polar.sh/v1/checkouts/${encodeURIComponent(order.polarCheckoutId)}`, {
                headers: { 'Authorization': `Bearer ${POLAR_ACCESS_TOKEN}` }
            });
            checkout = await r.json();
            if (!r.ok) {
                console.warn('⚠️ [Polar confirm] 查詢 checkout 失敗:', r.status, JSON.stringify(checkout));
                return res.status(502).json({ error: 'Payment verification failed', code: 'POLAR_LOOKUP_FAILED' });
            }
        } catch (e) {
            console.error('❌ [Polar confirm] Polar API 錯誤:', e.message);
            return res.status(502).json({ error: 'Payment verification failed', code: 'POLAR_LOOKUP_FAILED' });
        }

        // 綁定檢查：這個 checkout 必須真的屬於這筆訂單
        const metaOrderId = checkout && checkout.metadata && checkout.metadata.orderId;
        if (metaOrderId && metaOrderId !== orderId) {
            console.warn('⚠️ [Polar confirm] checkout metadata 對不上訂單:', metaOrderId, '!=', orderId);
            return res.status(400).json({ error: 'Order mismatch', code: 'ORDER_MISMATCH' });
        }

        if (!POLAR_PAID_STATUSES.has(String(checkout && checkout.status))) {
            return res.json({ success: false, code: 'NOT_PAID', status: checkout && checkout.status });
        }

        const licenseKey = await orderFlow.finalizePaidOrder(orderId, order, { gateway: 'polar' });
        return res.json({ success: true, licenseKey, planType: order.planType });
    } catch (error) {
        console.error('❌ Polar confirm 錯誤:', error);
        return res.status(500).json({ error: 'Internal error' });
    }
});

// 5.2. 獲取訂單信息
app.get('/api/payment/order/:orderId', async (req, res) => {
    const { orderId } = req.params;
    
    if (!orderId) {
        return res.status(400).json({ error: 'orderId 是必需的' });
    }
    
    const order = await getOrderFromKV(orderId);
    
    if (!order) {
        return res.status(404).json({ error: '訂單不存在' });
    }
    
    res.json({
        success: true,
        order: {
            orderId: orderId,
            planType: order.planType,
            amount: order.amount,
            status: order.status,
            licenseKey: order.status === 'paid' ? order.licenseKey : null,
            createdAt: order.createdAt
        }
    });
});

// 5.3. 處理付款（模擬或真實金流回調）
app.get('/payment/process', async (req, res) => {
    try {
        // production 預設禁用測試付款頁（避免繞過付款）
        if (isProd && !ALLOW_MOCK_PAYMENT) {
            return res.status(404).send('Not Found');
        }
        const { orderId } = req.query;
        
        if (!orderId) {
            // 使用者直接打開網址時給友善導向（避免看起來像壞掉）
            return res.redirect('/payment');
        }
        
        const order = await getOrderFromKV(orderId);
        
        if (!order) {
            return res.status(404).send('訂單不存在');
        }
        
        if (order.status === 'paid') {
            // 已付款，直接跳轉到成功頁面
            return res.redirect(`/payment/success?licenseKey=${order.licenseKey}&planType=${order.planType}`);
        }
        
        // 發送模擬付款頁面（實際應該跳轉到綠界）
        const processPath = path.resolve(paymentProcessDir, 'process.html');
        console.log('💳 發送付款處理頁面:', processPath, '存在:', fs.existsSync(processPath));
        if (!fs.existsSync(processPath)) {
            return res.status(404).json({ error: 'Process page not found', path: processPath });
        }
        res.sendFile(processPath);
    } catch (error) {
        console.error('❌ 付款處理頁面錯誤:', error);
        res.status(500).json({ error: 'Internal Server Error', message: error.message });
    }
});

// 5.3. 確認付款（由金流回調或模擬付款頁面調用）
app.post('/api/payment/confirm', async (req, res) => {
    // production 預設禁用測試確認付款（避免繞過付款）
    if (isProd && !ALLOW_MOCK_PAYMENT) {
        return res.status(404).json({ error: 'Not Found', code: 'NOT_AVAILABLE' });
    }
    const { orderId } = req.body;
    
    if (!orderId) {
        return res.status(400).json({ error: 'orderId 是必需的' });
    }
    
    const order = await getOrderFromKV(orderId);
    
    if (!order) {
        return res.status(404).json({ error: '訂單不存在' });
    }
    
    if (order.status === 'paid') {
        return res.json({
            success: true,
            licenseKey: order.licenseKey,
            message: '訂單已付款'
        });
    }
    
    // 生成授權碼
    const crypto = require('crypto');
    const licenseKey = generateLicenseKey();
    
    // 更新訂單狀態
    order.status = 'paid';
    order.licenseKey = licenseKey;
    order.paidAt = new Date().toISOString();
    await setOrder(orderId, order);
    
    // 將授權碼添加到持久化存儲（未綁定設備，等待用戶激活）
    await setLicense(licenseKey, {
        licenseKeyHash: crypto.createHash('sha256').update(licenseKey).digest('hex'),
        deviceId: null,
        boundDeviceId: null,
        paidAt: order.paidAt,
        isValid: true,
        createdAt: order.createdAt,
        activatedAt: null,
        planType: order.planType,
        issuedBy: 'payment',
        note: null
    });
    
    console.log('✅ [付款確認] 授權碼已生成並保存到持久化存儲:', licenseKey);
    
    res.json({
        success: true,
        licenseKey: licenseKey,
        orderId: orderId,
        message: '付款成功，授權碼已生成'
    });
});

// 6. 創建授權碼（管理員）
app.post('/api/admin/create-license', async (req, res) => {
    const { adminKey, deviceId } = req.body;
    
    if (adminKey !== ADMIN_KEY) {
        return res.status(401).json({ error: '無效的管理員密鑰' });
    }

    try {
        requireKV();
    } catch (error) {
        console.error('❌ [管理員] KV 不可用:', error);
        return res.status(503).json({
            error: '授權系統暫時不可用',
            message: error.message,
            code: 'KV_UNAVAILABLE'
        });
    }
    
    const crypto = require('crypto');
    const licenseKey = generateLicenseKey();
    const serverTime = new Date().toISOString();
    
    await setLicense(licenseKey, {
        licenseKeyHash: crypto.createHash('sha256').update(licenseKey).digest('hex'),
        deviceId: deviceId || null,
        boundDeviceId: deviceId || null,
        paidAt: serverTime,
        isValid: true,
        createdAt: serverTime,
        activatedAt: deviceId ? serverTime : null,
        planType: 'annual', // 舊的 admin 端點改為 annual
        durationDays: planDurationDays('annual'),
        expiresAt: null,
        issuedBy: 'admin',
        note: null
    });
    
    if (deviceId) {
        let device = await getDeviceFromKV(deviceId);
        if (!device) {
            device = {
                trialExpiresAt: null,
                licenseKey: licenseKey,
                activatedAt: serverTime,
                registeredAt: serverTime,
                updatedAt: serverTime
            };
        } else {
            device.licenseKey = licenseKey;
            device.activatedAt = serverTime;
            device.updatedAt = serverTime;
        }
        await setDevice(deviceId, device);
    }
    
    console.log('✅ [管理員] 授權碼已創建並保存到持久化存儲:', licenseKey, deviceId ? `綁定到設備: ${deviceId}` : '未綁定');
    
    res.json({
        success: true,
        licenseKey: licenseKey,
        deviceId: deviceId || null
    });
});

// 下載文件（直接從 public/downloads 提供，不轉址）
app.get('/downloads/:file', (req, res) => {
    const file = req.params.file;

    // ⚠️ 對於 DMG 檔案，直接從 GitHub Release 代理下載（使用 browser_download_url）
    if (file === 'ios-location-simulator-mac.dmg') {
        // 使用 GitHub Release 的 browser_download_url（更可靠）
        // 格式：https://github.com/OWNER/REPO/releases/download/TAG/FILENAME
        // 重要：GitHub Release 資產通常會先回 302 轉到 release-assets.githubusercontent.com
        // 我們必須處理 302（或直接用 ?download=1 觸發轉址），否則會誤判為失敗導致使用者下載到幾百 bytes 的錯誤 JSON。
        const rawUrl =
            process.env.MAC_DMG_URL ||
            'https://github.com/awe7893625/pikmin-architect/releases/download/v1.1.0/KongGoo-1.1.0-arm64.dmg';
        const downloadUrl = rawUrl.includes('?') ? rawUrl : `${rawUrl}?download=1`;
        console.log(`📥 [下載] 代理下載 DMG 從: ${downloadUrl}`);
        
        // 設置正確的 headers
        res.setHeader('Content-Type', 'application/x-apple-diskimage');
        res.setHeader('Content-Disposition', 'attachment; filename="ios-location-simulator-mac.dmg"');
        res.setHeader('X-Content-Type-Options', 'nosniff');
        res.setHeader('Cache-Control', 'public, max-age=3600');
        
        // 使用 stream 代理下載，不讓使用者看到原始 URL
        const https = require('https');
        const http = require('http');
        const url = require('url');
        const parsedUrl = url.parse(downloadUrl);
        const client = parsedUrl.protocol === 'https:' ? https : http;
        
        const proxyReq = client.get(parsedUrl, (proxyRes) => {
            // GitHub 會回 302 (Location: release-assets...)；直接把使用者導向到真正的資產下載位址即可
            if ((proxyRes.statusCode === 301 || proxyRes.statusCode === 302 || proxyRes.statusCode === 303 || proxyRes.statusCode === 307 || proxyRes.statusCode === 308) && proxyRes.headers.location) {
                res.setHeader('Content-Type', 'application/x-apple-diskimage');
                res.setHeader('Content-Disposition', 'attachment; filename="ios-location-simulator-mac.dmg"');
                res.setHeader('X-Content-Type-Options', 'nosniff');
                // 導向到 release-assets.githubusercontent.com（不是 GitHub 頁面）
                return res.redirect(proxyRes.statusCode, proxyRes.headers.location);
            }

            if (proxyRes.statusCode !== 200) {
                console.log(`⚠️ [下載] GitHub 回傳 ${proxyRes.statusCode}，嘗試備用連結`);
                // 如果 GitHub 回傳 404，嘗試使用多個備用連結
                const fallbackUrls = [
                    'https://github.com/awe7893625/pikmin-architect/releases/download/v1.1.0/KongGoo-1.1.0-arm64.dmg?download=1',
                    'https://github.com/awe7893625/pikmin-architect/releases/download/v1.1.0/KongGoo-1.1.0-x64.dmg?download=1'
                ];
                
                let fallbackIndex = 0;
                const tryFallback = () => {
                    if (fallbackIndex >= fallbackUrls.length) {
                        return res.status(503).json({ 
                            error: '下載暫時不可用', 
                            message: 'GitHub Release CDN 正在同步，請稍候 5-10 分鐘後再試，或直接從 GitHub Releases 頁面下載',
                            code: 'DOWNLOAD_UNAVAILABLE',
                            directUrl: 'https://github.com/awe7893625/pikmin-architect/releases/latest'
                        });
                    }
                    
                    const fallbackUrl = fallbackUrls[fallbackIndex];
                    console.log(`📥 [下載] 嘗試備用連結 ${fallbackIndex + 1}/${fallbackUrls.length}: ${fallbackUrl}`);
                    const fallbackParsed = url.parse(fallbackUrl);
                    const fallbackClient = fallbackParsed.protocol === 'https:' ? https : http;
                    const fallbackReq = fallbackClient.get(fallbackParsed, (fallbackRes) => {
                        if ((fallbackRes.statusCode === 301 || fallbackRes.statusCode === 302 || fallbackRes.statusCode === 303 || fallbackRes.statusCode === 307 || fallbackRes.statusCode === 308) && fallbackRes.headers.location) {
                            res.setHeader('Content-Type', 'application/x-apple-diskimage');
                            res.setHeader('Content-Disposition', 'attachment; filename="ios-location-simulator-mac.dmg"');
                            res.setHeader('X-Content-Type-Options', 'nosniff');
                            return res.redirect(fallbackRes.statusCode, fallbackRes.headers.location);
                        }
                        if (fallbackRes.statusCode === 200) {
                            res.statusCode = fallbackRes.statusCode;
                            Object.keys(fallbackRes.headers).forEach(key => {
                                if (key.toLowerCase() !== 'content-encoding' && key.toLowerCase() !== 'transfer-encoding') {
                                    res.setHeader(key, fallbackRes.headers[key]);
                                }
                            });
                            fallbackRes.pipe(res);
                        } else {
                            fallbackIndex++;
                            tryFallback();
                        }
                    });
                    fallbackReq.on('error', () => {
                        fallbackIndex++;
                        tryFallback();
                    });
                };
                tryFallback();
                return;
            }
            
            res.statusCode = proxyRes.statusCode;
            Object.keys(proxyRes.headers).forEach(key => {
                if (key.toLowerCase() !== 'content-encoding' && key.toLowerCase() !== 'transfer-encoding') {
                    res.setHeader(key, proxyRes.headers[key]);
                }
            });
            proxyRes.pipe(res);
        });
        
        proxyReq.on('error', (err) => {
            console.error(`❌ [下載] 代理下載失敗: ${err.message}`);
            // 返回錯誤而不是重定向
            return res.status(503).json({ 
                error: '下載失敗', 
                message: '無法連接到下載伺服器，請稍候再試',
                code: 'DOWNLOAD_PROXY_ERROR'
            });
        });
        
        proxyReq.setTimeout(15000, () => {
            proxyReq.destroy();
            console.log(`⚠️ [下載] 代理下載超時`);
            return res.status(504).json({ 
                error: '下載超時', 
                message: '下載請求超時，請稍候再試',
                code: 'DOWNLOAD_TIMEOUT'
            });
        });
        
        return;
    }

    // 對於其他檔案，從 public/downloads 直接提供
    const publicDownloadsPath = path.join(__dirname, 'public', 'downloads', file);
    if (fs.existsSync(publicDownloadsPath)) {
        // 檢查檔案大小，避免提供 Git LFS 指標檔（通常 < 200 bytes）
        const stats = fs.statSync(publicDownloadsPath);
        if (stats.size < 200) {
            console.log(`⚠️ [下載] 檔案太小（${stats.size} bytes），可能是 LFS 指標檔`);
            return res.status(404).json({ 
                error: '檔案不存在', 
                message: '檔案可能尚未上傳或正在處理中',
                code: 'FILE_NOT_FOUND'
            });
        }
        
        // 設置正確的 Content-Type
        if (file.endsWith('.dmg')) {
            res.setHeader('Content-Type', 'application/x-apple-diskimage');
        } else if (file.endsWith('.zip')) {
            res.setHeader('Content-Type', 'application/zip');
        } else if (file.endsWith('.exe')) {
            res.setHeader('Content-Type', 'application/x-msdownload');
        }
        
        // 防止 Safari 添加 quarantine 屬性的關鍵 headers
        res.setHeader('Content-Disposition', `attachment; filename="${file}"`);
        res.setHeader('X-Content-Type-Options', 'nosniff');
        res.setHeader('Cache-Control', 'public, max-age=3600');
        res.setHeader('Pragma', 'public');
        
        return res.sendFile(publicDownloadsPath);
    }


    // 備用：從 downloads 目錄提供
    const filePath = path.join(__dirname, 'downloads', file);
    if (fs.existsSync(filePath)) {
        // 設置正確的 Content-Type
        if (file.endsWith('.dmg')) {
            res.setHeader('Content-Type', 'application/x-apple-diskimage');
        } else if (file.endsWith('.zip')) {
            res.setHeader('Content-Type', 'application/zip');
        } else if (file.endsWith('.exe')) {
            res.setHeader('Content-Type', 'application/x-msdownload');
        }
        
        res.setHeader('Content-Disposition', `attachment; filename="${file}"`);
        res.setHeader('X-Content-Type-Options', 'nosniff');
        res.setHeader('Cache-Control', 'public, max-age=3600');
        res.setHeader('Pragma', 'public');
        
        return res.sendFile(filePath);
    }
    
    // 最後嘗試 public 根目錄
    const publicPath = path.join(__dirname, 'public', file);
    if (fs.existsSync(publicPath)) {
        if (file.endsWith('.dmg')) {
            res.setHeader('Content-Type', 'application/x-apple-diskimage');
        }
        res.setHeader('Content-Disposition', `attachment; filename="${file}"`);
        return res.sendFile(publicPath);
    }
    
    return res.status(404).json({ error: '檔案不存在' });
});

// ========================
// Admin Console (production 可用，三道門保護)
// ========================
// /admin 與 /api/admin/* 三道門：
// (1) ENABLE_ADMIN_CONSOLE === "1"
// (2) production 也允許，但必須手動開 ENABLE_ADMIN_CONSOLE（預設關閉）
// (3) 每個 request header 必須帶：x-admin-key: <ADMIN_KEY>
// 任一不符 → 404（不暴露存在性）

const ENABLE_ADMIN_CONSOLE = process.env.ENABLE_ADMIN_CONSOLE === '1';
const ADMIN_KEY_ENV = process.env.ADMIN_KEY || 'default-admin-key-change-in-production';

// Admin 權限檢查中間件（返回 null 表示通過，返回 response 表示拒絕）
function requireAdminOr404(req, res) {
    if (!ENABLE_ADMIN_CONSOLE) {
        return res.status(404).send('Not Found');
    }
    const headerKey = req.headers['x-admin-key'];
    if (!headerKey || String(headerKey) !== ADMIN_KEY_ENV) {
        return res.status(404).send('Not Found');
    }
    return null;
}

// Admin API 路由（僅在 ENABLE_ADMIN_CONSOLE=1 時註冊）
if (ENABLE_ADMIN_CONSOLE) {
    // A) GET /api/admin/licenses - 列出所有授權
    app.get('/api/admin/licenses', async (req, res) => {
        const denied = requireAdminOr404(req, res);
        if (denied) return;

        try {
            // 檢查 KV 是否可用
            if (!kv) {
                console.error('❌ [Admin] KV 未初始化');
                return res.status(503).json({
                    error: '授權系統暫時不可用',
                    message: 'KV 未初始化',
                    code: 'KV_UNAVAILABLE'
                });
            }
            
            requireKV();
            
            // 從 license index 取得所有 license keys（如果不存在則返回空數組）
            let index = [];
            try {
                index = await getLicenseIndex();
            } catch (indexError) {
                console.warn('⚠️ [Admin] license index 不存在或讀取失敗，返回空列表:', indexError.message);
                index = [];
            }
            
            // 批次讀取所有 license 資料
            const items = [];
            for (const item of index) {
                try {
                    const licenseData = await getLicenseFromKV(item.licenseKey);
                    if (licenseData) {
                        // 遮罩 licenseKey（顯示前 8 碼 + 後 4 碼）
                        const key = item.licenseKey;
                        const masked = key.length > 12 
                            ? `${key.substring(0, 8)}****${key.substring(key.length - 4)}`
                            : `${key.substring(0, 4)}****`;
                        
                        // 縮短 deviceId（顯示前 6 碼）
                        const boundDeviceId = licenseData.boundDeviceId || licenseData.deviceId || null;
                        const boundDeviceIdShort = boundDeviceId 
                            ? (boundDeviceId.length > 6 ? `${boundDeviceId.substring(0, 6)}…` : boundDeviceId)
                            : null;
                        
                        items.push({
                            licenseKeyMasked: masked,
                            licenseKey: key, // 完整 key 保留供 rebind 使用（後端驗證）
                            planType: licenseData.planType || 'annual',
                            issuedBy: licenseData.issuedBy || (licenseData.paidAt ? 'payment' : 'admin'),
                            note: licenseData.note || null,
                            createdAt: licenseData.createdAt || item.createdAt,
                            activatedAt: licenseData.activatedAt || null,
                            boundDeviceIdShort: boundDeviceIdShort,
                            boundDeviceId: boundDeviceId, // 完整 ID 保留供 rebind 使用
                            purchaseEmailMasked: licenseData.purchaseEmail ? maskEmail(licenseData.purchaseEmail) : null,
                            purchaseEmail: licenseData.purchaseEmail || null,
                            expiresAt: licenseData.expiresAt || null,
                            expired: isLicenseExpired(licenseData),
                            status: (licenseData.activatedAt || boundDeviceId) ? 'used' : 'unused'
                        });
                    }
                } catch (error) {
                    console.error(`❌ [Admin] 讀取授權失敗 ${item.licenseKey}:`, error);
                    // 繼續處理其他授權
                }
            }
            
            // 計算統計
            const summary = {
                total: items.length,
                used: items.filter(item => item.status === 'used').length,
                unused: items.filter(item => item.status === 'unused').length,
                adminGrantedDevices: 0 // 需要從 device 資料計算
            };
            
            // 計算 admin-granted devices（需要掃描所有 devices，但為了效能，這裡先設為 0，可後續優化）
            // 如果需要精確數字，可以維護一個 device:admin-granted:index
            
            res.json({ items, summary });
        } catch (error) {
            console.error('❌ [Admin] 列出授權失敗:', error);
            if (error.message.includes('授權系統不可用') || error.message.includes('KV')) {
                return res.status(503).json({
                    error: '授權系統暫時不可用',
                    message: error.message,
                    code: 'KV_UNAVAILABLE'
                });
            }
            return res.status(500).json({
                error: '操作失敗',
                message: error.message,
                code: 'ADMIN_OP_FAILED'
            });
        }
    });

    // B) POST /api/admin/license/create - 創建新授權
    app.post('/api/admin/license/create', async (req, res) => {
        const denied = requireAdminOr404(req, res);
        if (denied) return;

        try {
            // 檢查 KV 是否可用
            if (!kv) {
                console.error('❌ [Admin] KV 未初始化');
                return res.status(503).json({
                    error: '授權系統暫時不可用',
                    message: 'KV 未初始化',
                    code: 'KV_UNAVAILABLE'
                });
            }
            
            requireKV();
            
            const { planType, note } = req.body || {};
            if (!planType || (planType !== 'annual' && planType !== 'lifetime')) {
                return res.status(400).json({
                    error: '無效的授權類型',
                    code: 'BAD_REQUEST'
                });
            }
            
            const crypto = require('crypto');
            const licenseKey = generateLicenseKey();
            const now = new Date().toISOString();
            
            const licenseData = {
                licenseKeyHash: crypto.createHash('sha256').update(licenseKey).digest('hex'),
                planType: planType,
                createdAt: now,
                issuedBy: 'admin',
                note: note ? String(note).slice(0, 200) : null,
                boundDeviceId: null,
                activatedAt: null,
                // annual 一樣有效期（啟用時起算）；要發永久請開 lifetime
                durationDays: planDurationDays(planType),
                expiresAt: null,
                isValid: true
            };
            
            await setLicense(licenseKey, licenseData);
            
            const masked = `${licenseKey.substring(0, 8)}****${licenseKey.substring(licenseKey.length - 4)}`;
            
            console.log('✅ [Admin] 授權碼已創建:', licenseKey.substring(0, 8) + '...');
            
            res.json({
                success: true,
                licenseKey: licenseKey,
                licenseKeyMasked: masked,
                createdAt: now
            });
        } catch (error) {
            console.error('❌ [Admin] 創建授權失敗:', error);
            if (error.message.includes('授權系統不可用') || error.message.includes('KV')) {
                return res.status(503).json({
                    error: '授權系統暫時不可用',
                    message: error.message,
                    code: 'KV_UNAVAILABLE'
                });
            }
            return res.status(500).json({
                error: '操作失敗',
                message: error.message,
                code: 'ADMIN_OP_FAILED'
            });
        }
    });

    // C) POST /api/admin/license/rebind - 重新綁定裝置
    app.post('/api/admin/license/rebind', async (req, res) => {
        const denied = requireAdminOr404(req, res);
        if (denied) return;

        try {
            requireKV();
            
            const { licenseKey, newDeviceId } = req.body || {};
            if (!licenseKey || !newDeviceId) {
                return res.status(400).json({
                    error: '缺少必要參數',
                    code: 'BAD_REQUEST'
                });
            }
            
            // 讀取現有授權
            const licenseData = await getLicenseFromKV(licenseKey);
            if (!licenseData) {
                return res.status(404).json({
                    error: '授權碼不存在',
                    code: 'LICENSE_NOT_FOUND'
                });
            }
            
            const oldDeviceId = licenseData.boundDeviceId || licenseData.deviceId || null;
            const now = new Date().toISOString();
            
            // 更新授權（綁定新裝置）
            const updatedLicenseData = {
                ...licenseData,
                boundDeviceId: newDeviceId,
                activatedAt: licenseData.activatedAt || now, // 如果尚未激活，則現在激活
                updatedAt: now
            };
            await setLicense(licenseKey, updatedLicenseData);
            
            // 更新舊裝置（移除授權綁定）
            if (oldDeviceId) {
                try {
                    const oldDevice = await getDeviceFromKV(oldDeviceId);
                    if (oldDevice && oldDevice.licenseKey === licenseKey) {
                        const updatedOldDevice = {
                            ...oldDevice,
                            licenseKey: null,
                            activatedAt: null,
                            updatedAt: now
                        };
                        await setDevice(oldDeviceId, updatedOldDevice);
                    }
                } catch (error) {
                    console.error('❌ [Admin] 更新舊裝置失敗:', error);
                    // 不中斷流程，繼續處理新裝置
                }
            }
            
            // 更新新裝置（綁定授權）
            let newDevice = await getDeviceFromKV(newDeviceId);
            if (!newDevice) {
                newDevice = {
                    trialExpiresAt: null,
                    licenseKey: licenseKey,
                    activatedAt: now,
                    registeredAt: now,
                    updatedAt: now
                };
            } else {
                newDevice = {
                    ...newDevice,
                    licenseKey: licenseKey,
                    activatedAt: now,
                    updatedAt: now
                };
            }
            await setDevice(newDeviceId, newDevice);
            
            console.log('✅ [Admin] 授權已重新綁定:', licenseKey.substring(0, 8) + '...', '從', oldDeviceId?.substring(0, 6) + '...', '到', newDeviceId.substring(0, 6) + '...');
            
            res.json({ success: true });
        } catch (error) {
            console.error('❌ [Admin] 重新綁定失敗:', error);
            if (error.message.includes('授權系統不可用') || error.message.includes('KV')) {
                return res.status(503).json({
                    error: '授權系統暫時不可用',
                    message: error.message,
                    code: 'KV_UNAVAILABLE'
                });
            }
            return res.status(500).json({
                error: '操作失敗',
                message: error.message,
                code: 'ADMIN_OP_FAILED'
            });
        }
    });

    // D) POST /api/admin/device/grant - 直接授權裝置
    app.post('/api/admin/device/grant', async (req, res) => {
        const denied = requireAdminOr404(req, res);
        if (denied) return;

        try {
            // 檢查 KV 是否可用
            if (!kv) {
                console.error('❌ [Admin] KV 未初始化');
                return res.status(503).json({
                    error: '授權系統暫時不可用',
                    message: 'KV 未初始化',
                    code: 'KV_UNAVAILABLE'
                });
            }
            
            requireKV();
            
            const { deviceId, note } = req.body || {};
            if (!deviceId) {
                return res.status(400).json({
                    error: '缺少裝置 ID',
                    code: 'BAD_REQUEST'
                });
            }
            
            const now = new Date().toISOString();
            
            // 讀取或創建設備資料
            let device = await getDeviceFromKV(deviceId);
            if (!device) {
                device = {
                    trialExpiresAt: null,
                    registeredAt: now,
                    updatedAt: now
                };
            }
            
            // 標記為 admin-granted
            const updatedDevice = {
                ...device,
                grantedBy: 'admin',
                grantNote: note ? String(note).slice(0, 200) : null,
                grantedAt: now,
                activatedAt: now, // 視同已激活
                updatedAt: now
            };
            
            await setDevice(deviceId, updatedDevice);
            
            console.log('✅ [Admin] 裝置已直接授權:', deviceId.substring(0, 6) + '...');
            
            res.json({ success: true });
        } catch (error) {
            console.error('❌ [Admin] 直接授權裝置失敗:', error);
            if (error.message.includes('授權系統不可用') || error.message.includes('KV')) {
                return res.status(503).json({
                    error: '授權系統暫時不可用',
                    message: error.message,
                    code: 'KV_UNAVAILABLE'
                });
            }
            return res.status(500).json({
                error: '操作失敗',
                message: error.message,
                code: 'ADMIN_OP_FAILED'
            });
        }
    });

    // E) POST /api/admin/unbind - 管理員手動解綁（客服專用）
    // 受 requireAdminOr404 三道門保護（ENABLE_ADMIN_CONSOLE + x-admin-key header）
    // body: { licenseKey }
    // 與自助 rebind 不同：不受頻率限制、不需要 email，直接解綁
    app.post('/api/admin/unbind', async (req, res) => {
        const denied = requireAdminOr404(req, res);
        if (denied) return;

        const serverTime = new Date().toISOString();

        try {
            requireKV();

            const { licenseKey } = req.body || {};
            if (!licenseKey) {
                return res.status(400).json({ error: 'licenseKey 是必需的', code: 'BAD_REQUEST' });
            }

            // 讀取 license
            const license = await getLicenseFromKV(String(licenseKey).trim());
            if (!license) {
                return res.status(404).json({ error: '授權碼不存在', code: 'LICENSE_NOT_FOUND' });
            }

            const oldDeviceId = license.deviceId || license.boundDeviceId || null;

            // 清除舊裝置綁定
            if (oldDeviceId) {
                try {
                    const oldDevice = await getDeviceFromKV(oldDeviceId);
                    if (oldDevice && oldDevice.licenseKey === licenseKey) {
                        await setDevice(oldDeviceId, {
                            ...oldDevice,
                            licenseKey: null,
                            activatedAt: null,
                            updatedAt: serverTime
                        });
                        devicesCache.delete(oldDeviceId);
                    }
                } catch (deviceError) {
                    console.error('[Admin/Unbind] 清除舊裝置失敗（非致命）:', deviceError.message);
                }
            }

            // 更新 license record（管理員解綁，記錄 adminUnbindAt 但不增加 rebindCount）
            const updatedLicense = {
                ...license,
                deviceId: null,
                boundDeviceId: null,
                activatedAt: null,
                adminUnbindAt: serverTime,
                adminUnbindCount: (license.adminUnbindCount || 0) + 1,
                updatedAt: serverTime
            };
            await setLicense(licenseKey, updatedLicense);
            licensesCache.delete(licenseKey);

            console.log('[Admin/Unbind] 管理員解綁成功:', licenseKey.substring(0, 8) + '...', '舊裝置:', oldDeviceId ? oldDeviceId.substring(0, 6) + '...' : 'none');

            return res.json({
                success: true,
                message: '已解除裝置綁定，授權碼可在新裝置上重新激活',
                unbound: oldDeviceId ? oldDeviceId.substring(0, 6) + '...' : null
            });

        } catch (error) {
            console.error('[Admin/Unbind] 錯誤:', error);
            if (error.message.includes('授權系統不可用') || error.message.includes('KV')) {
                return res.status(503).json({
                    error: '授權系統暫時不可用',
                    message: error.message,
                    code: 'KV_UNAVAILABLE'
                });
            }
            return res.status(500).json({
                error: '操作失敗',
                message: error.message,
                code: 'ADMIN_OP_FAILED'
            });
        }
    });

    // Z) GET /api/admin/kv/diagnose - 只給管理員看的 KV 診斷（不回傳 token）
    app.get('/api/admin/kv/diagnose', async (req, res) => {
        const denied = requireAdminOr404(req, res);
        if (denied) return;

        const url = process.env.KV_REST_API_URL || '';
        const token = process.env.KV_REST_API_TOKEN || '';
        const urlLooksQuoted =
            (url.startsWith('\"') && url.endsWith('\"')) ||
            (url.startsWith('\'') && url.endsWith('\''));

        try {
            // 直接用 env 做一次 PING（不依賴 kvHealthCheckFailed）
            if (!url || !token) {
                return res.status(503).json({
                    ok: false,
                    code: 'KV_UNAVAILABLE',
                    message: 'KV_REST_API_URL 或 KV_REST_API_TOKEN 未設定',
                    urlPresent: !!url,
                    tokenPresent: !!token,
                    urlLooksQuoted
                });
            }
            const resp = await fetch(url, {
                method: 'POST',
                headers: {
                    Authorization: `Bearer ${token}`,
                    'Content-Type': 'application/json'
                },
                body: JSON.stringify(['PING'])
            });
            const text = await resp.text();
            return res.status(resp.ok ? 200 : 503).json({
                ok: resp.ok,
                code: resp.ok ? 'OK' : 'KV_UNAVAILABLE',
                status: resp.status,
                bodyPreview: text.slice(0, 300),
                urlPresent: true,
                tokenPresent: true,
                urlLooksQuoted
            });
        } catch (e) {
            return res.status(503).json({
                ok: false,
                code: 'KV_UNAVAILABLE',
                message: e && e.message ? e.message : String(e),
                urlPresent: !!url,
                tokenPresent: !!token,
                urlLooksQuoted
            });
        }
    });
}

// ========================
// Debug endpoints (僅本地/非 production)
// ========================
// /__debug/* 三道門：
// (1) NODE_ENV !== 'production'
// (2) ENABLE_DEBUG_ENDPOINTS === '1'
// (3) x-admin-key 正確
if (process.env.NODE_ENV !== 'production' && process.env.ENABLE_DEBUG_ENDPOINTS === '1' && process.env.ADMIN_KEY) {
    const adminKey = String(process.env.ADMIN_KEY);
    const requireAdminHeaderOr404 = (req, res) => {
        const headerKey = req.headers['x-admin-key'];
        if (!headerKey || String(headerKey) !== adminKey) {
            return res.status(404).send('Not Found');
        }
        return null;
    };

    // 列出所有 routes（用於驗證實際存在性，避免 404）
    app.get('/__debug/routes', (req, res) => {
        const denied = requireAdminHeaderOr404(req, res);
        if (denied) return;

        const routeIdByMethodPath = {
            'POST /api/auth/check': 'auth_check_v2',
            'POST /api/trial/consume': 'trial_consume_v2',
            'POST /api/license/activate': 'license_activate_v2'
        };
        const routes = [];
        const stack = (app && app._router && app._router.stack) ? app._router.stack : [];
        for (const layer of stack) {
            if (layer && layer.route && layer.route.path && layer.route.methods) {
                const methods = Object.keys(layer.route.methods)
                    .filter(k => layer.route.methods[k])
                    .map(k => k.toUpperCase())
                    .sort();
                for (const m of methods) {
                    const key = `${m} ${layer.route.path}`;
                    routes.push({ method: m, path: layer.route.path, routeId: routeIdByMethodPath[key] || null });
                }
            }
        }
        res.json(routes);
    });

    // 產生測試 license（僅非 production + 需 admin header；寫入 KV）
    app.post('/__debug/license/issue', async (req, res) => {
        const denied = requireAdminHeaderOr404(req, res);
        if (denied) return;

        try {
            requireKV();
            const crypto = require('crypto');
            // durationDays / expiresAt 可選：供驗收測試造出「年繳」「已到期」「舊永久」三種形狀
            const { planType, note, durationDays, expiresAt } = req.body || {};
            if (planType && planType !== 'annual' && planType !== 'lifetime') {
                return res.status(400).json({ error: '無效的 planType', code: 'BAD_REQUEST' });
            }
            const licenseKey = generateLicenseKey();
            const now = new Date().toISOString();
            await setLicense(licenseKey, {
                licenseKeyHash: crypto.createHash('sha256').update(licenseKey).digest('hex'),
                deviceId: null,
                boundDeviceId: null,
                paidAt: now,
                isValid: true,
                createdAt: now,
                activatedAt: null,
                planType: planType || 'annual',
                durationDays: typeof durationDays === 'number' ? durationDays : undefined,
                expiresAt: expiresAt || null,
                issuedBy: 'admin',
                note: note ? String(note).slice(0, 200) : null
            });
            console.log('✅ [__debug/license/issue] issued license:', licenseKey.substring(0, 8) + '...');
            return res.json({ licenseKey, createdAt: now, isValid: true });
        } catch (error) {
            console.error('❌ [__debug/license/issue] error:', error);
            if (error.message.includes('授權系統不可用') || error.message.includes('KV')) {
                return res.status(503).json({
                    error: '授權系統暫時不可用',
                    message: error.message,
                    code: 'KV_UNAVAILABLE'
                });
            }
            return res.status(500).json({ error: '服務器錯誤', message: error.message });
        }
    });
}

// Admin Console UI（三道門保護）
if (ENABLE_ADMIN_CONSOLE) {
    app.get('/admin', (req, res) => {
        const denied = requireAdminOr404(req, res);
        if (denied) return;
        
        const adminHtmlPath = path.join(publicDir, 'admin.html');
        res.sendFile(adminHtmlPath);
    });
}

// 必須比 express.static 早註冊，否則 public/admin.html 會被直接送出。
// Vercel 上 filesystem handle 更早於 server.js，vercel.json 另有 /admin.html → server.js。
app.get('/admin.html', (req, res) => {
    if (process.env.ENABLE_ADMIN_CONSOLE !== '1') {
        return res.status(404).send('Not Found');
    }
    res.sendFile(path.join(publicDir, 'admin.html'));
});

// 健康檢查
app.get('/api/health', (req, res) => {
    res.json({ status: 'ok', timestamp: new Date().toISOString() });
});

// 版本資訊（用於確認 Vercel 實際跑的是哪個 commit）
app.get('/api/version', (req, res) => {
    res.json({
        status: 'ok',
        commit: SERVER_COMMIT,
        entry: SERVER_ENTRY,
        vercelEnv: process.env.VERCEL_ENV || null,
        timestamp: new Date().toISOString()
    });
});

// 靜態文件服務（放在最後，作為 fallback）
app.use(express.static(path.join(__dirname, 'public')));
app.use('/locales', express.static(path.join(__dirname, 'locales')));
app.use('/downloads', express.static(path.join(__dirname, 'public', 'downloads')));

// 404 處理（放在最後）
app.use((req, res) => {
    console.log('❌ 404 - 未找到路由:', req.method, req.path);
    console.log('📂 __dirname:', __dirname);
    console.log('📂 publicDir:', publicDir);
    console.log('📂 paymentProcessDir:', paymentProcessDir);
    res.status(404).json({ 
        error: 'Not Found', 
        path: req.path,
        method: req.method,
        __dirname: __dirname
    });
});

// 僅在本地運行時啟動服務器
if (require.main === module) {
    app.listen(PORT, () => {
        console.log(`Server running on http://localhost:${PORT}`);
    });
}

// 導出給 Vercel 使用
module.exports = app;
