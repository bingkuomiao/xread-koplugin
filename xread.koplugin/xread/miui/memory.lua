-- xread.koplugin/xread/miui/memory.lua
-- 运行时内存档位。
--
-- 为什么需要它：插件里几处「缓存」的开销是整屏级的（1072x1448 的 32bpp
-- 图层约 6MB/层），在 512MB 的 PW3 上开 3 层就是 18MB 常驻，再加上
-- ImageCache 里所有解码过的封面，低内存设备很容易被挤出 OOM 或者频繁 GC。
-- 这里只做一件事：读一次 /proc/meminfo，把设备分成 low / normal 两档，
-- 让调用方用「档位」而不是硬编码常量来决定缓存策略。
--
-- 判定不依赖 Device.model（Simulator/真机/Kobo/Android 都通吃），
-- 也提供 XREAD_MEM_TIER=low|normal 环境变量用于在模拟器上强制跑低内存路径。

local logger = require("logger")

local M = {}

local MB = 1024 * 1024
-- 512MB 机型（PW3/PW2/KT4）MemTotal 普遍在 430~500MB；
-- 1GB 机型在 900MB 以上。阈值取在中间，避免 768MB 机型被误判成 low。
local LOW_TOTAL_BYTES = 700 * MB
-- 剩余内存低于这个值时就地降档：即使总内存够，当前也可能已经很紧张。
local LOW_AVAILABLE_BYTES = 120 * MB

local cached

local function read_meminfo()
    local f = io.open("/proc/meminfo", "r")
    if not f then return nil, nil end
    local total, avail
    for line in f:lines() do
        local key, kb = line:match("^(%w+):%s*(%d+)")
        if key == "MemTotal" then
            total = tonumber(kb) * 1024
        elseif key == "MemAvailable" then
            avail = tonumber(kb) * 1024
        end
    end
    f:close()
    return total, avail
end

local function tier_from_env()
    local forced = tostring(os.getenv("XREAD_MEM_TIER") or ""):lower()
    if forced == "low" or forced == "normal" then return forced end
    return nil
end

--- 返回当前内存快照，结果会缓存。
-- @param refresh boolean 为 true 时重新读 /proc/meminfo（可用内存会变）
-- @return table { total, available, tier = "low"|"normal", low = boolean }
function M.snapshot(refresh)
    if cached and not refresh then return cached end
    local total, avail = read_meminfo()
    local tier = tier_from_env()
    if not tier then
        tier = "normal"
        if total and total <= LOW_TOTAL_BYTES then
            tier = "low"
        elseif avail and avail <= LOW_AVAILABLE_BYTES then
            tier = "low"
        end
    end
    cached = {
        total = total,
        available = avail,
        tier = tier,
        low = tier == "low",
    }
    return cached
end

function M.is_low()
    return M.snapshot().low == true
end

-- 首页整屏图层缓存层数。每层都是一整块屏幕大小的 Blitbuffer：
--   low    → 1（只留当前节，切节时重排一次，换回整块内存）
--   其它   → 3（切节几乎无重绘，交互最顺）
function M.section_cache_layers()
    if M.is_low() then return 1 end
    return 3
end

-- 封面进入全局 ImageCache 的预算。
-- file_do_cache=true 会把解码后的 Blitbuffer 交给 ImageCache 常驻。那个缓存是
-- KOReader 全局的 8MiB / 128 项 LRU，里面还混着图标；插件每翻一页就塞 8 张
-- 封面（PW3 上约 2~3MB），几页之后图标被挤出去，封面却几乎不会再被复用
-- （翻回来时视图已重建、封面路径也换了）。
-- 所以只给「一屏多一点」的额度：16 张 ≈ 两页；用完的封面改由 widget 持有，
-- widget 树 free() 时立刻回收。低内存档位额度为 0（全部归 widget）。
local COVER_CACHE_BUDGET = 16
local cover_budget

local function budget()
    if cover_budget == nil then
        cover_budget = M.is_low() and 0 or COVER_CACHE_BUDGET
    end
    return cover_budget
end

--- 创建封面 ImageWidget 时调用：还有额度就进 ImageCache，否则归 widget 自己。
function M.cover_do_cache()
    local left = budget()
    if left <= 0 then return false end
    cover_budget = left - 1
    return true
end

--- 诊断用：还剩多少张封面可以进 ImageCache / 已经用掉多少张。
function M.cover_cache_left() return budget() end
function M.cover_cache_spent() return COVER_CACHE_BUDGET - budget() end

--- 供测试/诊断输出一行档位摘要。
function M.describe()
    local s = M.snapshot(true)
    return string.format("tier=%s total=%sMB avail=%sMB layers=%d cover_cache=%s budget=%d/%d",
        tostring(s.tier),
        s.total and tostring(math.floor(s.total / MB)) or "?",
        s.available and tostring(math.floor(s.available / MB)) or "?",
        M.section_cache_layers(),
        tostring(budget() > 0),  -- 兼容 28_memory_low 的 cover_cache=false 断言
        M.cover_cache_left(), M.cover_cache_spent())
end

function M.reset()
    cached = nil
    cover_budget = nil
end

pcall(function()
    logger.dbg("[XRead][Memory]", M.describe())
end)

return M
