#!/bin/bash
# TC-16 列目录挑最新版本热更新（filelist.json → 按语义版本挑最新 zip → 包内版本裁决）
# 前置：无（本地 http.server 模拟更新服务，raw 模式，不依赖 NAS）
# 预期：
#   ① filelist.json 列出两个包：旧版 v0.5.0（lastModified 更新）+ 新版 v0.7.1-test（lastModified 更旧）
#   ② 插件按"文件名语义版本"挑出 0.7.1-test，而不是按时间戳挑出 v0.5.0
#   ③ 下载后以包内 _meta.lua 版本为最终裁决，本地版本更新为 0.7.1-test
CASE_ID="16_filelist_latest"
source "$(dirname "$0")/../lib/common.sh"

PKG_ROOT=/tmp/xread_filelist_latest_pkg
SRV_PORT=8779
SRV_PID=""
VER_NEW="0.7.1-test"
VER_OLD="0.5.0"
ZIP_NEW="xread.koplugin_v${VER_NEW}_20261125-100000.zip"
ZIP_OLD="xread.koplugin_v${VER_OLD}_20261125-110000.zip"   # 时间戳更晚，但版本更低

cleanup() {
    emu_stop 2>/dev/null
    [ -n "$SRV_PID" ] && kill "$SRV_PID" 2>/dev/null
    return 0
}
trap cleanup EXIT

case_begin "TC-16 列目录挑最新版本热更新"

rm -f /root/.config/koreader/xread_update_manifest.json
rm -rf /root/.config/koreader/xread_update
rm -rf "$PKG_ROOT"
mkdir -p "$PKG_ROOT/assets/plugin/stage_new" "$PKG_ROOT/assets/plugin/stage_old"
cp -r "$DEPLOY"/. "$PKG_ROOT/assets/plugin/stage_new/" \
    || { fail "构造新版测试包失败"; case_finish; exit 1; }
cp -r "$DEPLOY"/. "$PKG_ROOT/assets/plugin/stage_old/" \
    || { fail "构造旧版测试包失败"; case_finish; exit 1; }
sed -i 's/version = ".*"/version = "0.7.1-test"/' "$PKG_ROOT/assets/plugin/stage_new/_meta.lua"
sed -i 's/version = ".*"/version = "0.5.0"/' "$PKG_ROOT/assets/plugin/stage_old/_meta.lua"

python3 - "$PKG_ROOT/assets/plugin" "$ZIP_NEW" "$ZIP_OLD" "$VER_NEW" "$VER_OLD" <<'PY'
import hashlib, json, os, sys, time, zipfile
root, znew, zold, vnew, vold = sys.argv[1:6]
picks = ["_meta.lua", "main.lua", "xread/updater.lua", "resources/icons/miuread/check.svg"]
def build(stage, zipname):
    zpath = os.path.join(root, zipname)
    with zipfile.ZipFile(zpath, "w", zipfile.ZIP_DEFLATED) as z:
        for rel in picks:
            z.write(os.path.join(stage, rel.replace("/", os.sep)), rel)
    blob = open(zpath, "rb").read()
    return len(blob), hashlib.md5(blob).hexdigest()
size_new, md5_new = build(os.path.join(root, "stage_new"), znew)
size_old, md5_old = build(os.path.join(root, "stage_old"), zold)
now_ms = int(time.time() * 1000)
# 关键：字段结构刻意与真实后端 getWebdavFileList 一致（不带 version），
# 强制插件从文件名解析版本；旧包 lastModified 更新（+60000ms），验证按版本而非按时间挑
filelist = [
    {"name": znew, "path": "/plugin/" + znew, "size": size_new,
     "lastModified": now_ms, "isDirectory": False},
    {"name": zold, "path": "/plugin/" + zold, "size": size_old,
     "lastModified": now_ms + 60000, "isDirectory": False},
]
with open(os.path.join(root, "filelist.json"), "w", encoding="utf-8") as fh:
    json.dump(filelist, fh, ensure_ascii=False)
# .md5 sidecar（列目录模式强校验路径）
with open(os.path.join(root, znew + ".md5"), "w") as fh:
    fh.write(md5_new + "\n")
print("filelist: 2 packages, latest-by-version =", vnew, "latest-by-time =", vold)
PY

(cd "$PKG_ROOT" && exec python3 -m http.server "$SRV_PORT" --bind 127.0.0.1 >/dev/null 2>&1) &
SRV_PID=$!
sleep 1
curl -sf "http://127.0.0.1:$SRV_PORT/assets/plugin/filelist.json" >/dev/null \
    || fail "本地更新服务不可用"

# 确认纯列目录环境：不提供 manifest 清单，插件只能靠 filelist.json 挑包
if [ -f "$PKG_ROOT/assets/plugin/manifest2.json" ]; then
    fail "测试环境不应存在 manifest2.json（纯列目录模式）"
fi

export XREAD_UPDATER_URL="http://127.0.0.1:$SRV_PORT/assets/plugin/"
emu_start "update"
emu_wait_mark "mode=update done" 180
assert_log_contains 'via=list' "走列目录模式"
assert_log_contains "remote=0[.]7[.]1-test" "按语义版本挑出最高版本（而非时间戳最新的旧版）"
assert_log_contains 'newer=true' "判定有新版本"
assert_log_contains "local_version_now=0[.]7[.]1-test" "包内版本裁决后本地版本已更新"
assert_no_fatal

# 不应误装时间戳更新但版本更低的旧包
if grep -qF 'local_version_now=0.5.0' "$EMU_LOG"; then
    fail "误装了时间戳更新但版本更低的旧包 v0.5.0"
fi

# 更新包落盘结构：挑中的新包按包名留档
PKG_DIR=/root/.config/koreader/xread_update
EXPECT_DIR="$PKG_DIR/${ZIP_NEW%.zip}"
if [ -d "$EXPECT_DIR" ]; then
    log "  解压目录: $EXPECT_DIR"
    [ -f "$EXPECT_DIR/_meta.lua" ] && log "  解压目录含 _meta.lua OK" || fail "解压目录缺少 _meta.lua"
    [ -f "$EXPECT_DIR.zip" ] && log "  同名压缩包同级留存 OK" || fail "缺少同名压缩包"
    n=$(find "$EXPECT_DIR" -type f | wc -l)
    [ "$n" = "4" ] && log "  解压文件数 4 OK" || fail "解压文件数异常: $n"
else
    fail "未生成同名解压目录: $EXPECT_DIR"
fi

case_finish

# 还原部署目录（apply 把文件改成了测试版本）
rm -rf "$DEPLOY"
cp -r "$ROOT_DIR/xread.koplugin" "$DEPLOY"
emu_stop
