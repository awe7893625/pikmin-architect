#!/bin/bash

# 授權流程測試腳本
# 使用方法: ./test_license_flow.sh [API_BASE_URL]
# 例如: ./test_license_flow.sh http://localhost:3001/api

API_BASE="${1:-http://localhost:3001/api}"
DEVICE_ID="TEST-DEVICE-$(date +%s)"

# 顏色定義
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}🧪 開始測試授權流程...${NC}"
echo -e "${BLUE}API 基礎 URL: $API_BASE${NC}"
echo -e "${BLUE}設備 ID: $DEVICE_ID${NC}"
echo ""

# 測試 1: 新設備註冊
echo -e "${YELLOW}📝 測試 1: 新設備註冊${NC}"
RESPONSE=$(curl -s -X POST $API_BASE/auth/check \
  -H "Content-Type: application/json" \
  -d "{\"deviceId\": \"$DEVICE_ID\"}")
echo "響應: $RESPONSE"
TRIAL_COUNT=$(echo $RESPONSE | grep -o '"trialCount":[0-9]*' | grep -o '[0-9]*')
if [ "$TRIAL_COUNT" = "3" ]; then
    echo -e "${GREEN}✅ 測試通過: trialCount = 3${NC}"
else
    echo -e "${RED}❌ 測試失敗: trialCount = $TRIAL_COUNT (預期: 3)${NC}"
fi
echo ""

# 測試 2: 消耗試用
echo -e "${YELLOW}🎯 測試 2: 消耗試用次數${NC}"
RESPONSE=$(curl -s -X POST $API_BASE/trial/consume \
  -H "Content-Type: application/json" \
  -d "{\"deviceId\": \"$DEVICE_ID\", \"feature\": \"teleport\"}")
echo "響應: $RESPONSE"
TRIAL_COUNT=$(echo $RESPONSE | grep -o '"trialCount":[0-9]*' | grep -o '[0-9]*')
if [ "$TRIAL_COUNT" = "2" ]; then
    echo -e "${GREEN}✅ 測試通過: trialCount = 2${NC}"
else
    echo -e "${RED}❌ 測試失敗: trialCount = $TRIAL_COUNT (預期: 2)${NC}"
fi
echo ""

# 測試 3: 檢查狀態（驗證已保存）
echo -e "${YELLOW}🔍 測試 3: 檢查狀態（驗證已保存）${NC}"
RESPONSE=$(curl -s -X POST $API_BASE/auth/check \
  -H "Content-Type: application/json" \
  -d "{\"deviceId\": \"$DEVICE_ID\"}")
echo "響應: $RESPONSE"
TRIAL_COUNT=$(echo $RESPONSE | grep -o '"trialCount":[0-9]*' | grep -o '[0-9]*')
if [ "$TRIAL_COUNT" = "2" ]; then
    echo -e "${GREEN}✅ 測試通過: 狀態已保存，trialCount = 2${NC}"
else
    echo -e "${RED}❌ 測試失敗: trialCount = $TRIAL_COUNT (預期: 2)${NC}"
fi
echo ""

# 測試 4: 激活授權碼
echo -e "${YELLOW}🔑 測試 4: 激活授權碼${NC}"
RESPONSE=$(curl -s -X POST $API_BASE/license/activate \
  -H "Content-Type: application/json" \
  -d "{\"deviceId\": \"$DEVICE_ID\", \"licenseKey\": \"PKM-F7EC3C6305756F6C\"}")
echo "響應: $RESPONSE"
IS_ACTIVATED=$(echo $RESPONSE | grep -o '"isActivated":true')
if [ -n "$IS_ACTIVATED" ]; then
    echo -e "${GREEN}✅ 測試通過: 授權碼激活成功${NC}"
else
    echo -e "${RED}❌ 測試失敗: 授權碼激活失敗${NC}"
fi
echo ""

# 測試 5: 授權後不扣 trial
echo -e "${YELLOW}✅ 測試 5: 授權後不扣 trial${NC}"
RESPONSE=$(curl -s -X POST $API_BASE/trial/consume \
  -H "Content-Type: application/json" \
  -d "{\"deviceId\": \"$DEVICE_ID\", \"feature\": \"teleport\"}")
echo "響應: $RESPONSE"
IS_ACTIVATED=$(echo $RESPONSE | grep -o '"isActivated":true')
MESSAGE=$(echo $RESPONSE | grep -o '"message":"[^"]*"')
if [ -n "$IS_ACTIVATED" ] && [ -n "$MESSAGE" ]; then
    echo -e "${GREEN}✅ 測試通過: 已激活，無需消耗試用次數${NC}"
else
    echo -e "${RED}❌ 測試失敗: 授權後仍扣 trial${NC}"
fi
echo ""

# 測試 6: 檢查授權狀態（最終驗證）
echo -e "${YELLOW}🔍 測試 6: 檢查授權狀態（最終驗證）${NC}"
RESPONSE=$(curl -s -X POST $API_BASE/auth/check \
  -H "Content-Type: application/json" \
  -d "{\"deviceId\": \"$DEVICE_ID\"}")
echo "響應: $RESPONSE"
IS_ACTIVATED=$(echo $RESPONSE | grep -o '"isActivated":true')
if [ -n "$IS_ACTIVATED" ]; then
    echo -e "${GREEN}✅ 測試通過: 授權狀態正確${NC}"
else
    echo -e "${RED}❌ 測試失敗: 授權狀態不正確${NC}"
fi
echo ""

echo -e "${BLUE}✅ 測試完成${NC}"
echo -e "${BLUE}設備 ID: $DEVICE_ID${NC}"
echo -e "${BLUE}如需測試 redeploy/cold start，請重啟服務器後再次運行此腳本${NC}"
