-- xread.koplugin/xread/client.lua
-- 网络层：封装 xread-fpk /reader3/* 的接口
-- 逻辑来自已实测通过的 test_network.lua，只依赖 KOReader 自带模块
--   (socket.http / ltn12 / dkjson)，无需额外安装
--
-- 超时：所有请求都走 xread/http_client，单请求可指定超时且结束后必定恢复全局值。
-- 绝不再写 `http.TIMEOUT = 12`（会把 KOReader 自己的 OPDS/同步/词典一并改掉）。

local ltn12 = require("ltn12")
local HttpClient = require("xread/http_client")

local json
local ok_json = pcall(function() json = require("json") end)   -- KOReader 内置 json
if not ok_json then json = require("dkjson") end               -- 桌面/测试环境回退

local Client = {}
Client.__index = Client

-- 全部请求的默认超时（秒）。
-- 之前不传 timeout 的请求会沿用 KOReader 全局 TIMEOUT（常见 12~60s），
-- 地址填错时整机 UI 会被同步 socket 冻住几十秒，且用户看不到任何反馈。
-- 这里统一收紧到 8s，配合 main.lua 的后端快速探测（2.5s）使用。
Client.DEFAULT_TIMEOUT = 8

--- URL 编码（query/表单参数用）
local function urlencode(str)
    if not str then return "" end
    str = tostring(str):gsub("\r\n", "\n"):gsub("\n", "\r\n")
    return (str:gsub("([^%w%-_%.~])", function(c)
        return string.format("%%%02X", string.byte(c))
    end))
end

--- 安全地把码点转成 UTF-8 字符
-- 关键：**不能**用 utf8.char。utf8 是 Lua 5.3+ 的标准库，KOReader 跑在 LuaJIT
-- （Lua 5.1 语义）上根本没有这个全局表，调用会抛 "attempt to index global 'utf8'"
-- 并连带整章正文失败。这里用纯字节运算自己编码，5.1 / LuaJIT / 5.4 全通用。
-- 非法码点（代理区、超出 Unicode 上限、负数）直接丢弃，宁缺不乱码。
-- @return string UTF-8 字节串（非法时返回 ""）
local function codePointToChar(cp)
    cp = tonumber(cp)
    if not cp or cp ~= cp then return "" end
    cp = math.floor(cp)
    if cp < 0 or cp > 0x10FFFF or (cp >= 0xD800 and cp <= 0xDFFF) then
        return ""
    end
    if cp < 0x80 then
        return string.char(cp)
    elseif cp < 0x800 then
        return string.char(
            0xC0 + math.floor(cp / 0x40),
            0x80 + (cp % 0x40))
    elseif cp < 0x10000 then
        return string.char(
            0xE0 + math.floor(cp / 0x1000),
            0x80 + (math.floor(cp / 0x40) % 0x40),
            0x80 + (cp % 0x40))
    end
    return string.char(
        0xF0 + math.floor(cp / 0x40000),
        0x80 + (math.floor(cp / 0x1000) % 0x40),
        0x80 + (math.floor(cp / 0x40) % 0x40),
        0x80 + (cp % 0x40))
end

--- HTML 正文 -> 纯文本
-- 后端返回的是网页 HTML（<div class="con"><p>...</p>...），需转成可阅读的纯文本。
-- 处理：剔脚本/样式块、img 保留占位、块级标签转换行、去标签、解实体、合并空行。
local function htmlToText(s)
    if type(s) ~= "string" then return tostring(s or "") end
    local text = s

    -- ① 先整块剔掉 script/style 的内容。
    -- 只靠后面对 "<[^>]+>" 去标签是不够的：标签内的 CSS/JS 文本会原样留在正文里，
    -- 表现为章节开头突然出现一段 ".con{...}" 或 "var a=..."。
    text = text:gsub("<%s*script[^>]*>.-<%s*/%s*script%s*>", "")
    text = text:gsub("<%s*style[^>]*>.-<%s*/%s*style%s*>", "")
    -- 无闭合的残块：从 <script 一直吃到文末，宁可丢内容也不显示源码
    text = text:gsub("<%s*script[^>]*>.*$", "")
    text = text:gsub("<%s*style[^>]*>.*$", "")

    -- ② 漫画图片：转成占位提示（KOReader TXT 不显示图片）
    local img_count = 0
    text = text:gsub("<img[^>]-src=[\"']([^\"']+)[\"'][^>]-/?>", function(src)
        img_count = img_count + 1
        return "\n[图 " .. img_count .. "]\n"
    end)
    -- ③ 块级标签转换行
    text = text:gsub("<%s*br%s*/?%s*>", "\n")
    text = text:gsub("</%s*p%s*>", "\n")
    text = text:gsub("<%s*p[^>]*>", "\n")
    text = text:gsub("</%s*div%s*>", "\n")
    text = text:gsub("<%s*div[^>]*>", "\n")
    text = text:gsub("</%s*(h%d?|li|tr|table)[^>]*>", "\n")
    -- ④ 去掉其余所有标签
    text = text:gsub("<[^>]+>", "")
    -- ⑤ 解 HTML 实体（命名实体 -> 字符；数字实体 -> UTF-8 字符）
    local entities = {
        nbsp = " ", amp = "&", lt = "<", gt = ">", quot = "\"", apos = "'",
        hellip = "…", mdash = "—", ndash = "–", ldquo = "“", rdquo = "”",
        lsquo = "‘", rsquo = "’", middot = "·",
    }
    text = text:gsub("&([%a][%a%d]*);", function(name)
        return entities[name] or ("&" .. name .. ";")
    end)
    -- 十进制实体 &#20013; = "中"。历史写法 string.char(n % 256) 会把中文变成 "-"。
    text = text:gsub("&#(%d+);", function(n) return codePointToChar(tonumber(n)) end)
    -- 十六进制实体 &#x4E2D;
    text = text:gsub("&#[xX](%x+);", function(n) return codePointToChar(tonumber(n, 16)) end)
    -- ⑥ 合并 >=3 的连续换行为 2 个，去掉行首行尾空白，去全角空格缩进
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
        secureKey = nil,
        userNS = nil,
        username = nil,
        password = nil,
    }, self)
