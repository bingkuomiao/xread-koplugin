#!/bin/bash
# TC-09 全量 Lua 语法检查（不依赖模拟器，秒级）
# 预期：部署目录中所有 .lua 均可被 LuaJIT loadfile 解析
CASE_ID="09_syntax"
source "$(dirname "$0")/../lib/common.sh"

case_begin "TC-09 全量 Lua 语法检查"
cd "$KOREADER_DIR" || { fail "无法进入 $KOREADER_DIR"; case_finish; exit 0; }

total=0
bad=0
while IFS= read -r f; do
    total=$((total+1))
    rel="${f#$DEPLOY/}"
    out=$(./lib/koreader/luajit -e "local fn,e=loadfile([[$f]]); print(fn and 'OK' or e)" 2>&1)
    if [ "$out" != "OK" ]; then
        bad=$((bad+1))
        fail "$rel: $out"
    fi
done < <(find "$DEPLOY" -name '*.lua' -type f | sort)

log "  checked $total lua files, bad=$bad"

case_finish
