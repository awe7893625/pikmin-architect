            // 步驟 3: 檢測設備並重新啟動隧道（改進版 - 支援 macOS 26.2）
            print("🔍 [設備偵測] 開始檢測設備...")
            
            // 方法 1: 使用 system_profiler（主要方法）
            let info = self.shell("/usr/sbin/system_profiler SPUSBDataType")
            print("📋 [設備偵測] USB 設備資訊長度: \(info.count) 字元")
            if info.count > 0 {
                print("📋 [設備偵測] USB 設備資訊前 500 字元:\n\(String(info.prefix(500)))")
            } else {
                print("⚠️ [設備偵測] USB 設備資訊為空")
            }
            
            // 方法 2: 嘗試使用 pymobiledevice3 bonjour 瀏覽設備（備用方法）
            let pymobiledeviceList = self.shell("\(self.pythonPath) -m pymobiledevice3 bonjour browse 2>&1 | head -20")
            print("📱 [設備偵測] pymobiledevice3 bonjour 輸出:\n\(pymobiledeviceList)")
            
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
            
            var deviceId: String? = nil
            var matchedPattern: String? = nil
            
            // 先從 system_profiler 結果中查找
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
            
            // 如果 system_profiler 找不到，嘗試從 pymobiledevice3 結果中提取
            if deviceId == nil && !pymobiledeviceList.isEmpty {
                let udidPatterns = [
                    "([0-9A-Z]{8}-[0-9A-Z]{16})",
                    "([0-9A-Z]{24})"
                ]
                
                for udidPattern in udidPatterns {
                    if let regex = try? NSRegularExpression(pattern: udidPattern, options: []),
                       let match = regex.firstMatch(in: pymobiledeviceList, options: [], range: NSRange(location: 0, length: pymobiledeviceList.utf16.count)) {
                        let ns = pymobiledeviceList as NSString
                        var id = ns.substring(with: match.range(at: 1))
                        if id.count == 24 && !id.contains("-") {
                            id.insert("-", at: id.index(id.startIndex, offsetBy: 8))
                        }
                        deviceId = id
                        matchedPattern = "pymobiledevice3-bonjour"
                        print("✅ [設備偵測] 從 pymobiledevice3 bonjour 找到設備 ID: \(id)")
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
                let script = "do shell script \"sudo \(self.pythonPath) -m pymobiledevice3 remote tunneld\" with administrator privileges"
                let p = Process()
                p.launchPath = "/usr/bin/osascript"
                p.arguments = ["-e", script]
                p.launch()
                
                Thread.sleep(forTimeInterval: 2.5)
                
                let tunnelCheck = self.shell("lsof -i tcp:49151 2>/dev/null | grep LISTEN")
                print("🔍 [隧道] 檢查結果: \(tunnelCheck.isEmpty ? "未啟動" : "已啟動")")
                if !tunnelCheck.isEmpty {
                    print("✅ [隧道] 隧道已成功啟動")
                } else {
                    print("⚠️ [隧道] 隧道未啟動，檢查進程...")
                    let processCheck = self.shell("ps aux | grep pymobiledevice3 | grep -v grep")
                    print("📋 [隧道] pymobiledevice3 進程: \(processCheck.isEmpty ? "未運行" : processCheck)")
                }
                
                if !tunnelCheck.isEmpty {
                    DispatchQueue.main.async {
                        self.webView?.evaluateJavaScript("setUI('online', ' iPhone 已連線')")
                    }
                } else {
                    DispatchQueue.main.async {
                        self.webView?.evaluateJavaScript("setUI('error', '⚠️ 隧道啟動失敗\\n\\n請確認：\\n1. 設備已信任此電腦\\n2. 已安裝最新版 pymobiledevice3\\n3. macOS 26.2 可能需要更新 pymobiledevice3')")
                    }
                }

            } else {
                print("❌ [設備偵測] 未找到設備序列號")
                print("📋 [設備偵測] 完整 USB 資訊長度: \(info.count) 字元")
                if info.count > 0 {
                    print("📋 [設備偵測] 完整 USB 資訊:\n\(info)")
                }
                print("📱 [設備偵測] pymobiledevice3 輸出:\n\(pymobiledeviceList)")
                
                let hasAppleDevice = info.contains("Apple") || info.contains("iPhone") || info.contains("iPad")
                let hasUSB = info.contains("USB") || info.count > 0
                let hasPymobiledeviceOutput = !pymobiledeviceList.isEmpty && !pymobiledeviceList.contains("No devices found") && !pymobiledeviceList.contains("command not found")
                
                var errorMsg = "⚠️ 未偵測到 iOS 設備\n\n"
                
                if !hasUSB || info.isEmpty {
                    errorMsg += "❌ 未偵測到 USB 連接\n\n請確認：\n1. iPhone/iPad 已用 USB 線連接\n2. USB 線是否正常\n3. 嘗試不同的 USB 端口\n4. 確認 USB 線可以傳輸數據（不只是充電）\n"
                } else if !hasAppleDevice {
                    errorMsg += "❌ 偵測到 USB 設備，但不是 iOS 設備\n\n請確認：\n1. 連接的是 iPhone 或 iPad\n2. 設備已解鎖\n3. 已點擊「信任此電腦」\n4. macOS 26.2 可能需要重新信任設備\n5. 前往「設定 > 一般 > 傳輸或重置 iPhone > 重置位置與隱私」\n"
                } else if hasPymobiledeviceOutput {
                    errorMsg += "❌ pymobiledevice3 偵測到設備，但無法讀取序列號\n\n可能原因：\n1. macOS 26.2 與 pymobiledevice3 兼容性問題\n2. 需要更新：pip3 install --break-system-packages --upgrade pymobiledevice3\n3. 設備未完全信任此電腦\n"
                } else {
                    errorMsg += "❌ 偵測到 Apple 設備，但無法讀取序列號\n\n可能原因：\n1. 設備未完全信任此電腦（最重要！）\n2. macOS 26.2 可能需要重新信任設備\n3. 需要在設備上點擊「信任此電腦」\n4. 嘗試重新插拔 USB 線\n5. macOS 26.2 可能需要更新 pymobiledevice3\n\n💡 調試資訊已輸出到 Xcode 控制台（⌥⌘Y）\n"
                }
                
                DispatchQueue.main.async { 
                    self.webView?.evaluateJavaScript("setUI('error', '\(errorMsg)')")
                }
            }
