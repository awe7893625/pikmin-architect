const { app, BrowserWindow, ipcMain, dialog } = require('electron');
const path = require('path');
const { exec } = require('child_process');
const LocationEngine = require('./src/location-engine');
const AuthManager = require('./src/auth-manager');
const DependencyInstaller = require('./scripts/install-dependencies');

let mainWindow;
let locationEngine = new LocationEngine();
let authManager = new AuthManager();
let dependencyInstaller = new DependencyInstaller();

// 連接 DependencyInstaller → LocationEngine
locationEngine.setDependencyInstaller(dependencyInstaller);

function createWindow() {
    mainWindow = new BrowserWindow({
        width: 1200,
        height: 800,
        icon: path.join(__dirname, 'build/icon.ico'),
        webPreferences: {
            preload: path.join(__dirname, 'preload.js'),
            nodeIntegration: false,
            contextIsolation: true
        },
        titleBarStyle: 'default',
        backgroundColor: '#ffffff'
    });

    mainWindow.loadFile('renderer/index.html');

    if (process.env.NODE_ENV === 'development') {
        mainWindow.webContents.openDevTools();
    }
}

// App 啟動
app.whenReady().then(async () => {
    createWindow();

    // 註冊設備（授權系統）
    authManager.registerDevice().then(() => {
        console.log('設備註冊成功');
    }).catch(err => {
        console.error('設備註冊失敗:', err);
    });

    // 背景靜默安裝依賴（不阻塞 UI，不彈對話框）
    dependencyInstaller.checkAndInstall((status) => {
        console.log('[依賴安裝]', status);
        // 把進度傳到前端顯示
        if (mainWindow && mainWindow.webContents) {
            mainWindow.webContents.executeJavaScript(
                `if(typeof setUI==='function') setUI('connecting', '${status.replace(/'/g, "\\'")}')`
            );
        }
    }).then(result => {
        if (result.success) {
            console.log('[依賴安裝] 完成，方式:', result.method);
            if (mainWindow && mainWindow.webContents) {
                mainWindow.webContents.executeJavaScript(
                    `if(typeof setUI==='function') setUI('online', ' 環境就緒')`
                );
            }
        } else {
            console.error('[依賴安裝] 失敗:', result.message || result.error);
        }
    });

    app.on('activate', () => {
        if (BrowserWindow.getAllWindows().length === 0) {
            createWindow();
        }
    });
});

app.on('window-all-closed', () => {
    if (process.platform !== 'darwin') {
        app.quit();
    }
});

// IPC 處理器
ipcMain.handle('getDeviceId', async () => {
    return await authManager.getDeviceId();
});

ipcMain.handle('checkAuth', async () => {
    return await authManager.checkAuth();
});

ipcMain.handle('activateLicense', async (event, key) => {
    return await authManager.activateLicense(key);
});

// GPS 模擬功能
ipcMain.handle('teleport', async (event, lat, lon) => {
    try {
        // 確保依賴已就緒
        if (!dependencyInstaller.isReady) {
            const installResult = await dependencyInstaller.checkAndInstall();
            if (!installResult.success) {
                return { success: false, error: installResult.message || '環境尚未準備好，請稍候重試' };
            }
        }
        return await locationEngine.teleport(lat, lon);
    } catch (error) {
        return { success: false, error: error.message };
    }
});

ipcMain.handle('startRoute', async (event, points) => {
    try {
        if (!dependencyInstaller.isReady) {
            const installResult = await dependencyInstaller.checkAndInstall();
            if (!installResult.success) {
                return { success: false, error: installResult.message || '環境尚未準備好' };
            }
        }
        return await locationEngine.startRoute(points);
    } catch (error) {
        return { success: false, error: error.message };
    }
});

ipcMain.handle('stop', async () => {
    locationEngine.stop();
    return { success: true };
});

ipcMain.handle('reconnect', async () => {
    // 確保依賴已就緒
    if (!dependencyInstaller.isReady) {
        const depsResult = await dependencyInstaller.checkAndInstall((status) => {
            if (mainWindow && mainWindow.webContents) {
                mainWindow.webContents.executeJavaScript(
                    `if(typeof setUI==='function') setUI('connecting', '${status.replace(/'/g, "\\'")}')`
                );
            }
        });
        if (!depsResult.success) {
            return {
                success: false,
                error: depsResult.message || '環境安裝失敗，請確認網路連線'
            };
        }
    }

    // 使用完整連線流程：detect → amfi → tunnel → ready
    const result = await locationEngine.fullConnect((status) => {
        if (mainWindow && mainWindow.webContents) {
            mainWindow.webContents.executeJavaScript(
                `if(typeof setUI==='function') setUI('connecting', '${status.replace(/'/g, "\\'")}')`
            );
        }
    });

    if (result.success && mainWindow && mainWindow.webContents) {
        const devName = result.deviceName || 'iPhone';
        const iosVer = result.iosVersion ? ` (iOS ${result.iosVersion})` : '';
        const tunnelInfo = result.tunnelActive ? ' [隧道已建立]' : '';
        mainWindow.webContents.executeJavaScript(
            `if(typeof setUI==='function') setUI('online', '已連線 — ${devName}${iosVer}${tunnelInfo}')`
        );
        // 如果 amfi 需要手動教學，顯示教學
        if (result.amfiResult === 'manual') {
            mainWindow.webContents.executeJavaScript(
                `if(typeof showDevModeTutorial==='function') showDevModeTutorial()`
            );
        }
    } else if (result.needsItunes && mainWindow && mainWindow.webContents) {
        mainWindow.webContents.executeJavaScript(
            `if(typeof setUI==='function') setUI('error', '需要安裝 iTunes — 請到 Microsoft Store 搜尋 iTunes 或 Apple Devices 安裝後重啟 App')`
        );
        const { shell } = require('electron');
        shell.openExternal('https://support.apple.com/zh-tw/106372');
    } else if (!result.success && mainWindow && mainWindow.webContents) {
        // 顯示具體錯誤
        const errMsg = (result.error || '連線失敗').replace(/'/g, "\\'").replace(/\n/g, '\\n');
        mainWindow.webContents.executeJavaScript(
            `if(typeof setUI==='function') setUI('error', '${errMsg}')`
        );
        // 如果設備偵測到了但隧道/amfi 失敗，顯示教學
        if (result.deviceDetected && result.needsTutorial) {
            mainWindow.webContents.executeJavaScript(
                `if(typeof showDevModeTutorial==='function') showDevModeTutorial()`
            );
        }
    }
    return result;
});

ipcMain.handle('loadRealTrack', async (event, file) => {
    return { success: true };
});

ipcMain.handle('startRealTrack', async () => {
    return { success: true };
});

ipcMain.handle('performActionWithAuth', async () => {
    return await authManager.performActionWithAuth();
});
