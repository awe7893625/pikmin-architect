// Windows 版本的 GPS 模擬引擎（含 tunnel 管理 — iOS 17+ 必要）
const { exec, spawn } = require('child_process');
const { promisify } = require('util');
const path = require('path');
const fs = require('fs');
const { app } = require('electron');
const execAsync = promisify(exec);

function getResourcesPath() {
    return app.isPackaged
        ? path.join(process.resourcesPath)
        : path.join(__dirname, '..');
}

class LocationEngine {
    constructor() {
        this.udid = null;
        this.deviceName = null;
        this.iosVersion = null;
        this.currentLat = 25.033;
        this.currentLon = 121.565;
        this.isRunning = false;
        this.timer = null;
        this._depInstaller = null;
        this.itunesInstalled = null; // cache
        this.tunnelRunning = false;
        this.tunnelLogPath = null; // 設定在第一次使用時
    }

    // 注入 DependencyInstaller 實例（由 main.js 設定）
    setDependencyInstaller(installer) {
        this._depInstaller = installer;
    }

    // 取得 tunnel log 路徑（lazy init）
    _getTunnelLogPath() {
        if (!this.tunnelLogPath) {
            this.tunnelLogPath = path.join(app.getPath('userData'), 'tunnel.log');
        }
        return this.tunnelLogPath;
    }

    // 取得 pymobiledevice3 執行指令
    _getCmd(args) {
        if (this._depInstaller) {
            return this._depInstaller.getCommand(args);
        }
        // fallback: 直接呼叫
        return `python -m pymobiledevice3 ${args}`;
    }

    // 取得 Python 路徑（從 DependencyInstaller）
    _getPythonPath() {
        if (this._depInstaller) {
            if (fs.existsSync(this._depInstaller.bundledExe)) {
                return this._depInstaller.bundledExe;
            }
            return this._depInstaller._pythonPath || this._depInstaller.pythonExe;
        }
        return 'python';
    }

    // 檢查 Apple USB 驅動是否可用（支援傳統 iTunes、MS Store iTunes、Apple Devices）
    async checkiTunes() {
        if (this.itunesInstalled !== null) return this.itunesInstalled;

        const checks = [
            // 方法 0（最可靠）: 直接嘗試 pymobiledevice3 usbmux list
            // 如果能執行就代表驅動存在，不管 iTunes 怎麼裝的
            async () => {
                try {
                    const cmd = this._getCmd('usbmux list');
                    await execAsync(cmd, { timeout: 10000 });
                    console.log('[iTunes 檢查] pymobiledevice3 usbmux 可用');
                    return true; // 能執行就代表驅動存在
                } catch (e) {
                    // 如果錯誤不是「找不到 usbmuxd」就算驅動存在
                    const errMsg = (e.stderr || e.message || '').toLowerCase();
                    if (errMsg.includes('usbmuxd') || errMsg.includes('no mux')) {
                        return false; // 確實沒驅動
                    }
                    // 其他錯誤（如沒有設備）代表驅動是好的
                    if (errMsg.includes('[]') || errMsg.includes('no device')) {
                        console.log('[iTunes 檢查] 驅動存在但無設備');
                        return true;
                    }
                    return false;
                }
            },
            // 方法 1: 檢查傳統 iTunes 服務
            async () => {
                try {
                    const { stdout } = await execAsync('sc query "Apple Mobile Device Service"', { timeout: 5000 });
                    return stdout.includes('RUNNING') || stdout.includes('STATE');
                } catch { return false; }
            },
            // 方法 2: 檢查 MS Store 版 Apple Devices / iTunes 服務
            async () => {
                try {
                    // MS Store 版使用不同的服務名稱
                    const { stdout } = await execAsync('sc query "AppleMobileDeviceService"', { timeout: 5000 });
                    return stdout.includes('RUNNING') || stdout.includes('STATE');
                } catch { return false; }
            },
            // 方法 3: 檢查安裝路徑（傳統 + MS Store + Apple Devices）
            async () => {
                const paths = [
                    'C:\\Program Files\\Common Files\\Apple\\Mobile Device Support',
                    'C:\\Program Files (x86)\\Common Files\\Apple\\Mobile Device Support',
                    'C:\\Program Files\\Common Files\\Apple\\Apple Application Support',
                    // MS Store 版本的 usbmuxd.exe 路徑
                    path.join(process.env.ProgramFiles || '', 'Common Files', 'Apple', 'Mobile Device Support', 'usbmuxd.exe'),
                ];
                return paths.some(p => fs.existsSync(p));
            },
            // 方法 4: 直接檢查 usbmuxd 進程是否運行（不管安裝方式）
            async () => {
                try {
                    const { stdout } = await execAsync('tasklist /FI "IMAGENAME eq usbmuxd.exe"', { timeout: 5000 });
                    return stdout.includes('usbmuxd');
                } catch { return false; }
            },
            // 方法 5: 檢查 Apple Mobile Device 相關進程（傳統 + MS Store）
            async () => {
                try {
                    const { stdout } = await execAsync('tasklist', { timeout: 5000 });
                    return stdout.includes('AppleMobileDeviceService') ||
                           stdout.includes('AppleMobileDevice') ||
                           stdout.includes('usbmuxd') ||
                           stdout.includes('AMPDevicesAgent');
                } catch { return false; }
            },
            // 方法 6: 嘗試 TCP 連接 usbmuxd 端口 27015
            async () => {
                return new Promise((resolve) => {
                    const net = require('net');
                    const sock = new net.Socket();
                    sock.setTimeout(3000);
                    sock.on('connect', () => { sock.destroy(); resolve(true); });
                    sock.on('error', () => { sock.destroy(); resolve(false); });
                    sock.on('timeout', () => { sock.destroy(); resolve(false); });
                    sock.connect(27015, '127.0.0.1');
                });
            }
        ];

        for (const check of checks) {
            if (await check()) {
                this.itunesInstalled = true;
                console.log('[iTunes 檢查] Apple USB 驅動已找到');
                return true;
            }
        }
        this.itunesInstalled = false;
        console.log('[iTunes 檢查] 未找到 Apple USB 驅動');
        return false;
    }

