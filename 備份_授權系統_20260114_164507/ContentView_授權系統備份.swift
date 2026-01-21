import SwiftUI
import WebKit
import Combine
import Foundation

// GPS 軌跡點結構
struct GPSTrackPoint {
    let lat: Double
    let lon: Double
    let altitude: Double
    let speed: Double  // km/h
    let timeOffset: Double  // 從開始的秒數
    let timestamp: Date?
}

final class LocationEngine: NSObject, ObservableObject, WKScriptMessageHandler {
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

    // 請根據環境修改 python3 路徑
    let pythonPath = "/opt/homebrew/bin/python3"

    override init() {
        super.init()
        // 自動載入預設軌跡
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            self.loadDefaultTrack()
        }
    }
    
    // 自動載入預設軌跡ㄋㄞ
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
        case "checkAuth":
            // 檢查授權狀態（調用授權服務器）
            self.checkAuthStatus()
        case "useTrial":
            // 使用一次試用次數
            self.useTrial()
        case "openPayment":
            // 打開付款連結（外部瀏覽器）
            if let urlString = dict["url"] as? String {
                print("🔗 收到打開付款連結請求: \(urlString)")
                if let url = URL(string: urlString) {
                    print("✅ URL 創建成功，正在打開...")
                    // 確保在主線程執行，並且使用同步方式確保立即執行
                    DispatchQueue.main.async {
                        let success = NSWorkspace.shared.open(url)
                        if success {
                            print("✅ 成功打開付款連結: \(urlString)")
                        } else {
                            print("❌ 打開付款連結失敗: \(urlString)")
                            // 如果失敗，嘗試使用備用方法
                            if let url = URL(string: urlString) {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    }
                } else {
                    print("❌ URL 創建失敗: \(urlString)")
                }
            } else {
                print("❌ 未收到 URL 參數")
            }
        case "activateLicense":
            // 激活授權碼
            if let licenseKey = dict["licenseKey"] as? String {
                self.activateLicense(licenseKey: licenseKey)
            }
        default: break
        }
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
            _ = self.shell("\(self.pythonPath) -m pymobiledevice3 developer dvt simulate-location set --tunnel \(self.udid) -- \(finalLat) \(finalLon)")
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
            _ = self.shell("\(self.pythonPath) -m pymobiledevice3 developer dvt simulate-location set --tunnel \(self.udid) -- \(finalLat) \(finalLon)")
        }
    }

    // 核心連線邏輯 (彈出密碼要求) - 改進版：完整清除所有進程和端口
    func reconnect() {
        // 更新 UI 狀態
        DispatchQueue.main.async { self.webView?.evaluateJavaScript("setUI('connecting', ' 正在清除舊連線...')") }
        
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
            DispatchQueue.main.async { self.webView?.evaluateJavaScript("setUI('connecting', ' 正在請求權限...')") }
            
            // 步驟 3: 檢測設備並重新啟動隧道
            let info = self.shell("/usr/sbin/system_profiler SPUSBDataType")
            let pattern = "Serial Number: ([0-9A-Z-]{16,})"

            if let regex = try? NSRegularExpression(pattern: pattern, options: []),
               let match = regex.firstMatch(in: info, options: [], range: NSRange(location: 0, length: info.utf16.count)) {

                let ns = info as NSString
                var id = ns.substring(with: match.range(at: 1))
                if id.count == 24 && !id.contains("-") { id.insert("-", at: id.index(id.startIndex, offsetBy: 8)) }

                DispatchQueue.main.async {
                    self.udid = id
                    self.webView?.evaluateJavaScript("setUI('connecting', ' 正在建立隧道...')")
                }

                // 步驟 4: 重新啟動隧道（關鍵）- 使用 osascript 彈出密碼輸入框
                let script = "do shell script \"sudo \(self.pythonPath) -m pymobiledevice3 remote tunneld\" with administrator privileges"
                let p = Process()
                p.launchPath = "/usr/bin/osascript"
                p.arguments = ["-e", script]
                p.launch()
                
                // 等待隧道啟動
                Thread.sleep(forTimeInterval: 1.0)
                
                DispatchQueue.main.async {
                    self.webView?.evaluateJavaScript("setUI('online', ' iPhone 已連線')")
                }

            } else {
                DispatchQueue.main.async { self.webView?.evaluateJavaScript("setUI('error', '⚠️ 未偵測到設備')") }
            }
        }
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

    @discardableResult private func shell(_ command: String) -> String {
        let task = Process(), pipe = Pipe(); task.standardOutput = pipe; task.standardError = pipe
        task.launchPath = "/bin/bash"; task.arguments = ["-c", command]; task.launch()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }
    
    // 授權管理功能
    private let apiBaseURL = "https://kòng-koo.vercel.app/api"
    
    private func getDeviceId() -> String {
        // 獲取 Mac 硬體 UUID
        let output = shell("system_profiler SPHardwareDataType | grep 'Hardware UUID' | awk '{print $3}'")
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    func checkAuthStatus() {
        let deviceId = getDeviceId()
        print("🔍 檢查授權狀態，設備ID: \(deviceId)")
        
        // 先嘗試 POST 方式（與服務器 API 一致）
        guard let url = URL(string: "\(apiBaseURL)/auth/check") else {
            print("❌ URL 創建失敗")
            // URL 創建失敗：顯示錯誤，不給免費試用（防止濫用）
            DispatchQueue.main.async {
                self.webView?.evaluateJavaScript("updateTrialStatus(0, false); alert('❌ 授權服務器配置錯誤，請聯繫開發者')")
            }
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 5.0  // 5 秒超時
        
        let body: [String: Any] = ["deviceId": deviceId]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }
            
            if let error = error {
                print("❌ 網絡錯誤: \(error.localizedDescription)")
                // 服務器連接失敗：顯示錯誤，不給免費試用（防止濫用）
                DispatchQueue.main.async {
                    self.webView?.evaluateJavaScript("updateTrialStatus(0, false); alert('❌ 無法連接到授權服務器，請檢查網絡連接後重試')")
                }
                return
            }
            
            if let httpResponse = response as? HTTPURLResponse {
                print("📡 HTTP 狀態碼: \(httpResponse.statusCode)")
            }
            
            if let data = data {
                if let jsonString = String(data: data, encoding: .utf8) {
                    print("📦 服務器返回: \(jsonString)")
                }
                
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    print("✅ JSON 解析成功: \(json)")
                    if let remaining = json["remaining"] as? Int,
                       let isPaid = json["isPaid"] as? Bool {
                        print("✅ 剩餘次數: \(remaining), 已付費: \(isPaid)")
                        DispatchQueue.main.async {
                            self.webView?.evaluateJavaScript("updateTrialStatus(\(remaining), \(isPaid))")
                        }
                        return
                    }
                }
            }
            
            // 如果服務器沒有返回有效數據，顯示錯誤，不給免費試用（防止濫用）
            print("⚠️ 服務器返回無效數據")
            DispatchQueue.main.async {
                self.webView?.evaluateJavaScript("updateTrialStatus(0, false); alert('❌ 授權服務器返回無效數據，請重試或聯繫開發者')")
            }
        }.resume()
    }
    
    func useTrial() {
        let deviceId = getDeviceId()
        guard let url = URL(string: "\(apiBaseURL)/trial/use") else { return }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let body: [String: Any] = ["deviceId": deviceId]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }
            if let data = data,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let remaining = json["remaining"] as? Int,
               let isPaid = json["isPaid"] as? Bool {
                DispatchQueue.main.async {
                    self.webView?.evaluateJavaScript("updateTrialStatus(\(remaining), \(isPaid))")
                }
            } else {
                // 使用失敗，重新檢查狀態
                self.checkAuthStatus()
            }
        }.resume()
    }
    
    func activateLicense(licenseKey: String) {
        let deviceId = getDeviceId()
        print("🔑 激活授權碼: \(licenseKey), 設備ID: \(deviceId)")
        guard let url = URL(string: "\(apiBaseURL)/license/activate") else { return }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let body: [String: Any] = ["deviceId": deviceId, "licenseKey": licenseKey]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }
            if let data = data,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let success = json["success"] as? Bool {
                DispatchQueue.main.async {
                    if success {
                        print("✅ 授權激活成功，清除所有授權相關資料")
                        // 清除所有授權相關的 localStorage 資料
                        self.webView?.evaluateJavaScript("""
                            localStorage.removeItem('appLanguage');
                            localStorage.removeItem('trialCount');
                            localStorage.removeItem('isPaid');
                            localStorage.removeItem('licenseKey');
                            updateTrialStatus(999, true);
                            alert('✅ 授權激活成功！所有授權相關資料已清除，App 已恢復為完整功能版本。');
                        """)
                    } else {
                        let message = json["message"] as? String ?? "激活失敗"
                        self.webView?.evaluateJavaScript("alert('❌ \(message)')")
                    }
                }
            } else {
                DispatchQueue.main.async {
                    self.webView?.evaluateJavaScript("alert('❌ 激活失敗，請檢查網絡連接')")
                }
            }
        }.resume()
    }
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
        engine.webView = webView
        if let url = Bundle.main.url(forResource: "index", withExtension: "html") {
            // 允許訪問整個資源目錄（包括 locales 資料夾）
            let resourceDirectory = url.deletingLastPathComponent()
            webView.loadFileURL(url, allowingReadAccessTo: resourceDirectory)
            print("📂 載入 HTML 文件: \(url.path)")
            print("📂 資源目錄: \(resourceDirectory.path)")
        }
        return webView
    }
    func updateNSView(_ nsView: WKWebView, context: NSViewRepresentableContext<AppleMapView>) {}
}