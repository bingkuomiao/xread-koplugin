import zipfile, os
src, out = "xread.koplugin", "xread.koplugin.zip"
files = []
for root, dirs, fs in os.walk(src):
    for f in fs:
        p = os.path.join(root, f)
        files.append((p, os.path.relpath(p, src).replace(os.sep, "/")))
files.sort(key=lambda x: x[1])
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
    for p, rel in files:
        z.write(p, rel)
print("WSL zip:", len(files), "files,", os.path.getsize(out), "bytes")
