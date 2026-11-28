-- xread/updater.lua — 插件在线热更新（列 /plugin 目录挑最新规范更新包）
--
-- 唯一更新入口：列出 /plugin 目录，按包名中的语义版本挑出最新 zip，
-- 下载后以包内 _meta.lua 版本做最终裁决，绝不安装旧包或同版本包。
-- 用户只要把规范命名的 zip 放进远端目录即完成发布，无需维护任何清单。
--
-- 列目录通道：
--   webdav：GET /reader3/getWebdavFileList?path=/plugin&accessToken=<token>
--     （后端已有接口，鉴权同 getWebdavFile；需安全模式 + 用户开启 WebDAV）
--   raw：  GET <root>filelist.json（XREAD_UPDATER_URL 指向更新根目录，本地测试用）
-- 下载通道：GET /reader3/getWebdavFile?path=/plugin/<文件>&accessToken=<token>
--   （token 失效自动重登一次）或 raw 模式下 GET <root><文件>
--
-- 规范包名（必须含语义版本，否则不参与挑选；支持 zip / tar.gz / tgz 三种格式）：
--   xread.koplugin_v<版本>_<YYYYMMDD-HHMMSS>.zip | .tar.gz | .tgz
--   例：xread.koplugin_v0.7.1-test_20261125-100000.zip
--      xread.koplugin_v0.7.1-test_20261125-100000.tar.gz
-- 强校验：<包名>.md5 sidecar（发布脚本自动生成，可选）。

local ltn12 = require("ltn12")
local HttpClient = require("xread/http_client")
local json = require("json")          -- KOReader 内置 LuaJSON（null 会解码成 function 哨兵）
local md5lib = require("ffi/MD5")     -- md5.sumFile(filename) -> hex string
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local DataStorage = require("datastorage")

local Updater = {}

-- 递归清洗 LuaJSON 的 function 哨兵（与 client.lua sanitizeJson 一致）
local function sanitizeJson(t)
    if type(t) ~= "table" then return t end
    for k, v in pairs(t) do
        if type(v) == "function" then
            t[k] = nil
        elseif type(v) == "table" then
            sanitizeJson(v)
        end
    end
end

--- 从 _meta.lua 文本解析 version（不走 require，避免模块缓存读到旧值）
local function parseVersionFromFile(text)
    return text and text:match("version%s*=%s*[\"']([^\"']+)[\"']") or nil
end

--- 从包名解析版本（含 -test 等后缀）：
---   xread.koplugin_v0.7.1-test_20261125-100000.zip -> 0.7.1-test
---   xread.koplugin_v0.7.1-test_20261125-100000.tar.gz -> 0.7.1-test
---   xread.koplugin-0.6.0.zip -> 0.6.0；取不到返回 nil（该包不参与挑选）。
local function parseVersionFromName(name)
    if type(name) ~= "string" then return nil end
    return name:match("[vV](%d+%.%d+%.%d+[%w%-]*)[_%.]")
        or name:match("(%d+%.%d+%.%d+[%w%-]*)")
end

