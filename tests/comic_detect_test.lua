-- 漫画判定单测（纯 Lua，可在 WSL luajit 下直接跑）
-- 验证 extractImageUrls 能识别各种懒加载写法，且不再依赖正文文字长度。
-- 用桩模块隔离网络依赖（ltn12 / http_client / json 都不需要真的加载）。
package.preload["ltn12"] = function() return {} end
package.preload["xread/http_client"] = function() return { request = function() end } end
package.preload["json"] = function() return { decode = function() end } end

local ok_count, fail_count = 0, 0
local function check(cond, name)
    if cond then ok_count = ok_count + 1 else
        fail_count = fail_count + 1
        print("FAIL: " .. name)
    end
end

local base = "/mnt/d/WorkBuddy/2026-11-24-23-40-18/xread-koplugin/xread.koplugin"
local Client = dofile(base .. "/xread/client.lua")
local c = Client:new("http://127.0.0.1:7777")

-- ① 普通 <img src>
local html1 = '<div><img src="http://x/1.jpg"><img src="http://x/2.jpg"></div>'
check(#c:extractImageUrls(html1) == 2, "plain src")

-- ② 懒加载 data-src（漫画站最常见）
local html2 = '<img data-src="http://x/3.jpg" src="data:image/gif;base64,R0lGODlh">'
    .. '<img data-src="http://x/4.jpg" src="data:image/gif;base64,R0lGODlh">'
local u2 = c:extractImageUrls(html2)
check(#u2 == 2 and u2[1] == "http://x/3.jpg", "data-src 优先于 data: 占位")

-- ③ data-original / srcset / <source>
local html3 = '<img data-original="http://x/5.png">'
    .. '<img srcset="http://x/6.webp 1x, http://x/7.webp 2x">'
    .. '<source src="http://x/8.jpg">'
check(#c:extractImageUrls(html3) == 3, "data-original + srcset + source")

-- ④ CSS url()
local html4 = '<div style="background-image:url(http://x/9.jpg)"></div>'
check(#c:extractImageUrls(html4) == 1, "css url()")

-- ⑤ 关键回归：带大段 script/style 的漫画页，图片数不受影响
local html5 = '<script>' .. string.rep("var a = 12345; ", 300) .. '</script>'
    .. '<style>' .. string.rep(".con{color:red}", 100) .. '</style>'
    .. '<img data-src="http://x/10.jpg"><img data-src="http://x/11.jpg">'
local u5 = c:extractImageUrls(html5)
check(#u5 == 2, "script/style 不影响图片提取")

-- ⑥ 去重：同一张图出现多次只算一张
local html6 = '<img src="http://x/same.jpg"><img data-src="http://x/same.jpg">'
check(#c:extractImageUrls(html6) == 1, "重复 URL 去重")

print(string.format("comic detect: %d passed, %d failed", ok_count, fail_count))
os.exit(fail_count == 0 and 0 or 1)
