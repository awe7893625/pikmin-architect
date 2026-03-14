// Windows 版本的 GPS 模擬引擎
const { exec } = require('child_process');
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
        this.currentLat = 25.033;
        this.currentLon = 121.565;
        this.isRunning = false;
        this.timer = null;
        this._depInstaller = null;
    }

    // 注入 DependencyInstaller 實例（由 main.js 設定）
    setDependencyInstaller(installer) {
        this._depInstaller = installer;
    }

    // 取得 pymobiledevice3 執行指令
    _getCmd(args) {
        if (this._depInstaller) {
            return this._depInstaller.getCommand(args);
        }
        // fallback: 直接呼叫
        return `python -m pymobiledevice3 ${args}`;
    }

    // 檢測 iOS 設備
    async detectDevice() {
        try {
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
                    return {
                        success: true,
                        udid: this.udid,
                        deviceName: this.deviceName,
                        iosVersion: this.iosVersion
                    };
                }
            } catch (error) {
                // pymobiledevice3 不可用，嘗試其他方法
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
                error: '未偵測到 iOS 設備。\n\n請確認：\n1. iPhone/iPad 已用 USB 線連接\n2. 已安裝 iTunes 或 Apple Devices\n3. 設備已解鎖並信任此電腦'
            };
        } catch (error) {
            return { success: false, error: error.message };
        }
    }

    // 瞬移功能
    async teleport(lat, lon) {
        if (!this.udid) {
            const detectResult = await this.detectDevice();
            if (!detectResult.success) {
                return { success: false, error: detectResult.error };
            }
        }

        try {
            const cmd = this._getCmd(`developer dvt simulate-location set --udid ${this.udid} -- ${lat} ${lon}`);
            await execAsync(cmd, { timeout: 15000 });
            this.currentLat = lat;
            this.currentLon = lon;
            return { success: true };
        } catch (error) {
            return {
                success: false,
                error: `定位模擬失敗：${error.message}`
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
}

module.exports = LocationEngine;
