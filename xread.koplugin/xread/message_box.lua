-- 统一提示 / 确认框。
--
-- 目的：全插件只有一种提示样式 —— 白底、2px 黑边、圆角、居中文字；
-- 夜间模式下和其它面板一样由系统整屏反色（黑底白字），不各写一套。
--
-- 为什么不再直画像素（bb:paintRect）：
--   自绘虽然能精确控制边框，但夜间反色的处理路径和普通容器不一致，
--   真机上出现过「框是白的、正文是黑的」这种半反色状态。
--   这里改成和「更多 / 设置」面板完全相同的容器结构（FrameContainer + TextWidget），
--   日/夜的观感自然与其它弹窗一致。
--
-- 用法：
--   MessageBox.show{ text = "…", title = "…", timeout = 4 }
--   MessageBox.confirm{ text = "…", ok_text = "删除", callback = function(ok) … end }

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local InputContainer = require("ui/widget/container/inputcontainer")
local LineWidget = require("ui/widget/linewidget")
local OverlapGroup = require("ui/widget/overlapgroup")
local RightContainer = require("ui/widget/container/rightcontainer")
local UICommon = require("xread/ui_common")
local Screen = Device.screen
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local logger = require("logger")

local M = {}

-- 逻辑尺寸：字体由 Font:getFace 内部 scaleBySize（font.lua:276），
-- 间距和按钮高度必须自己 scaleBySize，否则 300dpi 屏上只有十几像素，文字会贴边。
local PAD = 16              -- 卡片内边距
local GAP_HEAD = 10         -- 标题与分隔线
local GAP_BODY = 12         -- 分隔线与正文 / 正文与按钮
local BTN_H = 36            -- 按钮行高度
local CARD_RATIO = 0.72     -- 卡片宽度占屏比（固定宽度，保证所有提示框等宽）
local CARD_MAX = 560        -- 卡片宽度上限（小屏用比例，大屏别太宽）
local GAP_TOP = 0.04        -- 卡片中线比屏幕正中上移的比例
local FACE_TITLE = 19
local FACE_BODY = 17
local FACE_BTN = 17

local live = nil

-- 配色：只写「白天源色」，夜间交给系统整屏反色自动变黑底白字。
--
-- 为什么不做夜间分支：KOReader 的夜间模式不是给每个控件换色，而是
-- Screen.bb:invert() 给屏幕 blitbuffer 置 inverse 标志（ffi/blitbuffer.lua:692），
-- 之后任何 setPixel / paintRect / blitFrom 写进去的颜色都会再取反一次
--（同文件 850-986 行）。所以这里如果再显式给「黑底白字」，会被二次反色成
-- 白底黑字——夜里面突然一块白板。「更多」面板夜里正常，正是因为它只写白底黑字。
local C_BG = Blitbuffer.COLOR_WHITE
local C_FG = Blitbuffer.COLOR_BLACK
local C_LINE = Blitbuffer.COLOR_BLACK

