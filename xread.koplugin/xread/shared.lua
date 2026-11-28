-- xread.koplugin/xread/shared.lua
-- 跨实例共享的运行时状态（唯一一份）。
--
-- 为什么必须是模块级单例：书架在 FileManager 里、阅读器里是另一个插件实例，
-- 后台缓存和「当前正在读哪本书」两个实例必须看得见同一份数据，否则
-- 回到书架时旧实例会拿着过期的 txt_path 继续往后追章节。
--
-- 约定：这里只放「进程内一次性状态」，不放配置。所有持久化偏好都走
-- SETTINGS_FILE（xread.lua），别把两套东西混在一起。
return {
    client = nil,       -- 复用同一个 Client，登录 token 不用重复拿
    ui = nil,           -- 当前 ReaderUI
    fm = nil,           -- FileManager 里的插件实例（返回书架时用）
    panel = nil,        -- 屏幕中间呼出的快捷面板
    open_path = nil,    -- 当前真正在阅读器里打开的 TXT 路径（nil = 已退出书籍）
    txt_path = nil,     -- 本次会话写的 TXT
    txt_size = nil,     -- 打开/上次热加载时的文件大小，用于判断磁盘上有没有新章节
    book = nil,
    chapters = nil,
    index = nil,
    -- 当前 TXT 实际拼进去的章节范围（index .. index+max_chapters-1）；
    -- TOC 只覆盖这一段，翻页换算全书章节号时需要它。
    doc_first = nil,
    doc_last = nil,
    cover_paths = nil,  -- 书架这一页已缓存的封面，目录页复用
    prev_end_action = nil,
    -- 正文简繁转换模式（none / s 转简体 / t 转繁体）。
    -- 原来是 main.lua 的模块级 local，拆模块后 zhText 与正文设置分处两个文件，
    -- 放在共享状态里两边才看得到同一个值。
    zh_mode = "none",
}
