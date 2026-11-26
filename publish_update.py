#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
publish_update.py — 生成 xread.koplugin 在线热更新包并发布到 NAS（飞牛 fpk 部署）

【发布目录（服务端）】
  /vol1/@appdata/xread/data/webdav/<用户名>/plugin/（由 XREAD_NAS_REMOTE_DIR 指定）
    xread.koplugin_v<版本>_<YYYYMMDD-HHMMSS>.zip|.tar.gz|.tgz   ← 规范命名的完整包（唯一更新入口）
    同名 .md5 sidecar                                            ← 强校验
    filelist.json                                     ← 目录索引（raw 模式/静态托管用）
  服务端保留最近 N 个规范包（默认 3），插件列目录后按包名语义版本挑最新，
  下载后以包内 _meta.lua 版本做最终裁决（绝不装旧包）。无 manifest 清单。

【插件端（纯列目录）】GET /reader3/getWebdavFileList?path=/plugin&accessToken=<token>
  列目录 → 按包名版本挑最新 zip → GET /reader3/getWebdavFile?path=/plugin/<文件>&accessToken=<token>
  下载 → size/md5 校验（md5 取同名 sidecar）→ 解压 → 包内版本裁决。
  raw 模式（XREAD_UPDATER_URL）用 <root>filelist.json 代替后端列目录接口。

【命名规范（必须含语义版本，否则插件不识别）】
  xread.koplugin_v<版本号>_<YYYYMMDD-HHMMSS>.tar.gz（也兼容 .zip/.tgz）
  例：xread.koplugin_v0.6.7_20261125-214000.tar.gz

用法（在 xread-migration 目录下）：
    python3 publish_update.py                       # 源码 → 规范包（默认 tar.gz，--format zip/tgz 可选）+ md5 + filelist.json
    python3 publish_update.py --notes "修复xxx"     # 带更新说明（仅本地记录，不再上传清单）
    python3 publish_update.py --zip <规范zip路径>   # 用已有 zip 发布
    python3 publish_update.py --ssh <用户>@<NAS地址> --ssh-port <端口>   # 生成并上传
    python3 publish_update.py --check               # 校验线上 filelist.json 与挑中包的 md5

【凭据配置（不进版本库）】
    NAS 地址/账号/密码/发布目录从环境变量或本地 .publish_env 读取：
      XREAD_NAS_HOST / XREAD_NAS_USER / XREAD_NAS_PASS / XREAD_NAS_REMOTE_DIR
    .publish_env 已加入 .gitignore，格式见 .publish_env.example。
