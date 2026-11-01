# Markdown 预览插件设计

日期：2026-11-01
状态：已确认

## 目标

为 Luban Notepad 提供一个 Markdown 预览插件。插件以纯 Lua 单文件实现，运行在
宿主沙箱内；预览显示在插件面板中，随活动文档编辑自动刷新，并以 GFM 语义渲染
标题、强调、列表、任务列表、引用、代码块、表格、链接和图片占位。

由于宿主 1.0.0-preview.1 的面板只能渲染纯文本行，本项目同时扩展宿主面板 API，
提供行级块样式、行内 span、面板宽度、自动刷新和代码语法高亮。所有宿主扩展都是
向后兼容的：旧宿主忽略未知字段，插件回退为纯文本预览。

## 非目标

- 不实现 WYSIWYG 编辑；预览只读。
- 不注入 HTML/WebView，不加载远程图片，不执行原始 HTML。
- 不实现可点击的链接和目录跳转（面板行的 `command` 必须是静态命令，为每个
  标题注册命令会污染插件菜单）。
- 不支持 WASM、网络或子进程。

## 版本与兼容

- 宿主 API 主版本保持 `1`；新增字段和小 API 不改变 `api_version`。
- 商店条目 `api_version` 为 `1`。
- 旧宿主：忽略 `width`、`refresh`、`style`、`indent`、`spans`、`role`，使用面板行
  的 `text` 纯文本回退，手动刷新。
- 旧插件：新宿主按纯文本、380px、手动刷新渲染，行为不变。
- 富文本、自动刷新和代码高亮需要 Luban Notepad 1.0.0-preview.2 及以上。

## 宿主扩展

### 面板清单

```json
{
  "id": "markdown.preview.panel",
  "title": "Markdown Preview",
  "entry": "preview",
  "placement": "right",
  "width": 640,
  "refresh": "edit"
}
```

- `width`：280–1200，缺省 380；渲染时按窗口宽度收敛，至少给编辑区留 320px。
- `refresh`：`manual`（缺省）或 `edit`。`edit` 表示面板打开期间跟随活动文档。

### 面板行模型

```lua
{
  text = "跨平台的记事本",              -- 必填，纯文本回退
  style = "text",                      -- text|muted|h1..h6|code|quote|list|table|rule
  indent = 0,                          -- 0..8
  spans = {                            -- 可选；拼接后必须等于 text
    { text = "跨平台", style = "bold" },
    { text = "的记事本", role = "primary" },
  },
  command = nil,
}
```

- span `style` 是空格分隔的标志：`bold`、`italic`、`underline`、`strike`、`code`、
  `link`、`muted`。
- span `role` 使用编辑器同款语义角色（`keyword`、`string`、`comment`、`number`、
  `function`、`type` 等），宿主用当前语法主题解析颜色。
- 校验：单行文本和 spans 总量均不超过 4 KiB；spans 拼接必须等于 `text`，否则丢弃
  spans 并按纯文本渲染；未知样式和角色忽略；行数上限沿用 5,000。
- 渲染使用 `StyledText` + `TextRun`；行容器 `gap_0`，间距由行样式提供，连续代码行、
  引用行和表格行拼成完整块。
- code 行使用编辑器字体、语法主题前景色和面板的 `secondary` 背景，确保浅色主题下
  代码块也可见；标题使用更大字号；列表按 `indent` 缩进；rule 渲染为分隔线。
- 面板内容区固定为卡片高度，列表可滚动；右侧始终显示滚动条。面板获得焦点后滚轮
  可滚动，点击面板会把焦点交给列表，点击编辑器则回到编辑。

### `luban.syntax.highlight`

```lua
local spans, err = luban.syntax.highlight(code_text, "rust")
-- { { text = "fn", role = "keyword" }, { text = " main", role = "primary" }, ... }
```

- 覆盖全部输入文本，语法未覆盖的间隙用 `primary` 填充。
- 单次上限 64 KiB；未知/空语言返回整段 `primary`；无新增权限。
- 复用编辑器现有的 syntect 语法集与“语义角色 → 主题色”映射：把
  `luban-app/src/highlighter.rs` 的 `find_syntax`、`parse`、`semantic_name` 抽到
  `luban-core`，编辑器和插件运行时共用。

### `luban.panel.open`

