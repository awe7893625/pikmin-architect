#!/usr/bin/env bash
#
# rotate-ecpay-keys.sh — 綠界 HashKey/HashIV 輪換（一次更新所有使用中的專案）
#
# 背景：2026-08-20 發現 HashKey/HashIV 曾隨 public repo 外洩約七個月。
# 拿到這兩把就能算出合法 CheckMacValue，對各站的付款回調送假的「付款成功」。
#
# ⚠️ 三個 Vercel 專案共用同一個綠界商店（MerchantID 3487294）：
#       pikmin-architect       KongGoo（konggoo.uk）
#       saas-alternatives-hub  saasalternatives.uk
#       something-select       選物事務所（somethings.cool）
#   在綠界後台換金鑰之後，這三個必須「同時」更新，否則沒更新的那些站
#   會開始把真實付款判成 CheckMacValue 錯誤，等於金流全掛。
#
# 用法（新金鑰請用互動輸入，不要放進命令列，否則會留在 shell history）：
#     bash scripts/rotate-ecpay-keys.sh
#
set -euo pipefail

PROJECTS=(pikmin-architect saas-alternatives-hub something-select)
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

die() { printf '\033[31m✗ %s\033[0m\n' "$1" >&2; exit 1; }
step() { printf '\n\033[36m▶ %s\033[0m\n' "$1"; }

command -v vercel >/dev/null || die "找不到 vercel CLI"

step "輸入新的綠界金鑰（輸入時不會顯示）"
read -rsp "  新 HashKey: " NEW_KEY; echo
read -rsp "  新 HashIV : " NEW_IV; echo
[ ${#NEW_KEY} -ge 8 ] || die "HashKey 看起來不對（長度 ${#NEW_KEY}）"
[ ${#NEW_IV} -ge 8 ]  || die "HashIV 看起來不對（長度 ${#NEW_IV}）"

step "確認"
echo "  將更新這些專案的 production 環境變數："
printf '    - %s\n' "${PROJECTS[@]}"
read -rp "  確定要繼續？(yes/no) " ans
[ "$ans" = "yes" ] || die "已取消"

for proj in "${PROJECTS[@]}"; do
  step "更新 $proj"
  d="$WORKDIR/$proj"; mkdir -p "$d"
  ( cd "$d" && vercel link --yes --project "$proj" >/dev/null 2>&1 ) || die "$proj link 失敗"
  for pair in "ECPAY_HASH_KEY:$NEW_KEY" "ECPAY_HASH_IV:$NEW_IV"; do
    name="${pair%%:*}"; val="${pair#*:}"
    ( cd "$d" && vercel env rm "$name" production --yes >/dev/null 2>&1 || true )
    printf '%s' "$val" | ( cd "$d" && vercel env add "$name" production >/dev/null 2>&1 ) \
      || die "$proj 寫入 $name 失敗"
    echo "  $name ✓"
  done
done

step "重新部署（環境變數改了要重部署才會生效）"
echo "  ⚠️ 這一步請手動做，因為每個專案的部署目錄不同："
echo "     cd ~/Projects/pikmin-architect      && vercel --prod --yes"
echo "     cd ~/Projects/SomethingSelect-Store && vercel --prod --yes"
echo "     saas-alternatives-hub 的原始碼不在本機，需從其 repo 部署"

printf '\n\033[32m✅ 環境變數已更新。重部署後請務必實測一筆小額付款。\033[0m\n'
echo "   KongGoo 這側另有 queryEcpayTrade() 回頭對帳，金鑰換錯會在對帳階段就擋下，不會誤發授權。"
