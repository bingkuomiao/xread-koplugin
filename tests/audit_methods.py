import re
import sys

path = sys.argv[1] if len(sys.argv) > 1 else "xread.koplugin/main.lua"
src = open(path, encoding="utf-8").read()
lines = src.split("\n")

methods = set(re.findall(r"^function XRead:([\w]+)\(", src, re.M))
fields = set(re.findall(r"self\.([\w]+)\s*=(?!=)", src))

bad = []
for i, l in enumerate(lines, 1):
    for m in re.finditer(r"self\.([\w]+)\s*\(", l):
        name = m.group(1)
        if name in methods:
            bad.append((i, name, l.strip()))

for b in bad:
    print("DOT-CALL instead of colon: line=%d method=%s :: %s" % b)
print("methods=%d dot_call_issues=%d" % (len(methods), len(bad)))