end

--- 检查后端连通性
-- 新后端把 health 放在根路径 /health；旧后端在 /reader3/health。
-- 先试根路径，失败再回退到 /reader3/health，二者都兼容。
-- 超时给短（2.5s）：这条路径是「测试连接」和自检用的，用户等不起。
function Client:health(opts)
    opts = opts or {}
    local t = tonumber(opts.timeout) or 2.5
    local ok_res, res = pcall(function()
        return self:httpGet(self.address .. "/health", { timeout = t })
    end)
    if ok_res and type(res) == "table" and res.isSuccess ~= nil then
        return res
    end
    return self:httpGet(self.address .. "/reader3/health", { timeout = t })
end

--- 登录，成功后自动保存鉴权参数（封面本地资源接口需要）
function Client:login(username, password)
    self.username, self.password = username, password
    local res = self:httpPost(self.address .. "/reader3/login", {
        isLogin = true, username = username, password = password, code = "",
    }, { timeout = 5 })
    assert(res.isSuccess, "登录失败: " .. tostring(res.errorMsg))
    self.accessToken = res.data and res.data.accessToken
    self.secureKey = res.data and res.data.secureKey
    self.userNS = res.data and res.data.userNS
    return res
end

--- 统一 URL 拼接（对应前端 url() 函数逻辑）
-- 注意：token 仍放在 query 上（老版本后端只认这个），同时 _authHeaders 会把
-- Authorization / X-Secure-Key / X-User-NS 一并带上（新版本契约）。
function Client:apiUrl(router, params)
    local url = self.address .. "/reader3/" .. router .. "?v=" .. os.time()
    if self.accessToken then
        url = url .. "&accessToken=" .. urlencode(self.accessToken)
    end
    if params then
        for k, v in pairs(params) do
            if v ~= nil then
                url = url .. "&" .. k .. "=" .. urlencode(v)
            end
        end
    end
    return url
end

--- 鉴权头（接口文档 1.0.48.205+ 的官方约定：裸 token / secureKey / userNS）
-- 新后端三种都认；老后端忽略未知头，所以无条件加上是安全的。
function Client:_authHeaders(extra)
    local h = {
        ["Accept"] = "application/json",
    }
    if self.accessToken and self.accessToken ~= "" then
        h["Authorization"] = tostring(self.accessToken)
    end
    if self.secureKey and self.secureKey ~= "" then
        h["X-Secure-Key"] = tostring(self.secureKey)
    end
    if self.userNS and tostring(self.userNS) ~= "" then
        h["X-User-NS"] = tostring(self.userNS)
    end
    if extra then
        for k, v in pairs(extra) do h[k] = v end
    end
    return h
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

