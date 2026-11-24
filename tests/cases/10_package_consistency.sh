#!/bin/bash
# TC-10 交付包一致性（不依赖模拟器，秒级）
# 预期：zip 内每个文件与工作区源码、WSL 部署完全一致（md5）
CASE_ID="10_package_consistency"
source "$(dirname "$0")/../lib/common.sh"

case_begin "TC-10 交付包一致性"
cd "$ROOT_DIR" || { fail "无法进入 $ROOT_DIR"; case_finish; exit 0; }

ROOT_DIR="$ROOT_DIR" DEPLOY="$DEPLOY" PLUGIN_SRC="$PLUGIN_SRC" python3 - <<'PY'
import zipfile, hashlib, os, sys
root = os.environ["ROOT_DIR"]
deploy = os.environ["DEPLOY"]
src = os.environ["PLUGIN_SRC"]
zpath = os.path.join(root, "xread.koplugin.zip")
if not os.path.exists(zpath):
    print("FAIL: zip 不存在: " + zpath); sys.exit(1)
z = zipfile.ZipFile(zpath)
bad = []
for name in z.namelist():
    data = hashlib.md5(z.read(name)).hexdigest()
    for base, label in ((src, "src"), (deploy, "deploy")):
        p = os.path.join(base, name)
        if not os.path.exists(p):
            bad.append(f"{label} missing: {name}")
        elif hashlib.md5(open(p, "rb").read()).hexdigest() != data:
            bad.append(f"{label} diff: {name}")
print(f"checked {len(z.namelist())} files, mismatches={len(bad)}")
for line in bad[:10]:
    print("  " + line)
sys.exit(1 if bad else 0)
PY
rc=$?
[ "$rc" -ne 0 ] && fail "zip / 源码 / 部署 三方 md5 不一致"

case_finish
