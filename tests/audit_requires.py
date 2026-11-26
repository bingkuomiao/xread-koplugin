import re
import sys

path = sys.argv[1] if len(sys.argv) > 1 else "xread.koplugin/main.lua"
src = open(path, encoding="utf-8").read()
lines = src.split("\n")

funcs = []
cur = None
for i, l in enumerate(lines):
    m = re.match(r"^(?:local )?function ([A-Za-z_][\w:.]*)\s*\(", l)
    if m:
        if cur:
            cur["end"] = i
        cur = {"name": m.group(1), "start": i, "end": len(lines)}
        funcs.append(cur)

top = set()
for l in lines:
    m = re.match(r"^local (\w+)\s*=", l)
    if m:
        top.add(m.group(1))

need = ["HorizontalGroup", "VerticalGroup", "HorizontalSpan", "FrameContainer",
        "CenterContainer", "LeftContainer", "TextWidget", "TextBoxWidget",
        "LineWidget", "GestureRange", "Button", "ImageWidget", "InputDialog",
        "InputContainer", "OverlapGroup", "ConfirmBox", "Menu", "Font",
        "Blitbuffer", "Geom"]

bad = []
for f in funcs:
    body = "\n".join(lines[f["start"]:f["end"]])
    localdecl = set(re.findall(r"local (\w+)\s*=\s*require\(", body))
    for name in need:
        if name in localdecl or name in top:
            continue
        if re.search(r"\b" + name + r"\s*:\s*new\b", body):
            bad.append((f["name"], f["start"] + 1, name))

for b in bad:
    print("MISSING require: func=%s line=%d widget=%s" % b)
print("checked_funcs=%d issues=%d" % (len(funcs), len(bad)))
