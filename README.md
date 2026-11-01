# Markdown Preview for Luban Notepad

在 Luban Notepad 的右侧面板中预览当前 Markdown 文档。插件是单文件 Lua，运行在
编辑器沙箱内，只读取当前文档，不需要文件系统、网络或子进程权限。

A rendered Markdown preview for [Luban Notepad](https://github.com/yyn0210/luban-notepad).
The plugin is a single sandboxed Lua file and requests no permissions.

## 功能

- GFM 渲染：标题、段落、粗体/斜体/粗斜体、行内代码、链接、图片占位、删除线、
  自动链接、引用、嵌套列表、任务列表、围栏/缩进代码块、GFM 表格、分隔线。
- 代码块使用编辑器当前的 syntect 语法集和语法主题配色。
- 表格按中日韩显示宽度对齐，超宽列自动截断。
- 编辑文档时预览自动刷新（约 150ms 防抖）；也可以点面板上的“刷新”。
- YAML frontmatter 默认隐藏，可在插件设置中显示。
- 旧版宿主自动降级：忽略富文本字段，显示纯文本回退和手动刷新。

## 兼容性

| 宿主版本 | 体验 |
| --- | --- |
| Luban Notepad 1.0.0-preview.2 及以后 | 富文本预览、代码高亮、自动刷新 |
| Luban Notepad 1.0.0-preview.1 | 纯文本预览、手动刷新（插件仍可安装） |

插件清单的 `api_version` 为 1。

## 安装

- **插件商店**：插件 → 插件商店…，搜索 “Markdown Preview”。
- **手动安装**：把本仓库的 `plugin.json` 和 `main.lua` 放进
  `<config-dir>/plugins/io.github.yyn0210.markdown-preview/`，然后在插件管理器中
  批准并启用（插件不申请任何权限）。

## 使用

- 命令面板或“插件”菜单执行 `Markdown: Preview`。
- 默认快捷键：`Ctrl+Shift+V`（可在快捷键编辑器中修改）。
- 面板标题显示当前文件名；切换标签或编辑后自动跟随。
- 面板上“刷新”可手动重算，“关闭”关闭面板。

旧版宿主没有 `luban.panel.open`：命令会提示从“插件”菜单打开
“Markdown Preview”面板。

## 设置

| 键 | 类型 | 默认 | 说明 |
| --- | --- | --- | --- |
| `show_link_targets` | boolean | `true` | 在链接文字后显示目标 URL |
| `show_frontmatter` | boolean | `false` | 显示而不是隐藏 YAML frontmatter |

## 限制

- 预览是只读的侧栏，不是可编辑的 WYSIWYG 视图。
- 面板中的链接不可点击；图片以占位文本显示，不加载远程资源。
- 单篇预览最多读取 512 KiB 源文本、渲染 4,000 行；超出会截断并提示。
- 单个代码块最多 64 KiB 会交给宿主高亮，整篇高亮预算 128 KiB；超出时按纯代码显示。

## 开发

```bash
lua5.4 tests/run.lua            # 解析与渲染测试
python3 scripts/package.py --check
python3 scripts/package.py      # 生成 dist/<id>-<version>.zip
```

发布流程：更新 `plugin.json` 与 `CHANGELOG.md` 的版本，提交并推送 `v<version>`
标签；`.github/workflows/release.yml` 会运行测试、打包并上传 GitHub Release。
商店目录的 `plugins/<id>.json` 需要记录该产物的 SHA-256 与字节数。

## 许可证

木兰公共许可证第 2 版（MulanPubL-2.0），见 [LICENSE](LICENSE)。
