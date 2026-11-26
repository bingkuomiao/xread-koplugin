-- 书籍类型过滤：书架/首页/阅读记录只保留小说与漫画，
-- 过滤掉视频类条目（纪录片/动画片/短片/综艺等影视分类）。
-- 判断依据是书架条目的 kind 字段关键词黑名单。
--
-- 注意「动画 / 动漫」不能单独当视频特征：很多漫画书源把漫画归到这两个分类，
-- 直接拉黑会把整本漫画过滤掉（整本书从书架消失）。只有同时带视频语境词
-- （片/剧/视频/影视/集）时才判定为视频。

local BookFilter = {}

-- 明确的视频类关键词（子串匹配，纯文本非正则）
local VIDEO_PATTERNS = {
    "纪录片", "短片", "电影", "电视剧", "综艺",
    "预告", "正片", "花絮", "有声书", "影视剧",
}

-- 含糊的分类词：需叠加视频语境词才算视频
local AMBIGUOUS_PATTERNS = { "动画", "动漫" }

-- 视频语境词
local VIDEO_QUALIFIERS = { "片", "剧", "视频", "影视", "集" }

--- 单条文本是否命中视频类特征
local function isVideoText(s)
    s = tostring(s or "")
    if s == "" then return false end
    for _, p in ipairs(VIDEO_PATTERNS) do
        if s:find(p, 1, true) then return true end
    end
    local has_ambiguous = false
    for _, p in ipairs(AMBIGUOUS_PATTERNS) do
        if s:find(p, 1, true) then
            has_ambiguous = true
            break
        end
    end
    if has_ambiguous then
        for _, q in ipairs(VIDEO_QUALIFIERS) do
            if s:find(q, 1, true) then return true end
        end
    end
    return false
end

function BookFilter.isVideoBook(book)
    if type(book) ~= "table" then return false end
    local kind = tostring(book.kind or "")
    if kind == "" then return false end
    return isVideoText(kind)
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
    return isVideoText(title)
end

return BookFilter
