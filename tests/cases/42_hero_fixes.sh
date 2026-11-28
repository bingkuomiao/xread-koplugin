#!/bin/bash
# TC-42 v0.6.43 英雄封面七项整改的可自动验收部分
#   1) 最近阅读左移到封面左边缘（hero_recent 日志 + 截图人工复核）
#   2) 简介与封面空一行、段落缩进、过滤非简介内容（intro_text_test + hero_intro 日志）
#   3) 封面请求不再主动索要 AVIF（后端已做 AVIF/HEIC → JPEG 转码）
#   4) 目录四按钮透明无底黑字（catalog_buttons 日志 + 截图）
#   5) 缓存确认按钮「缓存」（源码锚点；旧文案不得残留）
#   6) 升级确认按钮「升级」（update_confirm_shown 日志）
#   7) 下载进度卡新增「等待」按钮，点击后卡片收起但任务继续
CASE_ID="42_hero_fixes"
source "$(dirname "$0")/../lib/common.sh"

case_begin "TC-42 v0.6.43 英雄封面整改"

# --- 简介清洗单测（纯 Lua，不需要模拟器） ---
LT=$(/opt/koreader/lib/koreader/luajit "$TESTS_DIR/intro_text_test.lua" 2>&1)
if echo "$LT" | grep -q "12 passed, 0 failed"; then
    log "  intro_text_test: 12 passed"
else
    fail "简介清洗单测未通过: $LT"
fi

# --- 源码级文案/请求头核对 ---
check_source() {
    if grep -qF "$1" "$2"; then
        log "  source OK: $1"
    else
        fail "源码缺少: $1 ($2)"
    fi
}
check_source 'image/jpeg,image/png,image/webp' "$PLUGIN_SRC/xread/cover_cache.lua"
check_source 'cache_confirm ok=缓存' "$PLUGIN_SRC/main.lua"
check_source 'cache_confirm ok=缓存' "$PLUGIN_SRC/xread/feature_book_cache.lua"
check_source 'ok_text = _("升级")' "$PLUGIN_SRC/xread/feature_menus.lua"
if grep -R -qE 'ok_text = _("(开始缓存|更新并重启)")' "$PLUGIN_SRC"; then
    fail "旧按钮文案「开始缓存 / 更新并重启」仍有残留"
else
    log "  旧按钮文案已清除"
fi

# --- 英雄卡排版 ---
emu_start "home"
emu_wait_mark "mode=home done" 180
assert_log_contains "hero_recent x=0 cover_x=0 .* align=cover" "最近阅读与封面左对齐"
assert_log_contains "hero_intro .* intro_gap=[0-9]+ indent=2" "简介空一行且段落缩进"
assert_log_contains "hero_intro_filtered dropped=" "简介过滤逻辑已运行"
emu_settle 6
emu_shot
cp "$SHOT" "$EMU_LOG_DIR/42_home.png"
assert_no_fatal
emu_stop

# --- 目录按钮透明无底黑字 ---
emu_start "open" "catalog"
emu_wait_mark "flow=catalog done" 180
assert_log_contains "catalog_buttons back_bg=transparent order_bg=transparent nav_bg=transparent text=black" "目录四按钮透明黑字"
emu_settle 3
emu_shot
cp "$SHOT" "$EMU_LOG_DIR/42_catalog.png"
assert_no_fatal
emu_stop

# --- 下载进度卡「等待」按钮点击后任务继续 ---
emu_start "open" "progress"
emu_wait_mark "flow=progress done" 180
assert_log_contains "progress_card .* wait_button=true" "进度卡有等待按钮"
HIT=$(grep -o 'progress_card_wait_hit x=[0-9]* y=[0-9]*' "$EMU_LOG" | tail -1)
if [ -z "$HIT" ]; then
    fail "找不到等待按钮热区日志"
else
    HX=$(echo "$HIT" | sed -E 's/.*x=([0-9]+).*/\1/')
    HY=$(echo "$HIT" | sed -E 's/.*y=([0-9]+).*/\1/')
    emu_tap "$HX" "$HY"
    emu_settle 3
    assert_log_contains "progress_wait=1 task_kept=true" "点等待后卡片收起且任务继续"
fi
emu_shot
cp "$SHOT" "$EMU_LOG_DIR/42_progress.png"
assert_no_fatal
emu_stop

case_finish
