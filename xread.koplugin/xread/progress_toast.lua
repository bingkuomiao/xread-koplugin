-- 长任务进度提示（整本缓存 / 整本导出 / 进度同步）。
--
-- 为什么不用 Trapper:info：
--   Trapper:info(text) 每次调用都是「关掉旧 InfoMessage → 新建一个 → forceRePaint」。
--   我们的轮询为了不卡界面，每轮都会调一次 Trapper:info(nil) 让出时间片，
--   而 text=nil 会新建一个「文字为空」的 InfoMessage —— 真机表现就是：
--   进度框不停地闪，中间反复出现一个空白框。
--
-- 这里的做法：
--   ① 只建一个提示框，文字原地 setText，只在文字变了才请求重绘（不闪）；
--   ② 固定卡片宽度 + 高度按内容算（原来跟着文字宽度走，又长又矮）；
--   ③ 白底 + 2px 黑边自己画，和普通提示框同一套尺寸/间距；
--   ④ 用 scheduleIn + coroutine.yield 让出时间片，UI 事件照常处理；
--   ⑤ 下载/缓存这类长时间任务显示「取消 / 确定」两个按钮：
--      取消 = 中止任务；确定 = 继续等待完成（收起按钮，进度继续显示）；
--      点弹窗以外的地方只吞掉点击防翻页，绝不误取消。

local Blitbuffer = require("ffi/blitbuffer")
local Geom = require("ui/geometry")
local UIManager = require("ui/uimanager")
local Device = require("device")
local Screen = Device.screen
local Font = require("ui/font")
local InputContainer = require("ui/widget/container/inputcontainer")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local GestureRange = require("ui/gesturerange")
local logger = require("logger")

local M = {}

local live

local BORDER = 2

local function card_metrics()
    local ok, MessageBox = pcall(require, "xread/message_box")
    if ok and MessageBox and MessageBox.cardMetrics then
        local w, pad, border, ratio = MessageBox.cardMetrics()
        return w, pad, border or BORDER, ratio or 0.04
    end
    local sw = Screen:getWidth()
    return math.min(math.floor(sw * 0.72)), Screen:scaleBySize(16), BORDER, 0.04
end

local Toast = InputContainer:extend{
    text = "",
    aborted = false,
    confirmed = false,
    with_buttons = false,
    only_cancel = false,   -- 下载这类任务：只给「取消」，点完确认就不再叠第二个确定
    _miuread_transient = true,
    -- 只是进度提示，不参与 TransientGuard 的模态互斥
    _miuread_modal_surface = false,
}

function Toast:init()
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    self.full_dimen = Geom:new{ x = 0, y = 0, w = sw, h = sh }
    self.dimen = self.full_dimen
    self.card_w, self.pad = select(1, card_metrics()), select(2, card_metrics())
    self.inner_w = math.max(1, self.card_w - self.pad * 2 - BORDER * 2)
    -- Font:getFace 内部已经 scaleBySize，不要再手动 scale（否则 300dpi 上字会大一倍）
    self.text_widget = TextBoxWidget:new{
        text = self.text,
        face = Font:getFace("cfont", 17),
        width = self.inner_w,
        alignment = "center",
        fgcolor = Blitbuffer.COLOR_BLACK,
    }
    self.btn_h = Screen:scaleBySize(38)
    self.btn_gap = Screen:scaleBySize(10)
    self.cancel_label = TextWidget:new{
        text = "取消", face = Font:getFace("cfont", 17),
        fgcolor = Blitbuffer.COLOR_BLACK,
    }
    self.confirm_label = TextWidget:new{
        text = "确定", face = Font:getFace("cfont", 17), bold = true,
        fgcolor = Blitbuffer.COLOR_BLACK,
    }
    self.text_h = math.max(1, tonumber(self.text_widget:getSize().h) or 1)
    self.box_dimen = self:_measure()
    -- 整屏热区：吞掉误触（导出时别翻页），但 onTap 只在按钮内才改状态，
    -- 点弹窗以外的地方不再取消任务。
    self.ges_events = { Tap = { GestureRange:new{ ges = "tap", range = self.full_dimen } } }
