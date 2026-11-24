-- xread.koplugin/xread/client.lua
-- 网络层：封装 xread-fpk /reader3/* 的 9 个接口
-- 逻辑来自已实测通过的 test_network.lua，只依赖 KOReader 自带模块
--   (socket.http / ltn12 / dkjson)，无需额外安装

local http = require("socket.http")
local ltn12 = require("ltn12")

-- luasocket 默认超时 60s，后端偶发挂起会让 UI 卡死/请求堆积。
-- 统一收紧：接口请求最多等 12 秒，失败走各自的错误提示/回退。
http.TIMEOUT = 12

local json
local ok = pcall(function() json = require("json") end)   -- KOReader 内置 json
if not ok then json = require("dkjson") end               -- 桌面/测试环境回退

local Client = {}
Client.__index = Client

--- URL 编码（query/表单参数用）
local function urlencode(str)
    if not str then return "" end
    str = tostring(str):gsub("\r\n", "\n"):gsub("\n", "\r\n")
    return (str:gsub("([^%w%-_%.~])", function(c)
        return string.format("%%%02X", string.byte(c))
    end))
end

--- HTML 正文 -> 纯文本
-- 后端返回的是网页 HTML（<div class="con"><p>...</p>...），需转成可阅读的纯文本。
-- 处理：img 保留占位、块级标签转换行、去标签、解实体、合并空行。
local function htmlToText(s)
    if type(s) ~= "string" then return tostring(s or "") end
    local text = s
    -- 漫画图片：转成占位提示（KOReader TXT 不显示图片）
    local img_count = 0
    text = text:gsub("<img[^>]-src=[\"']([^\"']+)[\"'][^>]-/?>", function(src)
        img_count = img_count + 1
        return "\n[图 " .. img_count .. "]\n"
    end)
    -- 块级标签转换行
    text = text:gsub("<%s*br%s*/?%s*>", "\n")
    text = text:gsub("</%s*p%s*>", "\n")
    text = text:gsub("<%s*p[^>]*>", "\n")
    text = text:gsub("</%s*div%s*>", "\n")
    text = text:gsub("<%s*div[^>]*>", "\n")
    text = text:gsub("</%s*(h%d?|li|tr|table)[^>]*>", "\n")
    -- 去掉其余所有标签
    text = text:gsub("<[^>]+>", "")
    -- 解 HTML 实体
    local entities = {
        nbsp = " ", amp = "&", lt = "<", gt = ">", quot = "\"", apos = "'",
        hellip = "…", mdash = "—", ndash = "–", ldquo = "“", rdquo = "”",
    }
    text = text:gsub("&([%a%d]+);", function(name) return entities[name] end)
    text = text:gsub("&#(%d+);", function(n) return string.char(tonumber(n) % 256) end)
    text = text:gsub("&#x(%x+);", function(n) return utf8.char(tonumber(n, 16)) end)
    -- 合并 >=3 的连续换行为 2 个，去掉行首行尾空白，去全角空格缩进
    text = text:gsub("\r\n", "\n"):gsub("\r", "\n")
    text = text:gsub("\n[ \t]*\n[ \t]*\n+", "\n\n")
    text = text:gsub("^[ \t\n]+", ""):gsub("[ \t\n]+$", "")
    return text
end

-- 供插件在“先探一章判断漫画”时复用，避免同一章请求两次
function Client:toText(html)
    return htmlToText(html)
end

--- 构造客户端
-- @param address 后端根地址，如 "http://192.168.31.51:7777"
function Client:new(address)
    return setmetatable({
        address = address or "http://127.0.0.1:7777",
        accessToken = nil,
        username = nil,
        password = nil,
    }, self)
end

--- 检查后端连通性
-- 新后端把 health 放在根路径 /health；旧后端在 /reader3/health。
-- 先试根路径，失败再回退到 /reader3/health，二者都兼容。
function Client:health()
    local ok_res, res = pcall(function()
        return self:httpGet(self.address .. "/health")
    end)
    if ok_res and type(res) == "table" and res.isSuccess ~= nil then
        return res
    end
    return self:httpGet(self.address .. "/reader3/health")
end

--- 登录，成功后自动保存 accessToken
function Client:login(username, password)
    self.username, self.password = username, password
    local res = self:httpPost(self.address .. "/reader3/login", {
        isLogin = true, username = username, password = password, code = "",
    })
    assert(res.isSuccess, "登录失败: " .. tostring(res.errorMsg))
    self.accessToken = res.data and res.data.accessToken
    return res
end

--- 统一 URL 拼接（对应前端 url() 函数逻辑）
function Client:apiUrl(router, params)
    local url = self.address .. "/reader3/" .. router .. "?v=" .. os.time()
    if self.accessToken then
        url = url .. "&accessToken=" .. urlencode(self.accessToken)
    end
    if params then
        for k, v in pairs(params) do
            url = url .. "&" .. k .. "=" .. urlencode(v)
        end
    end
    return url
end

