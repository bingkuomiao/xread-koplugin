-- xread.koplugin/xread/chapter_cache.lua
-- 每章正文的本地分片缓存：<data>/xread_books/chapters/<书名-hash>/00037.txt
-- 作用：第二次打开同一本书时可以直接拼 TXT 秒开，不必再等网络。

local DataStorage = require("datastorage")
local util        = require("util")

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

function ChapterCache:new(root)
    local dir = root or (DataStorage:getDataDir() .. "/xread_books/chapters")
    util.makePath(dir)
    return setmetatable({ root = dir }, self)
end

function ChapterCache:dirFor(book)
    local key = safeName(book.name or book.bookUrl) .. "-" .. hash(book.bookUrl or book.name)
    return self.root .. "/" .. key
end

function ChapterCache:pathFor(book, index)
    return string.format("%s/%05d.txt", self:dirFor(book), index)
end

function ChapterCache:has(book, index)
    -- 目录页高亮用：只查文件存在性，不读正文
    local path = self:pathFor(book, index)
    if not path then return false end
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

function ChapterCache:put(book, index, text)
    if not text or text == "" then return nil end
    util.makePath(self:dirFor(book))
    local path = self:pathFor(book, index)
    local f = io.open(path, "w")
    if not f then return nil end
    f:write(text)
    f:close()
    return path
end

return ChapterCache
