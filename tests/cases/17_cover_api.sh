#!/bin/bash
# TC-17 统一封面接口回归（纯 Lua，不启动模拟器、不依赖 NAS）
# 覆盖：path 编码 / 统一带鉴权 / 未登录远程书 / Referer header / 401 重登重试
CASE_ID="17_cover_api"
source "$(dirname "$0")/../lib/common.sh"

case_begin "TC-17 统一封面接口"
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
if ! (cd /opt/koreader && ./lib/koreader/luajit \
        "$ROOT/tests/cover_api_test.lua" "$ROOT/xread.koplugin" >> "$CASE_LOG" 2>&1); then
    fail "封面接口单元测试失败，详见 $CASE_LOG"
fi
case_finish
