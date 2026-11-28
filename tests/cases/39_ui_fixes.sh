#!/bin/bash
# TC-39 v0.6.40 九项 UI 修正的可自动验收部分
#   1) 英雄卡进度条上方有「阅读进度 N%」文字（hero_progress 日志）
#   2) 更多面板改名「加载管理」且不再有「升级管理」（more_row 日志）
#   3) 下载进度卡只有「取消」一个按钮（progress_card 日志）
#   4) 我的书架长按封面弹的是移除确认，不再是目录页（box_geom + shelf_book_removed）
# 截图人工复核：本地书架封面无 ✓ 角标/无上方白边；目录返回/倒序无灰底；
#               自动更新点「更新」直达升级确认框。这些无稳定日志锚点，不写断言。
CASE_ID="39_ui_fixes"
source "$(dirname "$0")/../lib/common.sh"

case_begin "TC-39 v0.6.40 UI 修正"

# --- 英雄卡进度百分比 ---
emu_start "home"
emu_wait_mark "mode=home done" 180
assert_log_contains "\[XREAD_AUTOTEST\] hero_progress text=阅读进度 [0-9]+%" "英雄卡有阅读进度文字"
emu_settle 5
emu_shot
assert_shot 20000
cp "$SHOT" "$EMU_LOG_DIR/39_hero.png"

# --- 更多面板：改名 + 去掉升级管理 ---
emu_tap 1005 45; sleep 4
assert_log_contains "more_row text=加载管理 " "更多页出现「加载管理」"
if grep -aq "more_row text=升级管理 " "$EMU_LOG"; then
    fail "更多页仍保留「升级管理」"
else
    log "  log OK: 更多页已无「升级管理」"
fi
emu_settle 2
emu_shot
cp "$SHOT" "$EMU_LOG_DIR/39_more.png"
assert_no_fatal
emu_stop

# --- 下载进度卡只有一个取消按钮 ---
# flow 只在阅读器实例里分发，所以必须用 open 模式（带文档）
emu_start "open" "progress"
emu_wait_mark "flow=progress done" 180
assert_log_contains "progress_card buttons=true only_cancel=true" "进度卡只有一个取消按钮"
emu_settle 4
emu_shot
assert_shot 20000
cp "$SHOT" "$EMU_LOG_DIR/39_progress.png"
assert_no_fatal
emu_stop

# --- 我的书架长按封面 = 移除书籍（原来弹目录） ---
emu_start "shelfback"
emu_wait_mark "mode=shelfback done" 240
emu_settle 6
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
    fail "长按书架封面没有弹出移除确认卡"
else
    log "  移除确认卡按钮 @$bx,$by"
    # 点「忽略」收掉确认框：只验证长按进的是移除流程，不真的删书，
    # 否则会污染后续 37_local_shelf 用的书架缓存。
    ibx=""; iby=""
    read -r ibx iby <<<"$(grep -a "box_geom" "$EMU_LOG" | grep -a "btn2=" | tail -1 \
        | sed -n 's/.*btn2=\([0-9]*\),\([0-9]*\).*/\1 \2/p')"
    if [ -n "$iby" ]; then emu_tap "$ibx" "$iby"; fi
fi
assert_log_contains "remove_flow_requested name=" "长按封面走的是移除书籍流程（不是目录页）"
emu_settle 3
emu_shot
assert_no_fatal
emu_stop

# --- 自动更新：点「更新」直达升级确认框（不跳关于本机） ---
emu_start "open" "update_notice"
emu_wait_mark "flow=update_notice done" 180
ubx=""; uby=""
for _i in $(seq 1 20); do
    read -r ubx uby <<<"$(grep -a "box_geom" "$EMU_LOG" | grep -a "btn1=" | tail -1 \
        | sed -n 's/.*btn1=\([0-9]*\),\([0-9]*\).*/\1 \2/p')"
    [ -n "$uby" ] && break
    sleep 1
done
if [ -z "$uby" ]; then
    fail "自动更新提示卡没有出现（找不到 box_geom btn1）"
else
    log "  更新按钮 @$ubx,$uby"
    emu_tap "$ubx" "$uby"
    for _i in $(seq 1 20); do
        grep -aq "update_confirm_shown" "$EMU_LOG" && break
        sleep 1
    done
fi
assert_log_contains "update_confirm_shown" "点更新后直接弹出升级确认框"
if grep -aq "about_server_version" "$EMU_LOG"; then
    fail "点更新后仍跳到了关于本机"
else
    log "  log OK: 没有跳到关于本机"
fi
emu_settle 3
emu_shot
assert_no_fatal
case_finish
emu_stop
