# Markdown Preview for Luban Notepad

在 Luban Notepad 的右侧面板中预览当前 Markdown 文档。插件运行在编辑器沙箱内，
只读取当前文档，不需要文件系统、网络或子进程权限。需要插件 API v2 的宿主
（`luban.version == 2`）。

A rendered Markdown preview for [Luban Notepad](https://github.com/yyn0210/luban-notepad).
The plugin runs sandboxed, requests no permissions, and requires a host with
plugin API v2 (`luban.version == 2`).

## 功能

- GFM 渲染：标题、段落、粗体/斜体/粗斜体、行内代码、链接、图片占位、删除线、
  自动链接、引用、嵌套列表、任务列表、围栏/缩进代码块、GFM 表格、分隔线。
- 代码块使用编辑器当前的 syntect 语法集和语法主题配色。
- 表格按中日韩显示宽度对齐，超宽列自动截断。
- **标题折叠**：点击标题行（或执行 `Markdown: Toggle Heading Fold`）折叠/展开
  该标题下的内容，刷新保持面板滚动位置。
- **点击跳转源码**：点击段落行把编辑器光标移到对应源码行
  （`Markdown: Go to Source Line`）。
- 编辑文档时预览自动刷新（宿主防抖）；也可以点面板上的“刷新”。
- 解析结果在两次渲染之间缓存（`on_edit` 失效），折叠切换和手动刷新不重新解析。
- YAML frontmatter 默认隐藏，可在插件设置中显示。

## 兼容性

| 宿主版本 | 体验 |
| --- | --- |
| Luban Notepad 插件 API v2（`luban.version == 2`） | 完整功能 |

`api_version` 为 2 的插件不会被 v1 宿主加载；激活时也会显式检查
`luban.version >= 2`。

## 模块布局

插件根目录（zip 布局保持扁平，沙箱内 `require` 按插件根解析）：

| 文件 | 职责 |
| --- | --- |
| `main.lua` | 组装：清单入口、设置、`on_edit` 解析缓存、折叠与跳转命令 |
| `parser.lua` | 块级解析（含 frontmatter、源码行号、标题序号） |
| `inline.lua` | 行内解析（强调、代码、链接、图片、自动链接） |
| `renderer.lua` | 面板渲染（行组装、表格、代码块、折叠、行命令） |
| `highlight.lua` | `luban.syntax.highlight` 的特性安全封装 |
| `text.lua` | 文本/显示宽度工具（各模块共享） |

## 安装

- **插件商店**：插件 → 插件商店…，搜索 “Markdown Preview”。
- **手动安装**：把仓库中的 `plugin.json` 和全部 `.lua` 文件放进
  `<config-dir>/plugins/io.github.yyn0210.markdown-preview/`，然后在插件管理器中
  批准并启用（插件不申请任何权限）。

## 使用

- 命令面板或“插件”菜单执行 `Markdown: Preview`。
- 默认快捷键：`Ctrl+Shift+V`（可在快捷键编辑器中修改）。
- 面板标题显示当前文件名；切换标签或编辑后自动跟随。
- 点击标题行折叠/展开；点击段落行跳到源码（光标移到该行行首并聚焦编辑器）。
- 面板上“刷新”可手动重算，“关闭”关闭面板。
- 无参数调用折叠/跳转命令时，按当前光标位置取最近的标题/段落。

## 设置

| 键 | 类型 | 默认 | 说明 |
| --- | --- | --- | --- |
| `show_link_targets` | boolean | `false` | 在链接文字后显示目标 URL（VSCode/IDEA 预览默认不显示） |
| `show_frontmatter` | boolean | `false` | 显示而不是隐藏 YAML frontmatter |

## 渲染

版式对齐 VSCode / IntelliJ IDEA 的 Markdown 预览：

- 14px 正文与 1.6 行高；H1/H2 带 VSCode 风格底部分隔线，H6 使用弱化色。
- 真实表格：表头底色加粗、单元格分隔线、偶数行斑马纹、列宽按内容分配，
  支持 `:---`/`:---:`/`---:` 对齐。
- 代码块渲染为圆角卡片并保留宿主语法高亮；相邻的围栏代码块各自独立。
- 引用左侧竖线、列表缩进与项目符号、硬换行间距、行内代码与链接样式
  均按 VSCode 预览的尺度处理。
- 独占一段的本地图片渲染为图片块（相对当前文档目录，越界路径拒绝）；行内图片、
  远程 URL 与缺失文件保留 alt 占位文本，不发起网络请求。
- 原始 HTML 块去除标签后按普通文本显示（注释、`script`/`style` 内容不显示，
  `<br>` 转为换行，常见实体解码），不执行 HTML。

结构化表格需要宿主提供 `luban.features.panel_tables`；老宿主会自动回退到
等宽 ASCII 表格，不会报错。图片块需要 `luban.features.panel_images`，缺失时
按 alt 文本行显示。

## 限制

- 预览是只读的侧栏，不是可编辑的 WYSIWYG 视图。
- 面板中的链接不可点击；远程图片不加载，显示 alt 占位文本。
- 原始 HTML 不渲染为 DOM（仅提取可见文本），也不执行脚本。
- 单篇预览最多读取 512 KiB 源文本、渲染 4,000 行；超出会截断并提示。
- 单个代码块最多 64 KiB 会交给宿主高亮，整篇高亮预算 128 KiB；超出时按纯代码显示。

## 开发

```bash
lua5.4 tests/run.lua            # 解析、渲染与交互测试
python3 scripts/package.py --check
python3 scripts/package.py      # 生成 dist/<id>-<version>.zip
```

发布流程：更新 `plugin.json` 与 `CHANGELOG.md` 的版本，提交并推送 `v<version>`
标签；`.github/workflows/release.yml` 会运行测试、打包并上传 GitHub Release。
商店目录的 `plugins/<id>.json` 需要记录该产物的 SHA-256 与字节数。

## 许可证

木兰公共许可证第 2 版（MulanPubL-2.0），见 [LICENSE](LICENSE)。
