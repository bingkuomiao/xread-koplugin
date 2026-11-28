#!/bin/bash
# TC-15c 更多页所有菜单项：每个独立会话，先开更多面板再点条目截图
# v0.6.37 起更多面板 6 项：我的书架 / 本地书架 / 首页管理 / 系统管理 / 升级管理 / 关于本机
# （地址管理、账号管理已从「更多」移除，首页齿轮「设置」里各有入口）
# 坐标不再硬编码：面板在自己 paint 时打印 `more_row text=<标签> x= y=`，
# 这里按标签取 y —— 以后再增删菜单项也不用改这个文件。
CASE_ID="15c_more_menu"
source "$(dirname "$0")/../lib/common.sh"

probe_menu() {  # probe_menu <名称> <菜单标签>
    local name="$1" label="$2"
    emu_start "home"
    emu_wait_mark "mode=home done" 180
    emu_settle 8
    emu_tap 1005 45; sleep 3       # 开更多面板
    local x y
    read -r x y <<<"$(grep -a "more_row text=${label} " "$EMU_LOG" | tail -1 \
        | sed -n 's/.*x=\([0-9]*\) y=\([0-9]*\).*/\1 \2/p')"
    if [ -z "$y" ]; then
        fail "更多面板里找不到「$label」的行坐标"
        emu_stop
        return
    fi
    emu_tap "$x" "$y"; sleep 5     # 点菜单项
    local f="$EMU_LOG_DIR/menu_$name.png"
    import -window root "$f" 2>/dev/null
    log "  MENU $name ($label) @$x,$y: $(stat -c %s "$f" 2>/dev/null || echo 0)B"
    emu_stop
}

case_begin "TC-15c 更多页菜单项遍历（独立会话）"
probe_menu "01_myshelf" "我的书架"
probe_menu "02_local" "本地书架"
probe_menu "03_boot" "首页管理"
probe_menu "04_system" "系统管理"
probe_menu "05_upgrade" "升级管理"
probe_menu "06_about" "关于本机"
assert_no_fatal
case_finish
emu_stop