end

function Toast:_measure()
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    self.text_h = math.max(1, tonumber(self.text_widget:getSize().h) or 1)
    local show_buttons = self.with_buttons and not self.confirmed
    local btn_block = show_buttons and (self.btn_gap + self.btn_h) or 0
    local box_w = self.card_w
    local box_h = BORDER * 2 + self.pad * 2 + self.text_h + btn_block
    local box_x = math.floor((sw - box_w) / 2)
    local box_y = math.floor(sh * (0.5 - select(4, card_metrics())) - box_h / 2)
    if box_y + box_h > sh - Screen:scaleBySize(24) then
        box_y = math.max(Screen:scaleBySize(24), math.floor((sh - box_h) / 2))
    end
    -- 两个按钮的绝对热区（取消在左、确定在右）
    self.cancel_rect, self.confirm_rect = nil, nil
    if show_buttons then
        local by = box_y + BORDER + self.pad + self.text_h + self.btn_gap
        local bx = box_x + BORDER + self.pad
        if self.only_cancel then
            -- 只有一个「取消」：整行都是它的热区，不再出现第二个确定按钮
            self.cancel_rect = Geom:new{ x = bx, y = by, w = self.inner_w, h = self.btn_h }
            self.confirm_rect = nil
        else
            local bw = math.floor(self.inner_w / 2)
            self.cancel_rect = Geom:new{ x = bx, y = by, w = bw, h = self.btn_h }
            self.confirm_rect = Geom:new{ x = bx + bw, y = by, w = self.inner_w - bw, h = self.btn_h }
        end
    end
    return Geom:new{ x = box_x, y = box_y, w = box_w, h = box_h }
end

-- 自己画白底 + 黑边 + 居中文字 + 按钮行：整块区域完全由这里决定，
-- 不依赖布局容器（之前用 FrameContainer，真机上只看到白底、看不到边框）
function Toast:paintTo(bb, x, y)
    local d = self.box_dimen
    if not d then return end
    local bx, by = d.x + x, d.y + y
    bb:paintRect(bx, by, d.w, d.h, Blitbuffer.COLOR_WHITE)
    bb:paintRect(bx, by, d.w, BORDER, Blitbuffer.COLOR_BLACK)
    bb:paintRect(bx, by + d.h - BORDER, d.w, BORDER, Blitbuffer.COLOR_BLACK)
    bb:paintRect(bx, by, BORDER, d.h, Blitbuffer.COLOR_BLACK)
    bb:paintRect(bx + d.w - BORDER, by, BORDER, d.h, Blitbuffer.COLOR_BLACK)
    local tx = bx + BORDER + self.pad
    local ty = by + BORDER + self.pad
    self.text_widget:paintTo(bb, tx, ty)
    if self.cancel_rect then
        if self.confirm_rect then
            -- 按钮之间一条细分隔线，和 MessageBox 的按钮行观感一致
            local sep_x = self.cancel_rect.x + self.cancel_rect.w
            bb:paintRect(sep_x, self.cancel_rect.y, 1, self.btn_h, Blitbuffer.COLOR_GRAY)
        end
        local function paint_label(widget, rect)
            local sz = widget:getSize()
            local lw, lh = tonumber(sz and sz.w) or 1, tonumber(sz and sz.h) or 1
            local lx = rect.x + math.floor((rect.w - lw) / 2)
            local ly = rect.y + math.floor((rect.h - lh) / 2)
            widget:paintTo(bb, lx, ly)
        end
        paint_label(self.cancel_label, self.cancel_rect)
        if self.confirm_rect then paint_label(self.confirm_label, self.confirm_rect) end
    end
end

