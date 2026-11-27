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

-- 封面是否进入全局 ImageCache。
-- file_do_cache=true 会把解码后的 Blitbuffer 交给 ImageCache 常驻（按字节
-- 上限淘汰），首页+书架+翻过的所有封面都会堆在里面；低内存设备上改成
-- false，让 Blitbuffer 归 widget 所有，widget 树 free() 时立刻回收。
function M.cover_do_cache()
    return not M.is_low()
end

--- 供测试/诊断输出一行档位摘要。
function M.describe()
    local s = M.snapshot(true)
    return string.format("tier=%s total=%sMB avail=%sMB layers=%d cover_cache=%s",
        tostring(s.tier),
        s.total and tostring(math.floor(s.total / MB)) or "?",
        s.available and tostring(math.floor(s.available / MB)) or "?",
        M.section_cache_layers(),
        tostring(M.cover_do_cache()))
end

function M.reset()
    cached = nil
end

pcall(function()
    logger.dbg("[XRead][Memory]", M.describe())
end)

return M
