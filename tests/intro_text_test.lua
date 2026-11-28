-- 英雄卡简介清洗单测（纯 Lua，可在 WSL luajit 下直接跑）
-- 验证：保留段落 + 中文缩进、剥「简介：」前缀、过滤非简介内容、清残缺实体。
package.preload["libs/libkoreader-lfs"] = function() return {} end

local ok_count, fail_count = 0, 0
local function check(cond, name)
    if cond then ok_count = ok_count + 1 else
        fail_count = fail_count + 1
        print("FAIL: " .. name)
    end
end

local base = "/mnt/d/WorkBuddy/2026-11-24-23-40-18/xread-koplugin/xread.koplugin"
local U = dofile(base .. "/xread/miui/util.lua")

local raw = table.concat({
    "简介：",
    "<p>少年自边陲而起，一路走过千山万水。</p>",
    "<p>他不知道，命运的齿轮早已开始转动。</p>",
    "作者：某作者",
    "来源：某书源",
    "最新章节：第453话 风起",
    "第五章 归途",
    "微信读书 www.example.com",
}, "\n")
local text, dropped = U.intro_text(raw)
local first, second = text:match("^([^\n]+)\n([^\n]+)$")
check(first ~= nil and second ~= nil, "两段正文都保留")
check(first and first:sub(1, 6) == "　　", "第一段有两个全角空格缩进")
check(second and second:sub(1, 6) == "　　", "第二段有两个全角空格缩进")
check(first and first:find("少年自边陲而起", 1, true) ~= nil, "正文内容未丢")
check(not text:find("作者：", 1, true), "作者行被过滤")
check(not text:find("最新章节：", 1, true), "最新章节行被过滤")
check(not text:find("第五章", 1, true), "纯章节标题行被过滤")
check(not text:find("www%.example", 1), "站点水印行被过滤")
check(dropped >= 4, "至少过滤 4 行噪声，实际 " .. tostring(dropped))

local messy = "简介：& ; & ; 正文里的残缺实体。<br />& ; 第二段也带一点。"
local messy_text = U.intro_text(messy)
check(not messy_text:find("& ;", 1, true), "残缺实体 & ; 被清掉")
check(messy_text:find("\n", 1, true) ~= nil, "br 标签保留为段落分隔")

local plain = U.intro_text("这是一段没有标签的简介。")
check(plain == "　　这是一段没有标签的简介。", "单段也补缩进")

print(string.format("intro text: %d passed, %d failed", ok_count, fail_count))
os.exit(fail_count == 0 and 0 or 1)
