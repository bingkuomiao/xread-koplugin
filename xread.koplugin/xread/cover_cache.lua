-- xread.koplugin/xread/cover_cache.lua
-- 封面缓存：下载 coverUrl -> 指定尺寸缩略图 PNG，落到本地缓存目录。
-- 缓存 key 带尺寸，界面改版后不会误用旧的小图。

local http = require("socket.http")
local ltn12 = require("ltn12")

local md5 = require("ffi/sha2").md5
local util = require("util")

local CoverCache = {}
CoverCache.__index = CoverCache

function CoverCache:new(cache_dir, base_url)
    util.makePath(cache_dir)
    return setmetatable({ dir = cache_dir, base_url = base_url }, self)
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

function CoverCache:pathFor(book, max_w, max_h)
    local path = self.dir .. "/" .. self:keyFor(book, max_w, max_h) .. ".png"
    local f = io.open(path, "rb")
    if f then
        local head = f:read(4)
        f:close()
        if head and head:sub(1, 4) == "\137PNG" then return path end
    end
    return nil
end

local function fetch(url)
    local chunks = {}
    -- 封面走懒加载队列，一张卡太久会拖累翻页交互；比接口超时更紧（临时覆盖）。
    local saved_timeout = http.TIMEOUT
    http.TIMEOUT = 8
    -- 带 Referer 绕过部分站点的防盗链
    local referer = url:match("^(%w+://[^/]+)")
    local _, code = http.request{
        url = url,
        sink = ltn12.sink.table(chunks),
        headers = {
            ["User-Agent"] = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
            ["Accept"] = "image/avif,image/webp,image/apng,image/svg+xml,image/*,*/*;q=0.8",
            referer and ("Referer: " .. referer .. "\r\n") or nil,
        },
    }
    http.TIMEOUT = saved_timeout
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

-- 走后端 /reader3/cover 代理：由后端带 Referer 抓图，绕过防盗链
function CoverCache:fetchViaProxy(url)
    if not self.base_url or self.base_url == "" then return nil, "no base url" end
    return fetch(self.base_url .. "/reader3/cover?path=" .. urlencode(url))
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

function CoverCache:fetchAndStore(book, url, max_w, max_h)
    local existing = self:pathFor(book, max_w, max_h)
    if existing then return existing end
    -- WebUI 同款优先级：用户自定义封面 > 书源封面
    url = url or book.customCoverUrl or book.coverUrl
    if not url or url == "" then return nil, "no url" end
    local data, err
    if url:sub(1, 4):lower() == "http" then
        data, err = fetch(url)
        if not data and self.base_url then
            -- 直连失败（防盗链/超时）：回退后端代理（代理可能转 AVIF，后面预检会拦）
            data, err = self:fetchViaProxy(url)
        end
    else
        -- 相对路径（如 /reader3/localEpubAsset...）：拼后端地址
        if not self.base_url or self.base_url == "" then return nil, "no base url" end
        data, err = fetch(self.base_url .. url)
    end
    if not data then return nil, err end
    if not isSupportedImage(data) then return nil, "unsupported image format" end
    return self:storeFromData(book, data, max_w, max_h)
end

return CoverCache
