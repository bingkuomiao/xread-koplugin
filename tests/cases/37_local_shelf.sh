#!/bin/bash
# TC-37 本地书架（v0.6.37）
# 背景：1)「更多」里新增「本地书架」，和首页底部「本地阅读」同一入口；
#       2) 本机导出的 EPUB 以前只有灰底占位块 —— 要和「我的书架」共享封面。
# 做法：flow=local_shelf 造一本和书架第一本同名的假 EPUB（不带 .cover.png），
#       打开本地书架后应命中书架封面缓存（cache=true / shown=true）。
# 截图人工复核：网格里第一张卡片是真实封面、铺满无白边；v0.6.40 起本地书架不再画 ✓ 角标。
CASE_ID="37_local_shelf"
source "$(dirname "$0")/../lib/common.sh"

case_begin "TC-37 本地书架复用书架封面 + 长按删除"
emu_start "home" "local_shelf"
emu_wait_mark "flow=local_shelf done" 180
assert_log_contains "flow=local_shelf done .*cache=true" "命中书架封面缓存"
assert_log_contains "flow=local_shelf done .*shown=true" "本地卡片带上了封面"
emu_settle 6
emu_shot
assert_shot 20000

# 长按第一张卡片 → 「删除本机这一份？」确认卡 → 点「删除」
# 注意：box_geom 每个按钮打印一行，必须挑 btn1 那一行（tail -1 拿到的是 btn2，没有 btn1 字段）。
xdotool mousemove 108 205; sleep 0.4
xdotool mousedown 1; sleep 1.3; xdotool mouseup 1
bx=""; by=""
for _i in $(seq 1 20); do
    read -r bx by <<<"$(grep -a "box_geom" "$EMU_LOG" | grep -a "btn1=" | tail -1 \
        | sed -n 's/.*btn1=\([0-9]*\),\([0-9]*\).*/\1 \2/p')"
    [ -n "$by" ] && break
    sleep 1
done
if [ -z "$by" ]; then
    fail "长按后没有弹出确认卡（找不到 box_geom btn1）"
else
    log "  确认卡删除按钮 @$bx,$by"
    emu_tap "$bx" "$by"
    for _i in $(seq 1 20); do
        grep -aq "local_book_deleted" "$EMU_LOG" && break
        sleep 1
    done
fi
if grep -aq "local_book_deleted" "$EMU_LOG"; then
    log "  删除标记: $(grep -a "local_book_deleted" "$EMU_LOG" | tail -1)"
else
    fail "没有出现 local_book_deleted 标记"
fi
emu_settle 2
emu_shot
assert_no_fatal
case_finish
emu_stop
