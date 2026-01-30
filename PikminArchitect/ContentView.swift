import SwiftUI
import WebKit
import Combine
import Foundation
import AppKit

// GPS 軌跡點結構
struct GPSTrackPoint {
    let lat: Double
    let lon: Double
    let altitude: Double
    let speed: Double  // km/h
    let timeOffset: Double  // 從開始的秒數
    let timestamp: Date?
}

final class LocationEngine: NSObject, ObservableObject, WKScriptMessageHandler, WKNavigationDelegate {
    @Published var udid: String = ""
    var webView: WKWebView?
    private var timer: Timer?
    private var currentLat: Double = 25.033
    private var currentLon: Double = 121.565
    private var currentAltitude: Double = 10.0  // 目前海拔高度（公尺）
    private var routeQueue: [[Double]] = []
    private var currentSpeed: Double = 15.0  // 目前速度 (km/h)
    private var lastUpdateTime: Date = Date()
    private var pathOffset: Double = 0.0  // 路徑搖擺偏移累積
    private var altitudeOffset: Double = 0.0  // 海拔變化累積
    
    // 真實 GPS 軌跡數據
    private var realTrack: [GPSTrackPoint] = []
    private var trackStartTime: Date?
    private var currentTrackIndex: Int = 0
    private var isUsingRealTrack: Bool = false
    
    // 原地踏步檢測
    private var lastPositions: [(lat: Double, lon: Double, time: Date)] = []
    private var stuckCheckTimer: Timer?
    private var stuckCount: Int = 0
    private let stuckThreshold: Int = 3  // 連續3次檢測到原地踏步才觸發

    private let preferredUDIDKey = "preferredUDID"
    private var preferredUDID: String = ""

    // 免安裝依賴：依架構選擇 App 內建的 Python/工具，找不到才回退到系統
    private var currentMachineArch: String {
        var size = 0
        sysctlbyname("hw.machine", nil, &size, nil, 0)
        var machine = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.machine", &machine, &size, nil, 0)
        return String(cString: machine)
    }
    private var isAppleSilicon: Bool {
        currentMachineArch.contains("arm64")
    }
    private var bundleResourcesPath: String {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Resources").path
    }
    private var bundledPythonBasePath: String {
        isAppleSilicon ? "\(bundleResourcesPath)/python_arm64" : "\(bundleResourcesPath)/python_x86_64"
    }
    private var bundledPythonPath: String {
        let preferred = "\(bundledPythonBasePath)/bin/python3"
        if FileManager.default.fileExists(atPath: preferred) { return preferred }
        let legacy = "\(bundleResourcesPath)/python/bin/python3"
        if FileManager.default.fileExists(atPath: legacy) { return legacy }
        return preferred
    }
    private var bundledBinPath: String {
        let preferred = isAppleSilicon ? "\(bundleResourcesPath)/bin_arm64" : "\(bundleResourcesPath)/bin_x86_64"
        if FileManager.default.fileExists(atPath: preferred) { return preferred }
        return "\(bundleResourcesPath)/bin"
    }
    private var bundledLibPath: String {
        let preferred = isAppleSilicon ? "\(bundleResourcesPath)/lib_arm64" : "\(bundleResourcesPath)/lib_x86_64"
        if FileManager.default.fileExists(atPath: preferred) { return preferred }
        return "\(bundleResourcesPath)/lib"
    }

    // 實際可用的 Python（避免「內建 python 存在但跑不起來」造成隧道永遠失敗）
    private var resolvedPythonPath: String?
    private var pymobiledevice3Installed: Bool = false
    
    private func isPythonRunnable(_ path: String) -> Bool {
        guard FileManager.default.fileExists(atPath: path) else { return false }
        let out = shell("\"\(path)\" --version 2>&1")
        if out.contains("dyld") || out.contains("Library not loaded") || out.contains("built for macOS") {
            return false
        }
        return out.contains("Python")
    }
    
    private func hasPymobiledevice3(_ pythonPath: String) -> Bool {
        let out = shell("\"\(pythonPath)\" -m pymobiledevice3 --version 2>&1")
        return out.contains("pymobiledevice3") || out.contains("version")
    }
    
    private func autoInstallPymobiledevice3IfNeeded(_ pythonPath: String) {
        if pymobiledevice3Installed { return }
        if hasPymobiledevice3(pythonPath) {
            pymobiledevice3Installed = true
            return
        }
        
        print("📦 [自動安裝] 偵測到缺少 pymobiledevice3，正在自動安裝...")
        DispatchQueue.main.async {
            self.webView?.evaluateJavaScript("setUI('connecting', ' 首次使用：正在安裝必要套件...')")
        }
        
        // 嘗試自動安裝（使用 --user 不需要 sudo）
        let installOut = shell("\"\(pythonPath)\" -m pip install --user --quiet pymobiledevice3 2>&1")
        
        if hasPymobiledevice3(pythonPath) {
            print("✅ [自動安裝] pymobiledevice3 安裝成功")
            pymobiledevice3Installed = true
        } else {
            print("⚠️ [自動安裝] 自動安裝失敗，輸出: \(installOut)")
            pymobiledevice3Installed = false
        }
    }
    
    private func resolvePythonPath() -> String {
        if let cached = resolvedPythonPath, isPythonRunnable(cached) { return cached }

        // 1) 先嘗試 App 內建 Python（若在使用者 OS 上跑不起來就回退）
        if isPythonRunnable(bundledPythonPath) {
            resolvedPythonPath = bundledPythonPath
            // 自動安裝 pymobiledevice3（如果需要）
            autoInstallPymobiledevice3IfNeeded(bundledPythonPath)
            return bundledPythonPath
        }

        // 2) 回退：Homebrew / 系統 Python
        let candidates = ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"]
        for c in candidates {
            if isPythonRunnable(c) {
                resolvedPythonPath = c
                // 自動安裝 pymobiledevice3（如果需要）
                autoInstallPymobiledevice3IfNeeded(c)
                return c
            }
        }

        // 3) 最後仍給一個路徑（讓下游錯誤訊息能被捕捉）
        resolvedPythonPath = "/usr/bin/python3"
        return "/usr/bin/python3"
    }
    private var ideviceIdPath: String? {
        let bundled = "\(bundledBinPath)/idevice_id"
        if FileManager.default.fileExists(atPath: bundled) { return bundled }
        if FileManager.default.fileExists(atPath: "/opt/homebrew/bin/idevice_id") { return "/opt/homebrew/bin/idevice_id" }
        if FileManager.default.fileExists(atPath: "/usr/local/bin/idevice_id") { return "/usr/local/bin/idevice_id" }
        return nil
    }
    private func envPrefixForShell(pythonPath: String) -> String {
        // 只有使用 App 內建 Python/工具時才注入 DYLD_LIBRARY_PATH / PATH，避免污染系統 Python
        if !pythonPath.hasPrefix(bundleResourcesPath) {
            return ""
        }
        var parts: [String] = []
        if FileManager.default.fileExists(atPath: bundledLibPath) {
            parts.append("DYLD_LIBRARY_PATH=\"\(bundledLibPath)\"")
        }
        if FileManager.default.fileExists(atPath: bundledBinPath) {
            parts.append("PATH=\"\(bundledBinPath):$PATH\"")
        }
        guard !parts.isEmpty else { return "" }
        return "env " + parts.joined(separator: " ")
    }
    private func pythonCommand(_ args: String) -> String {
        let py = resolvePythonPath()
        let env = envPrefixForShell(pythonPath: py)
        if env.isEmpty {
            return "\"\(py)\" \(args)"
        }
        return "\(env) \"\(py)\" \(args)"
    }
    private func escapeForAppleScript(_ text: String) -> String {
        text.replacingOccurrences(of: "\"", with: "\\\"")
    }

    override init() {
        super.init()
        if let saved = UserDefaults.standard.string(forKey: preferredUDIDKey) {
            self.preferredUDID = saved.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // 自動載入預設軌跡
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            self.loadDefaultTrack()
        }
    }
    
    // 自動載入預設軌跡
    private func loadDefaultTrack() {
        // 優先從 Bundle 載入（如果檔案已加入專案）
        if let bundlePath = Bundle.main.path(forResource: "default_track", ofType: "json"),
           let data = try? Data(contentsOf: URL(fileURLWithPath: bundlePath)) {
            self.parseAndLoadTrack(data: data)
            return
        }
        
        // 從專案目錄載入（開發時使用）
        let projectPaths = [
            "/Users/rain/Pikmin_Dev_Portable/PikminArchitect＿繼續開發版本/default_track.json",
            "/Users/rain/Pikmin_Dev_Portable/PikminArchitect＿繼續開發版本/PikminArchitect/default_track.json",
            Bundle.main.bundlePath + "/Contents/Resources/default_track.json"
        ]
        
        for path in projectPaths {
            if let data = try? Data(contentsOf: URL(fileURLWithPath: path)) {
                self.parseAndLoadTrack(data: data)
                return
            }
        }
        
        // 如果都找不到，從 Documents 目錄載入
        if let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.appendingPathComponent("default_track.json"),
           let data = try? Data(contentsOf: documentsPath) {
            self.parseAndLoadTrack(data: data)
        }
    }
    
