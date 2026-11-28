-- xread.koplugin/xread/book_cache.lua
-- 书架侧的书本操作：从后端移除书籍、整本预缓存（含人工中止）、漫画下载并打包 CBZ。
--
-- 从 main.lua 拆出（Batch 2），方法仍挂在同一个 XRead 类上。
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local Menu = require("ui/widget/menu")
local Trapper = require("ui/trapper")
local Screen = require("device").screen
local util = require("util")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template
local ffiutil = require("ffi/util")
local BookExport = require("xread.book_export")
local ProgressToast = require("xread.progress_toast")
local MessageBox = require("xread.message_box")

local M = {}

function M.install(env)
    local XRead = env.XRead
    local SHARED = env.SHARED
    local BOOK_DIR = env.BOOK_DIR
    local bookCacheStem = env.bookCacheStem
    local removeBookCacheFiles = env.removeBookCacheFiles
    local fileSize = env.fileSize
    local readable_error = env.readable_error
    local reapSubProcess = env.reapSubProcess

    -- ---------- 移除书籍（从后端书架删除） ----------
    -- 真正执行删除：后端 deleteBook + 本地章节/目录缓存清理 + 刷新书架缓存
    function XRead:_confirmRemoveBook(book)
        MessageBox.confirm{
            text = T(_("移除「%1」？\n服务器书架、服务器缓存和本地缓存都会删除。"), book.name or ""),
            ok_text = _("移除"),
            callback = function(ok)
                if not ok then return end
                self:runQuiet(function()
                    local del_ok = self.client:deleteBook(book)
                    if del_ok then
                        -- 清本地：章节分片目录 + 目录缓存 + 整本缓存文件 + 封面缓存
                        pcall(function()
                            local util = require("util")
                            local dir = self.chapter_cache:dirFor(book)
                            if lfs.attributes(dir, "mode") == "directory" then util.purgeDir(dir) end
                            local meta_path = self.meta_cache:chaptersPath(book)
                            if meta_path and lfs.attributes(meta_path, "mode") == "file" then os.remove(meta_path) end
                            removeBookCacheFiles(book)
                            if self.cover_cache and self.cover_cache.removeBook then
                                self.cover_cache:removeBook(book)
                            end
                        end)
                        -- 刷新书架缓存（移除后重新拉取）
                        pcall(function()
                            local fresh = self.client:getBookshelf()
                            if type(fresh) == "table" then self.meta_cache:putShelf(fresh) end
                        end)
                    else
                        self:showInfo(_("移除失败"))
                    end
                end)
            end,
        }
    end
    -- 正文「下载」：把整本书导出为 EPUB 到 Kindle/KOReader 本地文档目录。
    -- 后端无整本下载接口，按目录逐章 getBookContent；优先用本地章节缓存， networked 拉取带重试。
    function XRead:downloadBookToDevice(book)
        if not book then
            self:showInfo(_("没有可下载的书"))
            return
        end
        local dir
        pcall(function() dir = BookExport:exportDir() end)
        -- 已经导出过：确认框改成「覆盖」，并明确告诉用户会替换哪个文件
        local existing
        pcall(function() existing = BookExport:exportPath(book) end)
        local exists = existing and lfs.attributes(existing, "mode") == "file"
        local target = _("本地文档目录") .. "（" .. tostring(dir or "?") .. "）"
        local text
        if exists then
            text = T(_("本地已经有「%1」的 EPUB：\n%2\n\n重新导出会覆盖旧文件，继续？"),
                tostring(book.name or ""), tostring(existing))
        else
            text = T(_("把「%1」导出成 EPUB 到 %2？\n逐章拉取，章节多时需要等一会儿。"),
                tostring(book.name or ""), target)
        end
        MessageBox.confirm{
            text = text,
            ok_text = exists and _("覆盖") or _("下载"),
            callback = function(ok)
                if ok then self:_doDownloadBook(book) end
            end,
        }
    end

    function XRead:_doDownloadBook(book)
        -- 导出的网络 + 打包全部在 fork 出的子进程里做，主进程只轮询进度文件。
        -- 原实现逐章同步请求跑在 UI 线程（每章一个 12s 超时），几千章要跑很久，
        -- 期间界面完全无响应；失败章节还被写成「（本章获取失败）」后仍提示"下载完成"。
        Trapper:wrap(function()
            -- 取目录这一次请求仍在 UI 线程（本地缓存命中时是 0 网络），
            -- 先给个提示，避免用户以为点了没反应
            Trapper:info(_("正在准备目录…"))
            local ok_chapters, chapters = pcall(function()
                local cached = self.meta_cache:getChapters(book)
                if type(cached) == "table" and #cached > 0 then return cached end
                return self.client:getChapterList(book)
            end)
            if not ok_chapters or type(chapters) ~= "table" or #chapters == 0 then
                Trapper:clear()
                self:showInfo(_("下载失败：无法获取目录"))
                return
            end
            local total = #chapters
            local stem = bookCacheStem(book)
            local prog_file = BOOK_DIR .. "/" .. stem .. ".exportprog"
            local res_file = BOOK_DIR .. "/" .. stem .. ".exportres"
            pcall(os.remove, prog_file)
            pcall(os.remove, res_file)
            local client, cache = self.client, self.chapter_cache

            local function writeProg(done, state)
                local f = io.open(prog_file .. ".tmp", "w")
                if not f then return end
                f:write(string.format("done=%d total=%d state=%s", done, total, state))
                f:close()
                pcall(os.rename, prog_file .. ".tmp", prog_file)
            end

            local function writeResult(tag, payload)
                local f = io.open(res_file .. ".tmp", "w")
                if not f then return end
                f:write(tostring(tag) .. "\n" .. tostring(payload or "") .. "\n")
                f:close()
                pcall(os.rename, res_file .. ".tmp", res_file)
            end
            writeProg(0, "run")
            local ok_fork, pid = pcall(ffiutil.runInSubProcess, function()

                local function getContent(i, ch)
                    local cached = cache:get(book, i)
                    if cached and cached ~= "" then return cached end
                    local ok, text = pcall(function() return client:getBookContent(ch, book) end)
                    if ok and type(text) == "string" and text ~= "" then
                        pcall(function() cache:put(book, i, text) end)
                        return text
                    end
                    return nil       -- nil = 该章失败，由 book_export 统计并计入门槛
                end
                -- 多返回值用表接：createEpub -> path, err, stats
                local r = { pcall(BookExport.createEpub, BookExport, book, chapters, getContent,
                    function(done) writeProg(done, "run") end) }
                if r[1] and r[2] then
                    writeResult("ok", r[2])
                elseif r[1] then
                    writeResult("err", r[3])
                else
                    writeResult("err", r[2])
                end
                writeProg(total, "end")
            end, false)
            if not (ok_fork and pid) then
                logger.warn("xread export fork failed:", tostring(pid))
                Trapper:clear()
                pcall(os.remove, prog_file)
                self:showInfo(_("下载失败：当前环境不支持后台任务"))
                return
            end
            -- 先关掉上面那条「正在准备目录…」：Trapper:clear() 会把它从窗口栈上摘掉，
            -- 否则它会一直压在进度框上面（看着像进度框没出来、旧的提示一直不消失）。
            Trapper:clear()
            -- 进度框：只建一次，文字原地刷新（见 xread/progress_toast.lua 里的说明）。
            -- 原来是每轮 Trapper:info(nil) —— 它会新建一个空文字 InfoMessage，
            -- 真机上就是「进度框不停闪 + 反复出现空框」。
            ProgressToast.show(ProgressToast.hint(T(_("正在下载 %1%（%2/%3）"),
                "0", "0", tostring(total))), { buttons = true })
            local deadline = os.time() + math.max(180, total * 30)
            local last_done, last_t = -1, 0
            local user_aborted = false
            while os.time() < deadline do
                local text = ""
                local pf = io.open(prog_file, "r")
                if pf then
                    text = pf:read("*a") or ""
                    pf:close()
                end
                local state = text:match("state=(%w+)")
                local done = tonumber(text:match("done=(%d+)")) or 0
                if state == "end" then break end
                local now = os.time()
                local go_on
                if done ~= last_done and (now - last_t >= 1 or done >= total) then
                    last_done, last_t = done, now
                    go_on = ProgressToast.update(ProgressToast.hint(T(_("正在下载 %1%（%2/%3）"),
                        tostring(math.floor(done / total * 100)), tostring(done), tostring(total))))
                else
                    go_on = ProgressToast.update(nil)   -- 保持提示，仅让出一次时间片
                end
                -- 用户点了进度框：不再等下去（子进程会自己跑完，不阻塞界面）
                if go_on == false then
                    user_aborted = true
                    break
                end
            end
            ProgressToast.close()
            Trapper:clear()
            -- 轮询已结束：回收子进程。中止或超时时先杀掉，否则它会在后台把整本书
            -- 继续写完（界面提示「已取消」但导出文件照样生成）。
            reapSubProcess(pid, user_aborted or os.time() >= deadline)
            if user_aborted then
                -- 用户主动中止：子进程可能还在写，清掉进度文件，不要误报「下载失败」
                pcall(os.remove, prog_file)
                pcall(os.remove, res_file)
                self:showInfo(_("已取消下载"))
                return
            end
            local tag, payload = "err", _("子进程未返回结果")
            local rf = io.open(res_file, "r")
            if rf then
                local all = rf:read("*a") or ""
                rf:close()
                tag = all:match("^(%a+)") or "err"
                payload = all:match("^%a+\n(.-)\n*$") or ""
            end
            pcall(os.remove, prog_file)
            pcall(os.remove, res_file)
            if tag ~= "ok" or payload == "" then
                self:showInfo(_("下载失败：") .. tostring(payload))
                return
            end
            local size = fileSize(payload)
            -- 顺手把封面存到 EPUB 旁边：本地书架（含离线）就能显示和「我的书架」一样的封面
            pcall(function() self:saveLocalCover(book, payload) end)
            self:showInfo(T(_("下载完成\n%1\n共 %2 章 · %3\n可在 KOReader 文件管理器打开"),
                tostring(payload), tostring(total), tostring(size) .. " B"), 8)
        end)
    end
    -- 正文里的「删除」直接删当前书；没有传入书时才列书单供选择
    function XRead:removeBookFlow(book)
        if book then
            self:_confirmRemoveBook(book)
            return
        end
        local ok, books = pcall(function() return self.client:getBookshelf() end)
        if not ok or type(books) ~= "table" or #books == 0 then
            self:showInfo(_("书架为空或获取失败"))
            return
        end
        local items = {}
        for _i, b in ipairs(books) do
            items[#items + 1] = {
                text = (b.name or "?") .. "　" .. (b.author or ""),
                callback = function() self:_confirmRemoveBook(b) end,
            }
        end
        UIManager:show(Menu:new{
            title = _("选择要移除的书"),
            item_table = items,
            width = Screen:getWidth(),
            height = Screen:getHeight(),
        })
    end

    -- ---------- 整本预缓存（后端） ----------

    function XRead:chooseBookToCache()
        local books = self.client:getBookshelf()
        if #books == 0 then self:showInfo(_("书架为空")); return end
        local items = {}
        for _i, book in ipairs(books) do
            items[#items + 1] = {
                text = (book.name or "?") .. "　" .. (book.author or ""),
                callback = function()
                    MessageBox.confirm{
                        text = T(_("缓存「%1」到服务器？\n全部章节下载完后阅读秒开。"), book.name or ""),
                        ok_text = _("开始缓存"),
                        callback = function(ok)
                            if ok then self:doCacheBook(book) end
                        end,
                    }
                end,
            }
        end
        UIManager:show(Menu:new{
            title = _("选择要缓存的书"),
            item_table = items,
            width = Screen:getWidth(),
            height = Screen:getHeight(),
        })
    end

    function XRead:doCacheBook(book, count)
        -- 未设置缓存章节数（50/100/全部 全取消）= 不缓存，先提示去首页设置
        local wanted = tonumber(count)
        if wanted == nil then wanted = self:cacheDepthCount() end
        if wanted == nil then
            MessageBox.show{
                text = _("请设置服务器预缓存章节数"),
                sticky = true,
                dismissable = false,
                buttons = { { text = _("知道了") } },
            }
            return
        end
        -- 整本缓存是一条 SSE 长连接，几千章要跑几分钟。原来在 UI 线程同步跑，
        -- 这段时间界面完全无响应、无进度、不可取消，用户只能强杀 KOReader。
        -- 改成：子进程消费 SSE 并写进度文件，主进程轮询显示进度（网络不再占 UI 线程）。
        Trapper:wrap(function()
            local opts = {
                count = wanted,   -- 0 = 全部章节
                concurrentCount = 8,
                refresh = 0,
            }
            local stem = bookCacheStem(book)
            local prog_file = BOOK_DIR .. "/" .. stem .. ".sseprog"
            local err_file = prog_file .. ".err"
            pcall(os.remove, prog_file)
            pcall(os.remove, err_file)
            local client = self.client

            local function writeProg(info, done)
                local f = io.open(prog_file .. ".tmp", "w")
                if not f then return end
                f:write(string.format("cached=%d ok=%d fail=%d state=%s",
                    info.cachedCount or 0, info.successCount or 0, info.failedCount or 0,
                    done and "end" or "run"))
                f:close()
                pcall(os.rename, prog_file .. ".tmp", prog_file)
            end
            writeProg({}, false)
            local ok_fork, pid = pcall(ffiutil.runInSubProcess, function()
                local last = {}
                local ok_req, req_err = pcall(function()
                    client:cacheBookSSE(book, opts, function(info)
                        last = info
                        if info.isEnd then
                            logger.info("xread cache book done", tostring(info.cachedCount),
                                tostring(info.successCount), tostring(info.failedCount))
                        end
                        writeProg(info, info.isEnd)
                    end)
                end)
                if not ok_req then
                    local f = io.open(err_file, "w")
                    if f then
                        f:write(tostring(req_err))
                        f:close()
                    end
                end
                writeProg(last, true)
            end, false)
            if not (ok_fork and pid) then
                Trapper:clear()
                pcall(os.remove, prog_file)
                self:showInfo(_("缓存失败：当前环境不支持后台任务"))
                return
            end
            -- 主进程只轮询进度，不持有任何网络连接
            local deadline = os.time() + 3 * 3600
            -- 清掉「正在连接…」一类的残留提示，再显示进度框
            Trapper:clear()
            -- 进度框：只建一次，文字原地刷新（避免每轮新建空 InfoMessage 导致闪屏）
            ProgressToast.show(ProgressToast.hint(T(_("正在缓存到服务器：已处理 %1 章"), "0")),
                { buttons = true })
            local last_cached, last_t = -1, 0
            local user_aborted = false
            while os.time() < deadline do
                local text = ""
                local pf = io.open(prog_file, "r")
                if pf then
                    text = pf:read("*a") or ""
                    pf:close()
                end
                local state = text:match("state=(%w+)")
                local cached = tonumber(text:match("cached=(%d+)")) or 0
                if state == "end" then break end
                local now = os.time()
                local go_on
                if cached ~= last_cached and now - last_t >= 1 then
                    last_cached, last_t = cached, now
                    go_on = ProgressToast.update(ProgressToast.hint(T(_("正在缓存到服务器：已处理 %1 章"), tostring(cached))))
                else
                    go_on = ProgressToast.update(nil)
                end
                -- 用户点了进度框：不再等（子进程自己会结束，不阻塞界面）
                if go_on == false then
                    user_aborted = true
                    break
                end
            end
            ProgressToast.close()
            Trapper:clear()
            -- 轮询已结束：回收子进程。中止或超时时先杀掉，否则它还会在后台
            -- 按 SSE 继续把整本缓存完（可达数小时），用户却以为已经取消了。
            reapSubProcess(pid, user_aborted or os.time() >= deadline)
            if user_aborted then
                pcall(os.remove, prog_file)
                pcall(os.remove, err_file)
                self:showInfo(_("已取消缓存"))
                return
            end
            local err_text
            local ef = io.open(err_file, "r")
            if ef then
                err_text = ef:read("*a")
                ef:close()
            end
            pcall(os.remove, prog_file)
            pcall(os.remove, err_file)
            if err_text and err_text ~= "" then
                -- 失败原因必须让用户看清楚：原来 showInfo 几秒就自动消失，
                -- 常常还没读完就没了，只能反复重试。改成置顶卡片，手动关闭。
                MessageBox.show{
                    title = _("缓存失败"),
                    text = readable_error(err_text),
                    sticky = true,
                    dismissable = false,
                    buttons = { { text = _("知道了") } },
                }
            end
        end)
    end
    -- ---------- 漫画：下载图片 -> 打包 CBZ -> 打开 ----------

    function XRead:downloadComicAndOpen(book, chapters, start_index)
        local Archiver = require("ffi/archiver")
        local batch = tonumber(self:getSetting("comic_chapters", "5")) or 5
        if batch < 1 then batch = 1 end
        local last = math.min(start_index + batch - 1, #chapters)
        local path = BOOK_DIR .. "/" .. bookCacheStem(book) .. "_" .. start_index .. ".cbz"
        local arc = Archiver.Writer:new{}
        if not arc:open(path, "zip") then
            self:showInfo(_("无法创建漫画文件"))
            return
        end
        arc:setZipCompression("store")   -- 图片已压缩，无需再 deflate
        local mtime = os.time()
        local total_img, total_ch = 0, 0
        -- 用 pcall 包住整个下载 + 写包过程：任何异常都必须能走到 arc:close()，
        -- 否则 libarchive 句柄泄漏，并留下半个 .cbz（下次会被当成完整缓存直接打开）。
        local ok_loop, loop_err = pcall(function()
            for i = start_index, last do
                local ch = chapters[i]
                if ch then
                    local ok, html = pcall(function() return self.client:getBookContentRaw(ch, book) end)
                    if ok then
                        local urls = self.client:extractImageUrls(html)
                        local n = 0
                        for j, url in ipairs(urls) do
                            local data = self.client:downloadImage(url)
                            if data then
                                n = n + 1
                                arc:addFileFromMemory(string.format("%04d_%04d.jpg", i, j), data, mtime)
                                total_img = total_img + 1
                            end
                            -- 静默下载：不再弹进度框，点书后直接等正文打开（避免弹窗挡住操作）
                        end
                        if n > 0 then total_ch = total_ch + 1 end
                    end
                end
            end
        end)
        pcall(arc.close, arc)
        if not ok_loop then
            pcall(os.remove, path)
            self:showInfo(_("漫画下载失败：") .. readable_error(loop_err))
            return
        end
        if total_img == 0 then
            pcall(os.remove, path)      -- 不留 0 图片的坏 cbz
            self:showInfo(_("没有下载到任何图片"))
            return
        end
        pcall(function() self.client:saveBookProgress(book, start_index - 1) end)
        SHARED.book, SHARED.chapters, SHARED.index = book, chapters, start_index
        -- 静默打开漫画：不弹提示，直接切文档
        UIManager:nextTick(function()
            if self.ui.document then
                self.ui:switchDocument(path, true)
            else
                require("apps/reader/readerui"):showReader(path, nil, true)
            end
        end)
    end
end

return M
