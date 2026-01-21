#!/usr/bin/env python3
"""清理 ContentView.swift 中所有真實軌跡相關代碼"""
import re

# 讀取檔案
with open('ContentView.swift', 'r', encoding='utf-8') as f:
    content = f.read()

# 1. 刪除 GPSTrackPoint 結構
content = re.sub(r'// GPS 軌跡點結構\s*struct GPSTrackPoint \{.*?\}\s*\n', '', content, flags=re.DOTALL)

# 2. 刪除真實軌跡相關變數聲明
content = re.sub(r'\s*// 真實 GPS 軌跡數據\s*private var realTrack:.*?\n\s*private var trackStartTime:.*?\n\s*private var currentTrackIndex:.*?\n\s*private var isUsingRealTrack:.*?\n', '', content)

# 3. 刪除 init 中的自動載入
content = re.sub(r'\s*override init\(\) \{\s*super\.init\(\)\s*// 自動載入預設軌跡\s*DispatchQueue\.main\.asyncAfter.*?self\.loadDefaultTrack\(\)\s*\}\s*', '', content, flags=re.DOTALL)

# 4. 刪除 loadDefaultTrack 和 parseAndLoadTrack 函數
content = re.sub(r'\s*// 自動載入預設軌跡\s*private func loadDefaultTrack\(\) \{.*?\}\s*', '', content, flags=re.DOTALL)
content = re.sub(r'\s*// 解析並載入軌跡數據\s*private func parseAndLoadTrack\(data: Data\) \{.*?\}\s*', '', content, flags=re.DOTALL)

# 5. 刪除 userContentController 中的真實軌跡處理
content = re.sub(r'\s*case "loadRealTrack":.*?case "startRealTrack":.*?self\.startRealTrackPlayback\(\)\s*', '', content, flags=re.DOTALL)

# 6. 刪除所有 isUsingRealTrack = false/true 的賦值
content = re.sub(r'\s*self\.isUsingRealTrack = (false|true)\s*', '', content)

# 7. 刪除 loadRealTrack 函數
content = re.sub(r'\s*// 載入真實 GPS 軌跡數據\s*func loadRealTrack\(from filePath: String\) \{.*?\}\s*', '', content, flags=re.DOTALL)

# 8. 刪除 startRealTrackPlayback 函數
content = re.sub(r'\s*// 開始播放真實軌跡.*?func startRealTrackPlayback\(\) \{.*?\}\s*', '', content, flags=re.DOTALL)

# 9. 刪除 scheduleRealTrackStep 函數
content = re.sub(r'\s*// 播放真實軌跡的下一步.*?private func scheduleRealTrackStep\(\) \{.*?\}\s*', '', content, flags=re.DOTALL)

# 10. 刪除 autoRestartRealTrack 函數
content = re.sub(r'\s*// 自動重新啟動真實軌跡.*?private func autoRestartRealTrack\(\) \{.*?\}\s*', '', content, flags=re.DOTALL)

# 11. 修改 checkIfStuck 中的真實軌跡檢查
content = re.sub(r'guard \(isUsingRealTrack \|\| !routeQueue\.isEmpty\)', 'guard !routeQueue.isEmpty', content)
content = re.sub(r'if isUsingRealTrack \{\s*autoRestartRealTrack\(\)\s*\} else \{\s*autoRestartRouteMode\(\)\s*\}', 'autoRestartRouteMode()', content, flags=re.DOTALL)

# 12. 刪除 resetEverything 中的真實軌跡相關
content = re.sub(r'\s*self\.isUsingRealTrack = false\s*', '', content)
content = re.sub(r'\s*self\.currentTrackIndex = 0\s*', '', content)

# 13. 刪除所有對 realTrack 的引用（除了變數聲明，已經刪除了）
content = re.sub(r'\s*self\.realTrack\s*=\s*.*?\n', '', content)
content = re.sub(r'\s*realTrack\.[a-zA-Z]', '', content)
content = re.sub(r'\s*realTrack\.count', '0', content)
content = re.sub(r'\s*realTrack\.isEmpty', 'true', content)

# 14. 刪除所有對 GPSTrackPoint 的引用
content = re.sub(r':\s*\[GPSTrackPoint\]', ': []', content)
content = re.sub(r'GPSTrackPoint\(', '', content)

# 寫回檔案
with open('ContentView.swift', 'w', encoding='utf-8') as f:
    f.write(content)

print("✅ 已清理所有真實軌跡相關代碼")
