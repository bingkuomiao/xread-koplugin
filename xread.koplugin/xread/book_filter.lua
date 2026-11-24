-- 书籍类型过滤：书架/首页/阅读记录只保留小说与漫画，
-- 过滤掉视频类条目（纪录片/动画/短片/综艺等影视分类）。
-- 判断依据是书架条目的 kind 字段关键词黑名单——当前书源里
-- 小说/漫画的 kind 为空、数字标签（漫画站）或文学分类词，
-- 视频类 kind 固定含影视关键词，黑名单不会误伤。

local BookFilter = {}

-- 视频类分类关键词（kind 子串匹配，纯文本匹配非正则）
local VIDEO_PATTERNS = {
    "纪录片", "动画", "短片", "电影", "电视剧", "综艺",
    "影视", "预告", "正片", "花絮", "有声", "动漫",
}

function BookFilter.isVideoBook(book)
    if type(book) ~= "table" then return false end
    local kind = tostring(book.kind or "")
    if kind == "" then return false end
    for _, p in ipairs(VIDEO_PATTERNS) do
        if kind:find(p, 1, true) then return true end
    end
    return false
end

-- 过滤出可阅读的书（小说/漫画），返回新表
function BookFilter.filterReadable(books)
    local out = {}
    for _, b in ipairs(books or {}) do
        if not BookFilter.isVideoBook(b) then
            out[#out + 1] = b
        end
    end
    return out
end

-- 按标题过滤（用于阅读记录：统计库条目只有标题）
function BookFilter.isVideoTitle(title)
    local t = tostring(title or "")
    if t == "" then return false end
    for _, p in ipairs(VIDEO_PATTERNS) do
        if t:find(p, 1, true) then return true end
    end
    return false
end

return BookFilter