`luban.panel.open(panel_id)` 允许插件命令打开或刷新自己声明的面板；宿主校验面板
归属后走与“插件”菜单相同的打开流程。旧宿主没有此 API，命令通过通知提示用户从
“插件”菜单打开面板。

### 自动刷新

- `refresh: edit` 的面板打开时启动轮询任务：180ms 周期，编辑停止约 150ms 后刷新。
- 触发条件：活动标签切换、编辑器文本改动（`Tab.edit_generation`）、文档 revision
  变化。
- 刷新前对可预览文档调用 `sync_active`；大文件/只读/非文本文档不强制同步，插件收到
  `nil` 显示不可预览。
- 用 generation token 保证只有一个轮询任务；面板关闭或换面板即退出。
- 滚动位置通过面板状态里的 `ScrollHandle` 保持，自动刷新不会跳回顶部；滚轮在面板
  获得焦点后生效，右侧滚动条始终可见。

## 插件

### 仓库结构

```text
plugin.json
main.lua                  # 单文件：解析器 + 渲染器
README.md
CHANGELOG.md
LICENSE
scripts/package.py        # 生成发布 zip
tests/run.lua             # 独立 Lua 5.4 测试，stub luban API
tests/fixtures/*.md
.github/workflows/ci.yml
.github/workflows/release.yml
```

### 解析与渲染

- 块级：ATX/setext 标题、段落、引用、有序/无序/嵌套列表、任务列表、围栏代码块、
  GFM 表格、分隔线、YAML frontmatter（默认隐藏）、原始 HTML（按文本显示）。
- 行内：粗体、斜体、粗斜体、行内代码、链接、图片占位、删除线、自动链接、转义、
  硬换行。
- 表格：Unicode 制表符 + 中日韩显示宽度；单表最大约 96 字符，超宽单元格截断。
- 代码块：合并后调用 `luban.syntax.highlight`，按行切回 spans；单块 64 KiB、整篇
  高亮 128 KiB；API 不存在或超限时退回纯 code 样式。
- 链接：链接文字用 link 样式；目标 URL 用 muted 样式附在括号中（可关闭）。
- 截断：源文本 512 KiB、渲染行 4,000 行，超出追加 muted 提示。
- 长段落按 span 边界切成不超过 4 KiB 的面板行。

### 命令、面板与设置

- 命令：`markdown.preview`，标签 `Markdown: Preview`，默认 `ctrl+shift+v`，
  `when: edit_text`；命令通过 `luban.panel.open("markdown.preview.panel")` 打开面板，
  旧宿主则提示从“插件”菜单打开。
- 面板：`markdown.preview.panel`，右侧，`width: 640`，`refresh: edit`，标题动态显示
  `<文件名> — Preview`。
- 设置：`show_link_targets`（默认 true）、`show_frontmatter`（默认 false）。
- 权限：`[]`。

## 发布

1. 宿主升到 `1.0.0-preview.2`，更新 CHANGELOG，跑
   `fmt/clippy/test/--smoke-test`，提交并推 `main` + tag，核对三平台产物。
2. 插件 `v1.0.0` tag 触发 Release 工作流，生成
   `io.github.yyn0210.markdown-preview-1.0.0.zip`。
3. 商店添加 `plugins/io.github.yyn0210.markdown-preview.json`，
   `api_version: 1`、`universal` 产物，运行 `build_catalog.py` 和
   `validate.py --download`，提交并推送 `main`。

## 验证

- 宿主单元测试：面板解析、样式校验、语法高亮 API、清单字段。
- 插件 Lua 测试：各类 Markdown、CJK 宽度、spans 拼接、旧宿主回退。
- headless 集成：打开示例文档、截图核对富文本、编辑后自动刷新、滚动保持。
- 旧宿主降级：用 1.0.0-preview.1 发布二进制加载同一插件，确认纯文本和手动刷新。
- 商店：`validate.py --download` 校验产物，应用内从默认目录安装并截图。

## 默认值

- 插件 ID：`io.github.yyn0210.markdown-preview`
- 名称：`Markdown Preview`；商店 `zh-CN` 名称“Markdown 预览”
- 版本：`1.0.0`；许可证：`MulanPubL-2.0`
- 商店：提交到 `yyn0210/luban-notepad-store` 的 `main`
