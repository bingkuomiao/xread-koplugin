local UIManager = require("ui/uimanager")
local logger = require("logger")
local Geometry = require("xread.miui.modal_geometry")
local Repaint = require("xread.miui.repaint")

local M = {generation = 0}

function M.cancel_pending()
    M.generation = M.generation + 1
    return M.generation
end

-- CloseWidget can run before the widget is removed from UIManager's stack.
-- Never paint the retired window in place: ask UIManager to repaint the
-- CURRENT stack on the next turn.  "all" requests layout paint, whereas
-- nil requests waveform only and may leave an old frame behind.
--
-- after_close 在三个连续 tick 里会各标脏一次（旧框、动作后的新框、两者并集）。
-- 三次都是局部 ui 刷新，在 PW3 上就是三次物理局刷；交给 Repaint 在 120ms
-- 窗口内取并集合成一次，区域完全覆盖，肉眼看到的结果不变。
function M.restore(region, mode)
    local safe = Geometry.rect(region, 3)
    if safe then
        Repaint.paint("dialog.restore", mode or "ui", safe)
    end
end

-- The newly revealed dialog may be larger than the retired one.  Include its
-- frame only, not its full-screen gesture capture layer.
local function current_modal_frame()
    local stack = UIManager._window_stack or {}
    for i = #stack, 1, -1 do
        local window = stack[i]
        local widget = window and window.widget
        if widget and widget._miuread_modal_surface == true then
            local rect = widget.bubble_dimen or widget.popup_dimen
                or widget.frame_dimen or widget.panel_dimen
            if rect then return Geometry.rect(rect, 3) end
        end
    end
    return nil
end

function M.after_close(region, action, label)
    local token = M.cancel_pending()
    local old = Geometry.rect(region, 3)
    UIManager:nextTick(function()
        -- Never run a stale action after a newer explicit navigation.
        -- A newer modal may have superseded the pending action, but its
        -- appearance does not erase the old surface's physical ink pixels.
        -- Restore the retired frame even when the action is stale.
        M.restore(old)
        if token ~= M.generation then return end
        if type(action) ~= "function" then return end
        -- The next turn follows the retired widget's removal, not an
        -- arbitrary 40/50ms delay which varies across e-ink devices.
        UIManager:nextTick(function()
            if token ~= M.generation then return end
            local ok, err = pcall(action)
            if not ok then
                logger.warn("[MiuRead][DialogTransition] action failed", tostring(label or "dialog"), tostring(err))
            end
            -- New UI may be larger or smaller; its own show() dirties its
            -- complete frame. Repaint the OLD footprint on the current stack
            -- even if the action opened another dialog (and changed token).
            UIManager:nextTick(function()
                M.restore(Geometry.union(old, current_modal_frame()))
            end)
        end)
    end)
    return token
end

return M
