// Windows 版本的授權管理器
const axios = require('axios');

class AuthManager {
    constructor() {
        this.apiBaseURL = process.env.AUTH_SERVER_URL || 'https://pikmin-auth-server.vercel.app/api';
        this.deviceId = null;
        this.authStatus = 'unauthorized';
        this.remainingTrial = 3;
        this.isAuthorized = false;
        this.licenseKey = '';
    }

    // 獲取設備 ID
    async getDeviceId() {
        if (this.deviceId) {
            return this.deviceId;
        }

        const { exec } = require('child_process');
        const { promisify } = require('util');
        const execAsync = promisify(exec);

        try {
            // Windows 設備 ID：使用機器 UUID
            const { stdout } = await execAsync('wmic csproduct get uuid');
            const uuid = stdout.split('\n')[1].trim();
            this.deviceId = 'windows-' + uuid;
        } catch (error) {
            // 備用方案：使用機器名稱
            try {
                const { stdout } = await execAsync('hostname');
                this.deviceId = 'windows-' + stdout.trim() + '-' + Date.now();
            } catch (err) {
                this.deviceId = 'windows-' + Date.now();
            }
        }

        return this.deviceId;
    }

    // 註冊設備
    async registerDevice() {
        const deviceId = await this.getDeviceId();
        
        try {
            const response = await axios.post(`${this.apiBaseURL}/device/register`, {
                deviceId: deviceId,
                deviceInfo: {
                    platform: 'windows',
                    os: process.platform
                }
            });

            this.remainingTrial = response.data.remainingTrial || 3;
            this.isAuthorized = response.data.isPaid || false;
            
            return { success: true, data: response.data };
        } catch (error) {
            return { success: false, error: error.message };
        }
    }

    // 檢查授權狀態
    async checkAuth() {
        const deviceId = await this.getDeviceId();
        
        try {
            const response = await axios.post(`${this.apiBaseURL}/auth/check`, {
                deviceId: deviceId,
                licenseKey: this.licenseKey || undefined
            });

            if (response.data.authorized) {
                if (response.data.isPaid) {
                    this.authStatus = 'authorized';
                    this.isAuthorized = true;
                } else if (response.data.isTrial) {
                    this.authStatus = 'trial';
                    this.remainingTrial = response.data.remainingTrial || 0;
                    this.isAuthorized = true;
                }
            } else {
                this.authStatus = 'expired';
                this.isAuthorized = false;
            }

            return { success: true, data: response.data };
        } catch (error) {
            this.authStatus = 'unauthorized';
            return { success: false, error: error.message };
        }
    }

    // 使用試用次數
    async useTrial() {
        const deviceId = await this.getDeviceId();
        
        try {
            const response = await axios.post(`${this.apiBaseURL}/trial/use`, {
                deviceId: deviceId
            });

            if (response.data.success) {
                this.remainingTrial = response.data.remainingTrial || 0;
                if (this.remainingTrial > 0) {
                    this.authStatus = 'trial';
                } else {
                    this.authStatus = 'expired';
                }
                return { success: true, data: response.data };
            } else {
                return { success: false, error: response.data.error || '使用試用失敗' };
            }
        } catch (error) {
            return { success: false, error: error.message };
        }
    }

    // 激活授權碼
    async activateLicense(licenseKey) {
        const deviceId = await this.getDeviceId();
        
        try {
            const response = await axios.post(`${this.apiBaseURL}/license/activate`, {
                deviceId: deviceId,
                licenseKey: licenseKey
            });

            if (response.data.success) {
                this.licenseKey = licenseKey;
                this.authStatus = 'authorized';
                this.isAuthorized = true;
                return { success: true, message: response.data.message };
            } else {
                return { success: false, error: response.data.error || '激活失敗' };
            }
        } catch (error) {
            return { success: false, error: error.message };
        }
    }

    // 檢查是否可以執行操作
    canPerformAction() {
        if (this.authStatus === 'authorized') {
            return true;
        }
        if (this.authStatus === 'trial' && this.remainingTrial > 0) {
            return true;
        }
        return false;
    }

    // 執行操作前檢查（會自動使用試用次數）
    async performActionWithAuth() {
        if (this.isAuthorized && this.authStatus === 'authorized') {
            return { success: true };
        }

        // 試用用戶，使用試用次數
        return await this.useTrial();
    }
}

module.exports = AuthManager;