    // 解析並載入軌跡數據
    private func parseAndLoadTrack(data: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let trackData = json["track"] as? [[String: Any]] else {
            return
        }
        
        var loadedTrack: [GPSTrackPoint] = []
        for pointData in trackData {
            guard let lat = pointData["lat"] as? Double,
                  let lon = pointData["lon"] as? Double else { continue }
            
            let altitude = pointData["altitude"] as? Double ?? 15.0
            let speed = pointData["speed"] as? Double ?? 16.0
            let timeOffset = pointData["time_offset"] as? Double ?? 0.0
            
            var timestamp: Date? = nil
            if let timestampStr = pointData["timestamp"] as? String {
                let formatter = ISO8601DateFormatter()
                timestamp = formatter.date(from: timestampStr)
            }
            
            loadedTrack.append(GPSTrackPoint(
                lat: lat,
                lon: lon,
                altitude: altitude,
                speed: speed,
                timeOffset: timeOffset,
                timestamp: timestamp
            ))
        }
        
        DispatchQueue.main.async {
            self.realTrack = loadedTrack
            if let metadata = json["metadata"] as? [String: Any],
               let totalPoints = metadata["total_points"] as? Int {
                self.webView?.evaluateJavaScript("console.log('已自動載入預設軌跡：\(totalPoints) 個點')")
            }
        }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let dict = message.body as? [String: Any], let act = dict["act"] as? String else { return }
        switch act {
        case "reconnect": self.reconnect()
        case "tp":
            // 停止所有移動模式
            self.stopTimerOnly()
            self.stopStuckCheck()
            self.isUsingRealTrack = false
            // 執行瞬移
            self.teleport(lat: dict["la"] as? Double ?? 0, lon: dict["lo"] as? Double ?? 0)
        case "startRoute":
            let pts = dict["pts"] as? [[Double]] ?? []
            self.startCruise(points: pts, kmh: 18.0)
        case "loadRealTrack":
            // 載入真實 GPS 軌跡數據
            if let trackFile = dict["file"] as? String {
                self.loadRealTrack(from: trackFile)
            }
        case "startRealTrack":
            // 開始播放真實軌跡
            self.startRealTrackPlayback()
        case "stop": self.resetEverything()
        case "openPayment":
            // 打開購買連結
            if let urlString = dict["url"] as? String, let url = URL(string: urlString) {
                DispatchQueue.main.async {
                    NSWorkspace.shared.open(url)
                    print("✅ [購買] 已打開購買連結: \(urlString)")
                }
            } else {
                print("❌ [購買] 無效的 URL")
            }
        case "openExternal":
            // 相容舊版 Web 端：openExternal 同 openPayment
            if let urlString = dict["url"] as? String, let url = URL(string: urlString) {
                DispatchQueue.main.async {
                    NSWorkspace.shared.open(url)
                    print("✅ [外部連結] 已打開: \(urlString)")
                }
            } else {
                print("❌ [外部連結] 無效的 URL")
            }
        case "activateLicense":
            // 激活授權碼
            if let licenseKey = dict["licenseKey"] as? String {
                self.activateLicense(licenseKey: licenseKey)
            } else {
                print("❌ [授權] 未提供授權碼")
                DispatchQueue.main.async {
                    self.webView?.evaluateJavaScript("alert('❌ 請輸入授權碼')")
                }
            }
        case "checkAuth":
            // 檢查授權狀態
            self.checkAuthStatus()
        case "consumeTrial":
            // 消耗試用次數（Fail Closed：由 Swift 統一處理）
            if let feature = dict["feature"] as? String {
                self.consumeTrial(feature: feature)
            }
        case "getDeviceId":
            // 獲取設備 ID
            let deviceId = self.getDeviceId()
            DispatchQueue.main.async {
                self.webView?.evaluateJavaScript("""
                    if (window.postMessage) {
                        window.postMessage({ type: 'deviceId', deviceId: '\(deviceId)' }, '*');
                    }
                """)
            }
        case "listDevices":
            let devices = self.listConnectedDevices()
            self.sendDeviceListToWeb(devices)
        case "setDevice":
            if let udid = dict["udid"] as? String {
                self.setPreferredDevice(udid)
            }
        case "backupFavorites":
            // 上線版本不支援寫入備份檔（避免產生/混入個資檔案）
            break
        case "exportFavorites":
            // 導出最愛：使用 NSSavePanel 讓使用者選擇存檔位置（WKWebView 下載在 App 內可能無反應）
            if let favoritesData = dict["data"] as? String {
                // 確保在主線程執行
                DispatchQueue.main.async {
                    self.exportFavoritesViaSavePanel(data: favoritesData)
                }
            } else {
                DispatchQueue.main.async {
                    self.webView?.evaluateJavaScript("alert('❌ 導出失敗：沒有最愛資料')")
                }
            }
        case "importFavorites":
            // 導入最愛：使用 NSOpenPanel 讓使用者選擇 JSON 檔
            // 確保在主線程執行
            DispatchQueue.main.async {
                self.importFavoritesViaOpenPanel()
            }
        default: break
        }
    }

