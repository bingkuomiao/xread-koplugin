#!/bin/bash
# xread.koplugin 自动测试公共库（在 WSL Ubuntu 内运行）
# 被 cases/*.sh source，提供模拟器启停、验收标记等待、截图与断言。

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT_DIR="$(dirname "$TESTS_DIR")"
PLUGIN_SRC="$ROOT_DIR/xread.koplugin"
DEPLOY="/opt/koreader/lib/koreader/plugins/xread.koplugin"
KOREADER_DIR="/opt/koreader"
EMU_LOG_DIR="${RUN_DIR:-$TESTS_DIR/reports/manual}"

CASE_ID="${CASE_ID:-case}"
CASE_LOG="$EMU_LOG_DIR/$CASE_ID.case.log"
EMU_LOG="$EMU_LOG_DIR/$CASE_ID.emu.log"
SHOT="$EMU_LOG_DIR/$CASE_ID.png"
STATUS_FILE="$EMU_LOG_DIR/$CASE_ID.status"

FAIL_REASONS=""
EMU_PID=""
XVFB_PID=""
CURRENT_CASE=""

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" | tee -a "$CASE_LOG"; }

case_begin() {
    CURRENT_CASE="$1"
    mkdir -p "$EMU_LOG_DIR"
    : > "$CASE_LOG"
    : > "$EMU_LOG"
    log "CASE START: $CURRENT_CASE"
}

fail() {
    FAIL_REASONS="$FAIL_REASONS; $1"
    log "  FAIL: $1"
}

# 启动模拟器：emu_start <autotest模式: shelf|open|home> <flow: panel|catalog|shelf|stats|home|cache>
emu_start() {
    local mode="$1" flow="${2:-}"
    pkill -9 -f '[X]vfb' 2>/dev/null
    pkill -9 -f '[l]uajit' 2>/dev/null
    sleep 1
    rm -f /tmp/xread_autotest_once /tmp/xread_flow_once /root/.config/koreader/history.lua
    # KOReader 启动会恢复上次打开的书（settings["lastfile"]），会把自动进入的首页/书架盖住
    sed -i '/\["lastfile"\]/d' /root/.config/koreader/settings.reader.lua 2>/dev/null

    export DISPLAY=:99
    Xvfb :99 -screen 0 1072x1448x24 -nolisten tcp >/tmp/xread-xvfb.log 2>&1 &
    XVFB_PID=$!
    sleep 2

    cd "$KOREADER_DIR" || { fail "无法进入 $KOREADER_DIR"; return 1; }
    export EMULATE_READER_W=1072 EMULATE_READER_H=1448 EMULATE_READER_DPI=300
    export LIBGL_ALWAYS_SOFTWARE=1 SDL_VIDEODRIVER=x11
    export XREAD_AUTOTEST="$mode" XREAD_AUTOTEST_ONCE=1
    [ -n "$flow" ] && export XREAD_AUTOTEST_FLOW="$flow" || unset XREAD_AUTOTEST_FLOW
    # 测试书固定为健康书源（老子是马超），避免撞上书源挂掉返回垃圾正文的书（如 美味的皮肤，正文只剩 m3u8 链接）
    export XREAD_AUTOTEST_BOOK="${XREAD_AUTOTEST_BOOK:-老子是马超}"

    timeout 240 ./lib/koreader/koreader.sh /root >"$EMU_LOG" 2>&1 &
    EMU_PID=$!
    log "  emulator started: mode=$mode flow=${flow:-none}"
}

# 等待插件输出验收标记。标记只在 XREAD_AUTOTEST* 存在时打印，生产环境无副作用。
emu_wait_mark() {
    local tag="$1" limit="${2:-180}" elapsed=0
    log "  waiting marker: $tag (limit ${limit}s)"
    while [ "$elapsed" -lt "$limit" ]; do
        if grep -qF "[XREAD_AUTOTEST] $tag" "$EMU_LOG" 2>/dev/null; then
            log "  marker OK: $tag @${elapsed}s"
            return 0
        fi
        if ! kill -0 "$EMU_PID" 2>/dev/null && ! pgrep -f '[l]uajit' >/dev/null 2>&1; then
            fail "模拟器进程已退出但未见标记 $tag"
            return 1
        fi
        sleep 3
        elapsed=$((elapsed+3))
    done
    fail "超时未见标记: $tag (${limit}s)"
    return 1
}

# 等待画面稳定，避免 Trapper 任务期间截图/点击撞上 Paused 框
emu_settle() {
    local min="${1:-8}" elapsed=0 prev="" same=0 cur tmp="${EMU_LOG_DIR}/.stable.png"
    while [ "$elapsed" -lt "$min" ]; do
        sleep 2
        elapsed=$((elapsed+2))
        import -window root "$tmp" 2>/dev/null
        cur=$(md5sum "$tmp" 2>/dev/null | cut -d' ' -f1)
        [ "$cur" = "$prev" ] && same=$((same+1)) || same=0
        prev="$cur"
        [ "$same" -ge 2 ] && break
    done
    log "  settled @${elapsed}s"
}

emu_shot() {
    import -window root "$SHOT" 2>/dev/null
    log "  screenshot: $(stat -c %s "$SHOT" 2>/dev/null || echo 0) bytes"
}

emu_tap() {
    xdotool mousemove "$1" "$2"
    sleep 0.4
    xdotool mousedown 1
    sleep 0.2
    xdotool mouseup 1
    log "  tap: $1,$2"
}

emu_stop() {
    pkill -9 -f '[l]uajit' 2>/dev/null
    [ -n "$XVFB_PID" ] && kill "$XVFB_PID" 2>/dev/null
    pkill -9 -f '[X]vfb' 2>/dev/null
    return 0
}

assert_shot() {
    local min="${1:-20000}" size
    size=$(stat -c %s "$SHOT" 2>/dev/null || echo 0)
    if [ "$size" -lt "$min" ]; then
        fail "截图过小/无截图: ${size}B < ${min}B（界面未渲染或卡在启动）"
    else
        log "  screenshot OK: ${size}B"
    fi
}

assert_log_contains() {
    local pattern="$1" desc="${2:-$1}"
    if grep -qE "$pattern" "$EMU_LOG" 2>/dev/null; then
        log "  log OK: $desc"
    else
        fail "日志缺少预期内容: $desc ($pattern)"
    fi
}

# 致命错误断言：MuPDF 坏封面警告、后端 500 属环境噪音，不计失败
assert_no_fatal() {
    local fatal
    fatal=$(grep -inE 'UNHANDLED EXCEPTION|attempt to index|attempt to call a nil value|traceback|Lua error|bad argument #' "$EMU_LOG" 2>/dev/null \
        | grep -viE 'failed rendering image' | head -5)
    if [ -n "$fatal" ]; then
        fail "发现致命错误: $(echo "$fatal" | head -2 | tr '\n' ' ')"
    else
        log "  no fatal errors"
    fi
}

case_finish() {
    local result="PASS"
    [ -n "$FAIL_REASONS" ] && result="FAIL"
    printf '%s\n' "$result" > "$STATUS_FILE"
    printf 'RESULT: %s%s\n' "$result" "$FAIL_REASONS" | tee -a "$CASE_LOG"
    log "CASE END: $CURRENT_CASE"
    return 0
}
