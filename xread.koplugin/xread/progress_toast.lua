-- 长任务进度提示（整本缓存 / 整本导出）。
--
-- 为什么不用 Trapper:info：
--   Trapper:info(text) 每次调用都是「关掉旧 InfoMessage → 新建一个 → forceRePaint」。
--   我们的轮询为了不卡界面，每轮都会调一次 Trapper:info(nil) 让出时间片，
--   而 text=nil 会新建一个「文字为空」的 InfoMessage —— 真机表现就是：
--   进度框不停地闪，中间反复出现一个空白框（截图里那个只有 ⓘ 的空条）。
--
-- 这里的做法：
--   ① 只建一个提示框，文字原地 setText，只在文字变了才请求重绘（不闪）；
--   ② 白底 + 2px 黑边自己画（不依赖 FrameContainer 的圆角/边框路径）；
--   ③ 重绘区域限定在框本身，不整屏刷；
--   ④ 用 scheduleIn + coroutine.yield 让出时间片，UI 事件照常处理；
--   ⑤ 点一下提示框即可中止（框里写明），不必干等几分钟。

local Blitbuffer = require("ffi/blitbuffer")
local Geom = require("ui/geometry")
local UIManager = require("ui/uimanager")
local Device = require("device")
local Screen = Device.screen
local Font = require("ui/font")
local InputContainer = require("ui/widget/container/inputcontainer")
local TextBoxWidget = require("ui/widget/textboxwidget")
local GestureRange = require("ui/gesturerange")
local logger = require("logger")

local M = {}

local live

local ABORT_HINT = "（点按此处可中止）"
local BORDER = 2

local Toast = InputContainer:extend{
    text = "",
    aborted = false,
    _miuread_transient = true,
    -- 只是进度提示，不参与 TransientGuard 的模态互斥
    _miuread_modal_surface = false,
}

function Toast:init()
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    self.full_dimen = Geom:new{ x = 0, y = 0, w = sw, h = sh }
    self.dimen = self.full_dimen
    self.pad = Screen:scaleBySize(16)
    self.text_w = math.max(1,
        math.min(sw - Screen:scaleBySize(90), Screen:scaleBySize(660)) - self.pad * 2)
    self.text_widget = TextBoxWidget:new{
        text = self.text,
        face = Font:getFace("cfont", 17),
        width = self.text_w,
        alignment = "center",
        fgcolor = Blitbuffer.COLOR_BLACK,
    }
    self.box_dimen = self:_measure()
    -- 整屏热区、只画中间那块：既吞掉误触（导出时别翻页），又不糊住正文
    self.ges_events = { Tap = { GestureRange:new{ ges = "tap", range = self.full_dimen } } }
end

function Toast:_measure()
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    local size = self.text_widget and self.text_widget:getSize() or nil
    local tw = math.max(1, tonumber(size and size.w) or 1)
    local th = math.max(1, tonumber(size and size.h) or 1)
    local box_w = math.min(sw - Screen:scaleBySize(40), tw + self.pad * 2 + BORDER * 2)
    local box_h = th + self.pad * 2 + BORDER * 2
    local box_x = math.floor((sw - box_w) / 2)
    local box_y = math.floor(sh * .58)
    if box_y + box_h > sh - Screen:scaleBySize(24) then
        box_y = math.max(Screen:scaleBySize(24), math.floor((sh - box_h) / 2))
    end
    return Geom:new{ x = box_x, y = box_y, w = box_w, h = box_h }
end

-- 自己画白底 + 黑边 + 居中文字：整块区域完全由这里决定，
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
    local size = self.text_widget and self.text_widget:getSize() or nil
    local tw = tonumber(size and size.w) or 0
    local th = tonumber(size and size.h) or 0
    local tx = bx + math.floor((d.w - tw) / 2)
    local ty = by + math.floor((d.h - th) / 2)
    self.text_widget:paintTo(bb, math.max(bx + BORDER, tx), math.max(by + BORDER, ty))
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
    UIManager:setDirty(self, function() return "ui", region end)
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

function Toast:onTap()
    self.aborted = true
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

function M.hint(text)
    return tostring(text or "") .. "\n" .. ABORT_HINT
end

function M.show(text)
    M.close()
    local ok, toast = pcall(function() return Toast:new{ text = tostring(text or "") } end)
    if not ok or not toast then
        logger.warn("[MiuRead][ProgressToast] create failed", tostring(toast))
        return nil
    end
    live = toast
    UIManager:show(toast)
    return toast
end

-- 更新文字并让出一次时间片；返回 false 表示用户点了中止
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
