#!/bin/bash
set -euo pipefail

APP_PATH="${1:-}"
if [[ -z "$APP_PATH" || ! -d "$APP_PATH" ]]; then
  echo "用法: $0 /path/to/KongGoo.app"
  exit 1
fi

RES_DIR="$APP_PATH/Contents/Resources"
PY_DIR_ARM="$RES_DIR/python_arm64"
PY_DIR_X86="$RES_DIR/python_x86_64"
BIN_DIR_ARM="$RES_DIR/bin_arm64"
LIB_DIR_ARM="$RES_DIR/lib_arm64"
BIN_DIR_X86="$RES_DIR/bin_x86_64"
LIB_DIR_X86="$RES_DIR/lib_x86_64"

PYTHON_SRC_ARM="${PYTHON_SRC_ARM:-/usr/bin/python3}"
PYTHON_SRC_X86="${PYTHON_SRC_X86:-/usr/bin/python3}"
if [[ ! -x "$PYTHON_SRC_ARM" || ! -x "$PYTHON_SRC_X86" ]]; then
  echo "❌ 找不到 /usr/bin/python3（需要通用 python 來產出雙架構）"
  exit 1
fi

TMP_DIR="$(mktemp -d)"
VENV_DIR="$TMP_DIR/venv"
COPIED_LIST="$TMP_DIR/copied.txt"
touch "$COPIED_LIST"

echo "🐍 建立內嵌 Python venv（arm64 + x86_64）..."
VENV_DIR_ARM="$TMP_DIR/venv_arm64"
VENV_DIR_X86="$TMP_DIR/venv_x86_64"

# arm64 venv
# 先創建 venv（可能使用 symlink）
echo "創建 arm64 venv..."
VENV_ARGS_ARM="--copies"
if [[ "$PYTHON_SRC_ARM" == "/usr/bin/python3" ]]; then
  # /usr/bin/python3 不支援 --copies，先創建普通 venv
  VENV_ARGS_ARM=""
fi
arch -arm64 "$PYTHON_SRC_ARM" -m venv $VENV_ARGS_ARM "$VENV_DIR_ARM" 2>&1 || {
  # 如果失敗，嘗試不使用 --copies
  echo "⚠️  --copies 失敗，使用普通 venv..."
  arch -arm64 "$PYTHON_SRC_ARM" -m venv "$VENV_DIR_ARM"
}
arch -arm64 "$VENV_DIR_ARM/bin/python" -m ensurepip --upgrade >/dev/null 2>&1 || true
arch -arm64 "$VENV_DIR_ARM/bin/python" -m pip install --upgrade pip >/dev/null
PIP_NO_COMPILE=1 arch -arm64 "$VENV_DIR_ARM/bin/python" -m pip install --no-compile pymobiledevice3 >/dev/null

# x86_64 venv
echo "創建 x86_64 venv..."
VENV_ARGS_X86="--copies"
if [[ "$PYTHON_SRC_X86" == "/usr/bin/python3" ]]; then
  VENV_ARGS_X86=""
fi
arch -x86_64 "$PYTHON_SRC_X86" -m venv $VENV_ARGS_X86 "$VENV_DIR_X86" 2>&1 || {
  echo "⚠️  --copies 失敗，使用普通 venv..."
  arch -x86_64 "$PYTHON_SRC_X86" -m venv "$VENV_DIR_X86"
}
arch -x86_64 "$VENV_DIR_X86/bin/python" -m ensurepip --upgrade >/dev/null 2>&1 || true
arch -x86_64 "$VENV_DIR_X86/bin/python" -m pip install --upgrade pip >/dev/null
PIP_NO_COMPILE=1 arch -x86_64 "$VENV_DIR_X86/bin/python" -m pip install --no-compile pymobiledevice3 >/dev/null
arch -x86_64 "$VENV_DIR_X86/bin/python" -m ensurepip --upgrade >/dev/null 2>&1 || true
arch -x86_64 "$VENV_DIR_X86/bin/python" -m pip install --upgrade pip >/dev/null
PIP_NO_COMPILE=1 arch -x86_64 "$VENV_DIR_X86/bin/python" -m pip install --no-compile pymobiledevice3 >/dev/null

echo "📦 複製 venv 到 App Resources..."
rm -rf "$PY_DIR_ARM" "$PY_DIR_X86"
mkdir -p "$RES_DIR"
cp -R "$VENV_DIR_ARM" "$PY_DIR_ARM"
cp -R "$VENV_DIR_X86" "$PY_DIR_X86"

