-- xread.koplugin/xread/cover_cache.lua
-- 封面缓存：经后端统一接口取图 -> 指定尺寸缩略图 PNG，落到本地缓存目录。
-- 统一接口（本地/网络书通用）：GET /reader3/cover?path=<原值>&accessToken=<token>&secureKey=<key>
--   path 直接放 customCoverUrl || coverUrl 原值，无需区分本地/网络书：
--   · 网络书：http(s) 封面 URL（后端不读鉴权参数，未登录也能取）
--   · 本地 EPUB 内嵌封面：/reader3/localEpubAsset?bookUrl=<编码>&path=<编码>（需有效 token）
-- 缓存 key 带尺寸，界面改版后不会误用旧的小图。

local HttpClient = require("xread/http_client")
local ltn12 = require("ltn12")

local md5 = require("ffi/sha2").md5
local util = require("util")
local lfs = require("libs/libkoreader-lfs")

local CoverCache = {}
CoverCache.__index = CoverCache

--- @param client_getter function|nil 延迟返回已登录 client（封面鉴权参数 / 401 重登）
function CoverCache:new(cache_dir, base_url, client_getter)
    util.makePath(cache_dir)
    local o = setmetatable({
        dir = cache_dir, base_url = base_url, client_getter = client_getter,
    }, self)
    pcall(o.migrateLegacy, o)     -- 清掉旧命名（纯 md5）的孤儿封面，只做一次
    return o
end

function CoverCache:keyFor(book, max_w, max_h)
    local seed = table.concat({
        tostring(book.bookUrl or ""),
        tostring(book.coverUrl or ""),
        tostring(book.customCoverUrl or ""),
        tostring(max_w or 0), "x", tostring(max_h or 0),
    }, "|")
    return md5(seed)
end

--- 这本书有没有可取的封面源。
--- 网络书的封面在 coverUrl，本地书的封面几乎都只写在 customCoverUrl 上
--- （后端对 local-txt/local-epub 不返回 coverUrl）。以前各处只判 coverUrl，
--- 本地书的封面就永远进不了下载队列，只能显示占位色块。
function CoverCache:sourceFor(book)
    if not book then return nil end
    for _, k in ipairs({ "customCoverUrl", "coverUrl" }) do
        local v = book[k]
        if type(v) == "string" and v ~= "" then return v end
    end
    return nil
end

