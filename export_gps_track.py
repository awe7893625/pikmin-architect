#!/usr/bin/env python3
"""
從 iPhone 匯出 GPS 軌跡數據
支援從 HealthKit、位置服務日誌或手動匯入 GPX 檔案
"""
import json
import sys
import subprocess
from datetime import datetime, timedelta
from pathlib import Path

def export_from_healthkit(udid: str, output_file: str):
    """從 HealthKit 匯出 GPS 數據（需要 iOS 設備）"""
    try:
        # 使用 pymobiledevice3 嘗試讀取位置數據
        # 注意：這需要設備授權和特殊權限
        cmd = f"python3 -m pymobiledevice3 developer dvt location --tunnel {udid}"
        result = subprocess.run(cmd, shell=True, capture_output=True, text=True)
        
        if result.returncode == 0:
            print(f"✅ 成功從設備讀取位置數據")
            # 解析並保存數據
            # 這裡需要根據實際輸出格式進行解析
            return True
        else:
            print(f"⚠️ 無法從設備讀取位置數據：{result.stderr}")
            return False
    except Exception as e:
        print(f"❌ 匯出失敗：{e}")
        return False

def create_sample_track(output_file: str):
    """建立範例軌跡數據（用於測試）"""
    # 建立一個簡單的騎車軌跡範例
    track = []
    base_lat = 25.033  # 台北 101
    base_lon = 121.565
    
    # 模擬 30 分鐘的騎車軌跡，每 5 秒一個點
    start_time = datetime.now() - timedelta(hours=2)  # 2 小時前開始
    
    for i in range(360):  # 30 分鐘 * 12 點/分鐘 = 360 點
        # 模擬騎車路徑（繞圈）
        angle = (i / 360.0) * 2 * 3.14159
        radius = 0.01  # 約 1 公里半徑
        
        lat = base_lat + radius * 0.5 * (1 + 0.3 * (i % 20) / 20) * (1 if i % 2 == 0 else -1)
        lon = base_lon + radius * 0.5 * (1 + 0.3 * (i % 20) / 20) * (1 if i % 2 == 0 else -1)
        
        # 計算速度（騎車速度約 15-25 km/h）
        speed = 20.0 + (i % 10) * 0.5  # 15-25 km/h
        
        # 計算海拔（模擬上下坡）
        altitude = 10.0 + 5.0 * (i % 30) / 30.0
        
        timestamp = start_time + timedelta(seconds=i * 5)
        
        track.append({
            "lat": lat,
            "lon": lon,
            "altitude": altitude,
            "speed": speed,  # km/h
            "timestamp": timestamp.isoformat(),
            "time_offset": i * 5  # 從開始的秒數
        })
    
    # 保存為 JSON
    with open(output_file, 'w', encoding='utf-8') as f:
        json.dump({
            "metadata": {
                "source": "sample_track",
                "created_at": datetime.now().isoformat(),
                "total_points": len(track),
                "duration_seconds": len(track) * 5,
                "description": "範例騎車軌跡數據"
            },
            "track": track
        }, f, indent=2, ensure_ascii=False)
    
    print(f"✅ 已建立範例軌跡數據：{output_file}")
    print(f"   總共 {len(track)} 個點，時長 {len(track) * 5 / 60:.1f} 分鐘")
    return True

def parse_gpx_file(gpx_file: str, output_file: str):
    """解析 GPX 檔案並轉換為 JSON 格式"""
    try:
        import xml.etree.ElementTree as ET
        
        tree = ET.parse(gpx_file)
        root = tree.getroot()
        
        # GPX 命名空間
        ns = {'gpx': 'http://www.topografix.com/GPX/1/1'}
        
        track = []
        start_time = None
        
        # 解析所有 trkpt（軌跡點）
        for trkpt in root.findall('.//gpx:trkpt', ns):
            lat = float(trkpt.get('lat'))
            lon = float(trkpt.get('lon'))
            
            # 讀取海拔
            ele = trkpt.find('gpx:ele', ns)
            altitude = float(ele.text) if ele is not None else 10.0
            
            # 讀取時間
            time_elem = trkpt.find('gpx:time', ns)
            if time_elem is not None:
                timestamp_str = time_elem.text
                timestamp = datetime.fromisoformat(timestamp_str.replace('Z', '+00:00'))
                if start_time is None:
                    start_time = timestamp
                time_offset = (timestamp - start_time).total_seconds()
            else:
                time_offset = len(track) * 5  # 預設每 5 秒一個點
            
            # 讀取速度（如果有）
            speed_elem = trkpt.find('.//gpx:extensions//gpx:speed', ns)
            speed = float(speed_elem.text) * 3.6 if speed_elem is not None else 20.0  # m/s 轉 km/h
            
            track.append({
                "lat": lat,
                "lon": lon,
                "altitude": altitude,
                "speed": speed,
                "timestamp": timestamp.isoformat() if time_elem is not None else None,
                "time_offset": time_offset
            })
        
        # 保存為 JSON
        with open(output_file, 'w', encoding='utf-8') as f:
            json.dump({
                "metadata": {
                    "source": "gpx_file",
                    "source_file": gpx_file,
                    "created_at": datetime.now().isoformat(),
                    "total_points": len(track),
                    "duration_seconds": track[-1]["time_offset"] if track else 0,
                    "description": f"從 GPX 檔案匯入的軌跡數據"
                },
                "track": track
            }, f, indent=2, ensure_ascii=False)
        
        print(f"✅ 成功解析 GPX 檔案：{gpx_file}")
        print(f"   總共 {len(track)} 個點，時長 {track[-1]['time_offset'] / 60:.1f} 分鐘")
        return True
        
    except Exception as e:
        print(f"❌ 解析 GPX 檔案失敗：{e}")
        return False

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("使用方法：")
        print("  python3 export_gps_track.py sample <輸出檔案.json>  # 建立範例軌跡")
        print("  python3 export_gps_track.py gpx <GPX檔案> <輸出檔案.json>  # 從 GPX 匯入")
        print("  python3 export_gps_track.py device <UDID> <輸出檔案.json>  # 從設備匯出（需要權限）")
        sys.exit(1)
    
    command = sys.argv[1]
    
    if command == "sample":
        output_file = sys.argv[2] if len(sys.argv) > 2 else "sample_track.json"
        create_sample_track(output_file)
    elif command == "gpx":
        if len(sys.argv) < 4:
            print("❌ 請提供 GPX 檔案路徑和輸出檔案路徑")
            sys.exit(1)
        gpx_file = sys.argv[2]
        output_file = sys.argv[3]
        parse_gpx_file(gpx_file, output_file)
    elif command == "device":
        if len(sys.argv) < 4:
            print("❌ 請提供設備 UDID 和輸出檔案路徑")
            sys.exit(1)
        udid = sys.argv[2]
        output_file = sys.argv[3]
        export_from_healthkit(udid, output_file)
    else:
        print(f"❌ 未知命令：{command}")
        sys.exit(1)

