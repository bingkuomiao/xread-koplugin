#!/bin/bash
# TC-13 更新包留存策略：压缩包与同名解压目录同级留存，只保留最近 3 次
# 前置：无（本地 http.server 模拟更新服务）
# 手法：预置 4 个历史包（p1~p4 目录 + 同名 zip + packages.txt），再触发一次真实更新 p5
# 预期：解压到 xread_update/<新包名>/，同名 zip 同级；p1、p2 被淘汰，仅剩 3 条索引
CASE_ID="13_package_retention"
source "$(dirname "$0")/../lib/common.sh"

PKG_ROOT=/tmp/xread_retention_pkg
SRV_PORT=8779
SRV_PID=""
VER="0.8.0-test"
ZIP_NAME="xread.koplugin_v${VER}_20261124-133000.zip"
PKG_DIR=/root/.config/koreader/xread_update

cleanup() {
    emu_stop 2>/dev/null
    [ -n "$SRV_PID" ] && kill "$SRV_PID" 2>/dev/null
    return 0
}
trap cleanup EXIT

case_begin "TC-13 更新包留存与清理策略"

rm -f /root/.config/koreader/xread_update_manifest.json

# 1) 预置 4 个历史包（目录 + 同名 zip + 索引）
rm -rf "$PKG_DIR"
mkdir -p "$PKG_DIR"
for i in 1 2 3 4; do
    mkdir -p "$PKG_DIR/p$i"
    echo "old" > "$PKG_DIR/p$i/.keep"
    echo "old" > "$PKG_DIR/p$i.zip"
done
printf 'p1\np2\np3\np4\n' > "$PKG_DIR/packages.txt"
log "  预置历史包: p1 p2 p3 p4"

# 2) 构造新包（5 个文件，走 zip 模式）
rm -rf "$PKG_ROOT"
mkdir -p "$PKG_ROOT/assets/plugin/staging"
cp -r "$DEPLOY"/. "$PKG_ROOT/assets/plugin/staging/" \
    || { fail "构造 zip 测试包失败"; case_finish; exit 1; }
sed -i "s/version = \".*\"/version = \"$VER\"/" "$PKG_ROOT/assets/plugin/staging/_meta.lua"

python3 - "$PKG_ROOT/assets/plugin" "$ZIP_NAME" "$VER" <<'PY'
import hashlib, json, os, sys, time, zipfile
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
md5 = hashlib.md5(blob).hexdigest()
filelist = [{
    "name": zip_name, "path": "/plugin/" + zip_name,
    "size": len(blob), "lastModified": int(time.time() * 1000),
    "md5": md5, "isDirectory": False,
}]
with open(os.path.join(root, "filelist.json"), "w", encoding="utf-8") as fh:
    json.dump(filelist, fh, ensure_ascii=False)
with open(os.path.join(root, zip_name + ".md5"), "w") as fh:
    fh.write(md5 + "\n")
print("retention package:", len(files), "files")
PY

(cd "$PKG_ROOT" && exec python3 -m http.server "$SRV_PORT" --bind 127.0.0.1 >/dev/null 2>&1) &
SRV_PID=$!
sleep 1
curl -sf "http://127.0.0.1:$SRV_PORT/assets/plugin/$ZIP_NAME" >/dev/null || fail "本地更新服务不可用"

# 3) 触发更新
export XREAD_UPDATER_URL="http://127.0.0.1:$SRV_PORT/assets/plugin/"
emu_start "update"
emu_wait_mark "mode=update done" 180
assert_log_contains 'via=list' "走列目录模式"
assert_log_contains "remote=$VER" "识别远端版本"
assert_log_contains 'newer=true' "判定有新版本"
assert_no_fatal

# 4) 新包落盘：同名目录 + 同级 zip
NEW_BASE="${ZIP_NAME%.zip}"
[ -d "$PKG_DIR/$NEW_BASE" ] && log "  新解压目录: $NEW_BASE" || fail "缺少解压目录 $NEW_BASE"
[ -f "$PKG_DIR/$NEW_BASE.zip" ] && log "  同名压缩包同级 OK" || fail "缺少同名压缩包"
[ -f "$PKG_DIR/$NEW_BASE/_meta.lua" ] && log "  解压内容完整 OK" || fail "解压内容不完整"

# 5) 保留策略：只剩 3 条，p1/p2 被淘汰，p3/p4 保留
KEPT=$(wc -l < "$PKG_DIR/packages.txt" | tr -d ' ')
[ "$KEPT" = "3" ] && log "  索引条数 3 OK" || fail "索引条数应保留 3，实际 $KEPT"
grep -qx "$NEW_BASE" "$PKG_DIR/packages.txt" && log "  新包已登记 OK" || fail "新包未登记"
[ -d "$PKG_DIR/p1" ] && fail "最旧包 p1 目录未清理" || log "  最旧包 p1 目录已清理 OK"
[ -f "$PKG_DIR/p1.zip" ] && fail "最旧包 p1 zip 未清理" || log "  最旧包 p1 zip 已清理 OK"
[ -d "$PKG_DIR/p2" ] && fail "次旧包 p2 目录未清理" || log "  次旧包 p2 目录已清理 OK"
[ -d "$PKG_DIR/p3" ] && log "  p3 仍在保留窗口内 OK" || fail "p3 被误删"
[ -d "$PKG_DIR/p4" ] && log "  p4 仍在保留窗口内 OK" || fail "p4 被误删"
log "  最终索引: $(tr '\n' ' ' < "$PKG_DIR/packages.txt")"

case_finish

# 还原部署目录（apply 把文件改成了测试版本）
rm -rf "$DEPLOY"
cp -r "$ROOT_DIR/xread.koplugin" "$DEPLOY"
emu_stop