--- 鉴权失败判定
-- 后端两种表现都要认：HTTP 401/403，以及 HTTP 200 但 isSuccess=false 且提示里带
-- token/登录/未授权（部分版本的 reader3 走后者）。
local function isAuthFailure(code, data)
    code = tonumber(code)
    if code == 401 or code == 403 then return true end
    if code == 200 and type(data) == "table" and data.isSuccess == false then
        local msg = tostring(data.errorMsg or "")
        local lower = msg:lower()
        if lower:find("token", 1, true) or msg:find("登录", 1, true)
            or msg:find("未授权", 1, true) or lower:find("unauthorized", 1, true) then
            return true
        end
    end
    return false
end

--- 底层 GET：返回 ok, code, data(已清洗), raw_body
function Client:_rawGet(url, timeout)
    local chunks = {}
    local ok, code, _, err = HttpClient.request({
        url = url, sink = ltn12.sink.table(chunks),
        headers = self:_authHeaders(),
    }, timeout)
    local body = table.concat(chunks)
    if not ok then return false, nil, nil, (err and tostring(err) or body) end
    local data
    if body and body ~= "" then
        local ok_json_decode, decoded = pcall(json.decode, body)
        if ok_json_decode then data = sanitizeJson(decoded) end
    end
    return true, code, data, body
end

--- 底层 POST(JSON body)：返回 ok, code, data(已清洗), raw_body
function Client:_rawPost(url, obj, timeout)
    local payload = json.encode(obj)
    local chunks = {}
    local ok, code, _, err = HttpClient.request({
        url = url, method = "POST",
        source = ltn12.source.string(payload),
        headers = self:_authHeaders({
            ["Content-Type"] = "application/json; charset=utf-8",
            ["Content-Length"] = tostring(#payload),
        }),
        sink = ltn12.sink.table(chunks),
    }, timeout)
    local body = table.concat(chunks)
    if not ok then return false, nil, nil, (err and tostring(err) or body) end
    local data
    if body and body ~= "" then
        local ok_json_decode, decoded = pcall(json.decode, body)
        if ok_json_decode then data = sanitizeJson(decoded) end
    end
    return true, code, data, body
end

--- token 失效后自愈：用已保存的账号重登一次
-- 用 _reauthorizing 标志挡住 login 内部 httpPost 的递归重登，防止死循环。
-- @return true 表示已拿到新 token
function Client:_reauthorize()
    if self._reauthorizing then return false end
    if self.username == nil or self.password == nil then return false end
    self._reauthorizing = true
    local ok = pcall(function()
        local res = self:httpPost(self.address .. "/reader3/login", {
            isLogin = true, username = self.username, password = self.password, code = "",
        }, { _no_auth_retry = true, timeout = 5 })
        assert(res and res.isSuccess, "重登失败")
        self.accessToken = res.data and res.data.accessToken
        self.secureKey = res.data and res.data.secureKey
        self.userNS = res.data and res.data.userNS
    end)
    self._reauthorizing = false
    if not ok then self.accessToken = nil end
    return ok
end

--- 发起请求并在鉴权失败时自愈重试一次
-- @param opts { timeout=number, _no_auth_retry=boolean, _retried=boolean }
-- @return ok, code, data, raw
function Client:_request(method, url, obj, opts)
    opts = opts or {}
    local timeout = tonumber(opts.timeout) or Client.DEFAULT_TIMEOUT
    local function once(t)
        if method == "GET" then
            return self:_rawGet(url, t)
        end
        return self:_rawPost(url, obj, t)
    end
    local ok, code, data, raw = once(timeout)
    if ok and isAuthFailure(code, data) and not opts._no_auth_retry then
        if self:_reauthorize() then
            ok, code, data, raw = once(timeout)   -- 只重试一次
        end
    end
    return ok, code, data, raw
end

--- GET 请求 -> table
-- @param opts 可选 { timeout=秒 }
function Client:httpGet(url, opts)
    local ok, code, data, raw = self:_request("GET", url, nil, opts)
    if not ok then
        error("HTTP GET 失败: 网络错误 " .. tostring(raw), 0)
    end
    assert(tonumber(code) == 200, "HTTP GET 失败: " .. tostring(code))
    assert(data, "JSON 解析失败")
    return data
end

--- POST 请求(JSON body) -> table
-- 非 200 时尽量解析后端 errorMsg，给出简洁错误（不回显 URL/token）
-- @param opts 可选 { timeout=秒, retry=boolean }
--   retry=true 只用于**幂等**接口（读目录/读正文/搜索）。saveBook / deleteBook /
--   saveBookProgress 这类写操作绝不能重试，否则服务器会执行两次。
function Client:httpPost(url, obj, opts)
    if opts == true then opts = { retry = true } end        -- 兼容旧的布尔第三参
    opts = opts or {}
    local ok, code, data, raw = self:_request("POST", url, obj, opts)
    if not ok then
        error("网络错误：" .. tostring(raw or data), 0)
    end
    code = tonumber(code)
    if code ~= 200 then
        -- 5xx 且调用方声明幂等：重试一次（_retried 防无限递归）
        -- （code 理论上不会是 nil，但 (code or 0) 兜底，避免 nil 比较抛错）
        if opts.retry and (code or 0) >= 500 and not opts._retried then
            return self:httpPost(url, obj, {
                retry = true, _retried = true, timeout = opts.timeout,
            })
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

--- 获取书架
-- 接口文档 1.0.48.205+ 把这个接口定成「唯一、干净、无副作用」的书架读接口：
-- 入参为空、返回顺序即书架物理顺序（新书在前），展示字段由后端统一清洗。
-- 因此不再带 refresh 参数（新后端会忽略；老后端也只会多扫一次书源，纯浪费）。
-- 旧调用点里的 getBookshelf(true) 保留形参，只是不再影响请求。
function Client:getBookshelf(_refresh, opts)
    opts = opts or {}
    local res = self:httpGet(self:apiUrl("getBookshelf"),
        { timeout = tonumber(opts.timeout) or 8 })
    assert(res.isSuccess, "获取书架失败: " .. tostring(res.errorMsg))
    return res.data or {}
end

--- 获取某本书的目录（幂等读接口，允许 5xx 重试一次）
-- @param opts 可选 { refresh=1|0, timeout=秒 }
--   refresh=1 让后端重新从书源抓目录（慢，只在用户显式刷新/缓存过期后台刷新时用）；
--   refresh=0 吃后端已有缓存（点书秒开用这个）。
function Client:getChapterList(book, opts)
    opts = opts or {}
    local refresh = opts.refresh
    if refresh == nil then refresh = 1 end
    local ok_res, res = pcall(function()
        return self:httpPost(self:apiUrl("getChapterList"), {
            refresh = refresh, url = book.bookUrl,
        }, { retry = true, timeout = tonumber(opts.timeout) or 8 })
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
    }, { retry = true, timeout = 10 })
    assert(res.isSuccess, "获取正文失败: " .. tostring(res.errorMsg))
    return htmlToText(res.data or "")
