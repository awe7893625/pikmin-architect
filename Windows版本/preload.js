const { contextBridge, ipcRenderer } = require('electron');

// 暴露安全的 API 給渲染進程
contextBridge.exposeInMainWorld('electronAPI', {
    // GPS 模擬相關
    teleport: (lat, lon) => ipcRenderer.invoke('teleport', lat, lon),
    startRoute: (points) => ipcRenderer.invoke('startRoute', points),
    stop: () => ipcRenderer.invoke('stop'),
    reconnect: () => ipcRenderer.invoke('reconnect'),
    
    // 授權相關
    checkAuth: () => ipcRenderer.invoke('checkAuth'),
    activateLicense: (key) => ipcRenderer.invoke('activateLicense', key),
    performActionWithAuth: () => ipcRenderer.invoke('performActionWithAuth'),
    
    // 設備相關
    getDeviceId: () => ipcRenderer.invoke('getDeviceId'),
    
    // 真實軌跡相關
    loadRealTrack: (file) => ipcRenderer.invoke('loadRealTrack', file),
    startRealTrack: () => ipcRenderer.invoke('startRealTrack')
});

// 為了兼容現有的 index.html，也暴露 webkit messageHandlers
contextBridge.exposeInMainWorld('webkit', {
    messageHandlers: {
        bridge: {
            postMessage: (message) => {
                const { act, ...data } = message;
                
                switch (act) {
                    case 'tp':
                        ipcRenderer.invoke('teleport', data.la, data.lo);
                        break;
                    case 'startRoute':
                        ipcRenderer.invoke('startRoute', data.pts);
                        break;
                    case 'stop':
                        ipcRenderer.invoke('stop');
                        break;
                    case 'reconnect':
                        ipcRenderer.invoke('reconnect');
                        break;
                    case 'checkAuth':
                        ipcRenderer.invoke('checkAuth');
                        break;
                    case 'activateLicense':
                        ipcRenderer.invoke('activateLicense', data.licenseKey);
                        break;
                    case 'loadRealTrack':
                        ipcRenderer.invoke('loadRealTrack', data.file);
                        break;
                    case 'startRealTrack':
                        ipcRenderer.invoke('startRealTrack');
                        break;
                }
            }
        }
    }
});
