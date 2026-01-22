const express = require('express');
const path = require('path');
const fs = require('fs');
const cors = require('cors');
const { execSync } = require('child_process');
const app = express();
const PORT = process.env.PORT || 3001;

// 中間件
app.use(cors());
// 需要保留 raw body 以驗證 Polar webhook 簽名
app.use(
    express.json({
        verify: (req, _res, buf) => {
            req.rawBody = buf;
        }
    })
);

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

// 付款成功頁面
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
                activatedAt: device?.activatedAt || license.activatedAt
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
            message: '授權碼激活成功，設備已永久激活',
            licenseKey: licenseKey,
            isActivated: true,
            trialExpiresAt: device.trialExpiresAt || null,
            activatedAt: device.activatedAt
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
        return res.json({
            valid: true,
            planType: license.planType || 'annual',
            download: {
                mac: '/downloads/ios-location-simulator-mac.dmg',
                windows: '/downloads/ios-location-simulator-windows.exe'
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

// 5. 創建付款訂單（不生成授權碼，等待付款成功）
app.post('/api/payment/create', async (req, res) => {
    const { planType } = req.body;
    
    if (!planType || (planType !== 'annual' && planType !== 'lifetime')) {
        return res.status(400).json({ error: '無效的方案類型', code: 'BAD_REQUEST' });
    }
    
    // 定義價格
    const prices = {
        annual: 690,
        lifetime: 1750
    };
    
    const amount = prices[planType];
    
    // 生成訂單 ID
    const crypto = require('crypto');
    const orderId = 'ORD-' + Date.now() + '-' + crypto.randomBytes(4).toString('hex').toUpperCase();
    
    // 創建訂單（狀態為 pending，未付款）並保存到持久化存儲
    const orderData = {
        planType: planType,
        amount: amount,
        status: 'pending', // pending, paid, cancelled
        licenseKey: null, // 付款成功後才生成
        createdAt: new Date().toISOString(),
        paidAt: null
    };
    try {
        await setOrder(orderId, orderData);
    } catch (error) {
        console.error('❌ [付款建立] 訂單保存失敗:', error);
        if (error.message.includes('授權系統不可用') || error.message.includes('KV')) {
            return res.status(503).json({
                error: '授權系統暫時不可用',
                message: error.message,
                code: 'KV_UNAVAILABLE'
            });
        }
        return res.status(500).json({ error: 'Internal Server Error', message: error.message });
    }
    
    // 檢查是否有 Polar 金流設定
    const POLAR_ACCESS_TOKEN = process.env.POLAR_ACCESS_TOKEN;
    // 兼容舊命名：你可能存的是「價格 ID」或「產品 ID」。
    // - 若你有產品 ID，請優先用 POLAR_PRODUCT_ID_ANNUAL / POLAR_PRODUCT_ID_LIFETIME
    // - 若你只有價格 ID，仍可填 POLAR_PRODUCT_PRICE_ID_*，伺服器會嘗試從 Polar 產品清單反查對應的產品 ID
    const POLAR_PRODUCT_ID_ANNUAL = process.env.POLAR_PRODUCT_ID_ANNUAL || '';
    const POLAR_PRODUCT_ID_LIFETIME = process.env.POLAR_PRODUCT_ID_LIFETIME || '';
    const POLAR_PRODUCT_PRICE_ID_ANNUAL = process.env.POLAR_PRODUCT_PRICE_ID_ANNUAL || '3c450333-7ba3-4d6a-a93a-b4cb0a9b8aa2';
    const POLAR_PRODUCT_PRICE_ID_LIFETIME = process.env.POLAR_PRODUCT_PRICE_ID_LIFETIME || '4e7ccc7a-c4ef-4f55-b296-5c0f81d0af60';
    
    if (POLAR_ACCESS_TOKEN) {
        // 有 Polar 設定，使用 Polar 金流
        try {
            const { Polar } = require('@polar-sh/sdk');
            const polar = new Polar({
                accessToken: POLAR_ACCESS_TOKEN
            });
            
            // Polar JS SDK 的 checkouts.create 需要 products: string[]（產品 ID）
            async function resolveProductIdFromPriceId(priceId) {
                // 嘗試從 Polar 產品清單反查：找到某個 product.prices[].id === priceId 的 product.id
                const listResult = await polar.products.list({});
                for await (const page of listResult) {
                    const items =
                        (page && page.result && Array.isArray(page.result.items) ? page.result.items : null) ||
                        (page && Array.isArray(page.items) ? page.items : null) ||
                        (page && Array.isArray(page.products) ? page.products : null) ||
                        (Array.isArray(page) ? page : []);
                    for (const prod of items) {
                        const prices = prod && Array.isArray(prod.prices) ? prod.prices : [];
                        if (prices.find(p => p && p.id === priceId)) {
                            return prod.id;
                        }
                    }
                }
                return null;
            }

            const configuredProductId =
                planType === 'annual' ? POLAR_PRODUCT_ID_ANNUAL : POLAR_PRODUCT_ID_LIFETIME;
            const configuredPriceId =
                planType === 'annual' ? POLAR_PRODUCT_PRICE_ID_ANNUAL : POLAR_PRODUCT_PRICE_ID_LIFETIME;

            const productId = configuredProductId
                ? configuredProductId
                : (await resolveProductIdFromPriceId(configuredPriceId));
            if (!productId) {
                throw new Error(
                    `找不到對應的 Polar 產品（請在 Vercel 設定 POLAR_PRODUCT_ID_${planType === 'annual' ? 'ANNUAL' : 'LIFETIME'}，或確認 POLAR_PRODUCT_PRICE_ID_* 是否正確）`
                );
            }
            
            // 創建 Polar checkout session
            const baseUrl = process.env.SUCCESS_URL || 'https://konggoo.vercel.app';
            const checkoutSession = await polar.checkouts.create({
                products: [productId],
                successUrl: `${baseUrl}/payment/success?orderId=${orderId}`,
                cancelUrl: `${baseUrl}/payment?cancelled=1`,
                metadata: {
                    orderId: orderId,
                    planType: planType
                }
            });
            const checkoutUrl =
                checkoutSession && (checkoutSession.url || checkoutSession.checkout_url || checkoutSession.checkoutUrl);
            if (!checkoutUrl) {
                throw new Error('Polar checkout create succeeded but no checkout URL returned');
            }
            res.json({
                success: true,
                orderId: orderId,
                paymentUrl: checkoutUrl,
                message: '訂單已創建，請前往付款'
            });
        } catch (error) {
            console.error('❌ Polar 金流錯誤:', error);
            // production：不允許回退到模擬付款（避免繞過）
            if (isProd && !ALLOW_MOCK_PAYMENT) {
                // 僅在管理員帶正確 x-admin-key 時回傳除錯資訊（避免洩漏）
                const adminHeaderKey = req.headers['x-admin-key'];
                const isAdminDebug =
                    process.env.ENABLE_ADMIN_CONSOLE === '1' &&
                    process.env.ADMIN_KEY &&
                    adminHeaderKey &&
                    String(adminHeaderKey) === String(process.env.ADMIN_KEY);
                const debug = isAdminDebug
                    ? {
                          debugName: error && error.name ? error.name : null,
                          debugMessage: error && error.message ? error.message : String(error)
                      }
                    : {};
                return res.status(502).json({
                    success: false,
                    error: '金流暫時不可用，請稍後再試',
                    code: 'POLAR_FAILED',
                    ...debug
                });
            }
            // 非 production（或明確允許）：回退到模擬付款
            return res.json({
                success: true,
                orderId: orderId,
                paymentUrl: `/payment/process?orderId=${orderId}`,
                message: '訂單已創建，請前往付款（模擬模式）'
            });
        }
    } else {
        // production：必須設定 Polar，否則視為未上線
        if (isProd && !ALLOW_MOCK_PAYMENT) {
            console.error('❌ 未設定 Polar 金流（production 禁止模擬付款）');
            return res.status(500).json({
                success: false,
                error: '金流尚未設定完成，請聯絡管理員',
                code: 'PAYMENT_NOT_CONFIGURED'
            });
        }
        // 非 production（或明確允許）：模擬付款流程（僅用於測試）
        console.warn('⚠️ 警告：未設定 Polar 金流，使用模擬付款流程（僅用於測試）');
        return res.json({
            success: true,
            orderId: orderId,
            paymentUrl: `/payment/process?orderId=${orderId}`, // 模擬付款頁面
            message: '訂單已創建，請前往付款（測試模式）'
        });
    }
});

// 5.1. Polar 付款回調 webhook
app.post('/api/payment/polar-webhook', async (req, res) => {
    // Polar 會發送 webhook 通知付款狀態
    try {
        // 驗證 webhook（建議 production 必開）
        const secret = process.env.POLAR_WEBHOOK_SECRET || '';
        if (!secret) {
            console.warn('⚠️ [Polar webhook] POLAR_WEBHOOK_SECRET 未設定，拒絕處理（避免偽造）');
            return res.status(503).json({ error: 'Webhook not configured', code: 'WEBHOOK_NOT_CONFIGURED' });
        }

        const { validateEvent, WebhookVerificationError } = require('@polar-sh/sdk/webhooks');
        const raw = req.rawBody || Buffer.from(JSON.stringify(req.body || {}));
        let evt;
        try {
            evt = validateEvent(raw, req.headers, secret);
        } catch (e) {
            if (e instanceof WebhookVerificationError) {
                console.warn('⚠️ [Polar webhook] 簽名驗證失敗');
                return res.status(403).send('Forbidden');
            }
            throw e;
        }

        const event = evt.type;
        const data = evt.data;
        console.log('📥 Polar webhook 收到:', event);
        
        if (event === 'checkout.succeeded') {
            const orderId = data.metadata?.orderId;
            
            if (orderId) {
                const order = await getOrderFromKV(orderId);
                
                if (order) {
                    // 生成授權碼
                    const crypto = require('crypto');
                    const licenseKey = 'PKM-' + crypto.randomBytes(8).toString('hex').toUpperCase();
                    
                    // 更新訂單狀態
                    order.status = 'paid';
                    order.licenseKey = licenseKey;
                    order.paidAt = new Date().toISOString();
                    await setOrder(orderId, order);
                    
                    // 將授權碼添加到持久化存儲
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
                    
                    console.log('✅ Polar 付款成功，授權碼已生成並保存到持久化存儲:', licenseKey);
                }
            }
        }
        
        res.json({ received: true });
    } catch (error) {
        console.error('❌ Polar webhook 錯誤:', error);
        res.status(500).json({ error: 'Webhook processing failed' });
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
    const licenseKey = 'PKM-' + crypto.randomBytes(8).toString('hex').toUpperCase();
    
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
    const licenseKey = 'PKM-' + crypto.randomBytes(8).toString('hex').toUpperCase();
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

    // 優先：從 public/downloads 直接提供（簡單直接，讓 Vercel filesystem 處理）
    const publicDownloadsPath = path.join(__dirname, 'public', 'downloads', file);
    if (fs.existsSync(publicDownloadsPath)) {
        // 檢查檔案大小，避免提供 Git LFS 指標檔（通常 < 200 bytes）
        const stats = fs.statSync(publicDownloadsPath);
        if (stats.size < 200) {
            console.log(`⚠️ [下載] 檔案太小（${stats.size} bytes），可能是 LFS 指標檔，嘗試代理下載`);
            // 繼續執行，嘗試代理下載
        } else {
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
            res.setHeader('Cache-Control', 'public, max-age=3600'); // 允許快取 1 小時
            res.setHeader('Pragma', 'public');
            
            return res.sendFile(publicDownloadsPath);
        }
    }

    // 備用：如果環境變數有設定，代理下載（不讓使用者看到 GitHub）
    if (file === 'ios-location-simulator-mac.dmg' && process.env.MAC_DMG_URL) {
        const downloadUrl = process.env.MAC_DMG_URL;
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
            if (proxyRes.statusCode !== 200) {
                console.log(`⚠️ [下載] GitHub 回傳 ${proxyRes.statusCode}`);
                return res.status(proxyRes.statusCode).json({ error: '下載失敗', code: 'DOWNLOAD_FAILED' });
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
            res.status(500).json({ error: '下載失敗', code: 'DOWNLOAD_PROXY_ERROR' });
        });
        
        return;
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
            const licenseKey = 'PKM-' + crypto.randomBytes(8).toString('hex').toUpperCase();
            const now = new Date().toISOString();
            
            const licenseData = {
                licenseKeyHash: crypto.createHash('sha256').update(licenseKey).digest('hex'),
                planType: planType,
                createdAt: now,
                issuedBy: 'admin',
                note: note ? String(note).slice(0, 200) : null,
                boundDeviceId: null,
                activatedAt: null,
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
            const { planType, note } = req.body || {};
            if (planType && planType !== 'annual' && planType !== 'lifetime') {
                return res.status(400).json({ error: '無效的 planType', code: 'BAD_REQUEST' });
            }
            const licenseKey = 'PKM-' + crypto.randomBytes(8).toString('hex').toUpperCase(); // 16 hex uppercase
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

// 健康檢查
app.get('/api/health', (req, res) => {
    res.json({ status: 'ok', timestamp: new Date().toISOString() });
});

// 靜態文件服務（放在最後，作為 fallback）
app.use(express.static('public'));
app.use('/locales', express.static('locales'));
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
