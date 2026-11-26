-- xread.koplugin/xread/chapter_cache.lua
-- 每章正文的本地分片缓存：<data>/xread_books/chapters/<书名-hash>/00037.txt
-- 作用：第二次打开同一本书时可以直接拼 TXT 秒开，不必再等网络。

local DataStorage = require("datastorage")
local util        = require("util")
local lfs         = require("libs/libkoreader-lfs")

local ChapterCache = {}
ChapterCache.__index = ChapterCache

local function safeName(s)
    s = tostring(s or "book"):gsub("[%/\\:%*%?\"<>|]", "_")
    if #s > 60 then s = s:sub(1, 60) end
    return s
end

-- 简单 DJB2 散列，避免同名不同书互相覆盖
local function hash(s)
    local h = 5381
    s = tostring(s or "")
    for i = 1, #s do
        h = (h * 33 + s:byte(i)) % 4294967296
    end
    return string.format("%08x", h)
end

-- dirFor 缓存上限：超过就整体清空，避免长时间运行后无限增长
local DIR_CACHE_MAX = 500

function ChapterCache:new(root)
    local dir = root or (DataStorage:getDataDir() .. "/xread_books/chapters")
    util.makePath(dir)
    return setmetatable({ root = dir, _dir_cache = {} }, self)
end

--- 书籍缓存目录
-- 原来每次都重算 safeName + 逐字节 hash。目录页逐章 has() 会把它调成几百次，
-- 这里按「书标识」缓存结果，重复调用直接命中。
function ChapterCache:dirFor(book)
    local id = tostring(book.bookUrl or book.name or "book")
    local cache = self._dir_cache
    if cache and cache[id] then return cache[id] end
    local key = safeName(book.name or book.bookUrl) .. "-" .. hash(book.bookUrl or book.name)
    local dir = self.root .. "/" .. key
    if cache then
        local n = 0
        for _ in pairs(cache) do n = n + 1 end
        if n >= DIR_CACHE_MAX then
            cache = {}
            self._dir_cache = cache
        end
        cache[id] = dir
    end
    return dir
end

function ChapterCache:pathFor(book, index)
    return string.format("%s/%05d.txt", self:dirFor(book), index)
end

--- 只查文件存在性，不读正文
-- 用 lfs.attributes 而不是 io.open：省掉一次 open/close 系统调用，
-- 目录页对 3000 章逐章判断时差别明显（S7 的工具栏卡顿根因就在这里）。
function ChapterCache:has(book, index)
    local path = self:pathFor(book, index)
    if not path then return false end
    if lfs.attributes(path, "mode") == "file" then
        return true
    end
    -- 兜底：lfs 不可用时退回 open 探测
    local f = io.open(path, "r")
    if not f then return false end
    f:close()
    return true
end

function ChapterCache:get(book, index)
    local f = io.open(self:pathFor(book, index), "r")
    if not f then return nil end
    local data = f:read("*a")
    f:close()
    if not data or data == "" then return nil end
    return data
end

--- 原子写入：先写 .tmp 再 rename 覆盖
-- 原实现直接写目标文件：写一半被杀/断电，就会留下半截正文，
-- 而缓存没有校验机制，下次会把这半截当成整章读进来，且永远不会自愈。
function ChapterCache:put(book, index, text)
    if not text or text == "" then return nil end
    util.makePath(self:dirFor(book))
    local path = self:pathFor(book, index)
    local tmp = path .. ".tmp"
    local f = io.open(tmp, "w")
    if not f then return nil end
    local okw = f:write(text)
    f:close()
    if not okw then
        os.remove(tmp)
        return nil
    end
    if os.rename(tmp, path) then return path end
    -- rename 不可用时（个别文件系统）退化为直接覆盖写
    os.remove(tmp)
    local f2 = io.open(path, "w")
    if not f2 then return nil end
    local okw2 = f2:write(text)
    f2:close()
    if not okw2 then
        os.remove(path)
        return nil
    end
    return path
end

--- 删除整本书的章节缓存目录（删书时调用）
function ChapterCache:remove(book)
    local dir = self:dirFor(book)
    pcall(function()
        local ok_util = pcall(require, "ffi/util")
        if ok_util then
            require("ffi/util").purgeDir(dir)
            return
        end
        os.remove(dir)
    end)
    if self._dir_cache then self._dir_cache[tostring(book.bookUrl or book.name or "book")] = nil end
end

return ChapterCache