    // ===== 步驟 1: 檢測 iOS 設備 =====
    async detectDevice() {
        try {
            // 先檢查 iTunes 是否安裝
            const hasItunes = await this.checkiTunes();
            if (!hasItunes) {
                return {
                    success: false,
                    needsItunes: true,
                    error: '需要安裝 iTunes\n\n' +
                        'Windows 需要 iTunes 的 USB 驅動程式才能連接 iPhone。\n\n' +
                        '請安裝以下其中一個：\n' +
                        '• iTunes（Microsoft Store 或 apple.com/itunes）\n' +
                        '• Apple Devices（Microsoft Store 搜尋）\n\n' +
                        '安裝完成後重新啟動 KongGoo。'
                };
            }

            // 方法 1: 使用 pymobiledevice3 usbmux list（最可靠）
            try {
                const cmd = this._getCmd('usbmux list');
                const { stdout } = await execAsync(cmd, { timeout: 15000 });
                const devices = JSON.parse(stdout);
                const usbDevices = devices.filter(d => (d.ConnectionType || '').toUpperCase() === 'USB');
                if (usbDevices.length > 0) {
                    const dev = usbDevices[0];
                    this.udid = dev.Identifier || dev.UniqueDeviceID;
                    this.deviceName = dev.DeviceName || 'iPhone';
                    this.iosVersion = dev.ProductVersion || '';
                    console.log(`[detectDevice] 找到設備: ${this.deviceName} (iOS ${this.iosVersion}) UDID: ${this.udid}`);
                    return {
                        success: true,
                        udid: this.udid,
                        deviceName: this.deviceName,
                        iosVersion: this.iosVersion
                    };
                }
            } catch (error) {
                console.log('[detectDevice] pymobiledevice3 usbmux list 失敗:', error.message);
            }

            // 方法 2: 使用 idevice_id (libimobiledevice)
            try {
                const { stdout } = await execAsync('idevice_id -l', { timeout: 10000 });
                const udids = stdout.trim().split('\n').filter(id => id);
                if (udids.length > 0) {
                    this.udid = udids[0].trim();
                    return { success: true, udid: this.udid };
                }
            } catch (error) {
                // idevice_id 不存在
            }

            return {
                success: false,
                error: '未偵測到 iOS 設備。\n\n請確認：\n1. iPhone/iPad 已用 USB 線連接\n2. 設備已解鎖並信任此電腦'
            };
        } catch (error) {
            return { success: false, error: error.message };
        }
    }