"""
import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import time
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
PLUGIN_SRC = os.path.join(HERE, "xread.koplugin")
PUBLISH_DIR = os.path.join(HERE, "publish")
PUBLISHED_PLUGIN = os.path.join(PUBLISH_DIR, "plugin")
REMOTE_KEEP_PACKAGES = 3     # 服务端保留最近 N 个规范包（列目录挑最新需要历史包）
FILE_VERSION_RE = re.compile(r'version\s*=\s*["\']([^"\']+)["\']')
ZIP_NAME_RE = re.compile(r'xread[._-]?koplugin[_-]v?(\d+\.\d+\.\d+)[_-](\d{8})[_-]?(\d{4,6})', re.I)
ARCHIVE_EXTS = (".zip", ".tar.gz", ".tgz")   # 插件端识别的三种包格式
EXCLUDE_EXT = (".xup_tmp",)


def load_env_file(path):
    """读本地 KEY=VALUE 配置（不进版本库），环境变量优先"""
    out = {}
    if not os.path.isfile(path):
        return out
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            out[k.strip()] = v.strip().strip('"').strip("'")
    return out


_LOCAL_ENV = load_env_file(os.path.join(HERE, ".publish_env"))


def setting(name, default=""):
    return os.getenv(name) or _LOCAL_ENV.get(name) or default


REMOTE_DIR = setting("XREAD_NAS_REMOTE_DIR")
NAS_HOST = setting("XREAD_NAS_HOST")
NAS_USER = setting("XREAD_NAS_USER")
NAS_PASS = setting("XREAD_NAS_PASS")


def require_credentials():
    missing = [k for k, v in (("XREAD_NAS_HOST", NAS_HOST), ("XREAD_NAS_USER", NAS_USER),
                              ("XREAD_NAS_PASS", NAS_PASS), ("XREAD_NAS_REMOTE_DIR", REMOTE_DIR))
               if not v]
    if missing:
        raise SystemExit("缺少 NAS 凭据配置：" + ", ".join(missing)
                         + "（用环境变量或本地 .publish_env 提供，见 .publish_env.example）")


def read_version_from_text(text):
    m = FILE_VERSION_RE.search(text or "")
    return m.group(1) if m else None


def read_version(path=None):
    path = path or os.path.join(PLUGIN_SRC, "_meta.lua")
    with open(path, encoding="utf-8") as fh:
        return read_version_from_text(fh.read()) or "0.0.0"


def package_name(version, stamp=None, ext=".tar.gz"):
    stamp = stamp or time.strftime("%Y%m%d-%H%M%S")
    return f"xread.koplugin_v{version}_{stamp}{ext}"


def md5_bytes(data):
    return hashlib.md5(data).hexdigest()


def md5_file(path):
    h = hashlib.md5()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def collect_plugin_files(root):
    """返回 [(绝对路径, zip内相对路径)]，路径均为插件根相对"""
    out = []
    for base, dirs, fs in os.walk(root):
        dirs[:] = [d for d in dirs if not d.startswith(".")]
        for f in sorted(fs):
            if f.endswith(EXCLUDE_EXT):
                continue
            p = os.path.join(base, f)
            out.append((p, os.path.relpath(p, root).replace(os.sep, "/")))
    out.sort(key=lambda x: x[1])
    return out


def is_tar(name):
    n = str(name or "").lower()
    return n.endswith(".tar.gz") or n.endswith(".tgz")


def read_meta_from_blob(blob, name):
    """从包字节流读 _meta.lua 文本（zip 用 zipfile，tar.gz/tgz 用 tarfile）"""
    import io
    if is_tar(name):
        import tarfile
        with tarfile.open(fileobj=io.BytesIO(blob), mode="r:gz") as t:
            for m in t.getmembers():
                if m.isfile() and (m.name == "_meta.lua"
                                   or m.name.endswith("/_meta.lua")):
                    return t.extractfile(m).read().decode("utf-8", "replace")
        return None
    with zipfile.ZipFile(io.BytesIO(blob)) as z:
        meta = next((n for n in z.namelist()
                     if n == "_meta.lua" or n.endswith("/_meta.lua")), None)
        return z.read(meta).decode("utf-8", "replace") if meta else None


def build_zip_from_source(version, ext=".tar.gz"):
    """源码 → 规范更新包（默认 tar.gz，也支持 zip/tgz；包根就是插件目录内容，便于热更新解压）"""
    name = package_name(version, ext=ext)
    path = os.path.join(PUBLISH_DIR, name)
    os.makedirs(PUBLISH_DIR, exist_ok=True)
    files = collect_plugin_files(PLUGIN_SRC)
    if ext == ".zip":
        with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as z:
            for p, rel in files:
                z.write(p, rel)
    else:
        import tarfile
        with tarfile.open(path, "w:gz") as t:
            for p, rel in files:
                t.add(p, arcname=rel)
    print(f"生成规范包: {path}（{len(files)} 文件，{os.path.getsize(path)} 字节）")
    return path, len(files)


def normalize_zip(zip_path):
    """已有包 → 规范命名（zip / tar.gz / tgz 均可；兼容带 xread.koplugin/ 前缀的安装包）"""
    if not os.path.isfile(zip_path):
        raise SystemExit(f"包不存在: {zip_path}")
    ext = ".tar.gz" if str(zip_path).lower().endswith(".tar.gz") \
        else (".tgz" if str(zip_path).lower().endswith(".tgz") else ".zip")
    meta = read_meta_from_blob(open(zip_path, "rb").read(), zip_path)
    if meta is None:
        raise SystemExit("包内找不到 _meta.lua，无法识别版本")
    version = read_version_from_text(meta)
    if not version:
        raise SystemExit("包内 _meta.lua 没有 version 字段")
    m = ZIP_NAME_RE.search(os.path.basename(zip_path))
    stamp = (m.group(2) + "-" + m.group(3)) if m else time.strftime("%Y%m%d-%H%M%S")
    name = package_name(version, stamp, ext)
    target = os.path.join(PUBLISH_DIR, name)
    os.makedirs(PUBLISH_DIR, exist_ok=True)
    if os.path.abspath(zip_path) != os.path.abspath(target):
        shutil.copy2(zip_path, target)
    print(f"采用规范包: {target}（版本 {version}，格式 {ext}）")
    return target, version


def package_file_entries(zip_path):
    """读包内文件清单：path/size/md5（供线上校验与客户端 files_count）"""
    entries = []
    if is_tar(zip_path):
        import tarfile
        with tarfile.open(zip_path, "r:gz") as t:
            for m in t.getmembers():
                if not m.isfile():
                    continue
                rel = m.name.replace("\\", "/")
                if rel.startswith("xread.koplugin/"):
                    rel = rel[len("xread.koplugin/"):]
                if rel.startswith("./") or ".." in rel.split("/"):
                    continue
                data = t.extractfile(m).read()
                entries.append({"path": rel, "size": len(data), "md5": md5_bytes(data)})
    else:
        with zipfile.ZipFile(zip_path) as z:
            for info in z.infolist():
                if info.is_dir():
                    continue
                rel = info.filename.replace("\\", "/")
                if rel.startswith("xread.koplugin/"):
                    rel = rel[len("xread.koplugin/"):]
                if rel.startswith("./") or ".." in rel.split("/"):
                    continue
                data = z.read(info)
                entries.append({"path": rel, "size": len(data), "md5": md5_bytes(data)})
    entries.sort(key=lambda it: it["path"])
    return entries


def write_publish(zip_path, version, notes, files_count):
    """写 publish/plugin/：规范包 + 同名 .md5 sidecar + filelist.json（列目录索引）"""
    # 整体重建发布目录，杜绝旧格式散文件/旧包残留被一起上传
    if os.path.isdir(PUBLISHED_PLUGIN):
        shutil.rmtree(PUBLISHED_PLUGIN)
    os.makedirs(PUBLISHED_PLUGIN, exist_ok=True)
    zip_name = os.path.basename(zip_path)
    shutil.copy2(zip_path, os.path.join(PUBLISHED_PLUGIN, zip_name))

    file_entries = package_file_entries(zip_path)
    blob = open(zip_path, "rb").read()
    package_md5 = md5_bytes(blob)

    # .md5 sidecar：后端列目录不返回 md5，插件按 <包名>.md5 拉取做强校验
    # 固定用 \n 结尾（Windows 默认 \r\n 会让 sidecar 变 34 字节，插件虽能容错但没必要）
    with open(os.path.join(PUBLISHED_PLUGIN, zip_name + ".md5"), "w",
              encoding="utf-8", newline="\n") as fh:
        fh.write(package_md5 + "\n")

    # filelist.json：raw 模式（XREAD_UPDATER_URL）与静态托管用的目录索引，
    # 格式与后端 getWebdavFileList 的 data 数组一致。webdav 模式插件直接调后端列目录，
    # 不读此文件；保留它是为了让静态站点/本地测试也能走同一套挑选逻辑。
    filelist = [{
        "name": zip_name,
        "path": "/plugin/" + zip_name,
        "size": len(blob),
        "lastModified": int(time.time() * 1000),  # 毫秒，与后端一致
        "md5": package_md5,
        "isDirectory": False,
    }]
    with open(os.path.join(PUBLISHED_PLUGIN, "filelist.json"), "w", encoding="utf-8") as fh:
        json.dump(filelist, fh, ensure_ascii=False, indent=1)

    print(f"更新目录: {PUBLISHED_PLUGIN}")
    print(f"  {zip_name}（{len(blob)} 字节，{len(file_entries)} 文件，md5 {package_md5}）")
    print(f"  filelist.json（1 包）+ {zip_name}.md5 sidecar；插件列目录按包名版本挑最新")
    return {"version": version, "package": zip_name, "size": len(blob), "md5": package_md5,
            "files": file_entries}


def build_upload_blob():
    """把 publish/plugin 打成 tar.gz 字节流（Python 端打包，不经 shell 二进制管道）"""
    import io
    import tarfile
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:gz") as t:
        for name in sorted(os.listdir(PUBLISHED_PLUGIN)):
            t.add(os.path.join(PUBLISHED_PLUGIN, name), arcname=name)
    return buf.getvalue()


def upload(ssh_target, ssh_port):
    """fnOS 禁 scp：tar.gz 字节流写入 ssh stdin，远端 tar xzf - 解开。
    注意：不要用 `tar cf - | ssh` 的 shell 管道——Windows 下经 cmd.exe 转交
    二进制流不可靠（曾出现过远端目录空、退出码仍是 0 的情况）。"""
    if not os.path.isdir(PUBLISHED_PLUGIN):
        raise SystemExit("请先生成发布目录")
    blob = build_upload_blob()
    # 清理白名单：目录索引 + 规范包（zip/tar.gz/tgz）+ md5 sidecar 都保留（历史包留给列目录挑最新）
    keep = " ".join(
        f"! -name 'xread.koplugin_v*{e}' ! -name 'xread.koplugin_v*{e}.md5'"
        for e in ARCHIVE_EXTS)
    remote = (f'mkdir -p {REMOTE_DIR} && '
              f'find {REMOTE_DIR} -mindepth 1 -maxdepth 1 '
              f'! -name filelist.json {keep} '
              f'-exec rm -rf {{}} + && '
              f'tar xzf - -C {REMOTE_DIR} && '
              f'chown -R docker-xread:docker-xread {REMOTE_DIR} && echo UPLOAD_OK')
    cmd = ["ssh", "-p", str(ssh_port), "-o", "StrictHostKeyChecking=no",
           ssh_target, remote]
    print(f"上传: {len(blob)} 字节 tar.gz → {ssh_target}:{REMOTE_DIR}")
    proc = subprocess.Popen(cmd, stdin=subprocess.PIPE,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    out, err = proc.communicate(blob)
    text = (out or b"").decode("utf-8", "replace") + (err or b"").decode("utf-8", "replace")
    if proc.returncode != 0 or "UPLOAD_OK" not in (out or b"").decode("utf-8", "replace"):
        raise SystemExit(f"上传失败（exit {proc.returncode}）：{text.strip()}")
    cleanup_remote(ssh_target, ssh_port)
    check_online(ssh_target.split("@")[-1])


def cleanup_remote(ssh_target, ssh_port):
    """服务端保留最近 N 个规范包（含 md5 sidecar）；更早的清理，避免无限堆积"""
    globs = " ".join(f"xread.koplugin_v*{e}" for e in ARCHIVE_EXTS)
    # 只删超出保留数的旧包及其 .md5；filelist 由本次上传覆盖，不动
    remote = (f'cd {REMOTE_DIR} && '
              f'for z in $(ls -1t {globs} 2>/dev/null | tail -n +{REMOTE_KEEP_PACKAGES + 1}); do '
              f'rm -f "$z" "$z.md5"; done')
    cmd = f'ssh -p {ssh_port} -o StrictHostKeyChecking=no {ssh_target} "{remote}"'
    rc = subprocess.call(cmd, shell=True)
    if rc != 0:
        print("  （服务端旧包清理跳过）")
        return
    list_cmd = (f'ssh -p {ssh_port} -o StrictHostKeyChecking=no {ssh_target} '
                f'"cd {REMOTE_DIR} && ls -1t {globs} 2>/dev/null"')
    kept = subprocess.run(list_cmd, shell=True, capture_output=True, text=True).stdout.strip()
    if kept:
        print(f"服务端保留包（最近 {REMOTE_KEEP_PACKAGES} 个）:\n  " + "\n  ".join(kept.splitlines()))


def check_online(host):
    """登录后端，列 /plugin 目录挑最新版本包，校验线上 zip 的 md5 与包内版本"""
    import io
    import urllib.parse
    import urllib.request

    def post(url, obj):
        req = urllib.request.Request(url, data=json.dumps(obj).encode(),
                                     headers={"Content-Type": "application/json"})
        return json.loads(urllib.request.urlopen(req, timeout=15).read())

    def fetch(path, token):
        q = urllib.parse.quote(path)
        url = (f"http://{host}:7777/reader3/getWebdavFile?path={q}"
               f"&accessToken={urllib.parse.quote(token)}")
        with urllib.request.urlopen(url, timeout=60) as r:
            return r.read()

    def ver_key(name):
        m = re.search(r'_v?(\d+)\.(\d+)\.(\d+)', name)
        return tuple(int(x) for x in m.groups()) if m else (0, 0, 0)

    def list_entries(token):
        """列 /plugin：后端 getWebdavFileList 是 GET（POST 会 405），取不到再退回 filelist.json"""
        q = urllib.parse.urlencode({"path": "/plugin", "accessToken": token,
                                    "v": int(time.time())})
        try:
            with urllib.request.urlopen(
                    f"http://{host}:7777/reader3/getWebdavFileList?{q}", timeout=20) as r:
                listing = json.loads(r.read())
            data = listing.get("data") if isinstance(listing, dict) else listing
            if isinstance(data, dict):
                data = data.get("list") or data.get("files")
            entries = data if isinstance(data, list) else []
            if entries:
                return entries
        except Exception:
            pass
        return json.loads(fetch("/plugin/filelist.json", token).decode("utf-8"))

    try:
        require_credentials()
        login = post(f"http://{host}:7777/reader3/login",
                     {"isLogin": True, "username": NAS_USER, "password": NAS_PASS, "code": ""})
        token = login["data"]["accessToken"]
        entries = list_entries(token)
        archives = [e for e in entries if isinstance(e, dict)
                    and str(e.get("name", "")).lower().endswith(ARCHIVE_EXTS)
                    and ver_key(str(e.get("name", ""))) > (0, 0, 0)]
        if not archives:
            raise RuntimeError("目录中没有可识别的规范更新包")
        best = max(archives, key=lambda e: (ver_key(str(e["name"])), int(e.get("lastModified") or 0)))
        zip_name = str(best["name"])
        blob = fetch("/plugin/" + zip_name, token)
    except Exception as e:
        print(f"线上列目录/校验失败: {e}")
        print(f"请把 {PUBLISHED_PLUGIN} 的全部内容上传到 NAS 的 {REMOTE_DIR}/")
        sys.exit(1)

    print(f"线上挑中: {zip_name}（{len(blob)} 字节）")
    bad = 0
    # md5：优先 filelist 条目，其次同名 .md5 sidecar
    want_md5 = best.get("md5")
    if not want_md5:
        try:
            want_md5 = fetch("/plugin/" + zip_name + ".md5", token).decode("utf-8").strip()
        except Exception:
            want_md5 = None
    if best.get("size") and len(blob) != int(best["size"]):
        print(f"  大小不符: 期望 {best['size']} 实际 {len(blob)}")
        bad += 1
    if want_md5 and md5_bytes(blob) != want_md5:
        print(f"  md5 校验不符: {zip_name}")
        bad += 1
    # 校验包内 _meta.lua 版本与文件名版本一致（插件端同款裁决）
    try:
        meta = read_meta_from_blob(blob, zip_name)
        pv = read_version_from_text(meta) if meta else None
        name_v = re.search(r'_v?(\d+\.\d+\.\d+[^\_]*)_', zip_name)
        name_v = name_v.group(1) if name_v else None
        if not pv or (name_v and pv != name_v):
            print(f"  包内版本与文件名不符: 包内={pv} 文件名={name_v}")
            bad += 1
        else:
            print(f"  包内版本 {pv} 与文件名一致")
    except Exception as e:
        print(f"  无法校验包内 _meta.lua: {e}")
        bad += 1
    if bad:
        print(f"\n{bad} 项异常，请重新上传")
        sys.exit(1)
    print(f"\n线上目录校验通过，插件列目录即可发现并更新到 {zip_name}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--notes", default="", help="更新说明")
    ap.add_argument("--zip", default=None, help="用已有包发布（zip/tar.gz/tgz，自动识别版本并规范命名）")
    ap.add_argument("--format", default="targz", choices=["zip", "targz", "tgz"],
                    help="从源码打包时的格式（默认 tar.gz；zip/tgz 可选）")
    ap.add_argument("--ssh", default=None, help="NAS ssh 目标，如 root@<NAS地址>")
    ap.add_argument("--ssh-port", type=int, default=2233)
    ap.add_argument("--check", action="store_true", help="校验线上目录挑中的最新包")
    args = ap.parse_args()

    if args.check:
        check_online(NAS_HOST)
        return

    if args.zip:
        zip_path, version = normalize_zip(args.zip)
        count = len(package_file_entries(zip_path))
    else:
        version = read_version()
        ext = {"zip": ".zip", "targz": ".tar.gz", "tgz": ".tgz"}[args.format]
        zip_path, count = build_zip_from_source(version, ext)
    write_publish(zip_path, version, args.notes, count)

    if args.ssh:
        upload(args.ssh, args.ssh_port)
    else:
        print("\n未配置 --ssh，手动上传方式：")
        print(f"  将 {PUBLISHED_PLUGIN} 的全部内容拷到 NAS 的 {REMOTE_DIR}/")
        print("  或用: python3 publish_update.py --ssh root@<NAS地址> --ssh-port <端口>")
        print(f"  上传后执行: python3 publish_update.py --check")


if __name__ == "__main__":
    main()
