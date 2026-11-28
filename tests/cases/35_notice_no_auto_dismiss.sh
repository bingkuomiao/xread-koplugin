#!/bin/bash
# TC-35 结果类提示不再自动消失（v0.6.33）
# 背景：showInfo 原来按文案长度给 4~8s timeout，长一点的错误原因没读完就没了；
#       用户只能反复触发同一个错误去「抢读」，或者干脆不知道发生了什么。
# 预期：① 弹出后静置 12s 仍在（没有任何同 id 的 notice_closed）；
#       ② 点「知道了」后立即关闭（出现同 id 的 notice_closed）；
#       ③ 全程无致命错误。
CASE_ID="35_notice_no_auto_dismiss"
source "$(dirname "$0")/../lib/common.sh"

case_begin "TC-35 提示卡必须手动关闭"

emu_start "home" "notice_demo"
emu_wait_mark "flow=notice_demo shown" 180
emu_settle 4

NID=$(grep -o 'notice_shown id=[0-9]*' "$EMU_LOG" | head -1 | grep -o '[0-9]*$')
if [ -z "$NID" ]; then
    fail "日志里没有 notice_shown（提示卡没弹出来）"
    log "  tail: $(grep -a 'XREAD_AUTOTEST' "$EMU_LOG" | tail -5 | tr '\n' ' ')"
fi
log "  notice id=${NID:-none}"

# ① 12s 内不得自动关闭（旧实现的 timeout 最长 8s）
sleep 12
if [ -n "$NID" ] && grep -q "notice_closed id=$NID" "$EMU_LOG"; then
    fail "提示卡 $NID 在 12s 内自动消失了（应等用户点「知道了」或 ✕）"
else
    log "  notice still open after 12s"
fi
emu_shot
assert_shot 20000

# ② 按插件打印的按钮中心坐标点「知道了」（不猜坐标）
BTN=$(grep -o 'box_geom .*btn1=[0-9]*,[0-9]*' "$EMU_LOG" | tail -1 | grep -o 'btn1=[0-9]*,[0-9]*' | sed 's/btn1=//')
BX=${BTN%,*}
BY=${BTN#*,}
if [ -z "$BTN" ] || [ -z "$BX" ] || [ -z "$BY" ]; then
    fail "日志里没有 box_geom 按钮坐标"
else
    log "  tap 知道了 @ ${BX},${BY}"
    emu_tap "$BX" "$BY"
    closed=0
    for _i in $(seq 1 10); do
        if grep -q "notice_closed id=$NID" "$EMU_LOG"; then closed=1; break; fi
        sleep 2
    done
    [ "$closed" -eq 1 ] && log "  closed by button" || fail "点「知道了」后提示卡没有关闭"
fi

assert_no_fatal
case_finish
emu_stop
