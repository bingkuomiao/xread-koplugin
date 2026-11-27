-- xread.koplugin/xread/miui/repaint.lua
-- 延迟刷新合并器。
--
-- 背景：e-ink 上一次 "full" 刷新是真实的物理全刷（PW3 约 300~500ms 黑白闪），
-- 比 CPU 开销贵得多。而插件里有一批「操作结束后稍等一会儿，再补一次全刷
-- 清理残影」的逻辑（首页切节后的 quality cleanup、目录重建、弹层关闭等）。
-- 用户快速连点几次时，这些延迟任务会各自排一个定时器，等时间到了连续触发
-- 好几次全刷 —— 于是「点得快一点就黑闪好几下」。
--
-- 这个模块只做两件事：
--   1. debounce(key, delay, fn)：同 key 的延迟任务只保留最后一个（覆盖式），
--      时间窗口内反复安排同一个 key，最终只跑一次。
--   2. full_later(key, delay, target)：延迟全刷，天然去抖。
--
-- 注意：不做 setDirty 的同步节流/降级。KOReader 的 setDirty 只是标记 dirty，
-- 同一轮事件循环里的多次标记本来就会被合并成一次物理刷新（refresh mode 取
-- 最高），同步降级反而会把必要的 full 降成 ui、留下残影。

local UIManager = require("ui/uimanager")

local M = {}

local _timers = {}

local function now()
    local ok, socket = pcall(require, "socket")
    if ok and socket and socket.gettime then
        return socket.gettime()
    end
    return os.time()
end

--- 同 key 覆盖式延迟执行。窗口期内再次调用会撤销上一次，只跑最后一次。
-- @param key string 逻辑任务名，例如 "home.section_clean"
-- @param delay number 秒
-- @param fn function 到点执行
function M.debounce(key, delay, fn)
    key = tostring(key or "")
    if key == "" or type(fn) ~= "function" then return end
    local previous = _timers[key]
    if previous then
        pcall(function() UIManager:unschedule(previous.fn) end)
        previous.cancelled = true
    end
    local entry = { scheduled_at = now() }
    entry.fn = function()
        if _timers[key] ~= entry then return end
        _timers[key] = nil
        if entry.cancelled then return end
        local ok, err = pcall(fn)
        if not ok then
            pcall(function()
                require("logger").warn("[XRead][Repaint] task failed", key, tostring(err))
            end)
        end
    end
    _timers[key] = entry
    UIManager:scheduleIn(delay or 0, entry.fn)
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

return M