----------------------------------------------------------------------
-- 文字换行：按「行」拆开，再按像素宽贪心折行（提示文案都很短，够用）
----------------------------------------------------------------------
local function utf8Chars(s)
    local out = {}
    local i, n = 1, #s
    while i <= n do
        local b = s:byte(i)
        local len = 1
        if b >= 0xF0 then len = 4
        elseif b >= 0xE0 then len = 3
        elseif b >= 0xC0 then len = 2 end
        out[#out + 1] = s:sub(i, i + len - 1)
        i = i + len
    end
    return out
end

local function measure(text, face, bold)
    local ok, w = pcall(function()
        return TextWidget:new{ text = text, face = face, bold = bold }:getSize().w
    end)
    return ok and tonumber(w) or (tonumber(#text) or 0) * 10
end

--- 把一段文字按最大宽度折成若干行
local function wrapText(text, face, max_w)
    local lines = {}
    local paras = {}
    for para in (tostring(text or "") .. "\n"):gmatch("([^\n]*)\n") do
        paras[#paras + 1] = para
    end
    if #paras == 0 then paras = { "" } end

    for _i, para in ipairs(paras) do
        if para == "" then
            lines[#lines + 1] = ""
        else
            local cur = ""
            for _j, ch in ipairs(utf8Chars(para)) do
                local cand = cur .. ch
                if cur ~= "" and measure(cand, face) > max_w then
                    lines[#lines + 1] = cur
                    cur = ch
                else
                    cur = cand
                end
            end
            if cur ~= "" then lines[#lines + 1] = cur end
        end
    end
    return lines
end

----------------------------------------------------------------------
-- 卡片按钮（自带热区，不靠外部坐标判断）
----------------------------------------------------------------------
local CardButton = InputContainer:extend{
    text = nil, width = nil, height = nil, bold = false, callback = nil,
}

function CardButton:init()
    local tw = TextWidget:new{
        text = self.text or "",
        face = Font:getFace("cfont", FACE_BTN),
        bold = self.bold,
        fgcolor = C_FG,
        max_width = math.max(1, self.width - Screen:scaleBySize(12)),
    }
    self[1] = CenterContainer:new{
        dimen = Geom:new{ w = self.width, h = self.height },
        tw,
    }
    self.dimen = Geom:new{ w = self.width, h = self.height }
    self.ges_events = { Tap = { GestureRange:new{ ges = "tap", range = self.dimen } } }
end

function CardButton:onTap()
    if self.callback then pcall(self.callback) end
    return true
end

----------------------------------------------------------------------
-- 提示框
----------------------------------------------------------------------
local Box = InputContainer:extend{
    text = "",
    title = nil,
    buttons = nil,
    dismissable = true,
    full_refresh = false,
    on_close = nil,
    -- sticky=true：这类卡片要等用户亲自处理（取消/修改/✕），
    -- 不能被后台任务的普通 showInfo 顶掉。
    sticky = false,
    _miuread_transient = true,
    _miuread_modal_surface = true,
}

function Box:init()
    -- 置顶卡片（后端不可达等）在首页停留：首页的尺寸刷新会主动关闭
    -- _miuread_transient 的浮层，必须把自己标成非瞬态的模态表面；
    -- 同时首页也就不会在延迟重绘时盖到这张卡片上面。
    if self.sticky then
        self._miuread_transient = false
    end
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    self.full_dimen = Geom:new{ x = 0, y = 0, w = sw, h = sh }
    self.dimen = self.full_dimen

    local pad = Screen:scaleBySize(PAD)
    -- 固定卡片宽度：短提示不会缩成一条，长提示也不会铺满整屏，
    -- 所有提示 / 确认框宽度一致，互相切换时观感统一。
    local card_w = math.min(math.floor(sw * CARD_RATIO), Screen:scaleBySize(CARD_MAX))
    local inner_w = card_w - pad * 2
    local face_body = Font:getFace("cfont", FACE_BODY)
    local content = VerticalGroup:new{ align = "center" }

    -- 顶部给 ✕ 预留一行，正文整体下移，避免文字压到关闭按钮
    local close_w = UICommon.closeButtonSize()
    content[#content + 1] = VerticalSpan:new{ width = close_w }

    -- 标题 + 分隔线（可选）
    if self.title and self.title ~= "" then
        content[#content + 1] = TextWidget:new{
            text = self.title,
            face = Font:getFace("cfont", FACE_TITLE),
            bold = true,
            fgcolor = C_FG,
            max_width = inner_w,
        }
        content[#content + 1] = VerticalSpan:new{ width = Screen:scaleBySize(GAP_HEAD) }
        content[#content + 1] = LineWidget:new{
            dimen = Geom:new{ w = inner_w, h = 1 },
            background = C_LINE,
        }
        content[#content + 1] = VerticalSpan:new{ width = Screen:scaleBySize(GAP_BODY) }
    end

    -- 正文（已折行，每行一个 TextWidget，居中）
    local lines = wrapText(self.text, face_body, inner_w)
    for _i, line in ipairs(lines) do
        content[#content + 1] = TextWidget:new{
            text = (line == "" and " " or line),
            face = face_body,
            fgcolor = C_FG,
            max_width = inner_w,
        }
    end

    -- 按钮行（可选）
    local n_btn = self.buttons and #self.buttons or 0
    if n_btn > 0 then
        local btn_h = Screen:scaleBySize(BTN_H)
        content[#content + 1] = VerticalSpan:new{ width = Screen:scaleBySize(GAP_BODY) }
        content[#content + 1] = LineWidget:new{
            dimen = Geom:new{ w = inner_w, h = 1 },
            background = C_LINE,
        }
        local row = HorizontalGroup:new{ align = "center" }
        local bw = math.floor(inner_w / n_btn)
        for i = 1, n_btn do
            local btn = self.buttons[i]
            row[#row + 1] = CardButton:new{
                text = btn.text,
                width = (i == n_btn) and (inner_w - bw * (n_btn - 1)) or bw,
                height = btn_h,
                -- 最后一个按钮（确定/删除）加粗，主次分明
                bold = (i == n_btn),
                callback = function()
                    if btn.callback then pcall(btn.callback) end
                    self:close()
                end,
            }
        end
        content[#content + 1] = row
    end

    -- 用固定宽度的容器把内容撑到 inner_w，保证卡片等宽且内容水平居中
    local holder = CenterContainer:new{
        dimen = Geom:new{ w = inner_w, h = content:getSize().h },
        content,
    }

    -- 右上角关闭按钮：与其它弹窗同一套纯黑 ✕，叠在内容层之上贴右上角内侧。
    -- 正文已在顶部预留一行，两者不重叠。
    local close_mark = UICommon.closeButtonAtEdge(function() self:close() end, 0)
    local layered = OverlapGroup:new{
        dimen = Geom:new{ w = inner_w, h = content:getSize().h },
        allow_mirroring = false,
        holder,
        RightContainer:new{
            dimen = Geom:new{ w = inner_w, h = close_w },
            close_mark,
        },
    }

    local card = FrameContainer:new{
        bordersize = 2, color = C_LINE,
        background = C_BG, radius = 8,
        padding = pad, margin = 0,
        layered,
    }

    -- 略高于正中，不压住底部工具栏 / 页码
    self[1] = CenterContainer:new{
        dimen = Geom:new{ x = 0, y = math.floor(-GAP_TOP * sh), w = sw, h = sh },
        card,
    }

    self.ges_events = { Tap = { GestureRange:new{ ges = "tap", range = self.full_dimen } } }
    if Device:hasKeys() then
        self.key_events = { Close = { { Device.input.group.Back } } }
    end
end

function Box:onTap()
    if self.dismissable then
        self:close()
    end
    return true
end

function Box:onClose()
    self:close()
    return true
end

function Box:close()
    if self._closed then return end
    self._closed = true
    if live == self then live = nil end
    pcall(function() UIManager:close(self) end)
    if self.on_close then pcall(self.on_close) end
    pcall(function()
        UIManager:setDirty("all", self.full_refresh and "full" or "ui")
    end)
end

----------------------------------------------------------------------
-- 对外接口
----------------------------------------------------------------------
function M.show(opts)
    opts = opts or {}
    local text = tostring(opts.text or "")
    if text == "" and not (opts.title and opts.title ~= "") then return nil end
    -- 后端不可达这类卡片必须等用户处理，后台失败提示不能把它冲掉
    if live and live.sticky then return nil end

    M.close()

    local ok, box = pcall(function()
        return Box:new{
            text = text,
            title = opts.title,
            buttons = opts.buttons,
            dismissable = opts.dismissable ~= false,
            full_refresh = opts.full_refresh == true,
            on_close = opts.on_close,
            sticky = opts.sticky == true,
        }
    end)
    if not ok or not box then
        logger.warn("[MiuRead][MessageBox] create failed", tostring(box))
        return nil
    end

    live = box
    UIManager:show(box)
    -- sticky 卡片出现在首页时，首页可能还有排队的 dirty 回调；
    -- 只靠 show() 的标脏会被随后一次首页重绘盖住，这里补一次整屏刷新。
    if box.sticky then UIManager:setDirty("all", "full") end

    local timeout = tonumber(opts.timeout)
    if timeout and timeout > 0 then
        UIManager:scheduleIn(timeout, function()
            if live == box then box:close() end
        end)
    end
    return box
end

function M.close()
    local box = live
    if box then
        live = nil
        box._closed = true
        pcall(function() UIManager:close(box) end)
        pcall(function() UIManager:setDirty("all", "ui") end)
    end
end

--- 统一确认框：取消 / 确定（确定加粗）
function M.confirm(opts)
    opts = opts or {}
    local cb = opts.callback
    local resolved = false
    local function finish(v)
        if resolved then return end
        resolved = true
        if cb then pcall(cb, v) end
    end
    return M.show{
        title = opts.title,
        text = opts.text or "",
        timeout = nil,
        dismissable = false,
        full_refresh = opts.full_refresh == true,
        sticky = opts.sticky == true,
        buttons = {
            { text = opts.cancel_text or "取消", callback = function() finish(false) end },
            { text = opts.ok_text or "确定", callback = function() finish(true) end },
        },
        -- 返回键关闭 = 取消
        on_close = function() finish(false) end,
    }
end

--- 卡片尺寸，供其它自有提示框（进度提示）复用：
--- 统一宽度 / 内边距 / 边框宽度 / 垂直偏移，避免各页各写一套又漂移。
--- @return card_w, pad, border, top_ratio
function M.cardMetrics()
    local sw = Screen:getWidth()
    return math.min(math.floor(sw * CARD_RATIO), Screen:scaleBySize(CARD_MAX)),
        Screen:scaleBySize(PAD), 2, GAP_TOP
end

return M
