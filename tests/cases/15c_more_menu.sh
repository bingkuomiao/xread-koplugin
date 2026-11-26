#!/bin/bash
# TC-15c 更多页所有菜单项：每个独立会话，先开更多面板再点条目截图
# v0.6.9 起更多面板只剩 5 项：我的书架 / 地址管理 / 账号管理 / 翻页管理 / 关于本机（缓存管理已移除）
CASE_ID="15c_more_menu"
source "$(dirname "$0")/../lib/common.sh"

probe_menu() {  # probe_menu <名称> <y>
    local name="$1" y="$2"
    emu_start "home"
    emu_wait_mark "mode=home done" 180
    emu_settle 8
    emu_tap 1005 45; sleep 3       # 开更多面板
    emu_tap 400 "$y"; sleep 5      # 点菜单项
    local f="$EMU_LOG_DIR/menu_$name.png"
    import -window root "$f" 2>/dev/null
    log "  MENU $name @400,$y: $(stat -c %s "$f" 2>/dev/null || echo 0)B"
    emu_stop
}

case_begin "TC-15c 更多页菜单项遍历（独立会话）"
probe_menu "01_myshelf" 546
probe_menu "02_address" 647
probe_menu "03_account" 748
probe_menu "04_pageflip" 849
probe_menu "05_about" 950
assert_no_fatal
case_finish
emu_stop