function Toast:_refresh(old)
    if not UIManager:isWidgetShown(self) then return end
    local new = self.box_dimen
    if not new then return end
    local region = new
    if old then
        local x1 = math.min(old.x, new.x)
        local y1 = math.min(old.y, new.y)
        region = Geom:new{
            x = x1, y = y1,
            w = math.max(old.x + old.w, new.x + new.w) - x1,
            h = math.max(old.y + old.h, new.y + new.h) - y1,
        }
    end
    -- 必须让底层（正文）也跟着重画：只标脏 toast 自己的话，卡片缩小后
    -- 旧按钮行的像素没人擦，真机上就是「两个框叠在一起再也消不掉」。
    UIManager:setDirty("all", "ui", region)
end

function Toast:setText(text)
    text = tostring(text or "")
    if text == self.text then return self end
    local old = self.box_dimen
    self.text = text
    local ok = pcall(function()
        self.text_widget:setText(text)
        self.box_dimen = self:_measure()
    end)
    if not ok then
        logger.warn("[MiuRead][ProgressToast] setText failed")
        return self
    end
    self:_refresh(old)
    return self
end

local function in_rect(rect, pos)
    return pos and rect and pos.x >= rect.x and pos.x < rect.x + rect.w
        and pos.y >= rect.y and pos.y < rect.y + rect.h
end

function Toast:onTap(_, ges)
    local pos = ges and ges.pos
    -- 只有点在按钮热区里才响应；弹窗以外一律吞掉但不改变状态，
    -- 避免「点一下别处就把下载取消了」。
    if in_rect(self.cancel_rect, pos) then
        self.aborted = true
    elseif in_rect(self.confirm_rect, pos) then
        self.confirmed = true
        local old = self.box_dimen
        self.box_dimen = self:_measure()  -- 收起按钮行，卡片变矮
        self:_refresh(old)
    end
    return true
end

-- 让出一次时间片：UIManager 借这段时间处理点击/重绘，超时后再把我们唤醒
function Toast:pump(delay)
    local co = coroutine.running()
    if not co then return end
    UIManager:scheduleIn(delay or .08, function()
        local ok, err = coroutine.resume(co)
        if not ok then logger.dbg("[MiuRead][ProgressToast] resume failed", tostring(err)) end
    end)
    coroutine.yield()
end

-- 兼容旧调用点：现在按钮上直接写明「取消 / 确定」，不再追加「点按此处可中止」。
function M.hint(text)
    return tostring(text or "")
end

-- opts.buttons = true 时显示「取消 / 确定」（下载、缓存这类可中止的长任务）；
-- 同步等短任务不显示按钮，但点外部也不再误取消。
function M.show(text, opts)
    M.close()
    opts = type(opts) == "table" and opts or {}
    local ok, toast = pcall(function()
        return Toast:new{
            text = tostring(text or ""),
            with_buttons = opts.buttons == true,
            only_cancel = opts.only_cancel == true,
        }
    end)
    if not ok or not toast then
        logger.warn("[MiuRead][ProgressToast] create failed", tostring(toast))
        return nil
    end
    live = toast
    UIManager:show(toast)
    if os.getenv("XREAD_AUTOTEST") then
        print(string.format("[XREAD_AUTOTEST] progress_card buttons=%s only_cancel=%s",
            tostring(opts.buttons == true), tostring(opts.only_cancel == true)))
        pcall(function() io.stdout:flush() end)
    end
    return toast
end

-- 更新文字并让出一次时间片；返回 false 表示用户点了「取消」。
function M.update(text, delay)
    local toast = live
    if not toast then return true end
    if text ~= nil then toast:setText(text) end
    if toast.aborted then return false end
    toast:pump(delay)
    return not toast.aborted
end

function M.aborted()
    return live ~= nil and live.aborted == true
end

function M.confirmed()
    return live ~= nil and live.confirmed == true
end

function M.close()
    local toast = live
    live = nil
    if not toast then return end
    pcall(function() UIManager:close(toast) end)
    -- 进度框是直接画在 framebuffer 上的（没有子控件），关掉后必须让整屏重画一次，
    -- 否则框的残影会留在正文上（真机上表现为「下载完了框还挂着」）。
    pcall(function() UIManager:setDirty("all", "ui") end)
end

return M
