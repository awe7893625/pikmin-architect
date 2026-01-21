// Windows 版本的 GPS 模擬引擎
const { exec } = require('child_process');
const { promisify } = require('util');
const execAsync = promisify(exec);

class LocationEngine {
    constructor() {
        this.udid = null;
        this.currentLat = 25.033;
        this.currentLon = 121.565;
        this.isRunning = false;
        this.timer = null;
    }

    // 檢測 iOS 設備
    async detectDevice() {
        try {
            // Windows 上使用 libimobiledevice 或 usbmuxd
            // 需要先安裝：https://github.com/libimobiledevice-win32/libimobiledevice-win32
            
            // 方法 1: 使用 idevice_id (libimobiledevice)
            try {
                const { stdout } = await execAsync('idevice_id -l');
                const udids = stdout.trim().split('\n').filter(id => id);
                if (udids.length > 0) {
                    this.udid = udids[0];
                    return { success: true, udid: this.udid };
                }
            } catch (error) {
                // 如果 idevice_id 不存在，嘗試其他方法
            }

            // 方法 2: 使用 usbmuxd (如果已安裝)
            try {
                const { stdout } = await execAsync('usbmuxd --list-devices');
                // 解析輸出獲取 UDID
                const match = stdout.match(/UDID:\s*([A-Z0-9-]+)/i);
                if (match) {
                    this.udid = match[1];
                    return { success: true, udid: this.udid };
                }
            } catch (error) {
                // usbmuxd 不存在
            }

            return { success: false, error: '未檢測到 iOS 設備。請確保：\n1. 設備已通過 USB 連接\n2. 已安裝 iTunes 或 Apple Mobile Device Support\n3. 已安裝 libimobiledevice-win32' };
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
            // 使用 libimobiledevice 的 Windows 版本
            // 需要安裝：https://github.com/libimobiledevice-win32/libimobiledevice-win32
            
            // 方法 1: 使用 idevicesetlocation (如果可用)
            try {
                await execAsync(`idevicesetlocation ${this.udid} ${lat} ${lon}`);
                this.currentLat = lat;
                this.currentLon = lon;
                return { success: true };
            } catch (error) {
                // 如果 idevicesetlocation 不存在，使用 pymobiledevice3
            }

            // 方法 2: 使用內建的可執行檔（如果已打包）
            try {
                const resourcesPath = getResourcesPath();
                const pymobiledevice3Exe = path.join(resourcesPath, 'bin', 'pymobiledevice3.exe');
                
                // 檢查內建可執行檔是否存在
                if (fs.existsSync(pymobiledevice3Exe)) {
                    await execAsync(`"${pymobiledevice3Exe}" developer dvt simulate-location set --tunnel ${this.udid} -- ${lat} ${lon}`);
                    this.currentLat = lat;
                    this.currentLon = lon;
                    return { success: true };
                }
            } catch (error) {
                // 內建可執行檔不存在或失敗，繼續嘗試其他方法
            }

            // 方法 3: 使用系統 Python（需要用戶安裝）
            try {
                // 先檢查 Python 是否可用
                await execAsync('python --version');
                
                // 檢查 pymobiledevice3 是否已安裝
                try {
                    await execAsync('python -m pymobiledevice3 --version');
                } catch (e) {
                    // pymobiledevice3 未安裝，返回需要安裝的提示
                    return {
                        success: false,
                        error: 'pymobiledevice3 未安裝',
                        needsPymobiledevice3: true,
                        installCommand: 'python -m pip install pymobiledevice3'
                    };
                }
                
                await execAsync(`python -m pymobiledevice3 developer dvt simulate-location set --tunnel ${this.udid} -- ${lat} ${lon}`);
                this.currentLat = lat;
                this.currentLon = lon;
                return { success: true };
            } catch (error) {
                return {
                    success: false,
                    error: `GPS 模擬失敗：${error.message}`,
                    needsPython: true,
                    installGuide: '請安裝 Python 3.8 或更高版本，然後執行：pip install pymobiledevice3'
                };
            }
        } catch (error) {
            return { success: false, error: error.message };
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
        this.speed = speed; // km/h

        // 開始移動
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

        // 計算距離和移動時間
        const distance = this.calculateDistance(current[0], current[1], next[0], next[1]);
        const timeMs = (distance / this.speed) * 3600000; // 轉換為毫秒

        // 移動到下一點
        await this.teleport(next[0], next[1]);
        this.currentRouteIndex++;

        // 繼續下一段
        if (this.isRunning) {
            this.timer = setTimeout(() => this.moveAlongRoute(), Math.max(100, timeMs));
        }
    }

    // 計算兩點間距離（公里）
    calculateDistance(lat1, lon1, lat2, lon2) {
        const R = 6371; // 地球半徑（公里）
        const dLat = (lat2 - lat1) * Math.PI / 180;
        const dLon = (lon2 - lon1) * Math.PI / 180;
        const a = Math.sin(dLat / 2) * Math.sin(dLat / 2) +
                  Math.cos(lat1 * Math.PI / 180) * Math.cos(lat2 * Math.PI / 180) *
                  Math.sin(dLon / 2) * Math.sin(dLon / 2);
        const c = 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
        return R * c;
    }

    // 停止移動
    stop() {
        this.isRunning = false;
        if (this.timer) {
            clearTimeout(this.timer);
            this.timer = null;
        }
    }

    // 獲取當前位置
    getCurrentLocation() {
        return {
            lat: this.currentLat,
            lon: this.currentLon
        };
    }
}

module.exports = LocationEngine;
