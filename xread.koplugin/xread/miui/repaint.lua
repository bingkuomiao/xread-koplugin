-- xread.koplugin/xread/miui/repaint.lua
-- 刷新 / 延迟任务的合并器。
--
-- 背景：e-ink 上一次 "full" 刷新是真实的物理全刷（PW3 约 300~500ms 黑白闪），
-- 比 CPU 开销贵得多。插件里有一批「操作结束后稍等一会儿，再补一次全刷清残影」
-- 的逻辑（首页切节后的 quality cleanup、目录重建、弹层关闭等）。
-- 用户快速连点几次时，这些延迟任务会各自排一个定时器，等时间到了连续触发
-- 好几次全刷 —— 于是「点得快一点就黑闪好几下」。
--
-- 这个模块做三件事：
--   1. debounce(key, delay, fn)：同 key 的延迟任务只保留最后一个（覆盖式）。
--   2. paint(key, mode, rect, window)：同 key 的标脏请求在时间窗口内合并成一次，
--      full 优先于 ui，区域取并集。用于 dialog_transition / message_box 这类
--      「同一交互里连着标脏好几次」的路径。
--   3. full_later(key, delay, target)：延迟全刷，天然去抖。
--
-- 不做 setDirty 的同步降级：KOReader 的 setDirty 只是标记 dirty，同一轮事件
-- 循环里的多次标记本来就会合并成一次物理刷新；把 full 降成 ui 会留残影。
-- 本模块合并的是「跨 tick、但同属一次交互」的重复请求，那是 KOReader 帮不了的。
--
-- 所有合并动作都记在 M.stats 里；设置 XREAD_PERF_LOG=1 会在每次合并/冲刷后打
-- 一行 logger.dbg，方便在真机上确认门限是否真的生效（WSL 上测不出 e-ink 耗时）。

local UIManager = require("ui/uimanager")
local logger = require("logger")
local Geom = require("ui/geometry")
local Geometry = require("xread.miui.modal_geometry")

local M = {}

local _timers = {}
local _paints = {}

--- 累计计数，诊断/自动验收用。
M.stats = {
    full_requests = 0,
    full_issued = 0,
    full_merged = 0,
    paint_requests = 0,
    paint_issued = 0,
    paint_merged = 0,
    debounce_calls = 0,
    debounce_cancelled = 0,
    debounce_runs = 0,
}

local function perf(fmt, ...)
    if os.getenv("XREAD_PERF_LOG") ~= "1" then return end
    -- LuaJIT 不允许在嵌套闭包里直接用 ...，先在里面格式化好再送 logger
    local ok, msg = pcall(string.format, fmt, ...)
    if not ok then return end
    pcall(function() logger.dbg("[XRead][Perf] " .. msg) end)
end

local function now()
    local ok, socket = pcall(require, "socket")
    if ok and socket and socket.gettime then
        return socket.gettime()
    end
    return os.time()
end

--- 同 key 覆盖式延迟执行。窗口期内再次调用会撤销上一次，只跑最后一次。
-- @param key string 逻辑任务名，例如 "home.rebuild"
-- @param delay number 秒
-- @param fn function 到点执行
function M.debounce(key, delay, fn)
    key = tostring(key or "")
    if key == "" or type(fn) ~= "function" then return end
    M.stats.debounce_calls = M.stats.debounce_calls + 1
    local previous = _timers[key]
    if previous then
        pcall(function() UIManager:unschedule(previous.fn) end)
        previous.cancelled = true
        M.stats.debounce_cancelled = M.stats.debounce_cancelled + 1
        perf("debounce cancel key=%s", key)
    end
    local entry = { scheduled_at = now() }
    entry.fn = function()
        if _timers[key] ~= entry then return end
        _timers[key] = nil
        if entry.cancelled then return end
        M.stats.debounce_runs = M.stats.debounce_runs + 1
        local ok, err = pcall(fn)
        if not ok then
            pcall(function()
                logger.warn("[XRead][Repaint] task failed", key, tostring(err))
            end)
        end
    end
    _timers[key] = entry
    UIManager:scheduleIn(delay or 0, entry.fn)
