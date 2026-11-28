#!/usr/bin/env bash
# TC-34 更新器建目录（相对 / 绝对路径）
# 背景：v0.6.29→0.6.31 新增 xread/feature/ 子目录后整包更新失败，
#       弹窗只报「xread/feature/book_cache.lua（无法写入）」。
#       根因是 ensureDir 按绝对路径处理：cur 从 "" 开始拼 "/"、且第一段不创建，
#       plugin_root 是相对路径时会去 mkdir "/plugins/..."，父目录不存在 → 建目录失败，
#       于是「新增目录里的文件」全灭，而已有目录里的文件照常写入。
# 说明：模拟器进程的 CWD 是 $KOREADER_DIR/lib/koreader，相对路径就相对它落盘。
# 断言：相对路径与绝对路径都能真的建出多级目录；日志里没有「无法创建目录」。
CASE_ID="34_updater_ensure_dir"
source "$(dirname "$0")/../lib/common.sh"

cleanup() {
    rm -rf "$KOREADER_DIR/lib/koreader/xread_reltest" /tmp/xread_abstest
    emu_stop 2>/dev/null
    return 0
}
trap cleanup EXIT

case_begin "TC-34 更新器建目录（相对/绝对）"

rm -rf "$KOREADER_DIR/lib/koreader/xread_reltest" /tmp/xread_abstest

emu_start "home" "updater_ensure_dir"
emu_wait_mark "mode=home done" 180
emu_wait_mark "flow=updater_ensure_dir done" 120

assert_log_contains "ensure_dir relative ok=true mode=directory" "相对路径多级目录创建成功"
assert_log_contains "ensure_dir absolute ok=true mode=directory" "绝对路径多级目录创建成功"

[ -d "$KOREADER_DIR/lib/koreader/xread_reltest/a/b" ] || fail "相对路径目录未落盘：$KOREADER_DIR/lib/koreader/xread_reltest/a/b"
[ -d /tmp/xread_abstest/a/b ] || fail "绝对路径目录未落盘：/tmp/xread_abstest/a/b"

if grep -aq "无法创建目录" "$EMU_LOG"; then
    fail "建目录仍然报错：$(grep -a '无法创建目录' "$EMU_LOG" | tail -1)"
fi
assert_no_fatal

case_finish
emu_stop