    // ===== 步驟 1.5: 啟用開發者模式 =====
    async enableDeveloperMode() {
        if (!this.udid) {
            return { success: false, error: '尚未連接設備' };
        }

        try {
            console.log('[amfi] 嘗試啟用開發者模式...');
            const cmd = this._getCmd(`amfi enable-developer-mode --udid ${this.udid}`);
            const { stdout, stderr } = await execAsync(cmd, { timeout: 30000 });
            const output = (stdout + ' ' + stderr).toLowerCase();
            console.log('[amfi] 結果:', stdout.substring(0, 300));

            if (output.includes('success') || output.includes('already') || stdout.trim() === '') {
                return { success: true, message: '開發者模式已啟用' };
            } else if (output.includes('error') || output.includes('failed')) {
                return {
                    success: false,
                    needsTutorial: true,
                    error: '無法自動啟用開發者模式，請依教學手動啟用'
                };
            }
            // 其他情況當作成功（有些版本不回傳文字）
            return { success: true, message: '開發者模式指令已執行' };
        } catch (error) {
            console.log('[amfi] 錯誤:', error.message);
            return {
                success: false,
                needsTutorial: true,
                error: `開發者模式啟用失敗：${error.message}`
            };
        }
    }

    // ===== 步驟 2: 檢查隧道是否運行中 =====
    async isTunnelRunning() {
        // 方法 1: 檢查是否有 pymobiledevice3 tunneld 進程
        try {
            const { stdout } = await execAsync(
                'wmic process where "name=\'python.exe\' or name=\'python3.exe\' or name=\'pymobiledevice3.exe\'" get CommandLine /format:list',
                { timeout: 8000 }
            );
            if (stdout.includes('tunneld')) {
                this.tunnelRunning = true;
                return true;
            }
        } catch (e) {
            // wmic 可能不可用，嘗試 PowerShell
            try {
                const { stdout } = await execAsync(
                    'powershell -Command "Get-Process python*,pymobiledevice3 -ErrorAction SilentlyContinue | Select-Object -ExpandProperty CommandLine"',
                    { timeout: 8000 }
                );
                if (stdout.includes('tunneld')) {
                    this.tunnelRunning = true;
                    return true;
                }
            } catch (e2) { /* 繼續 */ }
        }

        // 方法 2: 檢查隧道端口 49151
        try {
            const { stdout } = await execAsync('netstat -an | findstr "49151"', { timeout: 5000 });
            if (stdout.includes('LISTENING')) {
                this.tunnelRunning = true;
                return true;
            }
        } catch (e) { /* 端口未監聽 */ }

        // 方法 3: 檢查日誌檔
        try {
            const logPath = this._getTunnelLogPath();
            if (fs.existsSync(logPath)) {
                const log = fs.readFileSync(logPath, 'utf8');
                if (log.includes('Uvicorn running') || log.includes('Created tunnel') || log.includes('Application startup')) {
                    this.tunnelRunning = true;
                    return true;
                }
            }
        } catch (e) { /* 沒有日誌 */ }

        this.tunnelRunning = false;
        return false;
    }

