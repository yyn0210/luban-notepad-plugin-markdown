# 更新日志

## 2.0.0 — 2026-11-08

面向插件 API v2（`luban.version == 2`）的重写；v1 宿主不再支持。

- 代码拆分为模块：`parser.lua`（块级解析）、`inline.lua`（行内解析）、
  `renderer.lua`(面板渲染)、`highlight.lua`（语法高亮封装）、`text.lua`
  （共享文本工具）；`main.lua` 只负责组装。zip 布局保持扁平，
  沙箱内 `require` 直接按插件根解析。
- 移除全部旧宿主特性探测与降级逻辑；激活时要求 `luban.version >= 2`，
  否则报错退出。
- 新增标题折叠：标题行带折叠指示（▸/▾）与 `markdown.toggle-heading` 命令，
  点击或无参数按光标位置折叠/展开标题下的内容；标题序号与渲染顺序解耦，
  折叠状态下保持稳定。
- 新增点击跳转源码：段落行带 `markdown.goto-source` 命令（源码行号在解析时
  记录并计入 frontmatter 偏移），点击或无参数按光标位置把编辑器光标移到
  对应行首。
- 新增 `on_edit` 解析缓存：编辑事件只做缓存失效，未夹带编辑的渲染
  （折叠切换、手动刷新）复用已解析的块树；`show_frontmatter` 变化参与缓存键。
- 命令 `markdown.toggle-heading`、`markdown.goto-source` 已注册到清单，
  但不进入“插件”菜单；`events` 声明 `on_edit`。
- 面板 id、既有命令 id（`markdown.preview`）与设置键保持不变，原地更新
  不会丢失用户设置。
- 测试更新到 v2 stub（`luban.document/events/panel/command`），新增模块加载、
  缓存失效、折叠与跳转共 9 项，共 29 项。

## 1.0.1 — 2026-11-01

- 表格最大宽度从 96 调整为 72 列，避免在 640px 预览面板中换行破坏对齐；
  超宽列继续按显示宽度截断。

## 1.0.0 — 2026-11-01

首个版本。

- 右侧面板中的只读 Markdown 预览。
- GFM 渲染：标题、段落、强调、行内代码、链接、图片占位、删除线、自动链接、
  引用、嵌套列表、任务列表、围栏/缩进代码块、表格和分隔线。
- 代码块通过 `luban.syntax.highlight` 使用编辑器当前的语法集和语法主题。
- 表格按中日韩显示宽度对齐，超宽列截断。
- 编辑后自动刷新（约 150ms 防抖），并保持面板滚动位置。
- 设置：`show_link_targets`、`show_frontmatter`。
- 命令 `Markdown: Preview`，默认快捷键 `Ctrl+Shift+V`。
- 旧宿主降级为纯文本回退和手动刷新；插件不需要任何权限。
