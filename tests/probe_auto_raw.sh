#!/bin/bash
# 验自动检查更新提示（raw 更新源，避免走 NAS webdav 的不确定性）
# 起本地 HTTP 提供 filelist.json + 0.6.8 包 → 首页 → quietUpdateCheck(10) → 提示
set -u
source "$(dirname "$0")/lib/common.sh"

DEPLOY_DIR="${DEPLOY%/}"
ROOT=/tmp/upd_root
VER="0.6.8-rawtest"
PKG_NAME="xread.koplugin_v${VER}_20261125-213000.zip"

cleanup() {
    [ -n "${HTTP_PID:-}" ] && kill "$HTTP_PID" 2>/dev/null
    rm -rf "$ROOT"
    emu_stop 2>/dev/null
    return 0
}
trap cleanup EXIT

rm -rf "$ROOT"; mkdir -p "$ROOT"
STAGING=/tmp/xread_raw_staging
rm -rf "$STAGING"; mkdir -p "$STAGING"
cp -r "$DEPLOY_DIR"/. "$STAGING/"
sed -i "s/version = \".*\"/version = \"$VER\"/" "$STAGING/_meta.lua"
python3 - "$STAGING" "$ROOT/$PKG_NAME" "$ROOT/filelist.json" "$PKG_NAME" <<'PY'
import json, os, sys, zipfile
staging, pkg, flist, name = sys.argv[1:5]
with zipfile.ZipFile(pkg, "w", zipfile.ZIP_DEFLATED) as z:
    for rel in ["_meta.lua", "main.lua"]:
        z.write(os.path.join(staging, rel.replace("/", os.sep)), rel)
size = os.path.getsize(pkg)
json.dump([{"name": name, "path": "/plugin/" + name, "size": size,
            "lastModified": 1764000000, "isDirectory": False}],
          open(flist, "w"))
print("raw source:", pkg, size, "bytes")
PY
rm -rf "$STAGING"

cd "$ROOT" && python3 -m http.server 8123 >/tmp/upd_http.log 2>&1 &
HTTP_PID=$!
sleep 1
curl -s -m 3 http://127.0.0.1:8123/filelist.json | head -c 200; echo

export XREAD_UPDATER_URL="http://127.0.0.1:8123/"
export XREAD_AUTOTEST_DELAY=0
emu_start "home"
emu_wait_mark "mode=home done" 180
sleep 10
import -window root /tmp/r0.png
sleep 4
import -window root /tmp/r1.png
sleep 4
import -window root /tmp/r2.png
cp "$EMU_LOG" /tmp/r_stage.log
emu_stop
cp /tmp/r0.png /tmp/r1.png /tmp/r2.png "${EMU_LOG_DIR}/" 2>/dev/null
echo "--- update log ---"
grep -iE "update available|update check|无法列出|list" /tmp/r_stage.log | tail -8
echo PROBE_END
