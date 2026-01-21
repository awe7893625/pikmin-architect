import Foundation

// Python 環境管理器 - 自動檢測和安裝 pymobiledevice3
class PythonManager {
    static let shared = PythonManager()
    
    private var cachedPythonPath: String?
    private var cachedPymobiledevicePath: String?
    
    private init() {}
    
    // 檢測可用的 Python 路徑
    func findPythonPath() -> String? {
        if let cached = cachedPythonPath {
            return cached
        }
        
        // 常見的 Python 路徑（按優先順序）
        let possiblePaths = [
            "/opt/homebrew/bin/python3",      // Homebrew (Apple Silicon)
            "/usr/local/bin/python3",          // Homebrew (Intel)
            "/usr/bin/python3",                // 系統 Python
            "/Library/Frameworks/Python.framework/Versions/3.*/bin/python3", // 官方安裝
        ]
        
        // 先檢查常見路徑
        for path in possiblePaths {
            if FileManager.default.fileExists(atPath: path) {
                // 測試是否可以執行
                if testPython(path) {
                    cachedPythonPath = path
                    return path
                }
            }
        }
        
        // 使用 which 命令查找
        let whichResult = shell("which python3")
        if !whichResult.isEmpty && FileManager.default.fileExists(atPath: whichResult.trimmingCharacters(in: .whitespacesAndNewlines)) {
            let path = whichResult.trimmingCharacters(in: .whitespacesAndNewlines)
            if testPython(path) {
                cachedPythonPath = path
                return path
            }
        }
        
        return nil
    }
    
    // 測試 Python 是否可用
    private func testPython(_ path: String) -> Bool {
        let result = shell("\(path) --version 2>&1")
        return result.contains("Python 3")
    }
    
    // 獲取 pymobiledevice3 路徑（自動安裝如果不存在）
    func getPymobiledevicePath(completion: @escaping (String?, String?) -> Void) {
        // 先檢查是否已安裝
        if let cached = cachedPymobiledevicePath, FileManager.default.fileExists(atPath: cached) {
            completion(cached, nil)
            return
        }
        
        guard let pythonPath = findPythonPath() else {
            completion(nil, "未找到 Python 3，請先安裝 Python 3")
            return
        }
        
        // 檢查 pymobiledevice3 是否已安裝
        let checkResult = shell("\(pythonPath) -m pymobiledevice3 --version 2>&1")
        
        if checkResult.contains("pymobiledevice3") || checkResult.contains("version") {
            // 已安裝，使用系統版本
            cachedPymobiledevicePath = pythonPath
            completion(pythonPath, nil)
            return
        }
        
        // 未安裝，自動安裝到用戶目錄（不需要 sudo）
        DispatchQueue.global(qos: .userInitiated).async {
            self.installPymobiledevice3(pythonPath: pythonPath) { success, error in
                if success {
                    DispatchQueue.main.async {
                        self.cachedPymobiledevicePath = pythonPath
                        completion(pythonPath, nil)
                    }
                } else {
                    DispatchQueue.main.async {
                        completion(nil, error ?? "安裝 pymobiledevice3 失敗")
                    }
                }
            }
        }
    }
    
    // 自動安裝 pymobiledevice3（使用 --user，不需要 sudo）
    private func installPymobiledevice3(pythonPath: String, completion: @escaping (Bool, String?) -> Void) {
        // 使用 --user 安裝到用戶目錄，不需要 sudo
        let installCommand = "\(pythonPath) -m pip install --user --quiet pymobiledevice3 2>&1"
        
        DispatchQueue.global(qos: .userInitiated).async {
            let result = self.shell(installCommand)
            
            // 檢查是否安裝成功
            let checkResult = self.shell("\(pythonPath) -m pymobiledevice3 --version 2>&1")
            
            if checkResult.contains("pymobiledevice3") || checkResult.contains("version") {
                completion(true, nil)
            } else {
                // 如果安裝失敗，嘗試使用 pip3
                _ = self.shell("pip3 install --user --quiet pymobiledevice3 2>&1")
                let checkAgain = self.shell("\(pythonPath) -m pymobiledevice3 --version 2>&1")
                
                if checkAgain.contains("pymobiledevice3") || checkAgain.contains("version") {
                    completion(true, nil)
                } else {
                    completion(false, "安裝失敗：\(result)")
                }
            }
        }
    }
    
    // 執行 shell 命令
    @discardableResult
    private func shell(_ command: String) -> String {
        #if os(macOS)
        let task = Process()
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        task.launchPath = "/bin/bash"
        task.arguments = ["-c", command]
        task.launch()
        task.waitUntilExit()
        
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
        #else
        return ""
        #endif
    }
    
    // 獲取完整的 Python 命令（包含自動安裝）
    func getPythonCommand(completion: @escaping (String?, String?) -> Void) {
        getPymobiledevicePath { pythonPath, error in
            if let path = pythonPath {
                completion(path, nil)
            } else {
                completion(nil, error)
            }
        }
    }
}