    private func exportFavoritesViaSavePanel(data: String) {
        // 必須在主線程執行，否則 runModal() 無法顯示
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.exportFavoritesViaSavePanel(data: data) }
            return
        }
        
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSSavePanel()
        panel.allowedFileTypes = ["json"]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        
        // 設定預設目錄為 Documents
        if let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            panel.directoryURL = docs
        }
        
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        panel.nameFieldStringValue = "favorite_locations_\(df.string(from: Date())).json"
        panel.title = "導出最愛地點"
        panel.message = "請選擇要儲存最愛地點備份的位置"

        let present: () -> Void = {
            // 優先掛到 App 視窗，避免對話框跑到其他 App
            if let window = self.webView?.window ?? NSApp.mainWindow ?? NSApp.keyWindow {
                window.makeKeyAndOrderFront(nil)
                panel.beginSheetModal(for: window) { response in
                    guard response == .OK, let url = panel.url else { return }
                    do {
                        try data.write(to: url, atomically: true, encoding: .utf8)
                        self.webView?.evaluateJavaScript("alert('✅ 已導出最愛地點到檔案：\\n\\n\(url.path)')")
                    } catch {
                        self.webView?.evaluateJavaScript("alert('❌ 導出失敗：\(error.localizedDescription)')")
                    }
                }
                return
            }

            // 無視窗時才 fallback runModal
            let response = panel.runModal()
            guard response == .OK, let url = panel.url else { return }
            do {
                try data.write(to: url, atomically: true, encoding: .utf8)
                self.webView?.evaluateJavaScript("alert('✅ 已導出最愛地點到檔案：\\n\\n\(url.path)')")
            } catch {
                self.webView?.evaluateJavaScript("alert('❌ 導出失敗：\(error.localizedDescription)')")
            }
        }

        // 延遲到下一個 runloop，避免 AppKitBreakInDebugger
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { present() }
    }

    private func importFavoritesViaOpenPanel() {
        // 必須在主線程執行，否則 runModal() 無法顯示
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.importFavoritesViaOpenPanel() }
            return
        }
        
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.allowedFileTypes = ["json"]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.title = "導入最愛地點"
        panel.message = "請選擇之前導出（或備份）的 favorite_locations_*.json 檔案"
        
        // 設定預設目錄為 Documents
        if let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            panel.directoryURL = docs
        }

        let present: () -> Void = {
            // 優先掛到 App 視窗，避免對話框跑到其他 App
            if let window = self.webView?.window ?? NSApp.mainWindow ?? NSApp.keyWindow {
                window.makeKeyAndOrderFront(nil)
                panel.beginSheetModal(for: window) { response in
                    guard response == .OK, let url = panel.url else { return }
                    do {
                        let fileData = try Data(contentsOf: url)
                        let base64 = fileData.base64EncodedString()
                        self.webView?.evaluateJavaScript("window.__importFavoritesFromSwiftBase64('\(base64)');")
                    } catch {
                        self.webView?.evaluateJavaScript("alert('❌ 導入失敗：\(error.localizedDescription)')")
                    }
                }
                return
            }

            // 無視窗時才 fallback runModal
            let response = panel.runModal()
            guard response == .OK, let url = panel.url else { return }
            do {
                let fileData = try Data(contentsOf: url)
                let base64 = fileData.base64EncodedString()
                self.webView?.evaluateJavaScript("window.__importFavoritesFromSwiftBase64('\(base64)');")
            } catch {
                self.webView?.evaluateJavaScript("alert('❌ 導入失敗：\(error.localizedDescription)')")
            }
        }

        // 延遲到下一個 runloop，避免 AppKitBreakInDebugger
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { present() }
    }

    private func apiBaseURL() -> String {
        // 預設一律走 production（避免 Debug build 沒開本地 server 就「激活失效」）
        // 如需本地測試，可在 Scheme → Run → Arguments → Environment Variables 設定：
        // KONGGOO_API_BASE=http://localhost:3001/api
        let env = ProcessInfo.processInfo.environment
        if let override = env["KONGGOO_API_BASE"], !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return override
        }
        return "https://konggoo.vercel.app/api"
    }

    // 瞬移邏輯（修正版：確保精確瞬移，不添加抖動）
    func teleport(lat: Double, lon: Double) {
        // 確保在主線程執行
        guard Thread.isMainThread else {
            DispatchQueue.main.async {
                self.teleport(lat: lat, lon: lon)
            }
            return
        }
        
        // 停止所有移動模式
        self.stopTimerOnly()
        self.stopStuckCheck()
        self.isUsingRealTrack = false
        self.routeQueue = []
        self.stuckCount = 0
        self.lastPositions = []
        
        // 更新位置
        self.currentLat = lat
        self.currentLon = lon
        
        // 更新 WebView 地圖標記
        self.webView?.evaluateJavaScript("syncLocation(\(lat), \(lon))")
        
        // 檢查設備是否已連線
        guard !udid.isEmpty else {
            return
        }
        
        // 瞬移使用精確位置，只添加最小的 GPS 誤差（約 ±0.15 公尺）
        // 不使用多層次抖動，確保精確瞬移
        let jitter = 0.00000135  // 約 ±0.15 公尺（最小誤差）
        let finalLat = lat + Double.random(in: -jitter...jitter)
        let finalLon = lon + Double.random(in: -jitter...jitter)
        
        // 立即發送位置（使用最高優先級）
        DispatchQueue.global(qos: .userInteractive).async {
            _ = self.shell(self.pythonCommand("-m pymobiledevice3 developer dvt simulate-location set --tunnel \(self.udid) -- \(finalLat) \(finalLon)"))
        }
    }

    // 散花模式 (路徑移動) - 改進版：使用真實數據的移動模式
    func startCruise(points: [[Double]], kmh: Double) {
        self.stopTimerOnly()
        self.stopStuckCheck()  // 停止之前的檢測
        self.routeQueue = points
        guard !self.routeQueue.isEmpty else { 
            return 
        }
        
        // 初始化狀態（使用真實數據的模式）
        self.currentSpeed = Double.random(in: 15.0...18.0)  // 速度 15-18 km/h（模擬真實騎車）
        self.lastUpdateTime = Date()
        self.pathOffset = 0.0
        self.altitudeOffset = 0.0
        self.stuckCount = 0
        self.lastPositions = []  // 清除位置記錄
        // 初始化海拔高度（模擬台北市區海拔）
        if self.currentAltitude < 1.0 {
            self.currentAltitude = Double.random(in: 10.0...25.0)
        }
        
        // 立即執行第一步移動（不等待計時器）
        DispatchQueue.main.async {
            // 立即執行第一步，確保開始移動
            self.executeRealisticStep()
            // 然後調度後續步驟
            self.scheduleRealisticStep()
        }
        
        // 啟動原地踏步檢測（多點移動也需要檢測）
        startStuckCheck()
    }
    
    // 真實數據模式的動態調度（改進版：修正計時器管理）
    private func scheduleRealisticStep() {
        guard !self.routeQueue.isEmpty else {
            self.stopTimerOnly()
            return
        }
        
        // 確保在主線程上執行
        guard Thread.isMainThread else {
            DispatchQueue.main.async {
                self.scheduleRealisticStep()
            }
            return
        }
        
        // 先停止舊計時器（避免重複計時器）
        self.stopTimerOnly()
        
        // 優化：固定計時器間隔在 0.5-1 秒之間，確保頻繁的位置更新
        let baseInterval = 0.75  // 基礎間隔 0.75 秒
        let variation = Double.random(in: -0.25...0.25)  // ±0.25 秒變化
        let actualInterval = max(0.5, min(1.0, baseInterval + variation))  // 嚴格限制在 0.5-1.0 秒
        
        // 動態調整速度（模擬真實騎車的速度變化，15-18 km/h）
        let speedVariation = Double.random(in: -1.0...1.0)
        self.currentSpeed = max(15.0, min(18.0, self.currentSpeed + speedVariation))
        
        // 創建計時器（scheduledTimer 已自動添加到 RunLoop）
        self.timer = Timer.scheduledTimer(withTimeInterval: actualInterval, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            self.executeRealisticStep()
            self.scheduleRealisticStep()  // 遞迴調度下一步
        }
    }
    
    // 執行真實數據模式的單步移動（改進版：確保位置持續更新）
    private func executeRealisticStep() {
        guard !self.routeQueue.isEmpty else {
            self.stopTimerOnly()
            return
        }
        
        // 確保在主線程上執行
        guard Thread.isMainThread else {
            DispatchQueue.main.async {
                self.executeRealisticStep()
            }
            return
        }
        
        let target = self.routeQueue[0]
        let dLat = target[0] - self.currentLat
        let dLon = target[1] - self.currentLon
        let dist = sqrt(dLat * dLat + dLon * dLon)
        
        // 優化：使用固定的時間間隔（0.5-1 秒），確保位置持續更新
        let timeElapsed = Date().timeIntervalSince(self.lastUpdateTime)
        let actualInterval = max(0.5, min(1.0, timeElapsed))  // 嚴格限制在 0.5-1.0 秒
        
        // 將速度轉換為度數（在緯度 25 度附近，1 度約 111 公里）
        let latFactor = cos(self.currentLat * .pi / 180.0)
        let metersPerDegreeLat = 111000.0
        let metersPerDegreeLon = 111000.0 * latFactor
        
        // 計算每步移動距離（公尺）- 使用真實速度 15-18 km/h
        let stepMeters = (self.currentSpeed / 3.6) * actualInterval
        
        // 轉換為度數
        let stepDistLat = stepMeters / metersPerDegreeLat
        let stepDistLon = stepMeters / metersPerDegreeLon
        
        // 計算總步長（度數）
        let stepDist = sqrt(stepDistLat * stepDistLat + stepDistLon * stepDistLon)
        
        // 改進：降低到達目標點的判斷閾值，確保更精確的移動
        // 如果距離目標很近（小於步長的 1.2 倍），直接移動到目標點
        if dist < stepDist * 1.2 {
            // 直接移動到目標點位置（確保位置實際更新）
            self.currentLat = target[0]
            self.currentLon = target[1]
            
            // 添加真實 GPS 誤差（±3 公尺，模擬真實 GPS 精度）
            let gpsErrorLat = Double.random(in: -0.000027...0.000027)  // ±3 公尺
            let gpsErrorLon = Double.random(in: -0.000027...0.000027) / latFactor
            
            // 立即發送位置更新（確保位置變化被記錄）
            self.transmit(lat: self.currentLat + gpsErrorLat, lon: self.currentLon + gpsErrorLon)
            
            // 更新時間戳
            self.lastUpdateTime = Date()
            
            // 移除已到達的目標點
            self.routeQueue.removeFirst()
            self.pathOffset = 0.0  // 重置路徑偏移
            
            // 改進：確保立即繼續移動到下一點，不等待
            if !self.routeQueue.isEmpty {
                // 立即調度下一步，不返回（確保連續移動）
                DispatchQueue.main.async {
                    self.scheduleRealisticStep()
                }
                return
            } else {
                // 所有點都走完了，停止
                self.stopTimerOnly()
                return
            }
        }
        
        // 計算移動方向（單位向量）
        let directionLat = dLat / dist
        let directionLon = dLon / dist
        
        // 使用真實數據的移動模式：較小的搖擺（騎車比走路穩定）
        self.pathOffset += 0.1  // 較慢的累積，模擬騎車的穩定移動
        let swingAmount = 0.0000027 * sin(self.pathOffset)  // 約 ±0.3 公尺的搖擺（騎車較穩定）
        
        // 計算垂直於移動方向的搖擺方向
        let perpendicularLat = -directionLon
        let perpendicularLon = directionLat
        
        // 應用搖擺偏移
        let swingLat = perpendicularLat * swingAmount
        let swingLon = perpendicularLon * swingAmount
        
        // 計算這一步應該移動的距離（確保不超過目標點）
        let moveRatio = min(1.0, dist / stepDist)
        
        // 移動到新位置（加上搖擺和 GPS 誤差）
        let gpsErrorLat = Double.random(in: -0.000027...0.000027)  // ±3 公尺 GPS 誤差
        let gpsErrorLon = Double.random(in: -0.000027...0.000027) / latFactor
        
        self.currentLat += directionLat * stepDistLat * moveRatio + swingLat + gpsErrorLat
        self.currentLon += directionLon * stepDistLon * moveRatio + swingLon + gpsErrorLon
        
        // 模擬海拔高度變化（模擬市區地形，10-25 公尺）
        self.altitudeOffset += 0.05  // 更慢的累積
        let terrainVariation = 3.0 * sin(self.altitudeOffset)  // 基礎地形起伏 ±3 公尺
        let randomVariation = Double.random(in: -2.0...2.0)  // 隨機變化 ±2 公尺
        let altitudeChange = (terrainVariation + randomVariation) * 0.05  // 每次變化幅度更小
        
        // 更新海拔高度（限制在合理範圍內：10-25 公尺，模擬台北市區）
        self.currentAltitude = max(10.0, min(25.0, self.currentAltitude + altitudeChange))
        
        // 更新時間戳
        self.lastUpdateTime = Date()
        
        // 激進改進：確保每次都有明顯的位置變化（強制最小移動距離）
        // 如果移動距離太小，強制添加更大的最小移動量（至少 0.5 公尺）
        let minMoveDistance = 0.0000045  // 約 0.5 公尺的最小移動（從 0.11 公尺增加到 0.5 公尺）
        let actualMoveDist = sqrt((directionLat * stepDistLat * moveRatio) * (directionLat * stepDistLat * moveRatio) + 
                                  (directionLon * stepDistLon * moveRatio) * (directionLon * stepDistLon * moveRatio))
        
        if actualMoveDist < minMoveDistance {
            // 如果移動距離太小，強制添加最小移動量（確保 iOS 能檢測到移動）
            self.currentLat += directionLat * minMoveDistance
            self.currentLon += directionLon * minMoveDistance
        }
        
        // 優化：增加位置變化的隨機性，防止 iOS 認為設備已靜止
        // 使用多層次的隨機抖動，確保每次更新都有明顯的位置變化
        let baseJitter = 0.000002  // 基礎抖動約 0.22 公尺
        let microJitter = 0.000001  // 微小抖動約 0.11 公尺（增加隨機性）
        
        // 組合多種隨機抖動
        let jitterLat1 = Double.random(in: -baseJitter...baseJitter)
        let jitterLon1 = Double.random(in: -baseJitter...baseJitter) / latFactor
        let jitterLat2 = Double.random(in: -microJitter...microJitter)
        let jitterLon2 = Double.random(in: -microJitter...microJitter) / latFactor
        
        // 總抖動 = 基礎抖動 + 微小抖動（增加隨機性）
        let totalJitterLat = jitterLat1 + jitterLat2
        let totalJitterLon = jitterLon1 + jitterLon2
        
        // 發送位置更新（加上多層次 GPS 誤差，增加隨機性）
        self.transmit(lat: self.currentLat + totalJitterLat, lon: self.currentLon + totalJitterLon)
        
        // 記錄位置用於檢測原地踏步（多點移動模式也需要檢測）
        self.recordPosition(lat: self.currentLat, lon: self.currentLon)
    }

    // 發送座標至設備（優化版：增加隨機性，確保在主線程執行）
    private func transmit(lat: Double, lon: Double) {
        // 優化：確保所有 UI 更新在主線程執行
        DispatchQueue.main.async { 
            self.webView?.evaluateJavaScript("syncLocation(\(lat), \(lon))") 
        }
        
        // 檢查設備是否已連線
        guard !udid.isEmpty else { 
            return 
        }

        // 優化：增加位置變化的隨機性，使用多層次抖動
        // 基礎抖動（約 ±0.5 公尺）+ 微小抖動（約 ±0.2 公尺）
        let baseJitter = 0.0000045  // 約 ±0.5 公尺
        let microJitter = 0.0000018  // 約 ±0.2 公尺（增加隨機性）
        
        // 組合多種隨機抖動，確保每次都有明顯的位置變化
        let jitter1 = Double.random(in: -baseJitter...baseJitter)
        let jitter2 = Double.random(in: -microJitter...microJitter)
        let finalLat = lat + jitter1 + jitter2
        let finalLon = lon + jitter1 + jitter2

        // 優化：使用最高優先級發送，確保立即執行
        DispatchQueue.global(qos: .userInteractive).async {
            _ = self.shell(self.pythonCommand("-m pymobiledevice3 developer dvt simulate-location set --tunnel \(self.udid) -- \(finalLat) \(finalLon)"))
        }
    }

    // 核心連線邏輯 (彈出密碼要求) - 改進版：完整清除所有進程和端口
    func reconnect() {
        // 更新 UI 狀態
        DispatchQueue.main.async { self.webView?.evaluateJavaScript("setUI('connecting', ' 正在清除舊連線...')") }
        
        DispatchQueue.global(qos: .userInitiated).async {
            // 步驟 1: 強制結束所有相關進程（解決「不連動」問題）
            _ = self.shell("sudo killall -9 pymobiledevice3 2>/dev/null")
            
            // 等待一下讓進程完全結束
            Thread.sleep(forTimeInterval: 0.5)
            
            // 步驟 2: 清除端口佔用 (Port 49151) - 有時候進程關閉了但端口還被鎖定
            _ = self.shell("sudo lsof -i tcp:49151 -t | xargs sudo kill -9 2>/dev/null")
            
            // 再等待一下確保端口釋放
            Thread.sleep(forTimeInterval: 0.5)
            
            // 更新 UI 狀態
            DispatchQueue.main.async { self.webView?.evaluateJavaScript("setUI('connecting', ' 正在請求權限...')") }
            
            // 步驟 3: 檢測設備並重新啟動隧道（改進版 - 支援 macOS 26.2）
            print("🔍 [設備偵測] 開始檢測設備...")
            
            var deviceId: String? = nil
            var matchedPattern: String? = nil
            
            // 方法 1: 使用 libimobiledevice（主要方法 - macOS 26.2 推薦）
            print("📱 [設備偵測] 嘗試使用 libimobiledevice 檢測...")
            let ideviceOutput: String
            if let idevice = self.ideviceIdPath {
                let env = self.envPrefixForShell(pythonPath: self.resolvePythonPath())
                let cmd = env.isEmpty ? "\"\(idevice)\" -l 2>&1" : "\(env) \"\(idevice)\" -l 2>&1"
                ideviceOutput = self.shell(cmd)
            } else {
                ideviceOutput = ""
            }
            print("📱 [設備偵測] idevice_id 輸出: \(ideviceOutput)")
            
            if !ideviceOutput.isEmpty && !ideviceOutput.contains("No device found") && !ideviceOutput.contains("error") {
                // 提取第一個 UDID（可能有多個設備）
                let udids = ideviceOutput.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n")
                if let firstUDID = udids.first, !firstUDID.isEmpty {
                    var id = firstUDID.trimmingCharacters(in: .whitespacesAndNewlines)
                    // 確保格式正確（添加連字符如果沒有）
                    if id.count == 24 && !id.contains("-") {
                        id.insert("-", at: id.index(id.startIndex, offsetBy: 8))
                    }
                    deviceId = id
                    matchedPattern = "libimobiledevice"
                    print("✅ [設備偵測] libimobiledevice 找到設備 ID: \(id)")
                }
            }
            
            // 方法 2: 使用 system_profiler（備用方法 - 如果 libimobiledevice 失敗）
            if deviceId == nil {
                print("📋 [設備偵測] libimobiledevice 未找到設備，嘗試 system_profiler...")
                let info = self.shell("/usr/sbin/system_profiler SPUSBDataType")
                print("📋 [設備偵測] USB 設備資訊長度: \(info.count) 字元")
                
                // 嘗試多種正則表達式模式來匹配序列號（支援 macOS 26.2 可能的格式變更）
                let patterns = [
                    "Serial Number:\\s*([0-9A-Z]{24})",
                    "Serial Number:\\s*([0-9A-Z-]{16,})",
                    "Serial Number:\\s*([0-9A-Z]{8}-[0-9A-Z]{16})",
                    "Serial Number: ([0-9A-Z]{24})",
                    "Serial Number: ([0-9A-Z-]{16,})",
                    "Serial Number: ([0-9A-Z]{8}-[0-9A-Z]{16})",
                    "Product ID:.*Serial Number:\\s*([0-9A-Z-]{16,})"
                ]
                
                // 從 system_profiler 結果中查找
                for pattern in patterns {
                    if let regex = try? NSRegularExpression(pattern: pattern, options: []),
                       let match = regex.firstMatch(in: info, options: [], range: NSRange(location: 0, length: info.utf16.count)) {
                        let ns = info as NSString
                        var id = ns.substring(with: match.range(at: 1))
                        print("✅ [設備偵測] 找到設備 ID (模式: \(pattern)): \(id)")
                        
                        if id.count == 24 && !id.contains("-") {
                            id.insert("-", at: id.index(id.startIndex, offsetBy: 8))
                            print("✅ [設備偵測] 格式化後的設備 ID: \(id)")
                        }
                        
                        deviceId = id
                        matchedPattern = pattern
                        break
                    }
                }
            }
            
            if let id = deviceId {
                print("✅ [設備偵測] 成功找到設備 ID: \(id) (使用模式: \(matchedPattern ?? "unknown"))")
                DispatchQueue.main.async {
                    self.udid = id
                    self.webView?.evaluateJavaScript("setUI('connecting', ' 正在建立隧道...')")
                }

                print("🔧 [隧道] 正在啟動隧道...")
                
                // 使用 osascript 一次性執行所有步驟（只需輸入一次密碼）
                // 使用 sudo -v 延長密碼緩存時間（5分鐘）
                let pythonCmd = self.escapeForAppleScript(self.pythonCommand("-m pymobiledevice3 remote tunneld"))
                let combinedScript = """
                do shell script "sudo -v && sudo killall -9 pymobiledevice3 2>/dev/null; sudo lsof -i tcp:49151 -t 2>/dev/null | xargs -r sudo kill -9 2>/dev/null; sleep 2; sudo rm -f /tmp/pymobiledevice3_tunnel.log 2>/dev/null; sudo touch /tmp/pymobiledevice3_tunnel.log 2>/dev/null; sudo chmod 666 /tmp/pymobiledevice3_tunnel.log 2>/dev/null; sudo \(pythonCmd) > /tmp/pymobiledevice3_tunnel.log 2>&1 &" with administrator privileges
                """
                
                let p = Process()
                p.launchPath = "/usr/bin/osascript"
                p.arguments = ["-e", combinedScript]
                p.standardOutput = nil
                p.standardError = nil
                
                do {
                    try p.run()
                    // 不等待完成，讓它在後台運行
                    print("✅ [隧道] osascript 進程已啟動（後台運行，只需輸入一次密碼）")
                } catch {
                    print("❌ [隧道] 無法啟動 osascript: \(error.localizedDescription)")
                    DispatchQueue.main.async {
                        self.webView?.evaluateJavaScript("setUI('error', '⚠️ 無法啟動隧道進程\\n\\n錯誤: \(error.localizedDescription)')")
                    }
                    return
                }
                
                // 等待一下讓進程啟動
                Thread.sleep(forTimeInterval: 2.5)
                
                // 優化：使用輪詢檢查，最多等待 30 秒（舊筆電可能需要更長時間），每 0.5 秒檢查一次
                var tunnelStarted = false
                let maxAttempts = 60  // 30 秒 / 0.5 秒 = 60 次（增加超時時間以支援舊筆電）
                var attempts = 0
                var lastError: String = ""
                
                while attempts < maxAttempts && !tunnelStarted {
                    Thread.sleep(forTimeInterval: 0.5)  // 增加檢查間隔，減少 CPU 使用
                    attempts += 1
                    
                    // 檢查進程是否在運行（最可靠的方法）
                    let processCheck = self.shell("ps aux | grep 'pymobiledevice3.*tunneld' | grep -v grep")
                    let processRunning = !processCheck.isEmpty
                    
                    // 檢查端口（使用多種方法確保檢測到）
                    let tunnelCheck = self.shell("lsof -i tcp:49151 2>/dev/null | grep LISTEN")
                    let portCheck = self.shell("lsof -i tcp:49151 2>/dev/null")
                    
                    // 檢查日誌檔案中是否有成功標誌
                    var logSuccess = false
                    let logContent = self.shell("cat /tmp/pymobiledevice3_tunnel.log 2>/dev/null")
                    if !logContent.isEmpty {
                        let hasUvicornRunning = logContent.contains("Uvicorn running on http://127.0.0.1:49151")
                        let hasCreatedTunnel = logContent.contains("Created tunnel")
                        let hasAppStartup = logContent.contains("Application startup complete")
                        
                        // 如果日誌中有明確的成功標誌，認為已啟動
                        if hasUvicornRunning || hasCreatedTunnel || hasAppStartup {
                            logSuccess = true
                        }
                    }
                    
                    // 改進的檢測邏輯：優先相信日誌內容
                    if logSuccess {
                        tunnelStarted = true
                        print("✅ [隧道] 隧道已成功啟動（通過日誌確認）")
                        break
                    } else if processRunning && (!tunnelCheck.isEmpty || !portCheck.isEmpty) {
                        tunnelStarted = true
                        print("✅ [隧道] 隧道已成功啟動（通過端口確認）")
                        break
                    } else if processRunning && attempts > 16 {
                        tunnelStarted = true
                        print("✅ [隧道] 隧道已成功啟動（進程運行超過 5 秒）")
                        break
                    }
                    
                    // 如果進程不在運行，檢查是否已退出
                    if !processRunning && attempts > 8 {
                        print("⚠️ [隧道] 隧道進程未運行，可能啟動失敗")
                        if let logContent = try? String(contentsOfFile: "/tmp/pymobiledevice3_tunnel.log", encoding: .utf8) {
                            print("📋 [隧道] 隧道日誌內容:")
                            print(logContent)
                            lastError = logContent
                        }
                        break
                    }
                }
                
                // 步驟 4: 重新獲取裝置列表（確保顯示正確的裝置名稱）
                DispatchQueue.main.async {
                    let devices = self.listConnectedDevices()
                    self.sendDeviceListToWeb(devices)
                    print("🔄 [裝置列表] 已更新裝置列表（共 \(devices.count) 個裝置）")
                }
                
                // 步驟 5: 驗證 HTTP 連線（必須有 HTTP 200 回應才算真正連線）
                var httpVerified = false
                if tunnelStarted {
                    print("🔍 [連線驗證] 開始驗證 HTTP 連線...")
                    for _ in 0..<10 {
                        Thread.sleep(forTimeInterval: 0.5)
                        let httpCheck = self.shell("curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:49151 2>/dev/null || echo '000'")
                        let statusCode = httpCheck.trimmingCharacters(in: .whitespacesAndNewlines)
                        print("🔍 [連線驗證] HTTP 狀態碼: \(statusCode)")
                        if statusCode == "200" {
                            httpVerified = true
                            print("✅ [連線驗證] HTTP 連線驗證成功")
                            break
                        }
                    }
                }
                
                if tunnelStarted && httpVerified {
                    DispatchQueue.main.async {
                        self.webView?.evaluateJavaScript("setUI('online', ' iPhone 已連線')")
                    }
                } else if tunnelStarted && !httpVerified {
                    print("⚠️ [連線驗證] 隧道已啟動但 HTTP 連線驗證失敗")
                    DispatchQueue.main.async {
                        var errorMsg = "⚠️ 隧道已啟動但無法驗證連線\n\n"
                        errorMsg += "可能原因：\n"
                        errorMsg += "1. 設備未正確連接\n"
                        errorMsg += "2. 設備未解鎖或未信任此電腦\n"
                        errorMsg += "3. 請確認設備已連接後重新點擊「初始化連線」\n"
                        self.webView?.evaluateJavaScript("setUI('error', '\(errorMsg)')")
                    }
                } else {
                    print("❌ [隧道] 隧道啟動失敗")
                    var errorMsg = "⚠️ 隧道啟動失敗\n\n"
                    
                    // 分析錯誤原因
                    if lastError.contains("Address already in use") || lastError.contains("address already in use") || lastError.contains("errno 48") {
                        errorMsg += "❌ 端口 49151 已被佔用\n\n"
                        errorMsg += "解決方法：\n"
                        errorMsg += "1. 在終端機執行：sudo lsof -i tcp:49151 -t | xargs sudo kill -9\n"
                        errorMsg += "2. 重新點擊「初始化連線」\n"
                    } else if lastError.contains("No device found") || lastError.contains("device not found") {
                        errorMsg += "❌ 未找到設備\n\n"
                        errorMsg += "請確認：\n"
                        errorMsg += "1. iPhone/iPad 已用 USB 線連接\n"
                        errorMsg += "2. 設備已解鎖\n"
                        errorMsg += "3. 已點擊「信任此電腦」\n"
                    } else if lastError.contains("No module named pymobiledevice3") || lastError.contains("No module named 'pymobiledevice3'") {
                        errorMsg += "❌ 缺少 pymobiledevice3 模組\n\n"
                        errorMsg += "請在終端機執行以下指令安裝：\n"
                        errorMsg += "pip3 install pymobiledevice3\n\n"
                        errorMsg += "或使用 brew 安裝：\n"
                        errorMsg += "brew install --cask pymobiledevice3\n\n"
                        errorMsg += "安裝完成後，重新啟動 App 並點擊「初始化連線」\n"
                    } else if !lastError.isEmpty {
                        let errorPreview = String(lastError.prefix(300))
                        errorMsg += "錯誤訊息：\n\(errorPreview)\n\n"
                        if lastError.contains("python") || lastError.contains("Python") {
                            errorMsg += "\n💡 提示：如果提示缺少 Python 模組，請嘗試：\n"
                            errorMsg += "pip3 install pymobiledevice3\n"
                        }
                    }
                    
                    DispatchQueue.main.async {
                        self.webView?.evaluateJavaScript("setUI('error', '\(errorMsg)')")
                    }
                }

            } else {
                print("❌ [設備偵測] 未找到設備序列號")
                var errorMsg = "⚠️ 未偵測到 iOS 設備\n\n"
                errorMsg += "請確認：\n"
                errorMsg += "1. iPhone/iPad 已用 USB 線連接\n"
                errorMsg += "2. 設備已解鎖\n"
                errorMsg += "3. 已點擊「信任此電腦」\n"
                
                DispatchQueue.main.async { 
                    self.webView?.evaluateJavaScript("setUI('error', '\(errorMsg)')")
                }
            }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let devices = self.listConnectedDevices()
        self.sendDeviceListToWeb(devices)
    }

    // 載入真實 GPS 軌跡數據
    func loadRealTrack(from filePath: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            var data: Data?
            
            // 處理 base64 編碼的數據（從網頁上傳）
            if filePath.hasPrefix("data:application/json;base64,") {
                let base64String = String(filePath.dropFirst("data:application/json;base64,".count))
                if let decodedData = Data(base64Encoded: base64String) {
                    data = decodedData
                }
            } else {
                // 處理本地檔案路徑
                let url: URL?
                if filePath.hasPrefix("/") {
                    url = URL(fileURLWithPath: filePath)
                } else {
                    url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.appendingPathComponent(filePath)
                }
                
                if let url = url {
                    data = try? Data(contentsOf: url)
                }
            }
            
            guard let jsonData = data,
                  let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                  let trackData = json["track"] as? [[String: Any]] else {
                DispatchQueue.main.async {
                    self.webView?.evaluateJavaScript("alert('無法載入軌跡檔案：\(filePath)')")
                }
                return
            }
            
            var loadedTrack: [GPSTrackPoint] = []
            for pointData in trackData {
                guard let lat = pointData["lat"] as? Double,
                      let lon = pointData["lon"] as? Double else { continue }
                
                let altitude = pointData["altitude"] as? Double ?? 10.0
                let speed = pointData["speed"] as? Double ?? 15.0
                let timeOffset = pointData["time_offset"] as? Double ?? 0.0
                
                var timestamp: Date? = nil
                if let timestampStr = pointData["timestamp"] as? String {
                    let formatter = ISO8601DateFormatter()
                    timestamp = formatter.date(from: timestampStr)
                }
                
                loadedTrack.append(GPSTrackPoint(
                    lat: lat,
                    lon: lon,
                    altitude: altitude,
                    speed: speed,
                    timeOffset: timeOffset,
                    timestamp: timestamp
                ))
            }
            
            DispatchQueue.main.async {
                self.realTrack = loadedTrack
                self.isUsingRealTrack = false
                self.webView?.evaluateJavaScript("alert('已載入 \(loadedTrack.count) 個 GPS 軌跡點')")
            }
        }
    }
    
    // 開始播放真實軌跡（完全從當前位置開始，不移動到任何軌跡點）
    func startRealTrackPlayback() {
        guard !realTrack.isEmpty else {
            webView?.evaluateJavaScript("alert('請先載入 GPS 軌跡數據')")
            return
        }
        
        self.stopTimerOnly()
        self.stopStuckCheck()
        self.isUsingRealTrack = true
        self.trackStartTime = Date()
        self.stuckCount = 0
        self.lastPositions = []
        
        // 從當前位置開始，找到最接近的軌跡點作為參考方向
        var minDistance = Double.infinity
        var startIndex = 0
        
        for (index, point) in realTrack.enumerated() {
            let dLat = point.lat - self.currentLat
            let dLon = point.lon - self.currentLon
            let dist = sqrt(dLat * dLat + dLon * dLon)
            if dist < minDistance {
                minDistance = dist
                startIndex = index
            }
        }
        
        self.currentTrackIndex = startIndex
        
        // 重要：保持當前位置不變，不移動到任何軌跡點
        // 只更新速度和海拔作為參考
        if startIndex < realTrack.count {
            let startPoint = realTrack[startIndex]
            self.currentSpeed = startPoint.speed
            self.currentAltitude = startPoint.altitude
        }
        
        // 立即發送當前位置（確保從目前位置開始）
        // 添加真實 GPS 誤差
        let latFactor = cos(self.currentLat * .pi / 180.0)
        let gpsErrorLat = Double.random(in: -0.000027...0.000027)  // ±3 公尺
        let gpsErrorLon = Double.random(in: -0.000027...0.000027) / latFactor
        
        self.transmit(lat: self.currentLat + gpsErrorLat, lon: self.currentLon + gpsErrorLon)
        
        // 記錄起始位置
        self.recordPosition(lat: self.currentLat, lon: self.currentLon)
        
        // 開始播放（從下一個軌跡點開始，但保持當前位置作為起點）
        scheduleRealTrackStep()
        
        // 啟動原地踏步檢測
        startStuckCheck()
    }
    
    // 播放真實軌跡的下一步（優化版：固定間隔 0.5-1 秒）
    private func scheduleRealTrackStep() {
        guard isUsingRealTrack, currentTrackIndex < realTrack.count - 1 else {
            self.stopTimerOnly()
            self.stopStuckCheck()
            self.isUsingRealTrack = false
            webView?.evaluateJavaScript("alert('軌跡播放完成')")
            return
        }
        
        // 確保在主線程執行
        guard Thread.isMainThread else {
            DispatchQueue.main.async {
                self.scheduleRealTrackStep()
            }
            return
        }
        
        let currentPoint = realTrack[currentTrackIndex]
        let nextPoint = realTrack[currentTrackIndex + 1]
        
        // 計算到下一個點的時間間隔
        let timeInterval = nextPoint.timeOffset - currentPoint.timeOffset
        
        // 優化：固定計時器間隔在 0.5-1 秒之間，確保頻繁的位置更新
        // 如果原始間隔太長（> 1 秒），強制縮短到 0.5-1 秒之間
        let actualInterval: Double
        if timeInterval > 1.0 {
            // 如果間隔太長，使用 0.5-1 秒的固定間隔
            let baseInterval = 0.75
            let variation = Double.random(in: -0.25...0.25)
            actualInterval = max(0.5, min(1.0, baseInterval + variation))
        } else {
            // 否則使用原始間隔，但確保至少 0.5 秒
            actualInterval = max(0.5, min(1.0, timeInterval))
        }
        
        timer = Timer.scheduledTimer(withTimeInterval: actualInterval, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            
            // 移動到下一個軌跡點
            self.currentTrackIndex += 1
            
            if self.currentTrackIndex < self.realTrack.count {
                let point = self.realTrack[self.currentTrackIndex]
                
                // 計算從當前位置到目標點的距離和方向
                let dLat = point.lat - self.currentLat
                let dLon = point.lon - self.currentLon
                let dist = sqrt(dLat * dLat + dLon * dLon)
                
                // 激進改進：降低距離閾值，確保更頻繁的位置更新
                // 如果距離很近（< 5 公尺），直接移動到目標點
                // 否則按照真實速度移動（模擬真實移動）
                if dist < 0.000045 {  // 約 5 公尺（從 10 公尺降低）
                    // 直接移動到目標點
                    self.currentLat = point.lat
                    self.currentLon = point.lon
                } else {
                    // 按照真實速度移動（使用極短間隔，確保頻繁更新）
                    let latFactor = cos(self.currentLat * .pi / 180.0)
                    let metersPerDegreeLat = 111000.0
                    let metersPerDegreeLon = 111000.0 * latFactor
                    
                    // 計算移動距離（使用真實速度，但間隔已縮短到 0.4-1 秒）
                    let speedMs = self.currentSpeed / 3.6  // 轉換為 m/s
                    let moveMeters = speedMs * actualInterval
                    
                    // 轉換為度數
                    let moveLat = moveMeters / metersPerDegreeLat
                    let moveLon = moveMeters / metersPerDegreeLon
                    
                    // 計算方向
                    let directionLat = dLat / dist
                    let directionLon = dLon / dist
                    
                    // 計算這一步應該移動的距離（不超過目標點）
                    let moveDist = sqrt(moveLat * moveLat + moveLon * moveLon)
                    let moveRatio = min(1.0, dist / moveDist)
                    
                    // 移動位置
                    self.currentLat += directionLat * moveLat * moveRatio
                    self.currentLon += directionLon * moveLon * moveRatio
                }
                
                // 更新速度和海拔（使用真實數據）
                self.currentAltitude = point.altitude
                self.currentSpeed = point.speed
                
                // 添加真實 GPS 誤差（±3 公尺）
                let latFactor = cos(self.currentLat * .pi / 180.0)
                let gpsErrorLat = Double.random(in: -0.000027...0.000027)  // ±3 公尺
                let gpsErrorLon = Double.random(in: -0.000027...0.000027) / latFactor
                
                // 發送位置更新（加上 GPS 誤差）
                self.transmit(lat: self.currentLat + gpsErrorLat, lon: self.currentLon + gpsErrorLon)
                
                // 記錄位置用於檢測原地踏步
                self.recordPosition(lat: self.currentLat, lon: self.currentLon)
                
                self.scheduleRealTrackStep()
            } else {
                self.stopTimerOnly()
                self.stopStuckCheck()
                self.isUsingRealTrack = false
            }
        }
    }
    
    // 記錄位置用於檢測原地踏步
    private func recordPosition(lat: Double, lon: Double) {
        let now = Date()
        lastPositions.append((lat: lat, lon: lon, time: now))
        
        // 只保留最近 5 個位置
        if lastPositions.count > 5 {
            lastPositions.removeFirst()
        }
    }
    
    // 啟動原地踏步檢測（優化版：更頻繁的檢測）
    private func startStuckCheck() {
        stopStuckCheck()
        // 優化：縮短檢測間隔到 5 秒，更早發現問題
        // 確保在主線程執行
        DispatchQueue.main.async {
            self.stuckCheckTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
                self?.checkIfStuck()
            }
            // 將計時器添加到 RunLoop
            if let timer = self.stuckCheckTimer {
                RunLoop.current.add(timer, forMode: .common)
            }
        }
    }
    
    // 停止原地踏步檢測
    private func stopStuckCheck() {
        stuckCheckTimer?.invalidate()
        stuckCheckTimer = nil
    }
    
    // 檢測是否原地踏步（優化版：更靈敏的檢測和可靠的重啟）
    private func checkIfStuck() {
        // 確保在主線程執行
        guard Thread.isMainThread else {
            DispatchQueue.main.async {
                self.checkIfStuck()
            }
            return
        }
        
        // 支援多點移動和真實軌跡模式的檢測
        guard (isUsingRealTrack || !routeQueue.isEmpty), lastPositions.count >= 3 else { return }
        
        // 優化：降低檢測閾值，更早發現原地踏步（誤差 < 3 公尺）
        let threshold = 0.000027  // 約 3 公尺（從 5 公尺降低）
        var allSame = true
        let firstPos = lastPositions[0]
        
        // 檢查最近 3 個位置是否都在同一個地方
        for pos in lastPositions {
            let dLat = abs(pos.lat - firstPos.lat)
            let dLon = abs(pos.lon - firstPos.lon)
            if dLat > threshold || dLon > threshold {
                allSame = false
                break
            }
        }
        
        if allSame {
            stuckCount += 1
            
            // 優化：降低觸發閾值，更快觸發重啟（從 3 次降低到 2 次）
            if stuckCount >= 2 {  // 從 stuckThreshold (3) 降低到 2
                // 立即觸發自動重新啟動
                if isUsingRealTrack {
                    autoRestartRealTrack()
                } else {
                    autoRestartRouteMode()
                }
                stuckCount = 0  // 重置計數
            }
        } else {
            // 如果移動了，重置計數
            if stuckCount > 0 {
                stuckCount = 0
            }
        }
    }
    
    // 多點移動模式的自動重啟
    private func autoRestartRouteMode() {
        guard !routeQueue.isEmpty else { return }
        
        print("🔄 自動重新啟動多點移動...")
        
        // 停止當前播放
        self.stopTimerOnly()
        
        // 清除舊的位置記錄
        self.lastPositions = []
        
        // 強制發送當前位置（確保位置更新）
        DispatchQueue.global(qos: .userInteractive).async {
            // 添加 GPS 誤差
            let latFactor = cos(self.currentLat * .pi / 180.0)
            let gpsErrorLat = Double.random(in: -0.000027...0.000027)
            let gpsErrorLon = Double.random(in: -0.000027...0.000027) / latFactor
            
            // 強制發送位置
            self.transmit(lat: self.currentLat + gpsErrorLat, lon: self.currentLon + gpsErrorLon)
            
            // 等待一下確保位置已發送
            Thread.sleep(forTimeInterval: 0.3)
            
            // 繼續移動
            DispatchQueue.main.async {
                self.scheduleRealisticStep()
                print("✅ 已重新啟動多點移動")
            }
        }
    }
    
    // 自動重新啟動真實軌跡（優化版：更可靠的重啟邏輯）
    private func autoRestartRealTrack() {
        guard isUsingRealTrack else { return }
        
        // 確保在主線程執行
        guard Thread.isMainThread else {
            DispatchQueue.main.async {
                self.autoRestartRealTrack()
            }
            return
        }
        
        // 停止當前播放
        self.stopTimerOnly()
        
        // 清除舊的位置記錄
        self.lastPositions = []
        self.stuckCount = 0
        
        // 優化：強制發送當前位置，使用更大的隨機抖動確保位置變化
        let latFactor = cos(self.currentLat * .pi / 180.0)
        // 使用更大的 GPS 誤差，確保位置有明顯變化
        let gpsErrorLat = Double.random(in: -0.000045...0.000045)  // ±5 公尺
        let gpsErrorLon = Double.random(in: -0.000045...0.000045) / latFactor
        
        // 強制發送位置（確保在主線程執行）
        self.transmit(lat: self.currentLat + gpsErrorLat, lon: self.currentLon + gpsErrorLon)
        
        // 優化：立即繼續播放，不等待
        // 使用 DispatchQueue.main.asyncAfter 確保位置已發送後再繼續
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            if self.currentTrackIndex < self.realTrack.count {
                self.scheduleRealTrackStep()
            }
        }
    }
    
    func resetEverything() {
        stopTimerOnly()
        stopStuckCheck()
        self.routeQueue = []
        self.pathOffset = 0.0
        self.altitudeOffset = 0.0
        self.currentSpeed = 15.0
        self.isUsingRealTrack = false
        self.currentTrackIndex = 0
        self.stuckCount = 0
        self.lastPositions = []
        // 保持當前海拔和軌跡數據，不重置
    }
    private func stopTimerOnly() { timer?.invalidate(); timer = nil }
    
    // 激活授權碼
    private func activateLicense(licenseKey: String) {
        let apiBaseURL = apiBaseURL()
        let deviceId = getDeviceId()
        
        guard let url = URL(string: "\(apiBaseURL)/license/activate") else {
            print("❌ [授權] 無效的 API URL")
            DispatchQueue.main.async {
                self.webView?.evaluateJavaScript("alert('❌ 無效的 API URL')")
            }
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let body: [String: Any] = [
            "deviceId": deviceId,
            "licenseKey": licenseKey
        ]
        
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            print("❌ [授權] JSON 序列化失敗: \(error)")
            DispatchQueue.main.async {
                self.webView?.evaluateJavaScript("alert('❌ 請求格式錯誤')")
            }
            return
        }
        
        print("📤 [授權] 發送激活請求: deviceId=\(deviceId), licenseKey=\(licenseKey)")
        
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }
            
            if let error = error {
                print("❌ [授權] 網絡錯誤: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    self.webView?.evaluateJavaScript("alert('❌ 網絡錯誤: \(error.localizedDescription)')")
                }
                return
            }
            
            guard let httpResponse = response as? HTTPURLResponse else {
                print("❌ [授權] 無效的響應")
                DispatchQueue.main.async {
                    self.webView?.evaluateJavaScript("alert('❌ 無效的響應')")
                }
                return
            }
            
            print("📋 [授權] HTTP 狀態碼: \(httpResponse.statusCode)")
            
            if httpResponse.statusCode == 200 {
                // 激活成功
                print("✅ [授權] HTTP 200 - 激活請求成功")
                
                // 解析響應數據
                if let data = data {
                    print("📋 [授權] 響應數據長度: \(data.count) bytes")
                    if let jsonString = String(data: data, encoding: .utf8) {
                        print("📋 [授權] 響應內容: \(jsonString)")
                    }
                    
                    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        print("✅ [授權] JSON 解析成功: \(json)")
                        
                        if let success = json["success"] as? Bool, success {
                            print("✅ [授權] 服務器確認激活成功")
                            DispatchQueue.main.async {
                                // 清除本地存儲的試用數據
                                self.webView?.evaluateJavaScript("""
                                    localStorage.removeItem('favLocs');
                                    localStorage.removeItem('tpLocs');
                                    console.log('✅ 授權碼激活成功，清除本地存儲');
                                """)
                                
                                // 直接更新 UI 為已激活狀態（強制更新）
                                self.webView?.evaluateJavaScript("""
                                    console.log('🔄 強制更新 UI 為已激活狀態');
                                    // 先更新狀態
                                    updateTrialStatus(null, true);
                                    // 強制更新頂部狀態欄（確保完全隱藏）
                                    const barEl = document.getElementById('trial-status-bar');
                                    const barCountEl = document.getElementById('remaining-trial-count-bar');
                                    if(barEl) {
                                        barEl.style.display = 'none';
                                        barEl.style.visibility = 'hidden';
                                        barEl.style.height = '0';
                                        barEl.style.overflow = 'hidden';
                                        barEl.style.margin = '0';
                                        barEl.style.padding = '0';
                                    }
                                    if(barCountEl) barCountEl.textContent = '';
                                    // 強制隱藏授權 UI
                                    const authUI = document.getElementById('auth-ui');
                                    if(authUI) {
                                        authUI.style.display = 'none';
                                        authUI.style.visibility = 'hidden';
                                        authUI.style.height = '0';
                                        authUI.style.overflow = 'hidden';
                                    }
                                    console.log('✅ UI 已更新為已激活狀態，所有試用次數顯示已隱藏');
                                """)
                                
                                // 顯示成功訊息
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                    self.webView?.evaluateJavaScript("alert('✅ 授權碼激活成功！\\n\\nApp 已解鎖所有功能')")
                                }
                                
                                // 等待一下再檢查狀態，確保服務器已更新
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                    self.checkAuthStatus()
                                }
                            }
                        } else {
                            print("⚠️ [授權] 服務器響應 success=false")
                            DispatchQueue.main.async {
                                self.webView?.evaluateJavaScript("alert('⚠️ 激活請求已發送，正在驗證...')")
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                                    self.checkAuthStatus()
                                }
                            }
                        }
                    } else {
                        print("❌ [授權] JSON 解析失敗")
                        DispatchQueue.main.async {
                            self.webView?.evaluateJavaScript("alert('✅ 激活請求已發送，正在驗證...')")
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                                self.checkAuthStatus()
                            }
                        }
                    }
                } else {
                    print("❌ [授權] 無響應數據")
                    DispatchQueue.main.async {
                        self.webView?.evaluateJavaScript("alert('✅ 激活請求已發送，正在驗證...')")
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                            self.checkAuthStatus()
                        }
                    }
                }
            } else {
                // 激活失敗
                var errorMsg = "激活失敗 (HTTP \(httpResponse.statusCode))"
                var errorCode: String? = nil
                if let data = data {
                    if let jsonString = String(data: data, encoding: .utf8) {
                        print("📋 [授權] 錯誤響應內容: \(jsonString)")
                    }
                    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let message = json["error"] as? String {
                        errorMsg = message
                        if let c = json["code"] as? String { errorCode = c }
                    }
                }
                print("❌ [授權] 激活失敗: HTTP \(httpResponse.statusCode), 錯誤: \(errorMsg)")
                DispatchQueue.main.async {
                    // Fail Closed：503 KV_UNAVAILABLE
                    if httpResponse.statusCode == 503 || errorCode == "KV_UNAVAILABLE" {
                        self.webView?.evaluateJavaScript("""
                            if (typeof updateAuthUnavailable === 'function') {
                                updateAuthUnavailable('KV_UNAVAILABLE', '\(errorMsg)');
                            } else {
                                alert('❌ 授權狀態暫不可用（KV_UNAVAILABLE）');
                            }
                        """)
                    } else {
                        let codeText = (errorCode != nil) ? "（\(errorCode!)）" : ""
                        self.webView?.evaluateJavaScript("alert('❌ \(errorMsg)\(codeText)')")
                    }
                }
            }
        }.resume()
    }
    
    // 檢查授權狀態（根據設備 UUID 自動識別是否已購買）
    private func checkAuthStatus() {
        let apiBaseURL = apiBaseURL()
        let deviceId = getDeviceId()
        
        print("🔍 [授權檢查] 開始檢查，設備 UUID: \(deviceId)")
        print("🔍 [授權檢查] API URL: \(apiBaseURL)/auth/check")
        
        guard let url = URL(string: "\(apiBaseURL)/auth/check") else {
            print("❌ [授權] 無效的 API URL")
            DispatchQueue.main.async {
                self.webView?.evaluateJavaScript("updateTrialStatus(null, false)")
            }
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 5.0
        
        let body: [String: Any] = [
            "deviceId": deviceId
        ]
        
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            print("❌ [授權] JSON 序列化失敗: \(error)")
            DispatchQueue.main.async {
                self.webView?.evaluateJavaScript("updateTrialStatus(null, false)")
            }
            return
        }
        
        print("📤 [授權] 檢查授權狀態: deviceId=\(deviceId)")
        
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }
            
            if let error = error {
                print("❌ [授權] 網絡錯誤: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    // Fail Closed：顯示授權狀態不可用（避免誤顯示 trial 可用）
                    self.webView?.evaluateJavaScript("""
                        if (typeof updateAuthUnavailable === 'function') {
                            updateAuthUnavailable('NETWORK_ERROR', '\(error.localizedDescription)');
                        } else {
                            updateTrialStatus(null, false);
                        }
                    """)
                }
                return
            }
            
            guard let httpResponse = response as? HTTPURLResponse else {
                print("❌ [授權] 無效的響應")
                DispatchQueue.main.async {
                    self.webView?.evaluateJavaScript("updateTrialStatus(null, false)")
                }
                return
            }
            
            print("📋 [授權] HTTP 狀態碼: \(httpResponse.statusCode)")
            
            if httpResponse.statusCode == 200 {
                if let data = data {
                    if let jsonString = String(data: data, encoding: .utf8) {
                        print("📋 [授權檢查] 響應內容: \(jsonString)")
                    }
                    
                    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        let trialExpiresAt = json["trialExpiresAt"] as? String
                        let isActivated = json["isActivated"] as? Bool ?? false
                        let licenseKey = json["licenseKey"] as? String
                        
                        print("✅ [授權檢查] 服務器返回: trialExpiresAt=\(trialExpiresAt ?? "nil"), isActivated=\(isActivated), licenseKey=\(licenseKey ?? "nil")")
                        
                        // ⚠️ 修正：僅依賴 server 返回的 isActivated 作為唯一判斷依據
                        // 不可使用 licenseKey 存在性檢查，因為 server 可能已重啟，licenseKey 在 server 端已遺失
                        let isPaid = isActivated
                        
                        print("💰 [授權檢查] 最終判斷: isPaid=\(isPaid) (僅依賴 server 的 isActivated，這是唯一真實來源)")
                        
                        DispatchQueue.main.async {
                            if isPaid {
                                // 已激活/已購買，顯示為已付費，無限制使用
                                print("✅ [授權檢查] 設備已購買，更新 UI 為已激活狀態（無限制使用）")
                                let deviceIdHash = String(deviceId.prefix(8)) + "..." + String(deviceId.suffix(4))
                                let serverTimeStr = json["serverTime"] as? String ?? ISO8601DateFormatter().string(from: Date())
                                self.webView?.evaluateJavaScript("""
                                    console.log('🔄 檢查授權後更新 UI 為已激活狀態（設備已購買）');
                                    // 先更新狀態（null 表示已購買）
                                    updateTrialStatus(null, true);
                                    // ⚠️ P0 必修 3：更新 Debug Snapshot
                                    if (typeof updateAuthDebugSnapshot === 'function') {
                                        updateAuthDebugSnapshot('\(deviceIdHash)', true, null, '\(serverTimeStr)', 'server');
                                    }
                                    // 強制更新頂部狀態欄（確保完全隱藏）
                                    const barEl = document.getElementById('trial-status-bar');
                                    const barCountEl = document.getElementById('remaining-trial-count-bar');
                                    if(barEl) {
                                        barEl.style.display = 'none';
                                        barEl.style.visibility = 'hidden';
                                        barEl.style.height = '0';
                                        barEl.style.overflow = 'hidden';
                                        barEl.style.margin = '0';
                                        barEl.style.padding = '0';
                                    }
                                    if(barCountEl) barCountEl.textContent = '';
                                    // 強制隱藏授權 UI
                                    const authUI = document.getElementById('auth-ui');
                                    if(authUI) {
                                        authUI.style.display = 'none';
                                        authUI.style.visibility = 'hidden';
                                        authUI.style.height = '0';
                                        authUI.style.overflow = 'hidden';
                                    }
                                    console.log('✅ UI 已更新為已激活狀態，所有試用狀態顯示已隱藏，可以無限制使用');
                                """)
                            } else {
                                // 未激活，顯示試用到期時間
                                print("⚠️ [授權檢查] 設備未購買，更新 UI 為試用狀態，到期時間: \(trialExpiresAt ?? "無")")
                                let formatter = ISO8601DateFormatter()
                                let currentTime = formatter.string(from: Date())
                                let serverTimeStr = json["serverTime"] as? String ?? currentTime
                                // ⚠️ P0 必修 3：生成 deviceId hash（僅顯示前 8 字符，保護隱私）
                                let deviceIdHash = String(deviceId.prefix(8)) + "..." + String(deviceId.suffix(4))
                                let trialExpiresAtJS = trialExpiresAt != nil ? "'\(trialExpiresAt!)'" : "null"
                                self.webView?.evaluateJavaScript("""
                                    updateTrialStatus(\(trialExpiresAtJS), false);
                                    if (typeof updateAuthDebugSnapshot === 'function') {
                                        updateAuthDebugSnapshot('\(deviceIdHash)', false, \(trialExpiresAtJS), '\(serverTimeStr)', 'server');
                                    }
                                """)
                            }
                        }
                    } else {
                        print("❌ [授權檢查] 無法解析響應數據")
                        if let jsonString = String(data: data, encoding: .utf8) {
                            print("❌ [授權檢查] 原始響應: \(jsonString)")
                        }
                        DispatchQueue.main.async {
                            self.webView?.evaluateJavaScript("""
                                if (typeof updateAuthUnavailable === 'function') {
                                    updateAuthUnavailable('PARSE_ERROR', '無法解析授權響應');
                                } else {
                                    updateTrialStatus(null, false);
                                }
                            """)
                        }
                    }
                } else {
                    print("❌ [授權檢查] 無響應數據")
                    DispatchQueue.main.async {
                        self.webView?.evaluateJavaScript("""
                            if (typeof updateAuthUnavailable === 'function') {
                                updateAuthUnavailable('NO_RESPONSE', '授權服務無回應');
                            } else {
                                updateTrialStatus(null, false);
                            }
                        """)
                    }
                }
            } else {
                // Fail Closed：503/錯誤碼顯示清楚
                var code = "HTTP_\(httpResponse.statusCode)"
                var msg = "授權狀態暫不可用"
                if let data = data,
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    if let serverCode = json["code"] as? String { code = serverCode }
                    if let serverMsg = (json["message"] as? String) ?? (json["error"] as? String) { msg = serverMsg }
                }
                print("❌ [授權] 服務器錯誤: \(httpResponse.statusCode) code=\(code) msg=\(msg)")
                DispatchQueue.main.async {
                    self.webView?.evaluateJavaScript("""
                        if (typeof updateAuthUnavailable === 'function') {
                            updateAuthUnavailable('\(code)', '\(msg)');
                        } else {
                            updateTrialStatus(null, false);
                        }
                    """)
                }
            }
        }.resume()
    }

    // 消耗試用次數（由 Swift 統一處理，避免 Web 端直連造成狀態不一致）
    private func consumeTrial(feature: String) {
        let apiBaseURL = apiBaseURL()
        let deviceId = getDeviceId()

        guard let url = URL(string: "\(apiBaseURL)/trial/consume") else {
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10.0

        let body: [String: Any] = [
            "deviceId": deviceId,
            "feature": feature
        ]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            return
        }

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }

            if let error = error {
                DispatchQueue.main.async {
                    self.webView?.evaluateJavaScript("""
                        if (window.onConsumeTrialResult) {
                            window.onConsumeTrialResult({ feature: '\(feature)', ok: false, code: 'NETWORK_ERROR', error: '\(error.localizedDescription)', trialCount: 0, isActivated: false });
                        }
                    """)
                }
                return
            }

            guard let httpResponse = response as? HTTPURLResponse else { return }

            var payload: [String: Any] = [
                "feature": feature,
                "ok": false,
                "code": "HTTP_\(httpResponse.statusCode)",
                "trialExpiresAt": NSNull(),
                "isActivated": false
            ]

            if let data = data,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let success = json["success"] as? Bool, success == true {
                    payload["ok"] = true
                    payload["trialExpiresAt"] = json["trialExpiresAt"] as? String ?? NSNull()
                    payload["isActivated"] = json["isActivated"] as? Bool ?? false
                } else {
                    if let c = json["code"] as? String { payload["code"] = c }
                    if let err = (json["error"] as? String) ?? (json["message"] as? String) { payload["error"] = err }
                    if let expiresAt = json["trialExpiresAt"] as? String { payload["trialExpiresAt"] = expiresAt }
                }
            } else {
                payload["error"] = "無法解析服務器回應"
            }

            // 狀態碼判斷：403 但無 code 時，視為 TRIAL_EXPIRED
            if httpResponse.statusCode == 403, (payload["code"] as? String)?.hasPrefix("HTTP_") == true {
                payload["code"] = "TRIAL_EXPIRED"
            }
            if httpResponse.statusCode == 503 {
                payload["code"] = "KV_UNAVAILABLE"
            }

            if let jsonData = try? JSONSerialization.data(withJSONObject: payload, options: []),
               let jsonString = String(data: jsonData, encoding: .utf8) {
                DispatchQueue.main.async {
                    self.webView?.evaluateJavaScript("window.onConsumeTrialResult && window.onConsumeTrialResult(\(jsonString));")
                }
            }
        }.resume()
    }
    
    private func setPreferredDevice(_ udid: String) {
        let trimmed = udid.trimmingCharacters(in: .whitespacesAndNewlines)
        self.preferredUDID = trimmed
        if trimmed.isEmpty {
            UserDefaults.standard.removeObject(forKey: preferredUDIDKey)
        } else {
            UserDefaults.standard.set(trimmed, forKey: preferredUDIDKey)
        }
        DispatchQueue.main.async {
            self.postSelectedDeviceToWeb(trimmed)
        }
    }
    
    private func listConnectedDevices() -> [[String: String]] {
        let output = shell(pythonCommand("-m pymobiledevice3 usbmux list 2>/dev/null"))
        if let json = parseDeviceListJSON(output) {
            // 只過濾出 USB 連線的裝置（Network 無法成功改定位）
            let usbDevices = json.compactMap { item -> [String: String]? in
                guard let identifier = item["Identifier"] as? String else { return nil }
                let conn = (item["ConnectionType"] as? String ?? "").uppercased()
                // 只接受 USB 連線
                if conn != "USB" && !conn.isEmpty {
                    return nil
                }
                var device: [String: String] = ["Identifier": identifier]
                if let name = item["DeviceName"] as? String { device["DeviceName"] = name }
                device["ConnectionType"] = "USB"  // 統一標記為 USB
                if let unique = item["UniqueDeviceID"] as? String { device["UniqueDeviceID"] = unique }
                return device
            }
            // 去重：同一台裝置只顯示一次
            var byUdid: [String: [String: String]] = [:]
            for device in usbDevices {
                let udid = device["UniqueDeviceID"] ?? device["Identifier"] ?? ""
                if udid.isEmpty { continue }
                if byUdid[udid] == nil {
                    byUdid[udid] = device
                }
            }
            return Array(byUdid.values)
        }
        // fallback: libimobiledevice only provides UDID list
        let ideviceOutput: String
        if let idevice = ideviceIdPath {
            let env = envPrefixForShell(pythonPath: resolvePythonPath())
            let cmd = env.isEmpty ? "\"\(idevice)\" -l 2>/dev/null" : "\(env) \"\(idevice)\" -l 2>/dev/null"
            ideviceOutput = shell(cmd)
        } else {
            ideviceOutput = ""
        }
        let udids = ideviceOutput
            .split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return udids.map { ["Identifier": $0] }
    }

    private func parseDeviceListJSON(_ output: String) -> [[String: Any]]? {
        if let data = output.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [[String: Any]] {
            return json
        }
        // 嘗試擷取第一段 JSON 陣列（避免 stdout 混雜 warning）
        guard let start = output.firstIndex(of: "["),
              let end = output.lastIndex(of: "]"),
              start < end else { return nil }
        let substring = String(output[start...end])
        guard let data = substring.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [[String: Any]] else {
            return nil
        }
        return json
    }

    private func escapeForJS(_ text: String) -> String {
        return text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "")
    }
    
    private func sendDeviceListToWeb(_ devices: [[String: String]]) {
        guard let jsonData = try? JSONSerialization.data(withJSONObject: devices, options: []),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            return
        }
        DispatchQueue.main.async {
            // 直接调用 JavaScript 函数，不使用 postMessage（WKWebView 中更可靠）
            self.webView?.evaluateJavaScript("""
                (function() {
                    if (typeof applyDeviceList === 'function') {
                        applyDeviceList(\(jsonString));
                    } else if (window.postMessage) {
                        window.postMessage({ type: 'deviceList', devices: \(jsonString) }, '*');
                    }
                })();
            """)
            self.postSelectedDeviceToWeb(self.preferredUDID)
        }
    }
    
    private func postSelectedDeviceToWeb(_ udid: String) {
        let safe = udid.replacingOccurrences(of: "'", with: "\\'").replacingOccurrences(of: "\"", with: "\\\"")
        DispatchQueue.main.async {
            self.webView?.evaluateJavaScript("""
                (function() {
                    const select = document.getElementById('device-select');
                    if (select && '\(safe)') {
                        select.value = '\(safe)';
                    }
                    if (window.postMessage) {
                        window.postMessage({ type: 'selectedDevice', udid: '\(safe)' }, '*');
                    }
                })();
            """)
        }
    }

    // 獲取設備 ID
    private func getDeviceId() -> String {
        let result = shell("system_profiler SPHardwareDataType | grep 'Hardware UUID' | awk '{print $3}'")
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @discardableResult private func shell(_ command: String) -> String {
        let task = Process(), pipe = Pipe(); task.standardOutput = pipe; task.standardError = pipe
        task.launchPath = "/bin/bash"; task.arguments = ["-c", command]; task.launch()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }
    
    // 上線版本不寫入最愛備份檔（避免產生/混入個資檔案）
}

struct ContentView: View {
    @StateObject private var engine = LocationEngine()
    var body: some View { 
        AppleMapView(engine: engine)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct AppleMapView: NSViewRepresentable {
    let engine: LocationEngine
    func makeNSView(context: NSViewRepresentableContext<AppleMapView>) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(engine, name: "bridge")
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = engine
        engine.webView = webView
        if let url = Bundle.main.url(forResource: "index", withExtension: "html") {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
        return webView
    }
    func updateNSView(_ nsView: WKWebView, context: NSViewRepresentableContext<AppleMapView>) {}
}