    // ===== 步驟 2b: 啟動隧道（需要管理員權限） =====
    async startTunnel(onProgress) {
        // 先檢查是否已在運行
        if (await this.isTunnelRunning()) {
            console.log('[tunnel] 隧道已在運行');
            return { success: true, alreadyRunning: true };
        }

        if (onProgress) onProgress('正在啟動隧道（需要管理員權限）...');
        console.log('[tunnel] 開始啟動隧道...');

        const logPath = this._getTunnelLogPath();

        // 清除舊日誌
        try { fs.unlinkSync(logPath); } catch (e) { /* 沒有舊日誌 */ }

        // 取得 Python/pymobiledevice3 路徑
        const pythonPath = this._getPythonPath();
        const isBundledExe = this._depInstaller && fs.existsSync(this._depInstaller.bundledExe);

        // 建立啟動批次檔（用於管理員提權執行）
        const batchPath = path.join(app.getPath('userData'), 'start-tunnel.bat');
        let batchContent;

        if (isBundledExe) {
            batchContent = `@echo off\r\n"${pythonPath}" remote tunneld > "${logPath}" 2>&1\r\n`;
        } else {
            batchContent = `@echo off\r\n"${pythonPath}" -m pymobiledevice3 remote tunneld > "${logPath}" 2>&1\r\n`;
        }

        fs.writeFileSync(batchPath, batchContent);
        console.log('[tunnel] 批次檔已建立:', batchPath);

        // 用 PowerShell 提權執行（會顯示 UAC 對話框）
        try {
            await execAsync(
                `powershell -Command "Start-Process -Verb RunAs -FilePath '${batchPath}' -WindowStyle Hidden"`,
                { timeout: 30000 }
            );
            console.log('[tunnel] UAC 已通過，等待隧道啟動...');
        } catch (error) {
            console.error('[tunnel] UAC 被拒絕或失敗:', error.message);
            return {
                success: false,
                error: '需要管理員權限才能啟動隧道。\n請在彈出的 UAC 視窗中點擊「是」。'
            };
        }

        // 等待隧道就緒（最多等 45 秒）
        if (onProgress) onProgress('等待隧道啟動...');
        const maxChecks = 90; // 90 x 500ms = 45s
        for (let i = 0; i < maxChecks; i++) {
            await this._sleep(500);

            // 檢查隧道是否就緒
            if (await this.isTunnelRunning()) {
                console.log(`[tunnel] 隧道就緒（第 ${i + 1} 次檢查）`);
                if (onProgress) onProgress('隧道已啟動');
                // 多等 2 秒讓 USB 設備被隧道發現
                await this._sleep(2000);
                return { success: true };
            }

            // 檢查日誌是否有錯誤
            try {
                if (fs.existsSync(logPath)) {
                    const log = fs.readFileSync(logPath, 'utf8');
                    if (log.includes('Address already in use')) {
                        console.log('[tunnel] 端口被佔用，可能已有隧道在運行');
                        this.tunnelRunning = true;
                        return { success: true };
                    }
                    if (log.includes('No module named')) {
                        return { success: false, error: 'pymobiledevice3 未正確安裝' };
                    }
                    // 進度更新
                    if (i % 10 === 0 && i > 0 && onProgress) {
                        onProgress(`隧道啟動中... (${Math.round(i * 500 / 1000)}秒)`);
                    }
                }
            } catch (e) { /* 讀不到日誌，繼續等 */ }

            // 超過 15 秒還沒啟動，檢查進程是否存在
            if (i > 30) {
                try {
                    const { stdout } = await execAsync('tasklist | findstr "python"', { timeout: 3000 });
                    if (!stdout.includes('python')) {
                        console.log('[tunnel] Python 進程不存在，隧道可能啟動失敗');
                        break;
                    }
                } catch (e) { /* 繼續等 */ }
            }
        }

        // 超時
        let errorMsg = '隧道啟動逾時';
        try {
            if (fs.existsSync(logPath)) {
                const log = fs.readFileSync(logPath, 'utf8');
                if (log.includes('developer') || log.includes('Developer') || log.includes('AMFI')) {
                    errorMsg = '請先在 iPhone 設定中啟用開發者模式';
                } else if (log.includes('No device')) {
                    errorMsg = '隧道找不到設備，請確認 USB 連接';
                } else if (log.length > 0) {
                    // 取最後幾行
                    const lines = log.trim().split('\n');
                    errorMsg = `隧道啟動失敗：${lines[lines.length - 1].substring(0, 100)}`;
                }
            }
        } catch (e) { /* 用預設錯誤訊息 */ }

        return { success: false, error: errorMsg };
    }

    // ===== 完整連線流程：detect → amfi → tunnel → ready =====
    async fullConnect(onProgress) {
        // Step 1: 偵測設備
        if (onProgress) onProgress('正在偵測設備...');
        const detectResult = await this.detectDevice();
        if (!detectResult.success) {
            return detectResult;
        }
        if (onProgress) onProgress(`找到 ${detectResult.deviceName || 'iPhone'}...`);

        // 判斷 iOS 版本是否需要隧道
        const iosVer = parseFloat(this.iosVersion) || 0;
        const needsTunnel = iosVer >= 17 || iosVer === 0; // 版本不明時也嘗試

        // Step 1.5: 啟用開發者模式
        if (onProgress) onProgress('正在啟用開發者模式...');
        const amfiResult = await this.enableDeveloperMode();
        console.log('[fullConnect] amfi 結果:', amfiResult);
        // 不管成功失敗都繼續（可能已經啟用了）

        // Step 2: 啟動隧道（iOS 17+ 必要）
        if (needsTunnel) {
            if (await this.isTunnelRunning()) {
                console.log('[fullConnect] 隧道已在運行，跳過啟動');
                if (onProgress) onProgress('隧道已運行');
            } else {
                if (onProgress) onProgress('正在啟動安全隧道（需要管理員權限）...');
                const tunnelResult = await this.startTunnel(onProgress);
                if (!tunnelResult.success) {
                    return {
                        success: false,
                        deviceDetected: true,
                        needsTutorial: amfiResult.needsTutorial || false,
                        error: tunnelResult.error
                    };
                }
            }
        }

        // Step 3: 確認一切就緒
        if (onProgress) onProgress('連線就緒');
        return {
            success: true,
            udid: this.udid,
            deviceName: this.deviceName,
            iosVersion: this.iosVersion,
            tunnelActive: needsTunnel,
            amfiResult: amfiResult.success ? 'ok' : 'manual'
        };
    }