end

--- 获取某一章的原始 HTML（漫画需提取图片 URL）
function Client:getBookContentRaw(chapter, book)
    local res = self:httpPost(self:apiUrl("getBookContent"), {
        chapterUrl = chapter.url or chapter.chapterUrl,
        bookSourceUrl = book.origin,
        refresh = 0,
    }, { retry = true, timeout = 10 })
    assert(res.isSuccess, "获取正文失败: " .. tostring(res.errorMsg))
    return res.data or ""
end

--- 从 HTML 中提取所有图片 URL
-- 覆盖三种常见写法：src、懒加载 data-src / data-original、srcset、以及 <source>。
-- 懒加载漫画如果只认 src，会得到一堆 data:image/gif 占位图（或直接漏图）。
function Client:extractImageUrls(html)
    local urls = {}
    if type(html) ~= "string" then return urls end
    local seen = {}
    local function push(u)
        if type(u) ~= "string" then return end
        u = u:gsub("^%s+", ""):gsub("%s+$", "")
        if u == "" or u:sub(1, 5) == "data:" then return end
        if seen[u] then return end
        seen[u] = true
        urls[#urls + 1] = u
    end
    -- <img>/<source> 标签内部：优先懒加载属性，其次 src
    for tag in html:gmatch("<%s*[Ii][Mm][Gg][^>]*>") do
        local u = tag:match("[Dd][Aa][Tt][Aa]%-[Oo][Rr][Ii][Gg][Ii][Nn][Aa][Ll]%s*=%s*[\"']([^\"']+)[\"']")
            or tag:match("[Dd][Aa][Tt][Aa]%-[Ss][Rr][Cc]%s*=%s*[\"']([^\"']+)[\"']")
            or tag:match("[Ss][Rr][Cc]%s*=%s*[\"']([^\"']+)[\"']")
        if u then push(u) end
        -- srcset="a.jpg 1x, b.jpg 2x"：取第一段
        local srcset = tag:match("[Ss][Rr][Cc][Ss][Ee][Tt]%s*=%s*[\"']([^\"']+)[\"']")
        if srcset then push(srcset:match("^%s*([^,]+)")) end
    end
    for tag in html:gmatch("<%s*[Ss][Oo][Uu][Rr][Cc][Ee][^>]*>") do
        local u = tag:match("[Ss][Rr][Cc][Ss][Ee][Tt]%s*=%s*[\"']([^\"']+)[\"']")
            or tag:match("[Ss][Rr][Cc]%s*=%s*[\"']([^\"']+)[\"']")
        if u then push(u:match("^%s*([^,]+)")) end
    end
    return urls
end

--- 保存阅读进度（写操作，不重试）
function Client:saveBookProgress(book, index)
    local res = self:httpPost(self:apiUrl("saveBookProgress"), {
        url = book.bookUrl, index = index, name = book.name, author = book.author,
    }, { timeout = 5 })
    return res
end

--- 获取后端版本（getVersionUpdate 的 currentVersion；失败返回 nil，不影响调用方）
function Client:getServerVersion()
    local ok, res = pcall(function()
        return self:httpGet(self:apiUrl("getVersionUpdate"), { timeout = 2.5 })
    end)
    if ok and res.isSuccess and type(res.data) == "table" then
        local v = res.data.currentVersion
        if v and v ~= "" then return tostring(v) end
    end
    return nil
end

--- 带缓存信息的书架（接口文档 3.2）
-- ⚠️ 契约变更：1.0.48.205 起**无入参**，返回整个书架数组，每本书多一个
-- cachedChapterCount 字段（服务端已缓存章节数）；旧版本传 url 只返回单本。
-- 另外它会在后台触发目录预取（延迟 15s、限流 8 本），比 getBookshelf 重，
-- 所以只有真的要显示「服务器已缓存 N 章」时才调它。
-- @return Book[]（每项带 cachedChapterCount）
function Client:getShelfBookWithCacheInfo(opts)
    opts = opts or {}
    local res = self:httpGet(self:apiUrl("getShelfBookWithCacheInfo"),
        { timeout = tonumber(opts.timeout) or 8 })
    if type(res) ~= "table" or not res.isSuccess then
        error("获取书架缓存信息失败: " .. tostring(res and res.errorMsg), 0)
    end
    local data = res.data
    if type(data) ~= "table" then return {} end
    -- 兼容旧后端（传 url 时返回单个 Book 对象）
    if data.bookUrl or data.name then return { data } end
    return data
end

--- 从 getShelfBookWithCacheInfo 的结果里取某本书的服务器缓存章节数
-- @return number|nil
function Client:cachedChapterCountOf(books, book)
    if type(books) ~= "table" or not book then return nil end
    local want = tostring(book.bookUrl or "")
    for _i, b in ipairs(books) do
        if want ~= "" and tostring(b.bookUrl or "") == want then
            return tonumber(b.cachedChapterCount)
        end
    end
    return nil
end

--- 获取全部书源（legado 格式列表：bookSourceName/bookSourceUrl/bookSourceType/enabled...）
function Client:getBookSources()
    local res = self:httpGet(self:apiUrl("getBookSources"), { timeout = 8 })
    assert(res.isSuccess, "获取书源失败: " .. tostring(res.errorMsg))
    return res.data or {}
end

--- 在指定书源搜索书籍（失败/无结果返回空表，不抛错，便于轮询换源）
-- @param timeout 可选，单次搜索超时秒数（多源轮询时给短超时）
function Client:searchBook(key, sourceUrl, timeout)
    local ok_res, res = pcall(function()
        return self:httpPost(self:apiUrl("searchBook"), {
            key = key,
            bookSourceUrl = sourceUrl,
        }, { retry = true, timeout = timeout })
    end)
    if not ok_res or not res.isSuccess then return {} end
    return res.data or {}
end

--- 保存书籍到服务器书架（换源后更新 bookUrl/origin；搜书加入书架）
-- 契约变更（1.0.48.205+）：新书由后端插到书架**最前面**（insert(0)），已存在的书
-- 更新时保持原位；展示字段由后端清洗。所以本地缓存不能再假设「新书在末尾」，
-- 保存后要拉一次 getBookshelf 重排（调用方已经这么做）。
-- @return 保存后的 Book（失败返回 false）
function Client:saveBook(book)
    local res = self:httpPost(self:apiUrl("saveBook"), {
        name = book.name,
        author = book.author,
        bookUrl = book.bookUrl,
        origin = book.origin,
        tocUrl = book.tocUrl or book.bookUrl,
        coverUrl = book.coverUrl,
        intro = book.intro,
        kind = book.kind,
        wordCount = book.wordCount,
    }, { timeout = 8 })
    if res.isSuccess ~= true then return false end
    if type(res.data) == "table" then return res.data end
    return true
end

--- 从书架移除书籍（reader3 deleteBook；cleanupCache=true 同时清服务器缓存）
function Client:deleteBook(book)
    local res = self:httpPost(self:apiUrl("deleteBook"), {
        bookUrl = tostring(book.bookUrl or ""),
        cleanupCache = "true",
    }, { timeout = 10 })
    return res.isSuccess == true
end

--- 删除某本书的正文缓存（count 全部）
function Client:deleteBookCache(book)
    local res = self:httpPost(self:apiUrl("deleteBookCache"), {
        bookUrl = book.bookUrl,
    }, { timeout = 10 })
    return res
end

--- 图片单张最大字节数（默认 12MB）：超过就中断，避免异常响应把内存打满
local MAX_IMAGE_BYTES = 12 * 1024 * 1024

--- 下载图片到内存（返回 string 或 nil, err）
-- 用自定义 sink 做两件事：限制累计大小、超限立刻中断传输。
function Client:downloadImage(url, max_bytes)
    local limit = tonumber(max_bytes) or MAX_IMAGE_BYTES
    local chunks, total, overflow = {}, 0, false
    local sink = function(chunk, err)
        if not chunk then return 1 end          -- 流结束
        total = total + #chunk
        if total > limit then
            overflow = true
            return nil, "image too large"       -- 非 nil 的第一个值会让 http 中断
        end
        chunks[#chunks + 1] = chunk
        return 1
    end
    local ok, code = HttpClient.request({
        url = url,
        sink = sink,
        headers = { ["User-Agent"] = "Mozilla/5.0" },
    }, 20)
    if not ok then return nil, "网络错误" end
    if overflow then return nil, "图片超过 " .. tostring(math.floor(limit / 1024)) .. "KB 上限" end
    if tonumber(code) ~= 200 then return nil, "HTTP " .. tostring(code) end
    local data = table.concat(chunks)
    if #data < 100 then return nil, "图片过小" end
    return data
end

----------------------------------------------------------------------
--- 整本预缓存：调用 GET /reader3/cacheBookSSE，消费 SSE 流
--- 后端逐章并发缓存到服务器磁盘（storage/<用户>/<书>/<章MD5>.txt）
--- @param book        书籍对象（需 bookUrl）
--- @param opts        { count=0(全部), concurrentCount=8, refresh=0, timeout=秒 }
--- @param on_progress function(info)  每收到一条 data 事件回调
---                    info = { cachedCount=, successCount=, failedCount=, isEnd=bool }
--- 注意：这是长连接，调用方必须放到子进程/协程里跑，不要占 UI 线程（见 main.lua）。
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
    -- 长连接：默认不设总超时（timeout=nil 表示沿用当前全局值），
    -- 由调用方的子进程/可取消进度控制生命周期。
    local ok, code = HttpClient.request({
        url = url, method = "GET",
        sink = chunk_sink,
        headers = { ["Accept"] = "text/event-stream", ["Connection"] = "keep-alive" },
    }, opts.timeout)
    if not ok then
        error("预缓存请求网络错误", 0)
    end
    assert(tonumber(code) == 200, "预缓存请求失败: " .. tostring(code))
end

--- 解析单条 SSE 事件文本 -> 回调
function Client:_parseSSEChunk(event, on_progress)
    if not on_progress or not event then return end
    local is_end = false
    local data_line = nil
    for line in event:gmatch("[^\r\n]+") do
        if line:sub(1, 6) == "event:" then
            -- 事件名必须整体比较。原来用 sub(7):match("end") 是子串匹配，
            -- "event: pending" / "event: append" 都会被误判成结束。
            local name = line:sub(7):gsub("^%s+", ""):gsub("%s+$", ""):lower()
            if name == "end" or name == "done" or name == "complete" or name == "finished" then
                is_end = true
            end
        elseif line:sub(1, 5) == "data:" then
            data_line = line:sub(6):gsub("^%s+", "")
        end
    end
    if data_line then
        local ok, info = pcall(json.decode, data_line)
        if ok and type(info) == "table" then
            -- 后端在 data 里自带 isEnd 时以它为准，event 名只作为补充信号
            info.isEnd = info.isEnd == true or is_end
            on_progress(info)
        end
    end
end

return Client
