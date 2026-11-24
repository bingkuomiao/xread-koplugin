#!/bin/bash
# TC-12 规范 zip 包热更新全流程（manifest2.json → 下载 zip → 解压增量替换）
# 前置：无（本地 http.server 模拟更新服务，不依赖 NAS）
# 预期：识别远端版本 → newer=true → 下载 zip → 本地 _meta 版本变为测试版本
CASE_ID="12_update_zip"
source "$(dirname "$0")/../lib/common.sh"

PKG_ROOT=/tmp/xread_update_zip_pkg
SRV_PORT=8778
SRV_PID=""
VER="0.7.0-test"
ZIP_NAME="xread.koplugin_v${VER}_20261124-120000.zip"

cleanup() {
    emu_stop 2>/dev/null
    [ -n "$SRV_PID" ] && kill "$SRV_PID" 2>/dev/null
    return 0
}
trap cleanup EXIT

case_begin "TC-12 规范 zip 包热更新"

rm -f /root/.config/koreader/xread_update_manifest.json
rm -rf /root/.config/koreader/xread_update
rm -rf "$PKG_ROOT"
mkdir -p "$PKG_ROOT/assets/plugin/staging"
cp -r "$DEPLOY"/. "$PKG_ROOT/assets/plugin/staging/" \
    || { fail "构造 zip 测试包失败"; case_finish; exit 1; }
sed -i 's/version = ".*"/version = "0.7.0-test"/' "$PKG_ROOT/assets/plugin/staging/_meta.lua"

python3 - "$PKG_ROOT/assets/plugin" "$ZIP_NAME" "$VER" <<'PY'
import hashlib, json, os, sys, zipfile
root, zip_name, ver = sys.argv[1], sys.argv[2], sys.argv[3]
staging = os.path.join(root, "staging")
picks = ["_meta.lua", "main.lua", "xread/updater.lua", "resources/icons/miuread/check.svg"]
files = []
for rel in picks:
    p = os.path.join(staging, rel.replace("/", os.sep))
    data = open(p, "rb").read()
    files.append({"path": rel, "size": len(data), "md5": hashlib.md5(data).hexdigest()})
zpath = os.path.join(root, zip_name)
with zipfile.ZipFile(zpath, "w", zipfile.ZIP_DEFLATED) as z:
    for it in files:
        z.write(os.path.join(staging, it["path"].replace("/", os.sep)), it["path"])
blob = open(zpath, "rb").read()
m = {
    "version": ver, "build": "20261124120000", "notes": "zip 自动测试",
    "package": zip_name, "package_size": len(blob), "package_md5": hashlib.md5(blob).hexdigest(),
    "files_count": len(files), "files": files,
}
with open(os.path.join(root, "manifest2.json"), "w", encoding="utf-8") as fh:
    json.dump(m, fh, ensure_ascii=False)
print("zip test package:", len(files), "files,", len(blob), "bytes")
PY

(cd "$PKG_ROOT" && exec python3 -m http.server "$SRV_PORT" --bind 127.0.0.1 >/dev/null 2>&1) &
SRV_PID=$!
sleep 1
curl -sf "http://127.0.0.1:$SRV_PORT/assets/plugin/$ZIP_NAME" >/dev/null \
    || fail "本地更新服务不可用"

export XREAD_UPDATER_URL="http://127.0.0.1:$SRV_PORT/assets/plugin/"
emu_start "update"
emu_wait_mark "mode=update done" 180
assert_log_contains 'remote=0\.7\.0-test' "远端版本识别（manifest2）"
assert_log_contains 'newer=true' "判定有新版本"
assert_log_contains 'local_version_now=0\.7\.0-test' "zip 解压后本地版本已更新"
assert_no_fatal

# 更新包落盘结构：压缩包与同名解压目录同级留存（多次更新可分辨）
PKG_DIR=/root/.config/koreader/xread_update
EXPECT_DIR="$PKG_DIR/${ZIP_NAME%.zip}"
if [ -d "$EXPECT_DIR" ]; then
    log "  解压目录: $EXPECT_DIR"
    [ -f "$EXPECT_DIR/_meta.lua" ] && log "  解压目录含 _meta.lua OK" || fail "解压目录缺少 _meta.lua"
    [ -f "$EXPECT_DIR.zip" ] && log "  同名压缩包同级留存 OK" || fail "缺少同名压缩包"
    n=$(find "$EXPECT_DIR" -type f | wc -l)
    [ "$n" = "4" ] && log "  解压文件数 4 OK" || fail "解压文件数异常: $n"
else
    fail "未生成同名解压目录: $EXPECT_DIR"
fi
grep -q "${ZIP_NAME%.zip}" "$PKG_DIR/packages.txt" 2>/dev/null \
    && log "  packages.txt 已登记本次包" || fail "packages.txt 未登记"

case_finish

# 还原部署目录（apply 把文件改成了测试版本）
rm -rf "$DEPLOY"
cp -r "$ROOT_DIR/xread.koplugin" "$DEPLOY"
emu_stop
