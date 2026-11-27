-- 共享 UI 原语：尺寸换算、数值夹取、圆角填充、标题折行。
-- 书架 / 目录 / 统计 / 快捷面板原来各存一份实现（4 份 scaled、2 份 wrapTitle、
-- 2 份 fillRound、2 份 clamp），这里收敛为唯一来源，改一处即全部生效。
local Blitbuffer = require("ffi/blitbuffer")
local Screen = require("device").screen
local TextWidget = require("ui/widget/textwidget")
local util = require("util")

local M = {}

-- 按屏幕缩放，四舍五入到整像素
function M.scaled(px)
    return math.floor(px * (Screen:scaleBySize(1000) / 1000) + 0.5)
end

function M.clamp(v, a, b)
    if v < a then return a end
    if v > b then return b end
    return v
end

-- 圆角矩形填充：按色深选 8bit / RGB32 接口
function M.fill_round(bb, x, y, w, h, color, r)
    if w <= 0 or h <= 0 then return end
    local fn = Blitbuffer.isColor8(color) and bb.paintRoundedRect or bb.paintRoundedRectRGB32
    fn(bb, x, y, w, h, color, r or 0)
end

-- 按字符宽度折成最多两行；第二行仍超宽时截断并补省略号。
-- 返回 line1, line2（可能为空串）。
function M.wrap_title(text, face, width)
    local chars = util.splitToChars(text or "")
    local lines, cur = {}, ""
    local overflow = false
    for _i, ch in ipairs(chars) do
        local test = cur .. ch
        if cur == "" or TextWidget.getTextWidth(test, face, false, 0) <= width then
            cur = test
        else
            lines[#lines + 1] = cur
            cur = ch
            if #lines == 2 then
                overflow = true
                break
            end
        end
    end
    if #lines < 2 then
        lines[#lines + 1] = cur
    end
    if overflow and lines[2] then
        local second = util.splitToChars(lines[2])
        while #second > 0
            and TextWidget.getTextWidth(table.concat(second) .. "…", face, false, 0) > width do
            table.remove(second)
        end
        lines[2] = table.concat(second) .. "…"
    end
    return lines[1] or "", lines[2] or ""
end

return M