--- 书籍指纹（DJB2）：让文件名带上「哪本书」这一维，删书时可按前缀批量清理。
-- 只用 md5(seed) 当文件名时，删书根本找不到这些文件，covers/*.png 永久残留。
local function bookFingerprint(book)
    local url = tostring(book.bookUrl or "")
    local h = 5381
    for i = 1, #url do
        h = (h * 33 + url:byte(i)) % 4294967296
    end
    return string.format("%08x", h)
end

function CoverCache:fileNameFor(book, max_w, max_h)
    return bookFingerprint(book) .. "-" .. self:keyFor(book, max_w, max_h) .. ".png"
end

function CoverCache:pathFor(book, max_w, max_h)
    local path = self.dir .. "/" .. self:fileNameFor(book, max_w, max_h)
    local f = io.open(path, "rb")
    if f then
        local head = f:read(4)
        f:close()
        if head and head:sub(1, 4) == "\137PNG" then return path end
    end
    return nil
end

--- 这本书已经缓存过的任意尺寸封面（不要求尺寸匹配）。
-- 本地书架要复用「我的书架」的封面，但它只知道书名、不知道当初按哪个尺寸取的图；
-- 按指纹前缀扫一遍比自己再下一次图便宜得多（离线时也只有这条能成）。
function CoverCache:anyPathFor(book)
    if not book or not book.bookUrl then return nil end
    local prefix = bookFingerprint(book) .. "-"
    local ok, iter, obj = pcall(lfs.dir, self.dir)
    if not ok then return nil end
    local best
    for name in iter, obj do
        if type(name) == "string" and name:sub(1, #prefix) == prefix and name:match("%.png$") then
            best = self.dir .. "/" .. name
            break
        end
    end
    return best
end

--- 删除某本书的全部封面缓存（所有尺寸变体）
-- 新文件名为 <指纹>-<md5>.png，按前缀扫一遍即可；
-- 老版本的纯 md5 文件名无法归属到具体书，在 migrateLegacy() 里一次性清掉。
function CoverCache:removeBook(book)
    if not book or not book.bookUrl then return 0 end
    local prefix = bookFingerprint(book) .. "-"
    local ok, iter, obj = pcall(lfs.dir, self.dir)
    if not ok then return 0 end
    local targets = {}
    for name in iter, obj do
        if name:sub(1, #prefix) == prefix and name:match("%.png$") then
            targets[#targets + 1] = self.dir .. "/" .. name
        end
    end
    for _, p in ipairs(targets) do pcall(os.remove, p) end
    return #targets
end

--- 一次性清理旧命名（纯 md5）的孤儿封面文件
-- 旧文件名不带书籍指纹，删书时永远清不掉，只会在磁盘上堆着。
-- schema3：v0.6.14 引入指纹命名时 storeFromData 仍按纯 md5 落盘，
-- 于是「写 key.png、找 指纹-key.png」，磁盘缓存一次都没命中过（每次开首页
-- 都重新下载全部封面）。升级后清掉那批只有 md5 的孤儿文件。
function CoverCache:migrateLegacy()
    local marker = self.dir .. "/.schema3"
    if lfs.attributes(marker, "mode") then return end
    local ok, iter, obj = pcall(lfs.dir, self.dir)
    if ok then
        local targets = {}
        for name in iter, obj do
            if name:match("%.png$") and not name:match("^%x%x%x%x%x%x%x%x%-%x+%.png$") then
                targets[#targets + 1] = self.dir .. "/" .. name
            end
        end
        for _, p in ipairs(targets) do pcall(os.remove, p) end
    end
    local f = io.open(marker, "w")
    if f then
        f:write("3\n")
        f:close()
    end
end

local function fetch(url)
    local chunks = {}
    -- 封面走懒加载队列，一张卡太久会拖累翻页交互：单张 8s。
    -- 超时由 http_client 统一管理（结束后必定恢复全局值，原来这里手写
    -- saved/restore，一旦 http.request 抛错就永久把全局 TIMEOUT 改成 8）。
    -- 带 Referer 绕过部分站点的防盗链
    local referer = url:match("^(%w+://[^/]+)")
    local ok, code = HttpClient.request({
        url = url,
        sink = ltn12.sink.table(chunks),
        headers = {
            ["User-Agent"] = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
            ["Accept"] = "image/avif,image/webp,image/apng,image/svg+xml,image/*,*/*;q=0.8",
            ["Referer"] = referer,   -- 必须是 key-value，否则 luasocket 不会发送该头
        },
    }, 8)
    if not ok then return nil, "network error" end
    if tonumber(code) ~= 200 then
        -- 把响应体一并带回：后端鉴权失败返回的是 400 + {"errorMsg":"NEED_LOGIN"}，
        -- 光看状态码没法区分「token 过期」和「本地 EPUB 地址本来就无效」。
        return nil, "HTTP " .. tostring(code), table.concat(chunks)
    end
    local data = table.concat(chunks)
    if #data < 100 then return nil, "too small" end
    -- 魔数校验：后端偶发把 HTML 错误页/损坏数据当封面返回，
    -- 直接交给 MuPDF 解码会抛 "unknown image file format" 未捕获异常。
    local head = data:sub(1, 12)
    local is_image = head:sub(1, 8) == "\137PNG\r\n\26\n"        -- PNG
        or head:sub(1, 3) == "\255\216\255"                      -- JPEG
        or head:sub(1, 4) == "GIF8"                              -- GIF
        or (head:sub(1, 4) == "RIFF" and head:sub(9, 12) == "WEBP") -- WebP
        or head:sub(1, 2) == "BM"                                -- BMP
    if not is_image then return nil, "not an image" end
    return data
end

--- 居中裁剪填满，保持比例不变形。
function CoverCache:storeFromData(book, data, max_w, max_h)
    max_w = max_w or 160
    max_h = max_h or 220
    local RenderImage = require("ui/renderimage")
    local Blitbuffer = require("ffi/blitbuffer")
    local key = self:keyFor(book, max_w, max_h)
    local tmp = self.dir .. "/.src_" .. key
    local f = io.open(tmp, "wb")
    if not f then return nil, "cannot write temp" end
    f:write(data); f:close()
    local ok, result = pcall(function()
        local source = RenderImage:renderImageFile(tmp, false)
        assert(source, "decode failed")
        local sw, sh = source:getWidth(), source:getHeight()
        assert(sw > 0 and sh > 0, "bad dims")
        local factor = math.max(max_w / sw, max_h / sh)
        local cw = math.max(max_w, math.ceil(sw * factor))
        local ch = math.max(max_h, math.ceil(sh * factor))
        local filled = RenderImage:scaleBlitBuffer(source, cw, ch, true)
        local out = Blitbuffer.new(max_w, max_h, filled:getType())
        local ox = math.floor((cw - max_w) / 2)
        local oy = math.floor((ch - max_h) / 2)
        out:blitFrom(filled, 0, 0, ox, oy, max_w, max_h)
        -- 必须和 pathFor() 用同一套命名，否则写进去的文件永远查不到。
        local path = self.dir .. "/" .. self:fileNameFor(book, max_w, max_h)
        out:writePNG(path)
        filled:free(); out:free(); source:free()
        return path
    end)
    os.remove(tmp)
    if ok and result then return result end
    return nil, tostring(result)
