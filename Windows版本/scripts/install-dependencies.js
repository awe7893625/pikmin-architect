// Windows 版本自動安裝依賴腳本（自動下載 Portable Python + pymobiledevice3）
const { exec } = require('child_process');
const { promisify } = require('util');
const fs = require('fs');
const path = require('path');
const https = require('https');
const http = require('http');
const { app } = require('electron');

const execAsync = promisify(exec);

// Python embeddable 下載 URL（3.11 穩定版）
const PYTHON_VERSION = '3.11.9';
const PYTHON_DOWNLOAD_URL = `https://www.python.org/ftp/python/${PYTHON_VERSION}/python-${PYTHON_VERSION}-embed-amd64.zip`;
const GET_PIP_URL = 'https://bootstrap.pypa.io/get-pip.py';

class DependencyInstaller {
    constructor() {
        this.isReady = false;
        this._pythonPath = null;
    }

    // 取得 App 資料目錄（持久化，不隨更新刪除）
    get depsDir() {
        return path.join(app.getPath('userData'), 'python-env');
    }

    get pythonExe() {
        return path.join(this.depsDir, 'python.exe');
    }

    // 取得 bundled pymobiledevice3.exe 路徑（如果已打包）
    get bundledExe() {
        const resourcesPath = app.isPackaged
            ? process.resourcesPath
            : path.join(__dirname, '..');
        return path.join(resourcesPath, 'bin', 'pymobiledevice3.exe');
    }

    // 取得可用的 Python 路徑（bundled > portable > system）
    async getPythonPath() {
        if (this._pythonPath) return this._pythonPath;

        // 1) bundled pymobiledevice3.exe（最佳，已打包）
        if (fs.existsSync(this.bundledExe)) {
            this._pythonPath = null; // 不需要 Python，直接用 exe
            this.isReady = true;
            return null;
        }

        // 2) Portable Python（App 自動下載的）
        if (fs.existsSync(this.pythonExe)) {
            try {
                await execAsync(`"${this.pythonExe}" --version`);
                this._pythonPath = this.pythonExe;
                return this._pythonPath;
            } catch (e) {
                // 損壞，重新下載
            }
        }

        // 3) 系統 Python
        for (const cmd of ['python', 'python3', 'py -3']) {
            try {
                const { stdout } = await execAsync(`${cmd} --version`);
                const ver = stdout.match(/Python (\d+\.\d+)/);
                if (ver && parseFloat(ver[1]) >= 3.8) {
                    this._pythonPath = cmd;
                    return this._pythonPath;
                }
            } catch (e) { /* 繼續嘗試 */ }
        }

        return null;
    }

    // 下載檔案（支援 redirect）
    _download(url, destPath) {
        return new Promise((resolve, reject) => {
            const file = fs.createWriteStream(destPath);
            const get = url.startsWith('https') ? https.get : http.get;

            get(url, (response) => {
                // 處理 redirect
                if (response.statusCode >= 300 && response.statusCode < 400 && response.headers.location) {
                    file.close();
                    fs.unlinkSync(destPath);
                    return this._download(response.headers.location, destPath).then(resolve).catch(reject);
                }
                if (response.statusCode !== 200) {
                    file.close();
                    fs.unlinkSync(destPath);
                    return reject(new Error(`Download failed: HTTP ${response.statusCode}`));
                }
                response.pipe(file);
                file.on('finish', () => { file.close(); resolve(); });
                file.on('error', (err) => { fs.unlinkSync(destPath); reject(err); });
            }).on('error', (err) => {
                if (fs.existsSync(destPath)) fs.unlinkSync(destPath);
                reject(err);
            });
        });
    }

    // 解壓 zip（使用 PowerShell）
    async _unzip(zipPath, destDir) {
        await execAsync(`powershell -Command "Expand-Archive -Force -Path '${zipPath}' -DestinationPath '${destDir}'"`, { timeout: 120000 });
    }

