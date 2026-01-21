// Windows 版本自動安裝依賴腳本
const { exec } = require('child_process');
const { promisify } = require('util');
const fs = require('fs');
const path = require('path');
const https = require('https');
const { app } = require('electron');
const { dialog } = require('electron').remote || require('@electron/remote');

const execAsync = promisify(exec);

class DependencyInstaller {
    constructor() {
        this.isInstalled = false;
        this.installPath = path.join(app.getPath('userData'), 'dependencies');
    }

    // 檢查 Python 是否已安裝
    async checkPython() {
        try {
            const { stdout } = await execAsync('python --version');
            const version = stdout.match(/Python (\d+\.\d+)/);
            if (version && parseFloat(version[1]) >= 3.8) {
                return { installed: true, version: version[1] };
            }
        } catch (error) {
            // Python 未安裝
        }
        return { installed: false };
    }

    // 檢查 pymobiledevice3 是否已安裝
    async checkPymobiledevice3() {
        try {
            await execAsync('python -m pymobiledevice3 --version');
            return { installed: true };
        } catch (error) {
            return { installed: false };
        }
    }

    // 自動安裝 pymobiledevice3
    async installPymobiledevice3() {
        try {
            await execAsync('python -m pip install --upgrade pip');
            await execAsync('python -m pip install pymobiledevice3');
            return { success: true };
        } catch (error) {
            return { success: false, error: error.message };
        }
    }

    // 檢查並安裝所有依賴
    async checkAndInstall() {
        const pythonCheck = await this.checkPython();
        
        if (!pythonCheck.installed) {
            // 顯示 Python 安裝提示
            const result = await dialog.showMessageBox({
                type: 'info',
                title: '需要安裝 Python',
                message: 'Pikmin Architect 需要 Python 3.8 或更高版本',
                detail: '是否要打開 Python 下載頁面？\n\n安裝時請勾選「Add Python to PATH」',
                buttons: ['打開下載頁面', '稍後安裝']
            });

            if (result.response === 0) {
                // 打開 Python 下載頁面
                const { shell } = require('electron');
                shell.openExternal('https://www.python.org/downloads/');
            }
            
            return { 
                success: false, 
                needsPython: true,
                message: '請先安裝 Python 3.8 或更高版本'
            };
        }

        const pymobiledevice3Check = await this.checkPymobiledevice3();
        
        if (!pymobiledevice3Check.installed) {
            // 自動安裝 pymobiledevice3
            const installResult = await this.installPymobiledevice3();
            
            if (!installResult.success) {
                return {
                    success: false,
                    needsPymobiledevice3: true,
                    message: 'pymobiledevice3 安裝失敗，請手動執行：pip install pymobiledevice3'
                };
            }
        }

        return { success: true, message: '所有依賴已就緒' };
    }
}

module.exports = DependencyInstaller;