end

-- URL encode（后端 cover 代理要求 path 参数）
local function urlencode(s)
    s = tostring(s or "")
    local out = s:gsub("[^%w_%.%~%-]", function(c)
        return string.format("%%%02X", string.byte(c))
    end)
    return out
end

--- 构造统一封面接口 URL：后端 getCoverUrl 零判断，所有封面都带鉴权参数。
--- 远程 URL 后端根本不读鉴权参数（无效/过期 token 不影响），本地书则必须有有效 token。
function CoverCache:coverApiUrl(source)
    local client = self.client_getter and self.client_getter()
    -- 地址以 client 为准：用户在设置里改 IP/端口后 client.address 会立刻更新，
    -- 而 CoverCache 是插件 init 时建的，base_url 是那一刻的快照——
    -- 只看 base_url 会导致换地址后封面继续往旧地址请求。
    local base = (client and client.address and client.address ~= "" and client.address)
        or self.base_url
    if not base or base == "" then return nil, "no base url" end
    local url = base .. "/reader3/cover?path=" .. urlencode(source)
    if client then
        if client.accessToken then
            url = url .. "&accessToken=" .. urlencode(client.accessToken)
        end
        if client.secureKey then
            url = url .. "&secureKey=" .. urlencode(client.secureKey)
        end
        if client.userNS then
            url = url .. "&userNS=" .. urlencode(client.userNS)
        end
    end
    return url
end

--- 统一封面接口取图；鉴权失败（401 / 400 NEED_LOGIN）时重登一次并重试。
-- 后端对本地书取封面要求有效 token，未登录时返回 400 NEED_LOGIN 而不是 401，
-- 只判 401 的话 token 过期后本地书封面会永久取不到，必须重新登录才恢复。
function CoverCache:fetchViaProxy(url, _retried)
    local api_url, err = self:coverApiUrl(url)
    if not api_url then return nil, err end
    local data, ferr, body = fetch(api_url)
    local needs_login = ferr == "HTTP 401" or ferr == "HTTP 403"
        or (ferr == "HTTP 400" and tostring(body or ""):find("NEED_LOGIN", 1, true) ~= nil)
    if not data and needs_login and not _retried then
        local client = self.client_getter and self.client_getter()
        if client and client.username and client.password then
            local ok = pcall(function() client:login(client.username, client.password) end)
            if ok then return self:fetchViaProxy(url, true) end
        end
    end
    return data, ferr
end

-- KOReader 能解码的图片格式预检：后端 cover 代理可能返回 AVIF（不支持），
-- 直接判失败，避免写缓存与无谓解码。
local function isSupportedImage(data)
    if not data or #data < 12 then return false end
    local b = data:byte(1) or 0
    local b2 = data:byte(2) or 0
    if b == 0xFF and b2 == 0xD8 then return true end          -- JPEG
    if b == 0x89 and data:sub(2, 4) == "PNG" then return true end
    if data:sub(1, 3) == "GIF" then return true end           -- GIF
    if data:sub(1, 2) == "BM" then return true end            -- BMP
    if data:sub(1, 4) == "RIFF" and data:sub(9, 12) == "WEBP" then return true end
    return false
end

-- 正在下载的封面 key：两套封面队列（prepareCovers 与封面重试循环）会同时
-- 请求同一张图，重复请求白耗流量，两路同时 writePNG 还可能写出坏图。
local inflight = {}

--- 网络抓取（不含解码）：返回原始图片字节。
-- 只碰 socket，不碰 RenderImage/Blitbuffer，可在 fork 子进程里跑。
-- 供「异步封面队列」把最慢的网络段挪出 UI 线程。
function CoverCache:fetchRaw(book, url)
    -- WebUI 同款优先级：用户自定义封面 > 调用方给的封面 > 书源封面。
    -- 调用点传的是 book.coverUrl，这里让 customCoverUrl 优先，
    -- 否则本地书匹配到的网络封面（写进 customCoverUrl）会被内嵌封面路径盖掉。
    local source = book.customCoverUrl or url or book.coverUrl
    if not source or source == "" then return nil, "no url" end
    -- 统一走后端 /reader3/cover：本地书由后端鉴权读包内封面，网络书由后端代理抓取并缓存。
    local data, ferr = self:fetchViaProxy(source)
    -- 网络书兜底：后端代理不可用时直连原 URL（本地相对路径无法直连）。
    if not data and source:sub(1, 4):lower() == "http" then
        data, ferr = fetch(source)
    end
    if not data then return nil, ferr end
    if not isSupportedImage(data) then return nil, "unsupported image format" end
    return data
