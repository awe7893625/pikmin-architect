#!/bin/bash
set -euo pipefail

APP_PATH="${1:-}"
if [[ -z "$APP_PATH" || ! -d "$APP_PATH" ]]; then
  echo "用法: $0 /path/to/KongGoo.app"
  exit 1
fi

RES_DIR="$APP_PATH/Contents/Resources"
PY_DIR="$RES_DIR/python"
BIN_DIR="$RES_DIR/bin"
LIB_DIR="$RES_DIR/lib"

PYTHON_SRC="${PYTHON_SRC:-$(command -v python3 || true)}"
if [[ -z "$PYTHON_SRC" ]]; then
  echo "❌ 找不到 python3，請先安裝 Python"
  exit 1
fi

TMP_DIR="$(mktemp -d)"
VENV_DIR="$TMP_DIR/venv"
COPIED_LIST="$TMP_DIR/copied.txt"
touch "$COPIED_LIST"

echo "🐍 建立內嵌 Python venv..."
"$PYTHON_SRC" -m venv --copies "$VENV_DIR"
"$VENV_DIR/bin/python" -m pip install --upgrade pip >/dev/null
"$VENV_DIR/bin/python" -m pip install pymobiledevice3 >/dev/null

echo "📦 複製 venv 到 App Resources..."
rm -rf "$PY_DIR"
mkdir -p "$RES_DIR"
cp -R "$VENV_DIR" "$PY_DIR"

echo "🔌 綁定 libimobiledevice / idevice_id..."
IDEVICE_ID_BIN="$(command -v idevice_id || true)"
if [[ -z "$IDEVICE_ID_BIN" ]]; then
  echo "❌ 找不到 idevice_id（請先安裝 libimobiledevice / idevice_id）"
  exit 1
fi

rm -rf "$BIN_DIR" "$LIB_DIR"
mkdir -p "$BIN_DIR" "$LIB_DIR"
cp "$IDEVICE_ID_BIN" "$BIN_DIR/idevice_id"
chmod +x "$BIN_DIR/idevice_id"

copy_dep() {
  local lib="$1"
  local base
  base="$(basename "$lib")"
  if grep -Fxq "$base" "$COPIED_LIST"; then
    return
  fi
  echo "$base" >> "$COPIED_LIST"
  cp -f "$lib" "$LIB_DIR/$base"

  while IFS= read -r dep; do
    if [[ "$dep" == /opt/homebrew/* || "$dep" == /usr/local/* ]]; then
      copy_dep "$dep"
    fi
  done < <(otool -L "$lib" | tail -n +2 | awk '{print $1}')
}

while IFS= read -r dep; do
  if [[ "$dep" == /opt/homebrew/* || "$dep" == /usr/local/* ]]; then
    copy_dep "$dep"
  fi
done < <(otool -L "$IDEVICE_ID_BIN" | tail -n +2 | awk '{print $1}')

echo "🔧 修正 idevice_id / dylib 的載入路徑（移除 Homebrew 絕對路徑）..."
# idevice_id 位於 Resources/bin，依賴的 dylib 位於 Resources/lib
# - idevice_id 使用 @executable_path/../lib/xxx.dylib
# - dylib 彼此依賴使用 @loader_path/xxx.dylib
fix_macho_deps() {
  local target="$1"        # Mach-O 檔案
  local mode="$2"          # bin 或 lib
  local dep old base new

  while IFS= read -r dep; do
    old="$dep"
    base="$(basename "$dep")"
    # 只處理 Homebrew /usr/local 的絕對依賴
    if [[ "$old" == /opt/homebrew/* || "$old" == /usr/local/* ]]; then
      if [[ "$mode" == "bin" ]]; then
        new="@executable_path/../lib/$base"
      else
        new="@loader_path/$base"
      fi
      if [[ -f "$LIB_DIR/$base" ]]; then
        install_name_tool -change "$old" "$new" "$target" 2>/dev/null || true
      fi
    fi
  done < <(otool -L "$target" | tail -n +2 | awk '{print $1}')
}

# 先修 dylib 本身（讓它們互相用相對路徑）
if [[ -d "$LIB_DIR" ]]; then
  while IFS= read -r -d '' dylib; do
    base="$(basename "$dylib")"
    # 設定 dylib 的 install id（避免殘留絕對路徑）
    install_name_tool -id "@rpath/$base" "$dylib" 2>/dev/null || true
    fix_macho_deps "$dylib" "lib"
  done < <(find "$LIB_DIR" -type f -name "*.dylib" -print0)
fi

# 再修 idevice_id
fix_macho_deps "$BIN_DIR/idevice_id" "bin"

echo "✅ 已打包 Python + pymobiledevice3 + libimobiledevice 依賴"
rm -rf "$TMP_DIR"
