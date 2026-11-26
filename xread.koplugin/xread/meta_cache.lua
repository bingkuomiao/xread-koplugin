-- xread.koplugin/xread/meta_cache.lua
-- 轻量元数据缓存：书架列表 / 章节目录，落到本地 JSON。
-- 目的：进书架、开书不再每次都等网络；缓存命中秒开，后台再静默刷新。
-- 所有读写都有 pcall 保护，坏缓存直接视为未命中，绝不影响主流程。

local DataStorage = require("datastorage")
local util        = require("util")

local json
pcall(function() json = require("json") end)
if not json then pcall(function() json = require("dkjson") end) end

local MetaCache = {}
MetaCache.__index = MetaCache

local function hash(s)
    local h = 5381
    s = tostring(s or "")
    for i = 1, #s do h = (h * 33 + s:byte(i)) % 4294967296 end
    return string.format("%08x", h)
end

local function readJson(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    if type(s) ~= "string" or #s < 2 then return nil end
    local ok, data = pcall(function() return json.decode(s) end)
    if ok and type(data) == "table" then return data end
    return nil
end

local function writeJson(path, data)
    local ok, s = pcall(function() return json.encode(data) end)
    if not ok or type(s) ~= "string" then return nil end
    local f = io.open(path, "w")
    if not f then return nil end
    f:write(s)
    f:close()
    return path
end

function MetaCache:new(root)
    local dir = root or (DataStorage:getDataDir() .. "/xread_books/meta")
    util.makePath(dir)
    return setmetatable({ dir = dir }, self)
end

function MetaCache:shelfPath()
    return self.dir .. "/shelf.json"
end

-- 读书架缓存。max_age 秒；返回 nil 表示未命中/过期。
function MetaCache:getShelf(max_age)
    local d = readJson(self:shelfPath())
    if not d or type(d.books) ~= "table" or #d.books == 0 then return nil end
    if max_age and os.time() - (tonumber(d.time) or 0) > max_age then return nil end
    return d.books
end

function MetaCache:putShelf(books)
    if type(books) ~= "table" or #books == 0 then return nil end
    return writeJson(self:shelfPath(), { time = os.time(), books = books })
end

-- 清掉书架缓存（下次读取走网络），用于「更新」按钮与进度同步后强制刷新
function MetaCache:clearShelf()
    pcall(os.remove, self:shelfPath())
end

-- 开书/手动同步后把最新章进度写进缓存里的对应书条目，
-- 让首页「最近阅读」卡片实时反映刚读的书（不用等缓存过期）
-- when_ts：本次进度的时间戳（默认当前时间）。同步时用它和服务器端的
-- durChapterTime 比较，避免把几周前的旧本地进度推上去覆盖其它设备的新进度。
function MetaCache:updateShelfProgress(book_url, dur_index, when_ts)
    local d = readJson(self:shelfPath())
    if not d or type(d.books) ~= "table" then return nil end
    local changed = false
    for _i, b in ipairs(d.books) do
        if tostring(b.bookUrl or "") == tostring(book_url or "") then
            b.durChapterIndex = tonumber(dur_index) or b.durChapterIndex
            b.durChapterTime = tonumber(when_ts) or os.time()
            changed = true
            break
        end
    end
    if changed then
        d.time = os.time()
        return writeJson(self:shelfPath(), d)
    end
    return nil
end

function MetaCache:chaptersPath(book)
    local key = hash(book.bookUrl or book.name or "book")
    return self.dir .. "/chapters_" .. key .. ".json"
end

-- 读目录缓存。total 变化时（后端目录有更新）自动失效。
function MetaCache:getChapters(book, max_age)
    local d = readJson(self:chaptersPath(book))
    if not d or type(d.chapters) ~= "table" or #d.chapters == 0 then return nil end
    local total = tonumber(book.totalChapterNum or 0)
    local cached_total = tonumber(d.total or 0)
    if total > 0 and cached_total > 0 and total ~= cached_total then return nil end
    if max_age and os.time() - (tonumber(d.time) or 0) > max_age then return nil end
    return d.chapters
end

function MetaCache:putChapters(book, chapters)
    if type(chapters) ~= "table" or #chapters == 0 then return nil end
    return writeJson(self:chaptersPath(book), {
        time = os.time(),
        total = tonumber(book.totalChapterNum or 0),
        chapters = chapters,
    })
end

return MetaCache