--- 递归清洗 LuaJSON 解码结果：JSON null 会被解码成 function 哨兵值，
--- 直接用 tostring 会显示 "function: 0x..."，这里统一转成 nil。
local function sanitizeJson(t)
    if type(t) ~= "table" then return t end
    for k, v in pairs(t) do
        if type(v) == "function" then
            t[k] = nil
        elseif type(v) == "table" then
            sanitizeJson(v)
        end
    end
    return t
end

--- GET 请求 -> table
function Client:httpGet(url)
    local chunks = {}
    local _, code = http.request{ url = url, sink = ltn12.sink.table(chunks) }
    assert(tonumber(code) == 200, "HTTP GET 失败: " .. tostring(code) .. " " .. url)
    local body = table.concat(chunks)
    local data, err = json.decode(body)
    assert(data, "JSON 解析失败: " .. tostring(err))
    return sanitizeJson(data)
end

--- POST 请求(JSON body) -> table
-- 非 200 时尽量解析后端 errorMsg，给出简洁错误（不回显 URL/token）
function Client:httpPost(url, obj, _retry)
    local payload = json.encode(obj)
    local chunks = {}
    local _, code = http.request{
        url = url, method = "POST",
        source = ltn12.source.string(payload),
        headers = {
            ["Content-Type"] = "application/json; charset=utf-8",
            ["Content-Length"] = tostring(#payload),
        },
        sink = ltn12.sink.table(chunks),
    }
    code = tonumber(code)
    local body = table.concat(chunks)
    local data = json.decode(body)   -- 成功/失败都可能是 JSON
    data = sanitizeJson(data)
    if code ~= 200 then
        -- 后端偶发 500：自动重试一次
        if code == 500 and not _retry then
            return self:httpPost(url, obj, true)
        end
        local msg = type(data) == "table" and data.errorMsg or nil
        if not msg or msg == "" then msg = tostring(code) end
        error("后端返回 " .. tostring(code) .. "：" .. tostring(msg), 0)
    end
    if type(data) ~= "table" then
        error("后端响应不是合法 JSON", 0)
    end
    return data
end

--- 获取书架（refresh=true 时让后端重新扫描，用于封面/元数据后台静默刷新）
function Client:getBookshelf(refresh)
    local res = self:httpGet(self:apiUrl("getBookshelf", { refresh = refresh and "1" or "0" }))
    assert(res.isSuccess, "获取书架失败: " .. tostring(res.errorMsg))
    return res.data or {}
end

--- 获取某本书的目录
function Client:getChapterList(book)
    local ok_res, res = pcall(function()
        return self:httpPost(self:apiUrl("getChapterList"), {
            refresh = 1, url = book.bookUrl,
        })
    end)
    if not ok_res then
        error("获取《" .. tostring(book.name or "?") .. "》目录失败：" .. tostring(res), 0)
    end
    assert(res.isSuccess, "获取目录失败: " .. tostring(res.errorMsg))
    return res.data or {}
end

--- 获取某一章正文（HTML -> 纯文本）
function Client:getBookContent(chapter, book)
    local res = self:httpPost(self:apiUrl("getBookContent"), {
        chapterUrl = chapter.url or chapter.chapterUrl,
        bookSourceUrl = book.origin,
        refresh = 0,
    })
    assert(res.isSuccess, "获取正文失败: " .. tostring(res.errorMsg))
    return htmlToText(res.data or "")
end

--- 获取某一章的原始 HTML（漫画需提取图片 URL）
function Client:getBookContentRaw(chapter, book)
    local res = self:httpPost(self:apiUrl("getBookContent"), {
        chapterUrl = chapter.url or chapter.chapterUrl,
        bookSourceUrl = book.origin,
        refresh = 0,
    })
    assert(res.isSuccess, "获取正文失败: " .. tostring(res.errorMsg))
    return res.data or ""
end

--- 从 HTML 中提取所有图片 URL
function Client:extractImageUrls(html)
    local urls = {}
    if type(html) ~= "string" then return urls end
    -- 匹配 <img ... src="..." ...>，兼容单双引号、属性顺序
    for src in html:gmatch("<img[^>]-src%s*=%s*[\"']([^\"']+)[\"']") do
        if src and src ~= "" then urls[#urls + 1] = src end
    end
    return urls
end

--- 保存阅读进度
function Client:saveBookProgress(book, index)
    local res = self:httpPost(self:apiUrl("saveBookProgress"), {
        url = book.bookUrl, index = index, name = book.name, author = book.author,
    })
    return res
end

--- 获取后端版本（getVersionUpdate 的 currentVersion；失败返回 nil，不影响调用方）
function Client:getServerVersion()
    local ok, res = pcall(function()
        return self:httpGet(self:apiUrl("getVersionUpdate"))
    end)
    if ok and res.isSuccess and type(res.data) == "table" then
        local v = res.data.currentVersion
        if v and v ~= "" then return tostring(v) end
    end
    return nil
end

--- 查询某本书的缓存信息（哪些章已缓存）
function Client:getShelfBookWithCacheInfo(book)
    local res = self:httpGet(self:apiUrl("getShelfBookWithCacheInfo", {
        url = book.bookUrl,
    }))
    return res
end

--- 获取全部书源（legado 格式列表：bookSourceName/bookSourceUrl/bookSourceType/enabled...）
function Client:getBookSources()
    local res = self:httpGet(self:apiUrl("getBookSources"))
    assert(res.isSuccess, "获取书源失败: " .. tostring(res.errorMsg))
    return res.data or {}
end

--- 在指定书源搜索书籍（失败/无结果返回空表，不抛错，便于轮询换源）
function Client:searchBook(key, sourceUrl)
    local ok_res, res = pcall(function()
        return self:httpPost(self:apiUrl("searchBook"), {
            key = key,
            bookSourceUrl = sourceUrl,
        })
    end)
    if not ok_res or not res.isSuccess then return {} end
    return res.data or {}
end

--- 保存书籍到服务器书架（换源后更新 bookUrl/origin）
function Client:saveBook(book)
    local res = self:httpPost(self:apiUrl("saveBook"), {
        name = book.name,
        author = book.author,
        bookUrl = book.bookUrl,
        origin = book.origin,
        tocUrl = book.tocUrl or book.bookUrl,
    })
    return res.isSuccess == true
end

--- 从书架移除书籍（reader3 deleteBook；cleanupCache=true 同时清服务器缓存）
function Client:deleteBook(book)
    local res = self:httpPost(self:apiUrl("deleteBook"), {
        bookUrl = tostring(book.bookUrl or ""),
        cleanupCache = "true",
    })
    return res.isSuccess == true
end

--- 删除某本书的正文缓存（count 全部）
function Client:deleteBookCache(book)    local res = self:httpPost(self:apiUrl("deleteBookCache"), {
        bookUrl = book.bookUrl,
    })
    return res
end

--- 下载图片到内存（返回 string 或 nil, err）
function Client:downloadImage(url)
    local chunks = {}
    local _, code = http.request{
        url = url,
        sink = ltn12.sink.table(chunks),
        headers = { ["User-Agent"] = "Mozilla/5.0" },
    }
    if tonumber(code) ~= 200 then return nil, "HTTP " .. tostring(code) end
    local data = table.concat(chunks)
    if #data < 100 then return nil, "图片过小" end
    return data
end

----------------------------------------------------------------------
--- 整本预缓存：调用 GET /reader3/cacheBookSSE，消费 SSE 流
--- 后端逐章并发缓存到服务器磁盘（storage/<用户>/<书>/<章MD5>.txt）
--- @param book        书籍对象（需 bookUrl）
--- @param opts        { count=0(全部), concurrentCount=8, refresh=0 }
--- @param on_progress function(info)  每收到一条 data 事件回调
---                    info = { cachedCount=, successCount=, failedCount=, isEnd=bool }
----------------------------------------------------------------------
function Client:cacheBookSSE(book, opts, on_progress)
    opts = opts or {}
    local params = {
        url = book.bookUrl,
        bookUrl = book.bookUrl,
        count = tostring(opts.count or 0),
        concurrentCount = tostring(opts.concurrentCount or 8),
        refresh = tostring(opts.refresh or 0),
    }
    local url = self:apiUrl("cacheBookSSE", params)
    local buffer = ""
    -- SSE 事件以空行(\n\n)分隔；每次收到数据块就尝试解析完整事件
    local chunk_sink = function(chunk, err)
        if not chunk then
            -- 流结束，处理残留 buffer
            if buffer ~= "" then self:_parseSSEChunk(buffer, on_progress) end
            return true
        end
        buffer = buffer .. chunk
        -- 反复切出以 \n\n 分隔的完整事件
        while true do
            local s, e = buffer:find("\r?\n\r?\n")
            if not s then break end
            local event = buffer:sub(1, s - 1)
            buffer = buffer:sub(e + 1)
            self:_parseSSEChunk(event, on_progress)
        end
        return true
    end
    local _, code = http.request{
        url = url, method = "GET",
        sink = chunk_sink,
        headers = { ["Accept"] = "text/event-stream", ["Connection"] = "keep-alive" },
    }
    assert(tonumber(code) == 200, "预缓存请求失败: " .. tostring(code))
end

--- 解析单条 SSE 事件文本 -> 回调
function Client:_parseSSEChunk(event, on_progress)
    if not on_progress or not event then return end
    local is_end = false
    local data_line = nil
    for line in event:gmatch("[^\r\n]+") do
        if line:sub(1, 6) == "event:" then
            if line:sub(7):match("end") then is_end = true end
        elseif line:sub(1, 5) == "data:" then
            data_line = line:sub(6):gsub("^%s+", "")
        end
    end
    if data_line then
        local ok, info = pcall(json.decode, data_line)
        if ok and type(info) == "table" then
            info.isEnd = is_end
            on_progress(info)
        end
    end
end

return Client
