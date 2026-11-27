#!/bin/bash
# TC-22 首页 hero 封面 / 刷新按钮 / 缓存章节数单选 / 翻章章节名同步
CASE_ID="22_home_hero_cache"
source "$(dirname "$0")/../lib/common.sh"

case_begin "TC-22 首页封面刷新 / 缓存设置 / 翻章同步"

# ---------- 1) 首页 hero 封面 + 右上角刷新按钮 ----------
emu_start "home"
emu_wait_mark "mode=home done" 180
emu_settle 12
import -window root "$EMU_LOG_DIR/hh_01_home.png" 2>/dev/null
log "  hh_01_home: $(stat -c %s "$EMU_LOG_DIR/hh_01_home.png" 2>/dev/null || echo 0)B"
# 1072x1448 下 hero 卡右上角刷新图标约在 (500,140)
emu_tap 500 140
sleep 8
import -window root "$EMU_LOG_DIR/hh_02_refresh.png" 2>/dev/null
log "  hh_02_refresh: $(stat -c %s "$EMU_LOG_DIR/hh_02_refresh.png" 2>/dev/null || echo 0)B"
assert_log_contains 'hero_refresh tapped shown=true' '首页刷新按钮被点中'
assert_no_fatal
emu_stop

# ---------- 2) 设置面板：缓存文案 + 选中态（黑底白字） ----------
sed -i 's/\["cache_depth"\] = "[^"]*"/\["cache_depth"\] = "50"/' \
    /root/.config/koreader/settings/xread.lua 2>/dev/null || true
emu_start "open" "settings"
emu_wait_mark "mode=open done" 180
emu_wait_mark "flow=settings done" 60
emu_settle 6
import -window root "$EMU_LOG_DIR/hh_03_settings.png" 2>/dev/null
log "  hh_03_settings: $(stat -c %s "$EMU_LOG_DIR/hh_03_settings.png" 2>/dev/null || echo 0)B"
assert_no_fatal
emu_stop

# ---------- 3) 缓存章节数全不选：点「缓存」先提示去首页设置 ----------
sed -i 's/\["cache_depth"\] = "[^"]*"/\["cache_depth"\] = "none"/' \
    /root/.config/koreader/settings/xread.lua 2>/dev/null || true
emu_start "open" "cache_none"
emu_wait_mark "mode=open done" 180
emu_wait_mark "flow=cache_none done" 60
emu_settle 8
import -window root "$EMU_LOG_DIR/hh_04_cache_none.png" 2>/dev/null
log "  hh_04_cache_none: $(stat -c %s "$EMU_LOG_DIR/hh_04_cache_none.png" 2>/dev/null || echo 0)B"
assert_no_fatal
emu_stop

# ---------- 4) 本地已有 EPUB：确认框按钮应为「覆盖」 ----------
emu_start "open" "download_confirm"
emu_wait_mark "mode=open done" 180
emu_wait_mark "flow=download_confirm" 60
emu_settle 6
import -window root "$EMU_LOG_DIR/hh_06_download.png" 2>/dev/null
log "  hh_06_download: $(stat -c %s "$EMU_LOG_DIR/hh_06_download.png" 2>/dev/null || echo 0)B"
assert_no_fatal
emu_stop

# ---------- 5) 正常翻到最后一页（跨章）后章节名同步 ----------
sed -i 's/\["cache_depth"\] = "[^"]*"/\["cache_depth"\] = "50"/' \
    /root/.config/koreader/settings/xread.lua 2>/dev/null || true
emu_start "open" "chapter_sync"
emu_wait_mark "mode=open done" 180
emu_wait_mark "flow=chapter_sync" 90
assert_log_contains 'flow=chapter_sync idx=[0-9]+ last=[0-9]+' '翻章后章节号已更新'
emu_settle 6
import -window root "$EMU_LOG_DIR/hh_05_chapter.png" 2>/dev/null
log "  hh_05_chapter: $(stat -c %s "$EMU_LOG_DIR/hh_05_chapter.png" 2>/dev/null || echo 0)B"
assert_no_fatal
emu_stop

case_finish