# 確保所有符號連結都被替換為實際檔案（公證要求）
echo "🔗 檢查並修復符號連結..."
fix_symlinks() {
  local dir="$1"
  local fixed=0
  local removed=0
  
  # 使用 find -exec 來處理每個符號連結
  find "$dir" -type l -print0 | while IFS= read -r -d '' symlink; do
    local target=$(readlink "$symlink")
    # 如果是絕對路徑（指向 bundle 外部），需要替換
    if [[ "$target" == /* ]]; then
      if [[ -f "$target" ]]; then
        echo "  替換符號連結: $symlink -> $target"
        # 先複製檔案
        local temp_file="${symlink}.tmp"
        cp "$target" "$temp_file"
        chmod +x "$temp_file" 2>/dev/null || true
        # 移除符號連結並移動檔案
        rm "$symlink"
        mv "$temp_file" "$symlink"
        fixed=$((fixed + 1))
      elif [[ -d "$target" ]]; then
        echo "  警告: 符號連結指向目錄，跳過: $symlink -> $target"
      else
        echo "  警告: 符號連結目標不存在，移除: $symlink -> $target"
        rm "$symlink"
        removed=$((removed + 1))
      fi
    fi
  done
  
  echo "  ✅ 已修復 $fixed 個符號連結，移除 $removed 個無效符號連結"
}

fix_symlinks "$PY_DIR_ARM"
fix_symlinks "$PY_DIR_X86"

echo "🔌 綁定 libimobiledevice / idevice_id（arm64）..."
IDEVICE_ID_BIN_ARM="${IDEVICE_ID_BIN_ARM:-$(command -v idevice_id || true)}"
if [[ -z "$IDEVICE_ID_BIN_ARM" ]]; then
  echo "⚠️  找不到 idevice_id（arm64），將略過（仍可用 system_profiler）"
else
  rm -rf "$BIN_DIR_ARM" "$LIB_DIR_ARM"
  mkdir -p "$BIN_DIR_ARM" "$LIB_DIR_ARM"
  cp "$IDEVICE_ID_BIN_ARM" "$BIN_DIR_ARM/idevice_id"
  chmod +x "$BIN_DIR_ARM/idevice_id"
fi

copy_dep() {
  local lib="$1"
  local lib_dir="$2"
  local copied_list="$3"
  local base
  base="$(basename "$lib")"
  if grep -Fxq "$base" "$copied_list"; then
    return
  fi
  echo "$base" >> "$copied_list"
  cp -f "$lib" "$lib_dir/$base"

  while IFS= read -r dep; do
    if [[ "$dep" == /opt/homebrew/* || "$dep" == /usr/local/* ]]; then
      copy_dep "$dep" "$lib_dir" "$copied_list"
    fi
  done < <(otool -L "$lib" | tail -n +2 | awk '{print $1}')
}

if [[ -n "${IDEVICE_ID_BIN_ARM:-}" && -f "$BIN_DIR_ARM/idevice_id" ]]; then
  COPIED_LIST_ARM="$TMP_DIR/copied_arm64.txt"
  touch "$COPIED_LIST_ARM"
  while IFS= read -r dep; do
    if [[ "$dep" == /opt/homebrew/* || "$dep" == /usr/local/* ]]; then
      copy_dep "$dep" "$LIB_DIR_ARM" "$COPIED_LIST_ARM"
    fi
  done < <(otool -L "$IDEVICE_ID_BIN_ARM" | tail -n +2 | awk '{print $1}')
fi

echo "🔧 修正 idevice_id / dylib 的載入路徑（移除 Homebrew 絕對路徑）..."
# idevice_id 位於 Resources/bin，依賴的 dylib 位於 Resources/lib
# - idevice_id 使用 @executable_path/../lib/xxx.dylib
# - dylib 彼此依賴使用 @loader_path/xxx.dylib
fix_macho_deps() {
  local target="$1"        # Mach-O 檔案
  local mode="$2"          # bin 或 lib
  local lib_dir="$3"
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
      if [[ -f "$lib_dir/$base" ]]; then
        install_name_tool -change "$old" "$new" "$target" 2>/dev/null || true
      fi
    fi
  done < <(otool -L "$target" | tail -n +2 | awk '{print $1}')
}

# 先修 dylib 本身（讓它們互相用相對路徑）
if [[ -d "$LIB_DIR_ARM" ]]; then
  while IFS= read -r -d '' dylib; do
    base="$(basename "$dylib")"
    # 設定 dylib 的 install id（避免殘留絕對路徑）
    install_name_tool -id "@rpath/$base" "$dylib" 2>/dev/null || true
    fix_macho_deps "$dylib" "lib" "$LIB_DIR_ARM"
  done < <(find "$LIB_DIR_ARM" -type f -name "*.dylib" -print0)
fi

# 再修 idevice_id
if [[ -f "$BIN_DIR_ARM/idevice_id" ]]; then
  fix_macho_deps "$BIN_DIR_ARM/idevice_id" "bin" "$LIB_DIR_ARM"
fi

echo "✅ 已打包 Python + pymobiledevice3 + libimobiledevice 依賴"
rm -rf "$TMP_DIR"
