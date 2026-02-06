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
    
    // Helper Process 持久連線管理（簡化版 — 不用 NSLock，避免死鎖）
    private var helperProcess: Process?
    private var helperStdinPipe: Pipe?
    private var helperStdoutPipe: Pipe?
    private var helperReady: Bool = false
    private var helperDegraded: Bool = false
    private var lastSuccessfulSend: Date?
    private var lastAutoReconnect: Date?
    private var lastHelperRestart: Date?
    private var helperSendCount: Int = 0
    private var helperErrorCount: Int = 0
    private var helperConsecutiveErrors: Int = 0
    private let helperQueue = DispatchQueue(label: "pikmin.helper.queue")
    private var helperMonitorThread: Thread?
    
    // Tunnel Watchdog
    private var tunnelWatchdogTimer: Timer?
    private var tunnelWasRunning: Bool = false
    
    // 腳步擺動相關
    private var cruiseStepPhase: Double = 0.0
    private var gpsNoiseLat: Double = 0.0
    private var gpsNoiseLon: Double = 0.0
    private var speedDrift: Double = 0.0
    private var baseSpeedKmh: Double = 16.0
    private var minSpeedKmh: Double = 13.0
    private var maxSpeedKmh: Double = 18.0
    
    /// 取得實際用於 simulate-location 的 UDID：優先使用者選擇，否則用隧道設定的
    private func effectiveUDID() -> String {
        let preferred = preferredUDID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !preferred.isEmpty { return preferred }
        return udid
    }

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
            self.webView?.evaluateJavaScript("setUI('connecting', ' 首次使用：正在安裝必要套件（可能需要1-2分鐘）...')")
        }
        
        // 策略 1: 先嘗試不加 --user 的全局安裝（sudo 環境也能看到）
        var installOut = shell("\"\(pythonPath)\" -m pip install --quiet pymobiledevice3 2>&1")
        if hasPymobiledevice3(pythonPath) {
            print("✅ [自動安裝] pymobiledevice3 全局安裝成功")
            pymobiledevice3Installed = true
            return
        }
        print("⚠️ [自動安裝] 全局安裝失敗（可能需要更高權限），輸出: \(installOut)")
        
        // 策略 2: 使用 pip3 命令直接安裝（某些系統 pip3 可用但 python3 -m pip 不行）
        installOut = shell("pip3 install --quiet pymobiledevice3 2>&1")
        if hasPymobiledevice3(pythonPath) {
            print("✅ [自動安裝] pymobiledevice3 通過 pip3 安裝成功")
            pymobiledevice3Installed = true
            return
        }
        print("⚠️ [自動安裝] pip3 安裝失敗，輸出: \(installOut)")

        // 策略 3: 使用 --user 安裝（舊的方式，作為最後備選）
        installOut = shell("\"\(pythonPath)\" -m pip install --user --quiet pymobiledevice3 2>&1")
        if hasPymobiledevice3(pythonPath) {
            print("✅ [自動安裝] pymobiledevice3 --user 安裝成功")
            pymobiledevice3Installed = true
            return
        }
        
        // 策略 4: 嘗試先安裝/升級 pip 本身，然後再裝 pymobiledevice3
        print("⚠️ [自動安裝] 嘗試先安裝 pip...")
        _ = shell("\"\(pythonPath)\" -m ensurepip --upgrade 2>&1")
        _ = shell("\"\(pythonPath)\" -m pip install --upgrade pip 2>&1")
        installOut = shell("\"\(pythonPath)\" -m pip install pymobiledevice3 2>&1")
        if hasPymobiledevice3(pythonPath) {
            print("✅ [自動安裝] pymobiledevice3 安裝成功（先修復 pip 後）")
            pymobiledevice3Installed = true
            return
        }
        
        print("⚠️ [自動安裝] 所有非 sudo 安裝方式都失敗，將在啟動隧道時以 sudo 安裝")
        print("⚠️ [自動安裝] 最後輸出: \(installOut)")
        pymobiledevice3Installed = false
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
    
    // ========== Helper Process 持久連線管理 ==========
    
    // MARK: - Helper Process Lifecycle（從參考專案移植）

    private func startHelper() {
        stopHelper()

        // 確認 tunnel 還在
        if !isTunnelRunning() {
            print("❌ [Helper] tunneld 不在運行，無法啟動 helper")
            return
        }

        let helperPath = Bundle.main.path(forResource: "location_helper", ofType: "py") ??
                         "\(Bundle.main.bundlePath)/Contents/Resources/location_helper.py"
        guard FileManager.default.fileExists(atPath: helperPath) else {
            print("❌ [Helper] 找不到 location_helper.py")
            return
        }

        let pythonPath = resolvePythonPath()
        guard FileManager.default.fileExists(atPath: pythonPath) else {
            print("❌ [Helper] 找不到 Python at \(pythonPath)")
            return
        }

        let process = Process()
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: pythonPath)
        process.arguments = ["-u", helperPath, effectiveUDID()]
        
        // 環境變數
        var env: [String: String] = [
            "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": NSHomeDirectory(),
            "PYTHONUNBUFFERED": "1",
            "PYTHONDONTWRITEBYTECODE": "1"
        ]
        if FileManager.default.fileExists(atPath: bundledLibPath) {
            env["DYLD_LIBRARY_PATH"] = bundledLibPath
        }
        if FileManager.default.fileExists(atPath: bundledBinPath) {
            env["PATH"] = "\(bundledBinPath):\(env["PATH"]!)"
        }
        // 加入 bundled Python 的 site-packages
        let sitePackages = "\(bundledPythonBasePath)/lib/python3.9/site-packages"
        if FileManager.default.fileExists(atPath: sitePackages) {
            env["PYTHONPATH"] = sitePackages
        }
        process.environment = env

        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            print("❌ [Helper] 啟動失敗: \(error)")
            return
        }

        helperProcess = process
        helperStdinPipe = stdinPipe
        helperStdoutPipe = stdoutPipe

        helperSendCount = 0
        helperErrorCount = 0
        helperConsecutiveErrors = 0
        helperDegraded = false

        // READY semaphore（最多等 12 秒）
        let readySemaphore = DispatchSemaphore(value: 0)
        var gotReady = false

        // 持續讀取 stdout（Monitor Thread）
        let monitorThread = Thread {
            let handle = stdoutPipe.fileHandleForReading
            var lineBuffer = ""

            while true {
                guard let data = try? handle.availableData, !data.isEmpty else {
                    self.helperReady = false
                    break
                }
                guard let str = String(data: data, encoding: .utf8) else { continue }
                lineBuffer += str

                while let newlineRange = lineBuffer.range(of: "\n") {
                    let line = String(lineBuffer[lineBuffer.startIndex..<newlineRange.lowerBound])
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    lineBuffer = String(lineBuffer[newlineRange.upperBound...])
                    if line.isEmpty { continue }

                    if line == "READY" || line.hasPrefix("READY") {
                        self.helperReady = true
                        self.helperDegraded = line.contains("CLI")
                        print("✅ [Helper] ready: \(line)")
                        if !gotReady { gotReady = true; readySemaphore.signal() }
                    } else if line == "OK" || line.hasPrefix("OK:") {
                        self.lastSuccessfulSend = Date()
                        self.helperConsecutiveErrors = 0
                    } else if line.hasPrefix("ERR:") {
                        self.helperErrorCount += 1
                        self.helperConsecutiveErrors += 1
                        if self.helperConsecutiveErrors >= 10 {
                            self.helperReady = false
                        }
                    } else if line == "PONG" || line == "PONG:DEGRADED" {
                        if line.contains("DEGRADED") { self.helperDegraded = true }
                    }
                }
            }
        }
        monitorThread.qualityOfService = .userInitiated
        monitorThread.name = "pikmin.helper.monitor"
        monitorThread.start()
        self.helperMonitorThread = monitorThread

        // stderr log
        DispatchQueue.global(qos: .utility).async {
            let handle = stderrPipe.fileHandleForReading
            while true {
                guard let data = try? handle.availableData, !data.isEmpty else { break }
                if let str = String(data: data, encoding: .utf8) {
                    for line in str.split(separator: "\n") {
                        print("[helper-stderr] \(line)")
                    }
                }
            }
        }

        let waitResult = readySemaphore.wait(timeout: .now() + 12.0)
        if waitResult == .timedOut && !gotReady {
            print("⚠️ [Helper] 12 秒內未收到 READY")
        }
    }

    private func stopHelper() {
        helperReady = false
        helperDegraded = false

        if let process = helperProcess, process.isRunning {
            if let stdin = helperStdinPipe?.fileHandleForWriting {
                try? stdin.write(contentsOf: "QUIT\n".data(using: .utf8)!)
            }
            usleep(300_000)
            if process.isRunning { process.terminate() }
            usleep(200_000)
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        helperProcess = nil
        helperStdinPipe = nil
        helperStdoutPipe = nil
        helperMonitorThread = nil

        // 殺死孤兒 helper 進程
        let udid = effectiveUDID()
        if !udid.isEmpty {
            let _ = shell("pgrep -f 'location_helper.py.*\(udid)' | xargs kill -9 2>/dev/null")
        }
    }

    /// 重連後立刻發送當前位置 5 次（防止跳回家）
    private func blastCurrentPosition() {
        let lat = currentLat
        let lon = currentLon
        guard lat != 0.0 || lon != 0.0 else { return }
        for i in 0..<5 {
            let jitter = 0.0000015
            let jLat = lat + Double.random(in: -jitter...jitter)
            let jLon = lon + Double.random(in: -jitter...jitter)
            if let stdin = helperStdinPipe?.fileHandleForWriting,
               let data = "\(jLat) \(jLon)\n".data(using: .utf8) {
                try? stdin.write(contentsOf: data)
            }
            if i < 4 { Thread.sleep(forTimeInterval: 0.15) }
        }
    }

    /// Soft reconnect: 只重啟 helper（不碰 tunnel，不彈密碼）
    private func softReconnectIfNeeded(reason: String) {
        let now = Date()
        if let last = lastAutoReconnect, now.timeIntervalSince(last) < 8.0 { return }
        lastAutoReconnect = now

        helperQueue.async { [weak self] in
            guard let self = self else { return }
            self.startHelper()
            if self.helperReady { self.blastCurrentPosition() }
        }
    }

    // MARK: - Tunnel Watchdog

    private func startTunnelWatchdog() {
        stopTunnelWatchdog()
        tunnelWasRunning = true
        tunnelWatchdogTimer = Timer.scheduledTimer(withTimeInterval: 15.0, repeats: true) { [weak self] _ in
            self?.checkTunnelHealth()
        }
        if let t = tunnelWatchdogTimer { RunLoop.current.add(t, forMode: .common) }
    }

    private func stopTunnelWatchdog() {
        tunnelWatchdogTimer?.invalidate()
        tunnelWatchdogTimer = nil
    }

    private func checkTunnelHealth() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            let alive = self.isTunnelRunning()
            if alive {
                if !self.helperReady {
                    let canRestart: Bool
                    if let last = self.lastHelperRestart { canRestart = Date().timeIntervalSince(last) > 15.0 }
                    else { canRestart = true }
                    if canRestart {
                        self.lastHelperRestart = Date()
                        self.helperQueue.async {
                            self.startHelper()
                            if self.helperReady { self.blastCurrentPosition() }
                        }
                    }
                }
            } else {
                if self.tunnelWasRunning {
                    self.tunnelWasRunning = false
                    DispatchQueue.main.async {
                        self.webView?.evaluateJavaScript("setUI('error', '隧道已斷線，請點擊初始化連線')")
                    }
                }
            }
        }
    }

    private func isTunnelRunning() -> Bool {
        let httpCheck = shell("curl -s -m 2 -o /dev/null -w '%{http_code}' http://127.0.0.1:49151 2>/dev/null")
        if httpCheck.trimmingCharacters(in: .whitespacesAndNewlines) == "200" { return true }
        let processCheck = shell("ps aux | grep 'pymobiledevice3.*remote.*tunneld' | grep -v grep | grep -v 'listen-port'")
        return !processCheck.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    
    /// 高斯隨機數生成器（Box-Muller 轉換）
    private func gaussianRandom() -> Double {
        let u1 = max(1e-10, Double.random(in: 0.0...1.0))
        let u2 = Double.random(in: 0.0...1.0)
        return sqrt(-2.0 * log(u1)) * cos(2.0 * .pi * u2)
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
            let kmh = dict["kmh"] as? Double ?? 16.0
            let loop = dict["loop"] as? Bool ?? true
            self.startCruise(points: pts, kmh: kmh, loop: loop)
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
        
        // 檢查設備是否已連線（使用 effectiveUDID 以支援使用者選擇的裝置）
        let targetUDID = effectiveUDID()
        guard !targetUDID.isEmpty else {
            print("⚠️ [瞬移] UDID 為空，無法發送位置")
            return
        }
        
        print("📍 [瞬移] 準備發送位置: lat=\(lat), lon=\(lon), udid=\(targetUDID)")
        
        // 瞬移使用精確位置，只添加最小的 GPS 誤差（約 ±0.15 公尺）
        // 不使用多層次抖動，確保精確瞬移
        let jitter = 0.00000135  // 約 ±0.15 公尺（最小誤差）
        let finalLat = lat + Double.random(in: -jitter...jitter)
        let finalLon = lon + Double.random(in: -jitter...jitter)
        
        // 立即發送位置（使用最高優先級，使用 effectiveUDID）
        DispatchQueue.global(qos: .userInteractive).async {
            let targetUDID = self.effectiveUDID()
            let cmd = self.pythonCommand("-m pymobiledevice3 developer dvt simulate-location set --tunnel \(targetUDID) -- \(finalLat) \(finalLon)")
            print("🔧 [瞬移] 執行命令: \(cmd)")
            let result = self.shell(cmd)
            if !result.isEmpty {
                print("📋 [瞬移] 命令輸出: \(result)")
            } else {
                print("✅ [瞬移] 命令執行完成（無輸出）")
            }
        }
    }

    // ========== 散花模式 v2.1 ==========
    // Catmull-Rom 樣條插值 + cruiseTick 0.3秒 + 步行擺動 + GPS噪點
    
    // 平滑路徑（Catmull-Rom 產出，每 1.5m 一個子點）
    private var smoothPath: [[Double]] = []
    private var smoothPathIndex: Int = 0
    private var routeOriginal: [[Double]] = []  // 原始路由點
    private var cruiseLoop: Bool = false         // 循環路線
    private var cruiseLastTick: Date?
    private var cruiseStartTime: Date?
    private var walkingSpeedKmh: Double = 16.0   // 當前走路速度
    
    // Catmull-Rom 插值
    private func catmullRom(t: Double, p0: Double, p1: Double, p2: Double, p3: Double) -> Double {
        let t2 = t * t
        let t3 = t2 * t
        return 0.5 * ((2.0 * p1) +
                       (-p0 + p2) * t +
                       (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * t2 +
                       (-p0 + 3.0 * p1 - 3.0 * p2 + p3) * t3)
    }
    
    // Haversine 距離（公尺）
    private func haversineMeters(lat1: Double, lon1: Double, lat2: Double, lon2: Double) -> Double {
        let R = 6371000.0
        let dLat = (lat2 - lat1) * .pi / 180.0
        let dLon = (lon2 - lon1) * .pi / 180.0
        let a = sin(dLat / 2) * sin(dLat / 2) +
                cos(lat1 * .pi / 180.0) * cos(lat2 * .pi / 180.0) *
                sin(dLon / 2) * sin(dLon / 2)
        let c = 2 * atan2(sqrt(a), sqrt(1 - a))
        return R * c
    }
    
    // 建立平滑路徑（Catmull-Rom，每 metersPerSegment 公尺一個子點）
    private func buildSmoothPath(waypoints: [[Double]], metersPerSegment: Double = 1.5) -> [[Double]] {
        guard waypoints.count >= 2 else { return waypoints }
        
        // 擴充控制點（首尾各鏡射一個點）
        var pts = waypoints
        let first = pts[0]
        let last = pts[pts.count - 1]
        let mirrorFirst = [2.0 * first[0] - pts[1][0], 2.0 * first[1] - pts[1][1]]
        let mirrorLast = [2.0 * last[0] - pts[pts.count - 2][0], 2.0 * last[1] - pts[pts.count - 2][1]]
        pts.insert(mirrorFirst, at: 0)
        pts.append(mirrorLast)
        
        var result: [[Double]] = []
        
        for i in 1..<(pts.count - 2) {
            let segDist = haversineMeters(lat1: pts[i][0], lon1: pts[i][1],
                                          lat2: pts[i + 1][0], lon2: pts[i + 1][1])
            let steps = max(2, Int(segDist / metersPerSegment))
            
            for s in 0..<steps {
                let t = Double(s) / Double(steps)
                let lat = catmullRom(t: t, p0: pts[i - 1][0], p1: pts[i][0],
                                     p2: pts[i + 1][0], p3: pts[i + 2][0])
                let lon = catmullRom(t: t, p0: pts[i - 1][1], p1: pts[i][1],
                                     p2: pts[i + 1][1], p3: pts[i + 2][1])
                result.append([lat, lon])
            }
        }
        
        // 加上最後一個點
        result.append(pts[pts.count - 2])
        return result
    }

    // 散花模式入口（v2.1 - Catmull-Rom + cruiseTick 0.3s）
    func startCruise(points: [[Double]], kmh: Double, loop: Bool = true) {
        self.stopTimerOnly()
        self.stopStuckCheck()
        self.routeQueue = points
        self.routeOriginal = points
        guard !points.isEmpty else { return }
        
        // 建立平滑路徑
        self.smoothPath = buildSmoothPath(waypoints: points)
        self.smoothPathIndex = 0
        
        // 初始化速度（使用傳入的 kmh，限制 5-20）
        self.baseSpeedKmh = max(2.0, kmh)
        self.minSpeedKmh = max(1.0, self.baseSpeedKmh - 2.5)
        self.maxSpeedKmh = self.baseSpeedKmh + 2.5
        self.walkingSpeedKmh = self.baseSpeedKmh
        self.speedDrift = 0.0
        self.cruiseStepPhase = 0.0
        self.gpsNoiseLat = 0.0
        self.gpsNoiseLon = 0.0
        self.cruiseLastTick = nil
        self.cruiseStartTime = Date()
        self.lastUpdateTime = Date()
        self.stuckCount = 0
        self.lastPositions = []
        
        // 使用前端傳入的 loop 參數
        self.cruiseLoop = loop
        
        // 啟動 0.3 秒 repeating Timer（cruiseTick）+ 加入 .common mode
        self.timer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            self?.cruiseTick()
        }
        if let t = self.timer { RunLoop.current.add(t, forMode: .common) }

        // 開啟地圖跟隨
        DispatchQueue.main.async {
            self.webView?.evaluateJavaScript("if(typeof setFollowMode==='function') setFollowMode(true)")
        }

        // 立刻執行第一次 tick
        cruiseTick()
        startStuckCheck()
    }
    
    // ========== cruiseTick: 每 0.3 秒觸發一次 ==========
    private func cruiseTick() {
        // 1. 檢查路徑是否走完
        if smoothPathIndex >= smoothPath.count {
            if cruiseLoop && !routeOriginal.isEmpty {
                // 循環：重新建立平滑路徑，重置所有狀態
                smoothPath = buildSmoothPath(waypoints: routeOriginal, metersPerSegment: 1.5)
                smoothPathIndex = 0
                cruiseStartTime = Date()
                cruiseLastTick = Date()
                cruiseStepPhase = 0.0
                speedDrift = 0.0
            } else {
                stopTimerOnly()
                return
            }
        }
        
        let now = Date()
        let rawDt = cruiseLastTick.map { now.timeIntervalSince($0) } ?? 0.3
        let dt = min(rawDt, 1.5)  // ⚠️ 上限 1.5 秒，防止卡頓後跳躍
        cruiseLastTick = now
        
        // 2. 速度飄移（高斯隨機漫步）
        speedDrift += gaussianRandom() * 0.3
        speedDrift = max(-2.5, min(2.5, speedDrift))
        walkingSpeedKmh = max(minSpeedKmh, min(maxSpeedKmh, baseSpeedKmh + speedDrift))
        
        // 3. 啟動加速（前 3 秒平滑加速，smoothstep）
        let elapsed = now.timeIntervalSince(cruiseStartTime ?? now)
        let accelFactor: Double
        if elapsed < 3.0 {
            let t = elapsed / 3.0
            accelFactor = t * t * (3.0 - 2.0 * t)  // smoothstep
        } else {
            accelFactor = 1.0
        }
        
        // 4. 計算這 tick 要移動的距離（公尺）
        let metersPerSec = (walkingSpeedKmh / 3.6) * accelFactor
        var metersToMove = metersPerSec * dt
        
        // 5. 沿平滑路徑前進
        while metersToMove > 0.0 && smoothPathIndex < smoothPath.count {
            let target = smoothPath[smoothPathIndex]
            let dist = haversineMeters(lat1: currentLat, lon1: currentLon,
                                        lat2: target[0], lon2: target[1])
            
            if dist <= metersToMove + 0.3 {
                currentLat = target[0]
                currentLon = target[1]
                metersToMove -= dist
                smoothPathIndex += 1
            } else {
                let ratio = metersToMove / dist
                currentLat += (target[0] - currentLat) * ratio
                currentLon += (target[1] - currentLon) * ratio
                metersToMove = 0.0
            }
        }
        
        // 6. 腳步擺動（橫向搖擺 — 模擬真實步行）
        cruiseStepPhase += 1.8 * dt  // 步頻 1.8 Hz
        let swayPrimary = sin(cruiseStepPhase * 2.0 * .pi) * 0.18      // 主擺動 ±0.18m
        let swaySecondary = sin(cruiseStepPhase * 2.3 * 2.0 * .pi) * 0.07  // 次擺動 ±0.07m
        let totalSwayMeters = swayPrimary + swaySecondary
        
        // 計算行進方向
        let heading: Double
        if smoothPathIndex < smoothPath.count {
            let next = smoothPath[smoothPathIndex]
            heading = atan2(next[1] - currentLon, next[0] - currentLat)
        } else if smoothPathIndex > 0 {
            let prev = smoothPath[smoothPathIndex - 1]
            heading = atan2(currentLon - prev[1], currentLat - prev[0])
        } else {
            heading = 0.0
        }
        let perpendicular = heading + .pi / 2.0
        let latFactor = cos(currentLat * .pi / 180.0)
        let swayLat = totalSwayMeters * cos(perpendicular) / 111000.0
        let swayLon = totalSwayMeters * sin(perpendicular) / (111000.0 * latFactor)
        
        // 7. GPS 噪點（高斯分佈 + 指數移動平均）
        let noiseSigma = 0.000018  // ~2 米
        let alpha = 0.3
        gpsNoiseLat = alpha * gaussianRandom() * noiseSigma + (1.0 - alpha) * gpsNoiseLat
        gpsNoiseLon = alpha * gaussianRandom() * noiseSigma + (1.0 - alpha) * gpsNoiseLon
        
        // 8. 最終位置 = 基礎位置 + 擺動 + 噪點
        let finalLat = currentLat + swayLat + gpsNoiseLat
        let finalLon = currentLon + swayLon + gpsNoiseLon
        
        // 9. 發送到設備
        transmit(lat: finalLat, lon: finalLon)
        recordPosition(lat: currentLat, lon: currentLon)
        
        // 更新時間戳
        self.lastUpdateTime = now
    }

    // MARK: - Transmit（非阻塞，helperQueue 發送）
    private func transmit(lat: Double, lon: Double) {
        // UI 永遠更新（即使 helper 掛了，地圖藍點照樣移動）
        DispatchQueue.main.async {
            self.webView?.evaluateJavaScript("syncLocation(\(lat), \(lon))")
        }

        let targetUDID = effectiveUDID()
        guard !targetUDID.isEmpty else { return }

        // 用 helperQueue 非阻塞發送
        // ⚠️ 關鍵：helper 沒準備好就靜默跳過，checkIfStuck 統一處理重啟
        helperQueue.async { [weak self] in
            guard let self = self else { return }
            guard self.helperReady,
                  let stdin = self.helperStdinPipe?.fileHandleForWriting else {
                return  // 靜默跳過，不嘗試 CLI 降級
            }
            let line = "\(lat) \(lon)\n"
            if let data = line.data(using: .utf8) {
                do {
                    try stdin.write(contentsOf: data)
                    self.helperSendCount += 1
                } catch {
                    self.helperReady = false
                    self.helperConsecutiveErrors += 1
                }
            }
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
                
                // 如果 pymobiledevice3 尚未安裝，在 sudo 環境中先安裝
                var installPrefix = ""
                if !self.pymobiledevice3Installed {
                    print("📦 [隧道] pymobiledevice3 尚未安裝，將在 sudo 環境中自動安裝...")
                    DispatchQueue.main.async {
                        self.webView?.evaluateJavaScript("setUI('connecting', ' 首次使用：正在以管理員權限安裝必要套件（約1-2分鐘）...')")
                    }
                    // 在 sudo（with administrator privileges）環境下先安裝 pymobiledevice3，再啟動隧道
                    let installCmd1 = self.escapeForAppleScript(self.pythonCommand("-m ensurepip --upgrade"))
                    let installCmd2 = self.escapeForAppleScript(self.pythonCommand("-m pip install --upgrade pip"))
                    let installCmd3 = self.escapeForAppleScript(self.pythonCommand("-m pip install pymobiledevice3"))
                    installPrefix = "\(installCmd1) 2>/dev/null; \(installCmd2) 2>/dev/null; \(installCmd3) 2>/dev/null; "
                }
                
                let combinedScript = """
                do shell script "sudo -v && sudo killall -9 pymobiledevice3 2>/dev/null; sudo lsof -i tcp:49151 -t 2>/dev/null | xargs -r sudo kill -9 2>/dev/null; sleep 2; sudo rm -f /tmp/pymobiledevice3_tunnel.log 2>/dev/null; sudo touch /tmp/pymobiledevice3_tunnel.log 2>/dev/null; sudo chmod 666 /tmp/pymobiledevice3_tunnel.log 2>/dev/null; \(installPrefix)sudo \(pythonCmd) > /tmp/pymobiledevice3_tunnel.log 2>&1 &" with administrator privileges
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
                
                // 等待一下讓進程啟動（如果需要安裝套件，給更多時間）
                let initialWait: TimeInterval = self.pymobiledevice3Installed ? 2.5 : 5.0
                Thread.sleep(forTimeInterval: initialWait)
                
                // 優化：使用輪詢檢查，如果需要安裝套件則最多等待 180 秒，否則 30 秒
                var tunnelStarted = false
                let maxAttempts = self.pymobiledevice3Installed ? 60 : 360  // 30秒 或 180秒
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
                
                // 步驟 4: 重新獲取裝置列表，並用 pymobiledevice3 的 UDID 更新（確保 simulate-location 格式正確）
                let devices = self.listConnectedDevices()
                var pmdUdid: String = ""
                if let first = devices.first {
                    pmdUdid = first["UniqueDeviceID"] ?? first["Identifier"] ?? ""
                }
                DispatchQueue.main.async {
                    if !pmdUdid.isEmpty {
                        self.udid = pmdUdid
                        if self.preferredUDID.isEmpty {
                            self.preferredUDID = pmdUdid
                            UserDefaults.standard.set(pmdUdid, forKey: self.preferredUDIDKey)
                        }
                        print("✅ [UDID] 已更新為 pymobiledevice3 格式: \(String(pmdUdid.prefix(12)))...")
                    }
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
                    
                    // 啟動 Helper Process + Tunnel Watchdog
                    DispatchQueue.global(qos: .utility).async {
                        Thread.sleep(forTimeInterval: 2.0)  // 等隧道穩定
                        self.startHelper()
                        Thread.sleep(forTimeInterval: 2.0)
                        // 如果第一次不成功，重試最多 3 次
                        var attempts = 0
                        while !self.helperReady && attempts < 3 {
                            attempts += 1
                            self.stopHelper()
                            Thread.sleep(forTimeInterval: 1.0)
                            self.startHelper()
                            Thread.sleep(forTimeInterval: 2.0)
                        }
                        DispatchQueue.main.async {
                            if self.helperReady {
                                self.startTunnelWatchdog()
                                print("✅ [連線] Helper + Watchdog 已就緒")
                            } else {
                                print("⚠️ [連線] Helper 啟動失敗")
                            }
                        }
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
                        errorMsg += "自動安裝未成功，請手動安裝：\n\n"
                        errorMsg += "方法 1（推薦）：在終端機執行：\n"
                        errorMsg += "sudo pip3 install pymobiledevice3\n\n"
                        errorMsg += "方法 2：如果上述失敗，先安裝 pip：\n"
                        errorMsg += "sudo python3 -m ensurepip --upgrade\n"
                        errorMsg += "sudo python3 -m pip install pymobiledevice3\n\n"
                        errorMsg += "方法 3：使用 brew 安裝 Python 和套件：\n"
                        errorMsg += "brew install python3\n"
                        errorMsg += "pip3 install pymobiledevice3\n\n"
                        errorMsg += "安裝完成後，重新點擊「GO」即可\n"
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
    
    // MARK: - Stuck Detection（參考專案版 — 非阻塞）

    private func startStuckCheck() {
        stopStuckCheck()
        stuckCheckTimer = Timer.scheduledTimer(withTimeInterval: 8.0, repeats: true) { [weak self] _ in
            self?.checkIfStuck()
        }
        if let t = stuckCheckTimer { RunLoop.current.add(t, forMode: .common) }
    }

    private func stopStuckCheck() {
        stuckCheckTimer?.invalidate()
        stuckCheckTimer = nil
    }

    private func checkIfStuck() {
        // 15 秒冷卻時間：防止重啟風暴
        let canRestart: Bool
        if let last = lastHelperRestart { canRestart = Date().timeIntervalSince(last) > 15.0 }
        else { canRestart = true }

        // Helper 掛了 → dispatch 到 helperQueue 重啟（不阻塞主線程！）
        if let process = helperProcess, !process.isRunning {
            print("⚠️ [checkIfStuck] Helper process 已死，排程重啟...")
            if canRestart {
                lastHelperRestart = Date()
                helperQueue.async { [weak self] in
                    guard let self = self else { return }
                    self.startHelper()
                    if self.helperReady { self.blastCurrentPosition() }
                }
            }
            return  // ← 關鍵：只走一條恢復路徑
        }

        // Helper 不 ready
        if !helperReady {
            if canRestart {
                lastHelperRestart = Date()
                helperQueue.async { [weak self] in
                    guard let self = self else { return }
                    self.startHelper()
                    if self.helperReady { self.blastCurrentPosition() }
                }
            }
            return
        }

        // 12 秒沒收到 OK → 先 RECONNECT，5 秒後還沒改善才重啟
        if let lastSend = lastSuccessfulSend, Date().timeIntervalSince(lastSend) > 12.0 {
            if let stdin = helperStdinPipe?.fileHandleForWriting {
                try? stdin.write(contentsOf: "RECONNECT\n".data(using: .utf8)!)
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 5.0) { [weak self] in
                guard let self = self else { return }
                if let lastSend = self.lastSuccessfulSend, Date().timeIntervalSince(lastSend) > 17.0 {
                    if let last = self.lastHelperRestart, Date().timeIntervalSince(last) < 15.0 { return }
                    self.lastHelperRestart = Date()
                    self.helperQueue.async {
                        self.startHelper()
                        if self.helperReady { self.blastCurrentPosition() }
                    }
                }
            }
        } else if lastSuccessfulSend == nil && helperSendCount > 10 {
            if canRestart {
                lastHelperRestart = Date()
                helperQueue.async { [weak self] in
                    guard let self = self else { return }
                    self.startHelper()
                    if self.helperReady { self.blastCurrentPosition() }
                }
            }
        }

        // Helper 處於降級模式（CLI）→ 嘗試 RECONNECT 切換回 API
        if helperDegraded && helperReady {
            if let stdin = helperStdinPipe?.fileHandleForWriting {
                try? stdin.write(contentsOf: "RECONNECT\n".data(using: .utf8)!)
            }
        }

        // 位置移動檢測（forceNudge）
        guard lastPositions.count >= 4 else { return }
        let threshold = 0.000027
        let first = lastPositions[0]
        var allSame = true
        for pos in lastPositions {
            if abs(pos.lat - first.lat) > threshold || abs(pos.lon - first.lon) > threshold {
                allSame = false; break
            }
        }
        if allSame {
            stuckCount += 1
            if stuckCount >= 2 {
                forceNudge()
                stuckCount = 0
            }
        } else {
            stuckCount = 0
        }
    }

    private func forceNudge() {
        let latFactor = cos(currentLat * .pi / 180.0)
        let nudge = 0.000045
        let nudgeLat = Double.random(in: -nudge...nudge)
        let nudgeLon = Double.random(in: -nudge...nudge) / latFactor
        transmit(lat: currentLat + nudgeLat, lon: currentLon + nudgeLon)
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
    private func stopTimerOnly() {
        timer?.invalidate()
        timer = nil
        stopStuckCheck()
        DispatchQueue.main.async {
            self.webView?.evaluateJavaScript("if(typeof setFollowMode==='function') setFollowMode(false)")
        }
    }
    
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