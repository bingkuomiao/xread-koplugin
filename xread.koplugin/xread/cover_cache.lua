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
function CoverCache:migrateLegacy()
    local marker = self.dir .. "/.schema2"
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
        f:write("2\n")
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
    if tonumber(code) ~= 200 then return nil, "HTTP " .. tostring(code) end
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
        local path = self.dir .. "/" .. key .. ".png"
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
    if not self.base_url or self.base_url == "" then return nil, "no base url" end
    local url = self.base_url .. "/reader3/cover?path=" .. urlencode(source)
    local client = self.client_getter and self.client_getter()
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

--- 统一封面接口取图；本地书 401（token 过期）时重登一次并重试。
function CoverCache:fetchViaProxy(url, _retried)
    local api_url, err = self:coverApiUrl(url)
    if not api_url then return nil, err end
    local data, ferr = fetch(api_url)
    if not data and ferr == "HTTP 401" and not _retried then
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

function CoverCache:fetchAndStore(book, url, max_w, max_h)
    local existing = self:pathFor(book, max_w, max_h)
    if existing then return existing end

    local key = self:keyFor(book, max_w, max_h)
    if inflight[key] then return nil, "inflight" end
    inflight[key] = true

    local ok, path, err = pcall(function()
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
        return self:storeFromData(book, data, max_w, max_h)
    end)

    inflight[key] = nil

    if not ok then return nil, tostring(path) end
    return path, err
end

return CoverCache