    // 瞬移功能
    async teleport(lat, lon) {
        if (!this.udid) {
            const detectResult = await this.detectDevice();
            if (!detectResult.success) {
                return { success: false, error: detectResult.error };
            }
        }

        // 確保隧道運行中（iOS 17+ 必要）
        const iosVer = parseFloat(this.iosVersion) || 0;
        if ((iosVer >= 17 || iosVer === 0) && !this.tunnelRunning) {
            const tunnelOk = await this.isTunnelRunning();
            if (!tunnelOk) {
                return {
                    success: false,
                    error: '隧道未啟動。請先點擊「重新連線」按鈕建立連線。'
                };
            }
        }

        try {
            const cmd = this._getCmd(`developer dvt simulate-location set --udid ${this.udid} -- ${lat} ${lon}`);
            console.log('[teleport] 執行:', cmd);
            await execAsync(cmd, { timeout: 15000 });
            this.currentLat = lat;
            this.currentLon = lon;
            return { success: true };
        } catch (error) {
            const errMsg = error.message || '';
            // 如果是隧道問題，給出更明確的提示
            if (errMsg.includes('tunnel') || errMsg.includes('RemoteXPC') || errMsg.includes('connection refused')) {
                this.tunnelRunning = false;
                return {
                    success: false,
                    error: '隧道連線已中斷，請點擊「重新連線」按鈕重新建立連線。'
                };
            }
            return {
                success: false,
                error: `定位模擬失敗：${errMsg}`
            };
        }
    }

    // 開始路線模擬
    async startRoute(points, speed = 18.0) {
        if (!this.udid) {
            const detectResult = await this.detectDevice();
            if (!detectResult.success) {
                return { success: false, error: detectResult.error };
            }
        }

        if (points.length < 2) {
            return { success: false, error: '路線至少需要 2 個點' };
        }

        this.isRunning = true;
        this.routePoints = points;
        this.currentRouteIndex = 0;
        this.speed = speed;

        this.moveAlongRoute();
        return { success: true };
    }

    // 沿路線移動
    async moveAlongRoute() {
        if (!this.isRunning || this.currentRouteIndex >= this.routePoints.length - 1) {
            this.stop();
            return;
        }

        const current = this.routePoints[this.currentRouteIndex];
        const next = this.routePoints[this.currentRouteIndex + 1];

        const distance = this.calculateDistance(current[0], current[1], next[0], next[1]);
        const timeMs = (distance / this.speed) * 3600000;

        await this.teleport(next[0], next[1]);
        this.currentRouteIndex++;

        if (this.isRunning) {
            this.timer = setTimeout(() => this.moveAlongRoute(), Math.max(100, timeMs));
        }
    }

    // 計算兩點間距離（公里）
    calculateDistance(lat1, lon1, lat2, lon2) {
        const R = 6371;
        const dLat = (lat2 - lat1) * Math.PI / 180;
        const dLon = (lon2 - lon1) * Math.PI / 180;
        const a = Math.sin(dLat / 2) * Math.sin(dLat / 2) +
                  Math.cos(lat1 * Math.PI / 180) * Math.cos(lat2 * Math.PI / 180) *
                  Math.sin(dLon / 2) * Math.sin(dLon / 2);
        const c = 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
        return R * c;
    }

    stop() {
        this.isRunning = false;
        if (this.timer) {
            clearTimeout(this.timer);
            this.timer = null;
        }
    }

    getCurrentLocation() {
        return { lat: this.currentLat, lon: this.currentLon };
    }

    // 工具方法：sleep
    _sleep(ms) {
        return new Promise(resolve => setTimeout(resolve, ms));
    }
}

module.exports = LocationEngine;
