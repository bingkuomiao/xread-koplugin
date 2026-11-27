-- xread.koplugin/xread/reading_stats.lua

-- 阅读记录（Overall 统计弹窗，样式参考微信读书统计页）：

-- Week / Month / Year / Total 四个范围、总时长与四项小统计、

-- 阅读时长趋势柱状图、读得最多的书 Top 榜。
-- 数据：KOReader 自带 statistics.sqlite3 + 插件自己的阅读会话记录（兜底）。
local UICommon        = require("xread.ui_common")

local Blitbuffer      = require("ffi/blitbuffer")

local Geom            = require("ui/geometry")

local Font            = require("ui/font")

local Screen          = require("device").screen

local Device          = require("device")

local DataStorage     = require("datastorage")

local BookFilter      = require("xread.book_filter")

local LuaSettings     = require("luasettings")

local lfs             = require("libs/libkoreader-lfs")

local GestureRange    = require("ui/gesturerange")

local TextWidget      = require("ui/widget/textwidget")

local FrameContainer  = require("ui/widget/container/framecontainer")

local CenterContainer = require("ui/widget/container/centercontainer")

local VerticalGroup   = require("ui/widget/verticalgroup")

local HorizontalGroup = require("ui/widget/horizontalgroup")

local HorizontalSpan  = require("ui/widget/horizontalspan")

local VerticalSpan    = require("ui/widget/verticalspan")

local LineWidget      = require("ui/widget/linewidget")

local Widget          = require("ui/widget/widget")

local InputContainer  = require("ui/widget/container/inputcontainer")

local UIManager       = require("ui/uimanager")

local logger          = require("logger")

local _               = require("gettext")

local T               = require("ffi/util").template
-- 分章 TXT 名（贪欢_5 / 妖神记_7）归并成书名

local function normalizeTitle(s)

    s = tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", "")

    local base = s:match("^(.-)_%d+$")

    if base and base ~= "" then return base end

    return s

end
local function logPath()

    return DataStorage:getDataDir() .. "/xread_books/reading_log.lua"

end

local function openLog()

    local ok, s = pcall(function() return LuaSettings:open(logPath()) end)

    if ok and s then return s end

    return nil

end
local ReadingStats = InputContainer:extend{}

local function scaled(px)

    return math.floor(px * (Screen:scaleBySize(1000) / 1000) + 0.5)

end

local function clamp(v, a, b)

    if v < a then return a end

    if v > b then return b end

    return v

end

local function fillRound(bb, x, y, w, h, color, r)

    if w <= 0 or h <= 0 then return end

    local fn = Blitbuffer.isColor8(color) and bb.paintRoundedRect or bb.paintRoundedRectRGB32

    fn(bb, x, y, w, h, color, r or 0)

end

local function fmtDuration(sec)

    sec = math.max(0, math.floor(tonumber(sec) or 0))

    local h = math.floor(sec / 3600)

    local m = math.floor((sec % 3600) / 60)

    if h > 0 then return T(_("%1 h %2 min"), tostring(h), tostring(m)) end

    return T(_("%1 min"), tostring(m))

end
-- ---------- 数据 ----------

function ReadingStats.record(book_name, seconds)

    if not book_name or book_name == "" then return end

    seconds = math.floor(tonumber(seconds) or 0)

    if seconds <= 0 then return end

    local s = openLog()

    if not s then return end

    local key = os.date("%Y-%m-%d")

    local days = s:readSetting("days") or {}

    days[key] = (tonumber(days[key]) or 0) + seconds

    s:saveSetting("days", days)

    local books = s:readSetting("books") or {}

    local b = books[book_name] or { sec = 0 }

    b.sec = (tonumber(b.sec) or 0) + seconds

    b.last = os.time()

    books[book_name] = b

    s:saveSetting("books", books)

    s:flush()

end

local function inRange(key, tab, now)


    local today = os.date("*t", now)

    if tab == "Day" then

        return key == os.date("%Y-%m-%d", now)

    elseif tab == "Week" then

        local t = os.date("%Y-%m-%d", now - 6 * 86400)

        return key >= t

    elseif tab == "Month" then

        return key:sub(1, 7) == string.format("%04d-%02d", today.year, today.month)

    elseif tab == "Year" then

        return key:sub(1, 4) == tostring(today.year)

    end

    return true

