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
local COVER_DIR = "/tmp/xread_cover_test"
os.execute("rm -rf " .. COVER_DIR .. "; mkdir -p " .. COVER_DIR)
local c = CoverCache:new(COVER_DIR, BASE, function() return client end)

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

-- 6) 后端鉴权失败返回的是 400 + NEED_LOGIN，不是 401 —— 也必须重登重试
-- 错误响应体是走 sink 回来的（luasocket 的 r1/r2 只有状态码），mock 要自己往 sink 写。
calls = 0
package.loaded["socket.http"].request = function(t)
    calls = calls + 1
    seen[calls] = t
    if calls == 1 then
        if t.sink then t.sink('{"isSuccess":false,"errorMsg":"NEED_LOGIN"}') end
        return 1, 400
    end
    return 1, 404
end
client.accessToken = "tok"
c:fetchViaProxy(local_src)
check(calls == 2, "400 NEED_LOGIN 后未重试（calls=" .. tostring(calls) .. "）")

-- 7) 写入与查找必须用同一个文件名：storeFromData 落盘后 pathFor 必须能命中
-- 这是 v0.6.14~v0.6.28 一直存在的缺陷（写 key.png、找 指纹-key.png），
-- 表现是每次开首页都重新下载全部封面。用假的解码器验证命名，不依赖网络与真机。
local written
package.loaded["ui/renderimage"] = {
    renderImageFile = function()
        return { getWidth = function() return 600 end, getHeight = function() return 800 end,
                 free = function() end }
    end,
    scaleBlitBuffer = function()
        return { getType = function() return 0 end, free = function() end }
    end,
}
package.loaded["ffi/blitbuffer"] = {
    new = function()
        return {
            blitFrom = function() end,
            free = function() end,
            writePNG = function(_, path)
                written = path
                local f = io.open(path, "wb")
                f:write("\137PNG\r\n\26\n")
                f:close()
            end,
        }
    end,
}
local book = { bookUrl = "local-txt:nametest", coverUrl = "http://example.com/n.jpg" }
local stored, serr = c:storeFromData(book, string.rep("x", 200), 160, 220)
check(written ~= nil, "storeFromData 未写出文件: " .. tostring(serr))
check(stored == written, "storeFromData 返回值与落盘路径不一致")
check(stored == c.dir .. "/" .. c:fileNameFor(book, 160, 220),
    "落盘文件名与 fileNameFor 不一致：" .. tostring(stored))
local hit = c:pathFor(book, 160, 220)
check(hit == stored, "落盘后 pathFor 未命中磁盘缓存（写到 " .. tostring(stored) .. "，查 " .. tostring(hit) .. "）")

-- 8) 重开插件（新实例 + migrateLegacy）不能把合法缓存当孤儿删掉
-- 删掉 schema 标记，让 migrateLegacy 真的跑一遍（否则它直接 return，等于没测）
os.remove(c.dir .. "/.schema3")
local c3 = CoverCache:new(COVER_DIR, BASE, function() return client end)
check(c3:pathFor(book, 160, 220) == stored, "migrateLegacy 误删了合法封面缓存")

-- 9) 换后端地址后封面必须跟着新地址走（CoverCache 是 init 时建的，base_url 是快照）
client.address = "http://10.0.0.9:8888"
check(c:coverApiUrl(net_src):find("^http://10.0.0.9:8888/reader3/cover", 1) ~= nil,
    "改地址后封面仍打旧地址：" .. tostring(c:coverApiUrl(net_src)))
client.address = nil

-- 10) 本地书只有 customCoverUrl 时也必须算「有封面源」
-- 后端对 local-txt/local-epub 不返回 coverUrl，只给 customCoverUrl；
-- 原来各处只判 coverUrl，本地书封面永远进不了下载队列。
local local_book = { bookUrl = "local-txt:abc", customCoverUrl = "http://example.com/local.jpg" }
check(c:sourceFor(local_book) == "http://example.com/local.jpg", "customCoverUrl 未被当作封面源")
check(c:sourceFor({ bookUrl = "local-txt:none" }) == nil, "无封面源时 sourceFor 应返回 nil")

-- 11) 失败负缓存：AVIF 这类确定性失败必须短期不再重试（否则每轮都重拉 170KB）
local fb = { bookUrl = "local-txt:fail", coverUrl = "http://example.com/avif" }
check(not c:recentlyFailed(fb, 160, 220), "初始不应处于失败态")
c:markFailed(fb, 160, 220, "unsupported image format")
check(c:recentlyFailed(fb, 160, 220), "AVIF 失败后应进入负缓存")
check(c:fetchAndStore(fb, fb.coverUrl, 160, 220) == nil, "负缓存期间不应再发起请求")
c:clearFailed(fb, 160, 220)
check(not c:recentlyFailed(fb, 160, 220), "clearFailed 未清除负缓存")

print("COVER_API_OK")
