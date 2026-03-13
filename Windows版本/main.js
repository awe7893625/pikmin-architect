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

// App 啟動時初始化授權 + 檢查依賴
app.whenReady().then(async () => {
    // 初始化授權管理器
    authManager.registerDevice().then(() => {
        console.log('設備註冊成功');
    }).catch(err => {
        console.error('設備註冊失敗:', err);
    });

    // 檢查並安裝依賴（在背景執行，不阻塞 UI）
    dependencyInstaller.checkAndInstall().then(result => {
        if (!result.success) {
            console.warn('依賴檢查結果:', result);
        }
    });
});

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
    
    // 開發時打開 DevTools
    if (process.env.NODE_ENV === 'development') {
        mainWindow.webContents.openDevTools();
    }
}

app.whenReady().then(() => {
    createWindow();

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
        const result = await locationEngine.teleport(lat, lon);
        
        // 如果失敗且需要 Python，自動檢查並安裝
        if (!result.success && result.needsPython) {
            const installResult = await dependencyInstaller.checkAndInstall();
            if (installResult.success) {
                // 重試
                return await locationEngine.teleport(lat, lon);
            } else {
                // 顯示安裝提示
                dialog.showMessageBox(mainWindow, {
                    type: 'info',
                    title: '需要安裝依賴',
                    message: installResult.message || '請安裝必要的軟體',
                    buttons: ['確定']
                });
            }
        }
        
        return result;
    } catch (error) {
        return { success: false, error: error.message };
    }
});

ipcMain.handle('startRoute', async (event, points) => {
    try {
        const result = await locationEngine.startRoute(points);
        return result;
    } catch (error) {
        return { success: false, error: error.message };
    }
});

ipcMain.handle('stop', async () => {
    locationEngine.stop();
    return { success: true };
});

ipcMain.handle('reconnect', async () => {
    // 先檢查依賴
    const depsResult = await dependencyInstaller.checkAndInstall();
    if (!depsResult.success) {
        return { 
            success: false, 
            error: depsResult.message || '請先安裝必要的依賴軟體',
            needsInstall: true
        };
    }
    
    const result = await locationEngine.detectDevice();
    return result;
});

ipcMain.handle('loadRealTrack', async (event, file) => {
    // TODO: 實現真實軌跡載入
    return { success: true };
});

ipcMain.handle('startRealTrack', async () => {
    // TODO: 實現真實軌跡播放
    return { success: true };
});

ipcMain.handle('performActionWithAuth', async () => {
    return await authManager.performActionWithAuth();
});