end
local function bucketize(days, tab)

    local now = os.time()

    local today = os.date("*t", now)

    local bars = {}

    if tab == "Day" then

        -- 数据按天粒度，日视图用单柱呈现今日总时长

        bars[#bars + 1] = { label = _("今天"), value = days[os.date("%Y-%m-%d", now)] or 0 }

    elseif tab == "Week" then

        for i = 6, 0, -1 do

            local t = now - i * 86400

            local k = os.date("%Y-%m-%d", t)

            bars[#bars + 1] = { label = os.date("%m/%d", t), value = days[k] or 0 }

        end

    elseif tab == "Month" then

        for i = 5, 0, -1 do

            local sum = 0

            for j = 0, 4 do

                sum = sum + (days[os.date("%Y-%m-%d", now - (i * 5 + j) * 86400)] or 0)

            end

            bars[#bars + 1] = {

                label = os.date("%m/%d", now - i * 5 * 86400), value = sum,

            }

        end

    elseif tab == "Year" then

        for m = 1, 12 do

            local sum = 0

            local prefix = string.format("%04d-%02d", today.year, m)

            for k, v in pairs(days) do

                if k:sub(1, 7) == prefix then sum = sum + v end

            end

            bars[#bars + 1] = { label = tostring(m), value = sum }

        end

    else

        local years = {}

        for k, v in pairs(days) do

            local y = k:sub(1, 4)

            years[y] = (years[y] or 0) + v

        end

        local first = today.year - 5

        for y in pairs(years) do

            local n = tonumber(y)

            if n and n < first then first = n end

        end

        for y = first, today.year do

            bars[#bars + 1] = { label = tostring(y), value = years[tostring(y)] or 0 }

        end

        if #bars > 8 then

            local tail = {}

            for i = #bars - 7, #bars do tail[#tail + 1] = bars[i] end

            bars = tail

        end

    end

    return bars

end
-- ---------- 自绘小部件 ----------

local BarChart = Widget:extend{ width = nil, height = nil, bars = nil, max_value = 1 }

function BarChart:getSize()

    return Geom:new{ w = self.width, h = self.height }

end

function BarChart:paintTo(bb, x, y)

    self.dimen = Geom:new{ x = x, y = y, w = self.width, h = self.height }

    local bars = self.bars or {}

    local n = math.max(1, #bars)

    local slot = self.width / n

    local bw = math.min(slot * 0.52, scaled(46))

    local base_y = y + self.height - 1

    bb:paintRect(x, base_y, self.width, 1, Blitbuffer.COLOR_GRAY_D)

    for i, b in ipairs(bars) do

        local value = tonumber(b.value) or 0

        local bh = math.floor((value / math.max(1, self.max_value)) * (self.height - scaled(8)))

        if value > 0 and bh < scaled(3) then bh = scaled(3) end

        if bh > 0 then

            local bx = x + math.floor((i - 0.5) * slot - bw / 2)

            bb:paintRect(bx, base_y - bh, math.floor(bw), bh, Blitbuffer.COLOR_GRAY_4)

        end

    end

end

local BarLine = Widget:extend{ width = nil, height = nil, ratio = 0 }

function BarLine:getSize()

    return Geom:new{ w = self.width, h = self.height }

end

function BarLine:paintTo(bb, x, y)

    self.dimen = Geom:new{ x = x, y = y, w = self.width, h = self.height }

    fillRound(bb, x, y, self.width, self.height, Blitbuffer.COLOR_GRAY_D, self.height / 2)

    local w = math.floor(self.width * clamp(self.ratio or 0, 0, 1))

    if w > 0 then

        fillRound(bb, x, y, w, self.height, Blitbuffer.COLOR_GRAY_4, self.height / 2)

    end

end

local TapBox = InputContainer:extend{ widget = nil, width = nil, height = nil, callback = nil }

function TapBox:init()

    self.dimen = Geom:new{ w = self.width, h = self.height }

    self[1] = CenterContainer:new{

        dimen = Geom:new{ w = self.width, h = self.height }, self.widget,

    }

    self.ges_events = { Tap = { GestureRange:new{ ges = "tap", range = self.dimen } } }

end

function TapBox:onTap()

    if self.callback then self.callback() end

    return true

end
local function smallCard(w, h, inner)

    return FrameContainer:new{

        bordersize = 1, radius = scaled(10),

        color = Blitbuffer.COLOR_GRAY_D,

        background = Blitbuffer.COLOR_WHITE,

        padding = scaled(8), margin = 0,

        width = w, height = h,

        inner,

    }

end
-- ---------- 布局 ----------

function ReadingStats.computeLayout(top_count)

    local sw, sh = Screen:getWidth(), Screen:getHeight()

    local card_w = math.min(sw - 2 * scaled(24), math.floor(sw * 0.86))

    local pad = scaled(20)

    local inner_w = card_w - 2 * pad - 2

    local content_w = inner_w - 2 * scaled(8) - 2

    local header_h = scaled(46)

    local tabs_h = scaled(42)

    local overview_h = scaled(170)

    local trend_h = scaled(160)

    -- 先按屏幕上限算出能放几项，再让卡片高度贴合内容，避免底部留白

    local max_card_h = sh - 2 * scaled(24)

    local max_content_h = max_card_h - header_h - tabs_h - 2 * scaled(8)

    local max_list_h = max_content_h - overview_h - trend_h - 2 * scaled(10)

    local item_h = scaled(60)  -- 每项的实测高度约 94px，留一点余量

    top_count = math.min(top_count or 0, 5,

        math.max(1, math.floor((max_list_h - scaled(20) - scaled(12)) / item_h)))

    local list_h = scaled(20) + top_count * item_h + scaled(12)
    local content_h = overview_h + trend_h + list_h + 2 * scaled(10)

    local card_h = header_h + tabs_h + content_h + 2 * scaled(8)

    return {

        screen_w = sw, screen_h = sh,

        card_w = card_w, card_h = card_h,

        pad = pad, inner_w = inner_w, content_w = content_w,

        header_h = header_h, tabs_h = tabs_h, content_h = content_h,

        overview_h = overview_h, trend_h = trend_h, list_h = list_h,

        top_count = top_count,

        left = math.floor((sw - card_w) / 2),

        top = math.floor((sh - card_h) / 2),

    }

end
local function loadData()

    local books, days = {}, {}

    local notes, highlights = 0, 0

    local db_has_days = false

    -- 1) KOReader 自带阅读统计（真实逐页数据）

    local db_ok, db_err = pcall(function()

        local SQ3 = require("lua-ljsqlite3/init")

        local db = DataStorage:getSettingsDir() .. "/statistics.sqlite3"

        if lfs.attributes(db, "mode") ~= "file" then return end

        local conn = SQ3.open(db)

        local res = conn:exec(

            "SELECT title, notes, highlights, total_read_time, total_read_pages, pages FROM book;")

        if res and res[1] then

            for i = 1, #res[1] do

                local name = normalizeTitle(res[1][i])

                if name ~= "" then

                    local b = books[name] or { sec = 0, read_pages = 0, pages = 0 }

                    b.sec = b.sec + (tonumber(res[4][i]) or 0)

                    b.read_pages = b.read_pages + (tonumber(res[5][i]) or 0)

                    b.pages = b.pages + (tonumber(res[6][i]) or 0)

                    books[name] = b

                    notes = notes + (tonumber(res[2][i]) or 0)

                    highlights = highlights + (tonumber(res[3][i]) or 0)

                end

            end

        end

        local ps = conn:exec("SELECT start_time, duration FROM page_stat_data;")

        if ps and ps[1] then

            for i = 1, #ps[1] do

                local ts, d = tonumber(ps[1][i]) or 0, tonumber(ps[2][i]) or 0

                if ts > 0 and d > 0 then

                    local k = os.date("%Y-%m-%d", ts)

                    days[k] = (days[k] or 0) + d

                end

            end

        end

        conn:close()

    end)

    if not db_ok then logger.warn("xread reading stats db:", tostring(db_err)) end

    for _k in pairs(days) do db_has_days = true break end

    -- 2) 插件自己的会话记录：只补 KOReader 没统计到的日期/书，避免双计

    local s = openLog()

    if s then

        for k, v in pairs(s:readSetting("days") or {}) do
            if not db_has_days or not days[k] then

                days[k] = (days[k] or 0) + (tonumber(v) or 0)

            end

        end

        for k, v in pairs(s:readSetting("books") or {}) do

            if not books[k] then

                books[k] = { sec = tonumber(v.sec) or 0, read_pages = 0, pages = 0 }

            end

        end

    end

    local finished = 0

    -- 阅读记录只保留小说/漫画：过滤视频类条目（按标题关键词黑名单）

    for name in pairs(books) do

        if BookFilter.isVideoTitle(name) then books[name] = nil end

    end

    for _n, b in pairs(books) do

        if b.pages and b.pages > 0 and b.read_pages and b.read_pages >= b.pages then

            finished = finished + 1

        end

    end

    return { books = books, days = days, notes = notes, highlights = highlights,

             finished = finished }

end

-- 首页右侧卡片用：本周（周一起）每天阅读时长汇总。
-- 注意：必须定义在局部函数 loadData 之后（依赖它做 upvalue）。
local function getHomeStats()

    local data = loadData()

    local days = data.days or {}

    local now = os.time()

    local today_key = os.date("%Y-%m-%d")

    local wday = tonumber(os.date("%w")) or 0   -- 0=周日

    local offset_to_monday = (wday == 0) and 6 or (wday - 1)

    local daily = {}

    local total = 0

    local read_days = 0

    for i = 1, 7 do

        local ts = now - (offset_to_monday - (i - 1)) * 86400

        local key = os.date("%Y-%m-%d", ts)

        local sec = tonumber(days[key]) or 0

        local future = ts > now

        daily[i] = { seconds = sec, future = future }

        if not future then

            total = total + sec

            if sec > 0 then read_days = read_days + 1 end

        end

    end

    return {

        available = true,

        kind = "local",

        total_seconds = total,

        today_seconds = tonumber(days[today_key]) or 0,

        average_seconds = math.floor(total / math.max(1, offset_to_monday + 1)),

        read_days = read_days,

        daily = daily,

        threshold = 60,   -- 当天 ≥1 分钟算打卡

    }

end

function ReadingStats.getHomeStats() return getHomeStats() end

function ReadingStats:init()

    self.tab = "Day"

    self.data = loadData()

    local ranked_count = 0

    for _n in pairs(self.data.books or {}) do ranked_count = ranked_count + 1 end

    local L = ReadingStats.computeLayout(ranked_count)

    self.L = L

    self.dimen = Geom:new{ x = 0, y = 0, w = L.screen_w, h = L.screen_h }

    if Device:hasKeys() then

        self.key_events.Close = { { Device.input.group.Back } }

    end

    -- 关闭按钮与其它弹出页统一：纯黑 ✕、贴到卡片边框内侧
    local close_w = UICommon.closeButtonSize()

    local close_mark = UICommon.closeButtonAtEdge(

        function() self:close() end, L.pad)

    -- 标题按实际宽度算 span（原来写死 scaled(90)，实际字宽更大，
    -- 会把 ✕ 顶出卡片边框）
    local title_tw = TextWidget:new{

        text = _("阅读记录"),

        face = Font:getFace("tfont", scaled(18)),

        fgcolor = Blitbuffer.COLOR_BLACK,

    }

    local header = FrameContainer:new{

        bordersize = 0, padding = 0, margin = 0,

        background = Blitbuffer.COLOR_WHITE,

        width = L.inner_w, height = L.header_h,

        HorizontalGroup:new{

            align = "center",

            title_tw,

            HorizontalSpan:new{ width = math.max(0, L.inner_w - title_tw:getSize().w - close_w) },

            close_mark,

        },

    }

    self.tabs_frame = FrameContainer:new{

        bordersize = 0, padding = 0, margin = 0,

        background = Blitbuffer.COLOR_WHITE,

        width = L.inner_w, height = L.tabs_h,

    }

    self.content_frame = FrameContainer:new{

        bordersize = 0, padding = 0, margin = 0,

        background = Blitbuffer.COLOR_WHITE,

        width = L.inner_w, height = L.content_h,

    }

    self.tabs_frame[1] = self:buildTabs()

    self.content_frame[1] = self:buildContent()

    local card = FrameContainer:new{

        bordersize = 1, radius = scaled(14),

        color = Blitbuffer.COLOR_GRAY_D,

        background = Blitbuffer.COLOR_WHITE,

        padding = 0, margin = 0,

        width = L.card_w, height = L.card_h,

        VerticalGroup:new{

            align = "left",

            VerticalSpan:new{ width = scaled(8) },

            HorizontalGroup:new{ HorizontalSpan:new{ width = L.pad }, header },

            HorizontalGroup:new{ HorizontalSpan:new{ width = L.pad }, self.tabs_frame },

            HorizontalGroup:new{ HorizontalSpan:new{ width = L.pad }, self.content_frame },

            VerticalSpan:new{ width = scaled(8) },

        },

    }

    self._card = card

    self[1] = card

    self.ges_events = { Tap = { GestureRange:new{ ges = "tap", range = self.dimen } } }

end
function ReadingStats:buildTabs()

    local L = self.L

    local names = { "Day", "Week", "Month", "Year", "Total" }

    local labels = { _("日"), _("周"), _("月"), _("年"), _("全部") }

    local w = math.floor(L.inner_w / 5)

    local h = L.tabs_h - scaled(10)

    local row = HorizontalGroup:new{ align = "center" }

    for i = 1, 5 do

        local selected = (names[i] == self.tab)

        local item = FrameContainer:new{

            bordersize = 1, radius = scaled(6),

            color = selected and Blitbuffer.COLOR_GRAY_4 or Blitbuffer.COLOR_GRAY_D,

            background = selected and Blitbuffer.COLOR_GRAY_4 or Blitbuffer.COLOR_WHITE,

            padding = 0, margin = 0,

            width = w - scaled(6), height = h,

            CenterContainer:new{

                dimen = Geom:new{ w = w - scaled(6), h = h },

                TextWidget:new{

                    text = labels[i],

                    face = Font:getFace("cfont", scaled(13)),

                    fgcolor = selected and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK,

                },

            },

        }

        local name = names[i]

        row[#row + 1] = TapBox:new{

            widget = item, width = w - scaled(6), height = h,

            callback = function() self:setTab(name) end,

        }

    end

    return row

end
function ReadingStats:setTab(tab)

    if self.tab == tab then return end

    self.tab = tab

    self:rebuild()

end
function ReadingStats:rebuild()

    self.tabs_frame[1] = self:buildTabs()

    self.content_frame[1] = self:buildContent()

    UIManager:setDirty("all", "full")

end
function ReadingStats:buildContent()

    local L = self.L

    local data = self.data or {}

    local days = data.days or {}

    local books = data.books or {}

    local now = os.time()

    -- 总时长 / 阅读天数（随范围变化）

    local total_sec, day_count = 0, 0

    for k, v in pairs(days) do

        if inRange(k, self.tab, now) then

            total_sec = total_sec + (tonumber(v) or 0)

            day_count = day_count + 1

        end

    end

    local book_count = 0

    for _n in pairs(books) do book_count = book_count + 1 end

    -- 总览卡

    local big = TextWidget:new{

        text = fmtDuration(total_sec),

        face = Font:getFace("tfont", scaled(28)),

        fgcolor = Blitbuffer.COLOR_BLACK,

    }

    local overview_w = L.content_w

    local stat_items = {

        T(_("读过 %1 本"), tostring(book_count)),

        T(_("读完 %1 本"), tostring(data.finished or 0)),

        T(_("阅读 %1 天"), tostring(day_count)),

        T(_("笔记 %1 条"), tostring((data.notes or 0) + (data.highlights or 0))),

    }

    local stat_row = HorizontalGroup:new{ align = "center" }

    local slot = math.floor(overview_w / 4)

    for i = 1, 4 do

        stat_row[#stat_row + 1] = CenterContainer:new{

            dimen = Geom:new{ w = slot, h = scaled(24) },

            TextWidget:new{

                text = stat_items[i],

                face = Font:getFace("cfont", scaled(11)),

                fgcolor = Blitbuffer.COLOR_GRAY_6,

                max_width = slot - scaled(4),

            },

        }

    end

    local overview_inner = VerticalGroup:new{

        align = "left",

        HorizontalGroup:new{

            align = "center",

            big,

            HorizontalSpan:new{ width = scaled(10) },

            TextWidget:new{

                text = _("总阅读时长"),

                face = Font:getFace("cfont", scaled(12)),

                fgcolor = Blitbuffer.COLOR_GRAY_6,

            },

        },

        VerticalSpan:new{ width = scaled(5) },

        TextWidget:new{

            text = T(_("共 %1 天有阅读记录"), tostring(day_count)),

            face = Font:getFace("cfont", scaled(11)),

            fgcolor = Blitbuffer.COLOR_GRAY_6,

        },

        VerticalSpan:new{ width = scaled(8) },

        LineWidget:new{ dimen = Geom:new{ w = overview_w, h = 1 },

                        background = Blitbuffer.COLOR_GRAY_D },

        VerticalSpan:new{ width = scaled(8) },

        stat_row,

    }

    local overview = smallCard(L.inner_w, L.overview_h, overview_inner)

    -- 趋势卡

    local bars = bucketize(days, self.tab)

    local max_value = 1

    for _i, b in ipairs(bars) do

        if (b.value or 0) > max_value then max_value = b.value end

    end

    local chart_w = L.content_w

    local chart_h = scaled(68)

    local chart = BarChart:new{ width = chart_w, height = chart_h,

                                bars = bars, max_value = max_value }

    local labels = HorizontalGroup:new{ align = "center" }

    local lslot = math.floor(chart_w / math.max(1, #bars))

    for _i, b in ipairs(bars) do

        labels[#labels + 1] = CenterContainer:new{

            dimen = Geom:new{ w = lslot, h = scaled(20) },

            TextWidget:new{

                text = b.label or "",

                face = Font:getFace("cfont", scaled(10)),

                fgcolor = Blitbuffer.COLOR_GRAY_6,

                max_width = lslot - scaled(2),

            },

        }

    end

    local trend_inner = VerticalGroup:new{

        align = "left",

        HorizontalGroup:new{

            TextWidget:new{

                text = _("阅读时长趋势"),

                face = Font:getFace("tfont", scaled(14)),

                fgcolor = Blitbuffer.COLOR_BLACK,

            },

            HorizontalSpan:new{ width = scaled(10) },

            TextWidget:new{

                text = T(_("最高 %1"), fmtDuration(max_value)),

                face = Font:getFace("cfont", scaled(11)),

                fgcolor = Blitbuffer.COLOR_GRAY_6,

            },

        },

        VerticalSpan:new{ width = scaled(8) },

        chart,

        labels,

    }

    local trend = smallCard(L.inner_w, L.trend_h, trend_inner)

    -- 读得最多的书

    local ranked = {}

    for name, b in pairs(books) do

        ranked[#ranked + 1] = { name = name, sec = tonumber(b.sec) or 0 }

    end

    table.sort(ranked, function(a, b) return a.sec > b.sec end)

    local top = {}

    for i = 1, math.min(self.L.top_count or 0, #ranked) do top[i] = ranked[i] end

    local top_max = (top[1] and top[1].sec > 0) and top[1].sec or 1

    local list_inner = VerticalGroup:new{

        align = "left",

        TextWidget:new{

            text = _("读得最多的书 · 累计"),

            face = Font:getFace("tfont", scaled(14)),

            fgcolor = Blitbuffer.COLOR_BLACK,

        },

        VerticalSpan:new{ width = scaled(6) },

    }

    local row_w = L.content_w

    if #top == 0 then

        list_inner[#list_inner + 1] = TextWidget:new{

            text = _("暂无阅读记录，读一会儿书再来看看吧"),

            face = Font:getFace("cfont", scaled(12)),

            fgcolor = Blitbuffer.COLOR_GRAY_6,

        }

    end

    for i, item in ipairs(top) do

        local name = TextWidget:new{

            text = tostring(i) .. ". " .. item.name,

            face = Font:getFace("cfont", scaled(12)),

            fgcolor = Blitbuffer.COLOR_BLACK,

            max_width = math.floor(row_w * 0.68),

        }

        local dur = TextWidget:new{

            text = fmtDuration(item.sec),

            face = Font:getFace("cfont", scaled(11)),

            fgcolor = Blitbuffer.COLOR_GRAY_6,

        }

        list_inner[#list_inner + 1] = VerticalGroup:new{

            align = "left",

            HorizontalGroup:new{

                name,

                HorizontalSpan:new{ width = math.max(scaled(6),

                    row_w - name:getSize().w - dur:getSize().w) },

                dur,

            },

            VerticalSpan:new{ width = scaled(3) },

            BarLine:new{ width = row_w, height = scaled(6),

                         ratio = item.sec / top_max },

            VerticalSpan:new{ width = scaled(8) },

        }

    end

    local list = smallCard(L.inner_w, L.list_h, list_inner)

    return VerticalGroup:new{

        align = "left",

        overview,

        VerticalSpan:new{ width = scaled(12) },

        trend,

        VerticalSpan:new{ width = scaled(12) },

        list,

    }

end
function ReadingStats:paintTo(bb, x, y)

    local L = self.L

    self.dimen.x = x

    self.dimen.y = y

    -- 半透明压暗：保留弹窗前的正文画面当背景（原整屏灰底会盖掉内容）
    UICommon.dimBackdrop(bb, x, y, L.screen_w, L.screen_h)

    if self._card then self._card:paintTo(bb, x + L.left, y + L.top) end

end
function ReadingStats:onTap(_arg, ges)

    local card = self._card

    if card and card.dimen and ges and ges.pos and card.dimen:contains(ges.pos) then

        return true

    end

    self:close()

    return true

end
function ReadingStats:onClose()

    self:close()

    return true

end
function ReadingStats:close()

    UIManager:close(self)

    UIManager:setDirty("all", "full")

end

return ReadingStats