    // 自動下載並設定 Portable Python + pymobiledevice3
    async setupPortablePython(onProgress) {
        const depsDir = this.depsDir;
        if (!fs.existsSync(depsDir)) {
            fs.mkdirSync(depsDir, { recursive: true });
        }

        // Step 1: 下載 Python embeddable
        if (onProgress) onProgress('正在下載 Python 環境...');
        const zipPath = path.join(depsDir, 'python-embed.zip');
        if (!fs.existsSync(this.pythonExe)) {
            await this._download(PYTHON_DOWNLOAD_URL, zipPath);
            if (onProgress) onProgress('正在解壓 Python...');
            await this._unzip(zipPath, depsDir);
            // 清理 zip
            if (fs.existsSync(zipPath)) fs.unlinkSync(zipPath);
        }

        // Step 2: 修改 python311._pth 以啟用 site-packages
        const pthFiles = fs.readdirSync(depsDir).filter(f => f.endsWith('._pth'));
        for (const pth of pthFiles) {
            const pthPath = path.join(depsDir, pth);
            let content = fs.readFileSync(pthPath, 'utf8');
            // 取消 import site 的注釋
            if (content.includes('#import site')) {
                content = content.replace('#import site', 'import site');
                fs.writeFileSync(pthPath, content);
            }
        }

        // Step 3: 安裝 pip
        if (onProgress) onProgress('正在安裝 pip...');
        const getPipPath = path.join(depsDir, 'get-pip.py');
        if (!fs.existsSync(path.join(depsDir, 'Scripts', 'pip.exe'))) {
            await this._download(GET_PIP_URL, getPipPath);
            await execAsync(`"${this.pythonExe}" "${getPipPath}"`, { cwd: depsDir, timeout: 300000 });
            if (fs.existsSync(getPipPath)) fs.unlinkSync(getPipPath);
        }

        // Step 4: 安裝 pymobiledevice3
        if (onProgress) onProgress('正在安裝定位模組（首次約 1-2 分鐘）...');
        const pipExe = path.join(depsDir, 'Scripts', 'pip.exe');
        try {
            await execAsync(`"${this.pythonExe}" -m pymobiledevice3 version`, { timeout: 10000 });
        } catch (e) {
            // 未安裝，安裝之
            await execAsync(`"${pipExe}" install pymobiledevice3`, { timeout: 600000 });
        }

        this._pythonPath = this.pythonExe;
        this.isReady = true;
        if (onProgress) onProgress('環境準備完成！');
        return { success: true };
    }

    // 檢查並安裝所有依賴（不會彈出安裝 Python 對話框）
    async checkAndInstall(onProgress) {
        // 1) 已有 bundled exe → 直接可用
        if (fs.existsSync(this.bundledExe)) {
            this.isReady = true;
            return { success: true, method: 'bundled-exe' };
        }

        // 2) 已有 portable Python + pymobiledevice3 → 檢查是否完整
        if (fs.existsSync(this.pythonExe)) {
            try {
                await execAsync(`"${this.pythonExe}" -m pymobiledevice3 version`, { timeout: 10000 });
                this._pythonPath = this.pythonExe;
                this.isReady = true;
                return { success: true, method: 'portable-python' };
            } catch (e) {
                // 不完整，重新安裝 pymobiledevice3
                try {
                    const pipExe = path.join(this.depsDir, 'Scripts', 'pip.exe');
                    if (fs.existsSync(pipExe)) {
                        if (onProgress) onProgress('正在修復定位模組...');
                        await execAsync(`"${pipExe}" install pymobiledevice3`, { timeout: 600000 });
                        this._pythonPath = this.pythonExe;
                        this.isReady = true;
                        return { success: true, method: 'portable-python-repaired' };
                    }
                } catch (e2) { /* fall through */ }
            }
        }

        // 3) 檢查系統 Python
        const sysPython = await this.getPythonPath();
        if (sysPython) {
            try {
                await execAsync(`${sysPython} -m pymobiledevice3 version`, { timeout: 10000 });
                this.isReady = true;
                return { success: true, method: 'system-python' };
            } catch (e) {
                // 系統 Python 有但沒有 pymobiledevice3
                if (onProgress) onProgress('正在安裝定位模組...');
                try {
                    await execAsync(`${sysPython} -m pip install pymobiledevice3`, { timeout: 600000 });
                    this.isReady = true;
                    return { success: true, method: 'system-python-installed' };
                } catch (e2) { /* fall through to portable */ }
            }
        }

        // 4) 什麼都沒有 → 自動下載 Portable Python
        try {
            return await this.setupPortablePython(onProgress);
        } catch (error) {
            return {
                success: false,
                error: error.message,
                message: `自動安裝失敗：${error.message}\n請確認網路連線正常後重試。`
            };
        }
    }

    // 取得 pymobiledevice3 執行指令
    getCommand(args) {
        if (fs.existsSync(this.bundledExe)) {
            return `"${this.bundledExe}" ${args}`;
        }
        const python = this._pythonPath || this.pythonExe;
        return `"${python}" -m pymobiledevice3 ${args}`;
    }
}

module.exports = DependencyInstaller;
