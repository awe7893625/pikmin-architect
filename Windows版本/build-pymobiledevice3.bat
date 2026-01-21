@echo off
REM 打包 pymobiledevice3 為可執行檔的腳本
REM 這需要在有 Python 的環境中運行

echo 正在打包 pymobiledevice3 為可執行檔...

REM 檢查 Python 是否安裝
python --version >nul 2>&1
if errorlevel 1 (
    echo 錯誤：未檢測到 Python，請先安裝 Python 3.8 或更高版本
    pause
    exit /b 1
)

REM 安裝 PyInstaller
echo 正在安裝 PyInstaller...
python -m pip install --upgrade pip
python -m pip install pyinstaller

REM 安裝 pymobiledevice3
echo 正在安裝 pymobiledevice3...
python -m pip install pymobiledevice3

REM 創建打包目錄
if not exist "build_temp" mkdir build_temp

REM 打包為可執行檔
echo 正在打包...
pyinstaller --onefile ^
  --name=pymobiledevice3 ^
  --distpath=build_temp ^
  --workpath=build_temp ^
  --specpath=build_temp ^
  --hidden-import=pymobiledevice3 ^
  --hidden-import=pymobiledevice3.cli ^
  --hidden-import=pymobiledevice3.cli.developer ^
  --hidden-import=pymobiledevice3.cli.developer.dvt ^
  --hidden-import=pymobiledevice3.cli.developer.dvt.simulate_location ^
  -m pymobiledevice3.cli.developer.dvt.simulate_location

REM 複製到 bin 目錄
if not exist "bin" mkdir bin
copy /Y build_temp\pymobiledevice3.exe bin\

echo.
echo ✅ 打包完成！可執行檔已複製到 bin\pymobiledevice3.exe
echo.
pause
