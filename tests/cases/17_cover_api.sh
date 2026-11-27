#!/bin/bash
# TC-17 统一封面接口回归（纯 Lua，不启动模拟器、不依赖 NAS）
# 覆盖：path 编码 / 统一带鉴权 / 未登录远程书 / Referer header / 401 重登重试
CASE_ID="17_cover_api"
source "$(dirname "$0")/../lib/common.sh"

case_begin "TC-17 统一封面接口"
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
# 纯 Lua 用例直接跑 luajit，不经过 koreader.sh，必须自己给全 Lua 搜索路径：
# 否则 require("libs/libkoreader-lfs") 找不到 .so，用例会因为环境而不是代码失败。
LUAROOT="/opt/koreader/lib/koreader"
export LUA_PATH="$LUAROOT/?.lua;$LUAROOT/frontend/?.lua;$LUAROOT/plugins/?.lua;${LUA_PATH:-};;"
export LUA_CPATH="$LUAROOT/?.so;${LUA_CPATH:-};;"
if ! (cd /opt/koreader && ./lib/koreader/luajit \
        "$ROOT/tests/cover_api_test.lua" "$ROOT/xread.koplugin" >> "$CASE_LOG" 2>&1); then
    fail "封面接口单元测试失败，详见 $CASE_LOG"
fi
case_finish