end

--- 把同一交互里对同一 key 的多次标脏合并成一次。
-- mode 取 "full" > "ui"；rect 取并集；window 默认 0.12s。
-- 首次请求在窗口末尾统一发出，所以不会比原来更早刷，也不会吞掉后续内容变化。
-- @param key string 交互标识，例如 "dialog.restore" / "msgbox"
-- @param mode string "ui" | "full"
-- @param rect table|nil nil 表示整屏
-- @param window number|nil 合并窗口（秒）
function M.paint(key, mode, rect, window)
    key = tostring(key or "")
    if key == "" then return end
    if mode ~= "full" and mode ~= "ui" then mode = "ui" end
    M.stats.paint_requests = M.stats.paint_requests + 1
    if mode == "full" then M.stats.full_requests = M.stats.full_requests + 1 end

    local pending = _paints[key]
    if not pending then
        pending = { mode = mode, rect = rect, flush_at = now(), merged = 0 }
        _paints[key] = pending
        pending.timer = function()
            if _paints[key] ~= pending then return end
            _paints[key] = nil
            M.stats.paint_issued = M.stats.paint_issued + 1
            if pending.mode == "full" then M.stats.full_issued = M.stats.full_issued + 1 end
            perf("paint flush key=%s mode=%s waited=%.3f merged=%d",
                key, pending.mode, now() - pending.flush_at, pending.merged)
            pcall(function()
                UIManager:setDirty("all", pending.mode,
                    pending.rect and Geom:new(pending.rect) or nil)
            end)
        end
        UIManager:scheduleIn(window or 0.12, pending.timer)
        return
    end

    if mode == "full" and pending.mode ~= "full" then
        pending.mode = "full"
    end
    pending.rect = Geometry.union(pending.rect, rect)
    pending.merged = pending.merged + 1
    M.stats.paint_merged = M.stats.paint_merged + 1
    if mode == "full" then M.stats.full_merged = M.stats.full_merged + 1 end
    perf("paint merge key=%s mode=%s rect=%s", key, mode,
        pending.rect and string.format("%dx%d+%d+%d", pending.rect.w, pending.rect.h,
            pending.rect.x, pending.rect.y) or "all")
end

--- 延迟一次全屏刷新（同 key 覆盖）。
-- target 用 "all" 表示整屏；传 widget 时只标记该 widget。
function M.full_later(key, delay, target)
    M.debounce(key, delay, function()
        UIManager:setDirty(target or "all", "full")
    end)
end

--- 撤销一个还没执行的延迟任务。
function M.cancel(key)
    local entry = _timers[tostring(key or "")]
    if not entry then return false end
    entry.cancelled = true
    pcall(function() UIManager:unschedule(entry.fn) end)
    _timers[key] = nil
    return true
end

--- 撤销全部（视图关闭时用，避免关掉之后还对着旧 widget 刷新）。
function M.cancel_all()
    for key, entry in pairs(_timers) do
        entry.cancelled = true
        pcall(function() UIManager:unschedule(entry.fn) end)
        _timers[key] = nil
    end
    for key, pending in pairs(_paints) do
        pcall(function() UIManager:unschedule(pending.timer) end)
        _paints[key] = nil
    end
end

--- 诊断/测试用：某个 key 是否还有待执行任务。
function M.is_pending(key)
    local entry = _timers[tostring(key or "")]
    return entry ~= nil and entry.cancelled ~= true
end

--- 诊断/测试用：当前排队的 key 数量。
function M.pending_count()
    local n = 0
    for _, entry in pairs(_timers) do
        if not entry.cancelled then n = n + 1 end
    end
    return n
end

--- 一行汇总，供自动验收日志和真机排查使用。
function M.stats_line()
    local s = M.stats
    return string.format(
        "paint req=%d issued=%d merged=%d full req=%d issued=%d merged=%d debounce call=%d cancel=%d run=%d",
        s.paint_requests, s.paint_issued, s.paint_merged,
        s.full_requests, s.full_issued, s.full_merged,
        s.debounce_calls, s.debounce_cancelled, s.debounce_runs)
end

return M
