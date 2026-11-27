-- 统一封面接口回归（纯 Lua，不启动模拟器）
-- 验证：path=customCoverUrl||coverUrl 原值编码、统一带鉴权、未登录远程书可用、
--       Referer 正确作为 header、本地书 401 自动重登重试。
local plugin_dir = arg[1] or "/opt/koreader/lib/koreader/plugins/xread.koplugin"
package.path = plugin_dir .. "/?.lua;/opt/koreader/lib/koreader/?.lua;"
    .. "/opt/koreader/lib/koreader/?/init.lua;/opt/koreader/lib/koreader/common/?.lua;" .. package.path

package.loaded["util"] = { makePath = function() end }
local seen = {}
package.loaded["socket.http"] = {
    TIMEOUT = 1,
    request = function(t) seen[#seen + 1] = t; return nil, 404 end,
}

local CoverCache = require("xread.cover_cache")
local BASE = "http://192.168.31.51:7777"
local client = {
    accessToken = "tok", secureKey = "sk", userNS = "ns",
    username = "u", password = "p",
}
local c = CoverCache:new("/tmp/xread_cover_test", BASE, function() return client end)

local function check(cond, msg)
    if not cond then error(msg, 0) end
end

-- 1) 网络书：path 为原值编码，且统一带鉴权参数
local net_src = "http://example.com/c.jpg"
local prefix = BASE .. "/reader3/cover?path=http%3A%2F%2Fexample.com%2Fc.jpg"
check(c:coverApiUrl(net_src) == prefix .. "&accessToken=tok&secureKey=sk&userNS=ns",
    "网络书 URL 不符")

-- 2) 本地书：path 为 /reader3/localEpubAsset?... 原值编码 + 鉴权
local local_src = "/reader3/localEpubAsset?bookUrl=abc&path=cover%2F1.jpg"
local u2 = c:coverApiUrl(local_src)
check(u2:find("path=%2Freader3%2FlocalEpubAsset%3FbookUrl%3Dabc%26path%3Dcover%252F1.jpg", 1, true),
    "本地书 path 编码不符")
check(u2:find("accessToken=tok", 1, true), "本地书缺 accessToken")

-- 3) 未登录：不带鉴权，但网络书 URL 正确（后端对远程 URL 不读鉴权）
local c2 = CoverCache:new("/tmp/xread_cover_test", BASE, function() return nil end)
check(c2:coverApiUrl(net_src) == prefix, "未登录网络书 URL 不符")

-- 4) 实际请求：Referer 必须是合法 header（key-value），不是数组项
c:fetchViaProxy(net_src)
local last = seen[#seen]
check(last.url == c:coverApiUrl(net_src), "代理请求 URL 不符")
check(last.headers["Referer"] == BASE, "Referer header 缺失")

-- 5) 本地书 401：重登一次后用新 token 重试
-- 注意 socket.http / KOReader 的约定：成功时第一个返回值是 1，第二个才是 HTTP 状态码。
-- mock 成 `nil, 401` 会被 HttpClient 当成「请求失败」而不是「HTTP 401」，
-- 覆盖不到 401 重登分支（之前这条用例一直是这么写的，等于没在测）。
local calls = 0
package.loaded["socket.http"].request = function(t)
    calls = calls + 1
    seen[calls] = t
    if calls == 1 then return 1, 401 end
    return 1, 404
end
client.login = function()
    client.accessToken = "tok2"
    return { isSuccess = true }
end
local _, err = c:fetchViaProxy(local_src)
check(calls == 2, "401 后未重试（calls=" .. tostring(calls) .. "）")
check(seen[2].url:find("accessToken=tok2", 1, true), "重试未使用新 token")

print("COVER_API_OK")