end

--- 原始字节临时文件路径（子进程写、主线程读，父子共享文件系统）
function CoverCache:rawTempPath(book, max_w, max_h)
    return self.dir .. "/.raw_" .. self:keyFor(book, max_w, max_h)
end

--- 把抓到的原始字节写到临时文件（在 fork 子进程里调用）
function CoverCache:writeRawFile(book, data, max_w, max_h)
    local path = self:rawTempPath(book, max_w, max_h)
    local f = io.open(path, "wb")
    if not f then return nil end
    f:write(data); f:close()
    return path
end

--- 子进程抓取失败时把原因写在旁边：主线程只看到「没文件」的话，
--- 就没法区分「AVIF 永远解不了」还是「这次网络抖了一下」。
function CoverCache:rawErrPath(book, max_w, max_h)
    return self.dir .. "/.rawerr_" .. self:keyFor(book, max_w, max_h)
end

function CoverCache:writeRawError(book, err, max_w, max_h)
    local f = io.open(self:rawErrPath(book, max_w, max_h), "w")
    if f then f:write(tostring(err or "")); f:close() end
end

function CoverCache:readRawError(book, max_w, max_h)
    local p = self:rawErrPath(book, max_w, max_h)
    local f = io.open(p, "r")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    pcall(os.remove, p)
    return s
end

--- 读原始字节文件并解码成缩略图 PNG（必须在主线程跑：RenderImage/Blitbuffer）
function CoverCache:storeFromRawFile(book, max_w, max_h)
    local path = self:rawTempPath(book, max_w, max_h)
    local f = io.open(path, "rb")
    if not f then
        return nil, self:readRawError(book, max_w, max_h) or "no raw file"
    end
    local data = f:read("*a")
    f:close()
    pcall(os.remove, path)
    if not data or #data < 100 then return nil, "raw too small" end
    return self:storeFromData(book, data, max_w, max_h)
end

-- 失败负缓存：后端对部分书源原样透传 AVIF（KOReader 没有 libavif，永远解不了）、
-- 或书源本身 404。这类书此前每 2 分钟重试一次，一本 170KB 的图反复拉，
-- 低端机上是纯浪费。按失败原因分两档：确定性失败（格式不支持 / 404）30 分钟
-- 不再试；临时失败（超时、断网）3 分钟后重试。
local FAIL_TTL_HARD = 30 * 60
local FAIL_TTL_SOFT = 3 * 60
local failed_until = {}

local function isHardFail(err)
    local s = tostring(err or "")
    return s:find("unsupported image format", 1, true) ~= nil
        or s:find("not an image", 1, true) ~= nil
        or s:find("HTTP 404", 1, true) ~= nil
        or s:find("HTTP 400", 1, true) ~= nil
        or s:find("no url", 1, true) ~= nil
end

function CoverCache:recentlyFailed(book, max_w, max_h)
    local key = self:keyFor(book, max_w, max_h)
    local until_t = failed_until[key]
    if not until_t then return false end
    if os.time() >= until_t then
        failed_until[key] = nil
        return false
    end
    return true
end

function CoverCache:markFailed(book, max_w, max_h, err)
    local ttl = isHardFail(err) and FAIL_TTL_HARD or FAIL_TTL_SOFT
    failed_until[self:keyFor(book, max_w, max_h)] = os.time() + ttl
end

function CoverCache:clearFailed(book, max_w, max_h)
    failed_until[self:keyFor(book, max_w, max_h)] = nil
end

function CoverCache:fetchAndStore(book, url, max_w, max_h)
    local existing = self:pathFor(book, max_w, max_h)
    if existing then return existing end
    if self:recentlyFailed(book, max_w, max_h) then return nil, "recently failed" end

    local key = self:keyFor(book, max_w, max_h)
    if inflight[key] then return nil, "inflight" end
    inflight[key] = true

    local ok, path, err = pcall(function()
        local data, ferr = self:fetchRaw(book, url)
        if not data then return nil, ferr end
        return self:storeFromData(book, data, max_w, max_h)
    end)

    inflight[key] = nil

    if not ok then
        self:markFailed(book, max_w, max_h, tostring(path))
        return nil, tostring(path)
    end
    if not path then self:markFailed(book, max_w, max_h, err) end
    return path, err
end

return CoverCache