--- "0.5.0" -> {0,5,0}
local function versionParts(v)
    local parts = {}
    for num in tostring(v or ""):gmatch("%d+") do
        parts[#parts + 1] = tonumber(num) or 0
    end
    return parts
end

--- 语义比较版本号：远端 > 本地 返回 true
function Updater.versionNewer(remote, local_v)
    local a, b = versionParts(remote), versionParts(local_v)
    for i = 1, math.max(#a, #b) do
        local x, y = a[i] or 0, b[i] or 0
        if x ~= y then return x > y end
    end
    return false
end

--- 插件根目录（xread/updater.lua -> 上两级）
function Updater.getPluginRoot()
    local source = debug.getinfo(1, "S").source or ""
    if source:sub(1, 1) == "@" then source = source:sub(2) end
    local module_dir = source:match("^(.*[/\\])") or ""
    return module_dir:gsub("xread[/\\]$", "")
end

--- 本地插件版本（读 _meta.lua 文件）
function Updater:getLocalVersion(plugin_root)
    plugin_root = plugin_root or (self and self.plugin_root) or Updater.getPluginRoot()
    plugin_root = plugin_root or Updater.getPluginRoot()
    local f = io.open(plugin_root .. "_meta.lua", "r")
    if not f then return nil end
    local text = f:read("*a")
    f:close()
    return parseVersionFromFile(text)
end

function Updater:new(opts)
    opts = opts or {}
    local o = {}
    o.plugin_root = opts.plugin_root or Updater.getPluginRoot()
    o.client = opts.client                -- xread/client.lua 实例（取 address）
    o.url_root = opts.url_root            -- raw 模式更新根目录（带尾斜杠）
    setmetatable(o, { __index = Updater })
    return o
end

--- GET 下载到字符串（不抛错，返回 nil, err）
--- 超时交给 xread/http_client：它保证请求结束后把全局 http.TIMEOUT 恢复原值。
--- 注意：socket.http 的 request 表里**没有** timeout 字段，写在这里是死参数，
--- 所以早期版本「列目录 10s / 下载 30s」实际都是全局值。
local function httpGetRaw(url, timeout)
    local chunks = {}
    local ok, code = HttpClient.request({
        url = url,
        sink = ltn12.sink.table(chunks),
    }, timeout or 30)
    if not ok then return nil, "网络错误" end
    if tonumber(code) ~= 200 then return nil, "HTTP " .. tostring(code) end
    return table.concat(chunks)
end

--- 更新包扩展名识别：zip / tar.gz / tgz 三种（KOReader ffi/archiver 基于
--- libarchive，format/filter 全开，tar.gz 解包与 zip 同一接口，无需额外处理）
local function archiveExt(name)
    local n = tostring(name or ""):lower()
    if n:match("%.tar%.gz$") then return ".tar.gz" end
    if n:match("%.tgz$") then return ".tgz" end
    if n:match("%.zip$") then return ".zip" end
    return nil
end

--- 更新文件根 URL（raw 模式）：settings.update_url > 环境变量；未设置返回 nil（webdav 模式）
function Updater:getRawUrlRoot()
    if self.url_root then return self.url_root end
    local env_url = os.getenv("XREAD_UPDATER_URL")
    if env_url and env_url ~= "" then
        self.url_root = env_url
        return self.url_root
    end
    return nil
end

--- 构造单个更新文件的下载 URL
--- raw 模式：<root><相对路径>；webdav 模式：getWebdavFile 接口 + accessToken
function Updater:fetchUrl(rel, cache_bust)
    local root = self:getRawUrlRoot()
    if root then
        return root .. rel .. "?v=" .. tostring(cache_bust)
    end
    local base = self.client and self.client.address or "http://127.0.0.1:7777"
    -- 只编码保留字符，保留字母数字与 ._-/ 以外的字符
    local enc = tostring(rel):gsub("[^%w%._%-/]", function(c)
        return string.format("%%%02X", string.byte(c))
    end)
    local token = (self.client and self.client.accessToken) or ""
    return base .. "/reader3/getWebdavFile?path=/plugin/" .. enc
        .. "&accessToken=" .. tostring(token)
        .. "&v=" .. tostring(cache_bust)
end

--- 带重登的 GET：builder() 每次现取 URL（webdav 的 accessToken 重登后会变），
--- 401/403 时用 client 凭据重登一次再试。所有更新请求都走这里。
function Updater:httpFetchVia(builder, timeout)
    local body, err = httpGetRaw(builder(), timeout)
    if not body and (err == "HTTP 401" or err == "HTTP 403") and self.client
            and self.client.username then
        local ok = pcall(function()
            self.client:login(self.client.username, self.client.password)
        end)
        if ok then
            return httpGetRaw(builder(), timeout)
        end
    end
    return body, err
end

--- 按文件名取单个更新文件
function Updater:httpFetch(rel, timeout)
    return self:httpFetchVia(function()
        return self:fetchUrl(rel, os.time())
    end, timeout)
end

--- 列目录 URL：
--- webdav 模式 GET /reader3/getWebdavFileList?path=/plugin&accessToken=...
--- raw 模式 GET <root>filelist.json
function Updater:fetchListUrl(cache_bust)
    local root = self:getRawUrlRoot()
    if root then
        return root .. "filelist.json?v=" .. tostring(cache_bust)
    end
    local base = self.client and self.client.address or "http://127.0.0.1:7777"
    local token = (self.client and self.client.accessToken) or ""
    return base .. "/reader3/getWebdavFileList?path=/plugin&accessToken="
        .. tostring(token) .. "&v=" .. tostring(cache_bust)
end

--- 拉取 /plugin 目录清单，返回更新包候选数组（失败返回 nil, err）：
--- 每项 { name, path, size, lastModified, version, md5 }
--- 兼容后端 { isSuccess, data = [...] }、裸数组、以及 data.list/data.files 包装。
function Updater:fetchFileList()
    -- 列目录只给 10s：这步在 UI 线程同步跑，后端挂了也不该把首页拖住
    local body, err = self:httpFetchVia(function()
        return self:fetchListUrl(os.time())
    end, 10)
    if not body then return nil, err end
    local ok, decoded = pcall(json.decode, body)
    if not ok or type(decoded) ~= "table" then return nil, "目录清单格式无效" end
    sanitizeJson(decoded)
    local arr = decoded
    if type(decoded.data) == "table" then
        arr = decoded.data
        if type(arr.list) == "table" then arr = arr.list end
        if type(arr.files) == "table" then arr = arr.files end
    end
    if type(arr) ~= "table" then return nil, "目录清单格式无效" end
    local out = {}
    for _, e in pairs(arr) do
        if type(e) == "table" and e.isDirectory ~= true then
            local name = e.name or tostring(e.path or ""):match("[^/]+$")
            if type(name) == "string" and archiveExt(name) then
                local version = parseVersionFromName(name)
                -- 没有语义版本的包不参与挑选（无法判断新旧）
                if version then
                    out[#out + 1] = {
                        name = name,
                        path = e.path or ("/plugin/" .. name),
                        size = tonumber(e.size),
                        lastModified = tonumber(e.lastModified) or 0,
                        version = version,
                        md5 = type(e.md5) == "string" and e.md5 or nil,
                    }
                end
            end
        end
    end
    return out
end

--- 从候选中挑最新版本：语义版本高者优先；版本相同/缺失时按 lastModified 取新。
function Updater:pickLatest(candidates)
    if type(candidates) ~= "table" or #candidates == 0 then return nil end
    local best = candidates[1]
    for i = 2, #candidates do
        local c = candidates[i]
        local take = false
        if c.version and best.version then
            if Updater.versionNewer(c.version, best.version) then
                take = true
            elseif not Updater.versionNewer(best.version, c.version) then
                take = (c.lastModified or 0) > (best.lastModified or 0)
            end
        elseif c.version and not best.version then
            take = true
        elseif not c.version and not best.version then
            take = (c.lastModified or 0) > (best.lastModified or 0)
        end
        if take then best = c end
    end
    return best
end

--- 把目录候选转成内部包描述（字段兼容调用方：package/version/size/md5）
local function packageInfoFromCandidate(c)
    return {
        version = c.version,
        package = c.name,
        package_size = c.size,
        package_md5 = c.md5,
        notes = "",
    }
end

--- 安全校验：只允许插件内的相对路径
local function safeRelPath(path)
    if type(path) ~= "string" or path == "" then return nil end
    if path:sub(1, 1) == "/" or path:find("\\", 1, true) then return nil end
    if path:find("%.%.") then return nil end     -- 禁 .. 任意段
    if path:sub(1, 1) == "." then return nil end -- 禁隐藏文件
    return path
end

--- 逐级创建目录，返回是否真的存在了。
-- 旧实现把路径当绝对路径处理（从 "" 开始拼 "/"、且第一段不创建）：
-- 一旦 plugin_root 是相对路径（KOReader 以相对路径启动时就是这样），
-- 它会去 mkdir "/plugins/..."，父目录不存在必然失败，表现为整包更新报
-- 「无法写入」——v0.6.29→0.6.31 新增 xread/feature/ 目录时正是这样炸的。
-- 交给 KOReader 的 util.makePath：它自己区分绝对/相对，从最近的已存在祖先逐级 mkdir。
local function ensureDir(path)
    if not path or path == "" then return true end
    if lfs.attributes(path, "mode") == "directory" then return true end
    local util = require("util")
    local ok = pcall(util.makePath, path)
    if ok and lfs.attributes(path, "mode") == "directory" then return true end
    -- 兜底：util.makePath 在极老固件上签名不同，退回手工逐级创建（相对/绝对都支持）
    local sep = path:sub(1, 1) == "/" and "/" or ""
    local cur = sep
    for seg in path:gmatch("[^/\\]+") do
        cur = (cur == "" or cur == "/") and (cur .. seg) or (cur .. "/" .. seg)
        if not lfs.attributes(cur, "mode") then pcall(lfs.mkdir, cur) end
    end
    return lfs.attributes(path, "mode") == "directory"
end

-- 供自动验收直接验证建目录行为（相对/绝对路径都要成立）。
-- 生产代码不会读这个字段，只是把同一个实现暴露出来，避免测试复制一份逻辑。
Updater.ensureDirForTest = ensureDir

--- 本地文件 md5（不存在返回 nil）
local function localMd5(path)
    if not lfs.attributes(path, "mode") then return nil end
    local ok, sum = pcall(md5lib.sumFile, path)
    if ok then return sum end
    return nil
end

--- 更新包落盘目录：<数据目录>/xread_update/
--- 压缩包与「同名解压目录」同级存放，每次更新的包可单独辨认，不再互相覆盖
local UPDATE_PKG_DIRNAME = "xread_update"
local KEEP_PACKAGES = 3          -- 只保留最近 N 次更新的包与解压目录

local function updatePkgRoot()
    return DataStorage:getDataDir() .. "/" .. UPDATE_PKG_DIRNAME
end

--- 从包名（可能是 URL 或路径）取出安全的文件基名，去掉压缩包扩展名
local function packageBaseName(name)
    local p = tostring(name or ""):gsub("\\", "/")
    p = p:match("[^/]+$") or ""
    local lower = p:lower()
    if lower:match("%.tar%.gz$") then p = p:sub(1, -8)
    elseif lower:match("%.tgz$") or lower:match("%.zip$") then p = p:sub(1, -5) end
    p = p:gsub("[^%w%._%-]", "_")          -- 禁路径分隔与特殊字符
    p = p:gsub("^%.+", "")                 -- 禁隐藏名
    if p == "" then return nil end
    return p
end

--- 删除目录（存在才删）；非目录退回单文件删除
local function removeTree(path)
    local mode = lfs.attributes(path, "mode")
    if not mode then return end
    if mode == "directory" then
        local ok, util = pcall(require, "ffi/util")
        if ok and util and util.purgeDir then
            pcall(util.purgeDir, path)
            return
        end
    end
    pcall(os.remove, path)
end

--- 记录本次已安装的包，并清理超出保留数量的旧包（压缩包 + 同名解压目录）
local function noteAppliedPackage(root, base, keep)
    local names = {}
    local f = io.open(root .. "/packages.txt", "r")
    if f then
        for line in f:lines() do
            local n = line:match("^%s*(.-)%s*$")
            if n ~= "" and n ~= base then names[#names + 1] = n end
        end
        f:close()
    end
    names[#names + 1] = base
    local over = #names - keep
    for i = 1, over do
        removeTree(root .. "/" .. names[i])
        removeTree(root .. "/" .. names[i] .. ".bak")   -- 安装失败回滚副本
        -- 清理历史压缩包时三种扩展名都试一遍（zip/tar.gz/tgz 混用也能清干净）
        for _, e in ipairs({ ".zip", ".tar.gz", ".tgz" }) do
            pcall(os.remove, root .. "/" .. names[i] .. e)
        end
    end
    local kept = {}
    for i = math.max(1, over + 1), #names do kept[#kept + 1] = names[i] end
    local w = io.open(root .. "/packages.txt", "w")
    if w then
        w:write(table.concat(kept, "\n") .. "\n")
        w:close()
    end
end

--- zip 包条目路径 → 插件根相对路径（兼容带 xread.koplugin/ 前缀的安装包）
local function packageRelPath(path)
    local p = tostring(path or ""):gsub("\\", "/")
    if p:sub(1, 2) == "./" then p = p:sub(3) end
    local inner = p:match("^xread%.koplugin/(.+)$")
    if inner then p = inner end
    return safeRelPath(p)
end

--- 复制文件（源不存在时返回 false）
local function copyFile(src, dst)
    local rf = io.open(src, "rb")
    if not rf then return false end
    local data = rf:read("*a")
    rf:close()
    if not data then return false end
    local dir = dst:match("^(.*)/[^/]+$")
    if dir then ensureDir(dir) end
    local wf = io.open(dst, "wb")
    if not wf then return false end
    local okw = wf:write(data)
    wf:close()
    return okw ~= nil
end

--- 原子替换单个文件
-- POSIX 同一文件系统内的 rename 是原子覆盖，直接 rename 就够了。
-- 原来「先 os.remove(target) 再 os.rename(tmp, target)」是致命的：rename 一旦失败
-- （只读挂载、文件被占用、跨设备、索引/杀毒锁），原文件已经删了，插件处于残缺状态。
-- 而更新入口就在插件内部（更多 → 关于本机），坏了就再进不去，只能手动拷文件。
-- 这里改为：先直接 rename；仅当目标存在导致 rename 失败（Windows/FAT/exFAT）时，
-- 退化为「备份 → rename → 删备份」，任何一步失败都回滚原文件。
-- @return true | false, err
local function atomicReplace(tmp, target)
    if os.rename(tmp, target) then return true end
    local bak = target .. ".xup_bak"
    os.remove(bak)
    local had_old = lfs.attributes(target, "mode") ~= nil
    if had_old then
        if not os.rename(target, bak) then
            os.remove(tmp)
            return false, "无法备份原文件"
        end
    end
    if os.rename(tmp, target) then
        if had_old then os.remove(bak) end
        return true
    end
    if had_old then os.rename(bak, target) end   -- 回滚
    os.remove(tmp)
    return false, "替换失败"
end

--- 安装一个已在磁盘上的更新包（zip/tar.gz/tgz）：
--- md5/size 由调用方先行校验（远端下载路径）；本地包以文件本身为准
--- expected_name_version：包名中的版本，用于与包内 _meta.lua 一致性裁决
--- on_progress(done, total, rel_path, skipped)
function Updater:installArchive(archive_path, expected_name_version, on_progress)
    local local_version = self:getLocalVersion()
    local base = packageBaseName(archive_path)
    if not base then error("更新包名不合法：" .. tostring(archive_path), 0) end
    if not archiveExt(archive_path) then
        error("不支持的更新包格式（仅 zip/tar.gz/tgz）：" .. tostring(archive_path), 0)
    end
    local root = updatePkgRoot()
    ensureDir(root)
    local extract_dir = root .. "/" .. base     -- 与压缩包同名（去扩展名）、同级
    local backup_dir = root .. "/" .. base .. ".bak"   -- 被替换文件的原始副本，失败回滚用

    self._last_package_file = archive_path
    self._last_package_dir = extract_dir

    local arc                     -- 提到 pcall 外，保证任何分支都能 close
    local applied = {}            -- { { target=, bak=路径|"absent" }, ... } 按替换顺序

    local okall, changed, skipped = pcall(function()
        -- 解压目标：与压缩包同名同级的目录；先清空，避免上次残留混进来
        removeTree(extract_dir)
        ensureDir(extract_dir)
        removeTree(backup_dir)
        ensureDir(backup_dir)
        local okreq, Archiver = pcall(require, "ffi/archiver")
        if not okreq then error("当前固件不支持压缩包解压：" .. tostring(Archiver), 0) end
        arc = Archiver.Reader:new()
        if not arc:open(archive_path) then error("无法打开更新包", 0) end
        local entries = {}
        for e in arc:iterate() do
            if e.mode == "file" then
                local rel = packageRelPath(e.path)
                if rel then entries[#entries + 1] = { key = e.path, rel = rel } end
            end
        end
        local has_meta = false
        for _, e in ipairs(entries) do
            if e.rel == "_meta.lua" then has_meta = true end
        end
        if not has_meta then error("更新包缺少 _meta.lua", 0) end

        -- 替换前把原文件复制到 backup_dir，失败时用于回滚
        -- @return 备份路径 | "absent"(原文件不存在) | nil(备份失败)
        local function backupOnce(rel)
            local target = self.plugin_root .. rel
            if not lfs.attributes(target, "mode") then return "absent" end
            local bak = backup_dir .. "/" .. rel
            if copyFile(target, bak) then return bak end
            return nil
        end

        local changed_n, skipped_n, failed = 0, 0, nil
        for i, e in ipairs(entries) do
            if on_progress then pcall(on_progress, i, #entries, e.rel, 0) end
            local content = arc:extractToMemory(e.key)
            if not content then
                failed = failed or {}
                failed[#failed + 1] = e.rel .. "（解压失败）"
            else
                if e.rel == "_meta.lua" then
                    local pv = parseVersionFromFile(content)
                    if not pv then error("更新包缺少版本号", 0) end
                    -- 包内版本为唯一事实来源：绝不装旧包/同版本包
                    if local_version and not Updater.versionNewer(pv, local_version) then
                        error("包内版本 " .. tostring(pv)
                            .. " 不高于本地 " .. tostring(local_version) .. "，跳过", 0)
                    end
                    -- 包名版本须与包内一致，防止放错包
                    if expected_name_version and tostring(expected_name_version) ~= pv then
                        error("包名版本 " .. tostring(expected_name_version)
                            .. " 与包内版本 " .. tostring(pv) .. " 不符", 0)
                    end
                end
                -- 先落盘到同名解压目录留档，再替换插件内文件
                local epath = extract_dir .. "/" .. e.rel
                local edir = epath:match("^(.*)/[^/]+$")
                if edir then ensureDir(edir) end
                local ef = io.open(epath, "wb")
                if ef then
                    ef:write(content)
                    ef:close()
                end
                local target = self.plugin_root .. e.rel
                local dir = target:match("^(.*)/[^/]+$")
                -- 建目录失败要和「写文件失败」分开报：混在一起只会看到「无法写入」，
                -- 根本看不出是父目录没创建出来。
                local dir_ok = true
                if dir then dir_ok = ensureDir(dir) end
                if not dir_ok then
                    failed = failed or {}
                    failed[#failed + 1] = e.rel .. "（无法创建目录：" .. tostring(dir) .. "）"
                end
                local tmp = target .. ".xup_tmp"
                local tf = dir_ok and io.open(tmp, "wb") or nil
                if dir_ok and not tf then
                    failed = failed or {}
                    failed[#failed + 1] = e.rel .. "（无法写入）"
                elseif tf then
                    local wrote = tf:write(content)
                    tf:close()
                    if not wrote then
                        os.remove(tmp)
                        failed = failed or {}
                        failed[#failed + 1] = e.rel .. "（写入不完整，可能是磁盘已满）"
                    elseif e.rel:match("%.lua$") and not pcall(loadfile, tmp) then
                        -- 覆盖前先做语法校验：包里的 .lua 半截/编码损坏时，
                        -- 直接替换上去会让插件下次启动就崩，而更新入口就在插件内部，
                        -- 用户再也没有办法从界面修好它。
                        os.remove(tmp)
                        failed = failed or {}
                        failed[#failed + 1] = e.rel .. "（语法校验失败，已跳过）"
                    else
                        local new_md5, old_md5 = localMd5(tmp), localMd5(target)
                        if new_md5 and old_md5 and new_md5 == old_md5 then
                            os.remove(tmp)
                            skipped_n = skipped_n + 1
                        else
                            local bak = backupOnce(e.rel)
                            if not bak then
                                os.remove(tmp)
                                failed = failed or {}
                                failed[#failed + 1] = e.rel .. "（无法备份原文件，已跳过）"
                            else
                                local ok_rep, rep_err = atomicReplace(tmp, target)
                                if ok_rep then
                                    applied[#applied + 1] = { target = target, bak = bak }
                                    changed_n = changed_n + 1
                                else
                                    failed = failed or {}
                                    failed[#failed + 1] = e.rel .. "（" .. tostring(rep_err) .. "）"
                                end
                            end
                        end
                    end
                end
            end
        end
        if failed and #failed > 0 then
            error("以下文件更新失败：\n" .. table.concat(failed, "\n"), 0)
        end
        return changed_n, skipped_n
    end)

    -- 无论成败都要关句柄：原来循环里 error() 会直接跳出，arc:close() 被跳过，
    -- libarchive 句柄泄漏，反复检查更新后固件句柄耗尽。
    if arc then pcall(arc.close, arc) end

    if not okall then
        -- 回滚已替换的文件（逆序），清掉半成品解压目录；压缩包保留便于排查
        for i = #applied, 1, -1 do
            local rec = applied[i]
            if rec.bak == "absent" then
                os.remove(rec.target)
            else
                local rb = rec.target .. ".xup_rb"
                if copyFile(rec.bak, rb) then atomicReplace(rb, rec.target) end
            end
        end
        pcall(removeTree, extract_dir)
        removeTree(backup_dir)
        error(changed, 0)
    end

    removeTree(backup_dir)       -- 成功：不再需要回滚副本
    noteAppliedPackage(root, base, KEEP_PACKAGES)
    logger.info("xread updater: applied package", tostring(expected_name_version),
        "changed", tostring(changed), "skipped", tostring(skipped),
        "package", archive_path, "extract", extract_dir)
    return changed, skipped
end

--- 列目录选中的更新包（zip/tar.gz/tgz）：下载整包 → md5/size 校验 → installArchive
function Updater:applyPackage(manifest, on_progress)
    local zip_name = manifest.package
    if not zip_name or zip_name == "" then error("更新清单缺少包名", 0) end
    local ext = archiveExt(zip_name)
    if not ext then error("不支持的更新包格式（仅 zip/tar.gz/tgz）：" .. tostring(zip_name), 0) end
    local base = packageBaseName(zip_name)
    if not base then error("更新包名不合法：" .. tostring(zip_name), 0) end
    local root = updatePkgRoot()
    ensureDir(root)
    local archive_path = root .. "/" .. base .. ext

    local body, err = self:httpFetch(zip_name)
    if not body then error("下载更新包失败：" .. tostring(err), 0) end

    -- 后端列目录不返回 md5：尝试同名 .md5 sidecar（发布端自动生成）
    local want_md5 = manifest.package_md5
    if not want_md5 then
        local ok_side, side = pcall(function()
            local b = self:httpFetch(zip_name .. ".md5")
            return type(b) == "string" and b:match("^%s*(%x+)%s*$") or nil
        end)
        if ok_side and side then want_md5 = side end
    end

    local f = io.open(archive_path, "wb")
    if not f then error("无法写入更新包：" .. archive_path, 0) end
    local wrote = f:write(body)
    f:close()
    if not wrote then
        os.remove(archive_path)
        error("写入更新包失败（可能磁盘已满）：" .. archive_path, 0)
    end

    local okall, changed, skipped = pcall(function()
        if manifest.package_size and #body ~= tonumber(manifest.package_size) then
            error("更新包大小不符", 0)
        end
        if want_md5 and localMd5(archive_path) ~= want_md5 then
            error("更新包校验不符", 0)
        end
        return self:installArchive(archive_path, manifest.version, on_progress)
    end)
    if not okall then error(changed, 0) end
    return changed, skipped
end

--- 本地更新包扫描：仅插件目录内，规范命名的 zip/tar.gz/tgz
function Updater:findLocalPackages()
    local dir = (self.plugin_root or Updater.getPluginRoot()):gsub("/+$", "") .. "/"
    local out = {}
    local ok, iter, obj = pcall(lfs.dir, dir)
    if ok then
        for name in iter, obj do
            local ext = archiveExt(name)
            local path = dir .. name
            if ext and lfs.attributes(path, "mode") == "file" then
                local version = parseVersionFromName(name)
                if version then
                    out[#out + 1] = {
                        name = name,
                        path = path,
                        version = version,
                        size = tonumber(lfs.attributes(path, "size")) or 0,
                        lastModified = tonumber(lfs.attributes(path, "modification")) or 0,
                    }
                end
            end
        end
    end
    return out
end

--- 本地包检查：插件目录内的规范包挑最新，且须高于本地版本；没有返回 nil
--- 返回 manifest（package=绝对路径, local_file=true）与 info（via="local"）
function Updater:checkLocal()
    local local_version = self:getLocalVersion()
    local best = self:pickLatest(self:findLocalPackages())
    if not best or not Updater.versionNewer(best.version, local_version) then
        return nil
    end
    return {
        package = best.path,
        version = best.version,
        package_size = best.size,
        notes = "",
        local_file = true,
    }, {
        newer = true,
        local_version = local_version,
        remote_version = best.version,
        via = "local",
    }
end

--- 本地包安装：不经网络，直接解压校验并增量替换；
--- 安装成功后把源包挪入 xread_update/ 留存（跨设备移动失败则原地保留）
function Updater:applyLocalPackage(manifest, on_progress)
    local src = manifest.package
    if not src or lfs.attributes(src, "mode") ~= "file" then
        error("本地更新包不存在：" .. tostring(src), 0)
    end
    local changed, skipped = self:installArchive(src, manifest.version, on_progress)
    local base = packageBaseName(src)
    local ext = archiveExt(src) or ".zip"
    local dst = updatePkgRoot() .. "/" .. base .. ext
    if src ~= dst then
        local rf = io.open(src, "rb")
        if rf then
            local blob = rf:read("*a")
            rf:close()
            local wf = io.open(dst, "wb")
            if wf then
                wf:write(blob)
                wf:close()
                os.remove(src)
            end
        end
    end
    self._last_package_file = dst
    return changed, skipped
end

--- 最近一次更新的包路径与解压目录（UI 提示用，未更新过返回 nil）
function Updater:getLastPackage()
    return self._last_package_file, self._last_package_dir
end

--- 应用更新：下载 zip 整包 → 校验 → 文件级 md5 增量替换
--- on_progress(done, total, path, skipped)
--- 成功返回 changed, skipped；失败抛错（version 不落盘，下次重试）
function Updater:apply(manifest, on_progress)
    if type(manifest.package) ~= "string" or manifest.package == "" then
        error("更新清单缺少包名", 0)
    end
    return self:applyPackage(manifest, on_progress)
end

--- 只检查不下载：返回包描述 + { newer, local_version, remote_version, via }
--- 列 /plugin 目录（webdav getWebdavFileList / raw filelist.json），
--- 按包名语义版本挑最新；列目录失败或无规范包时抛错（无清单回退路径）。
function Updater:check()
    local local_version = self:getLocalVersion()
    local candidates, err = self:fetchFileList()
    if not candidates then
        error("无法列出更新目录：" .. tostring(err), 0)
    end
    local best = self:pickLatest(candidates)
    if not best then
        error("更新目录中没有可识别的规范更新包（zip/tar.gz/tgz）", 0)
    end
    local manifest = packageInfoFromCandidate(best)
    local newer = Updater.versionNewer(best.version, local_version)
    return manifest, {
        newer = newer,
        local_version = local_version,
        remote_version = best.version,
        total = 0,
        skipped = 0,
        via = "list",
    }
end

return Updater
