-- Standalone tests for the Markdown Preview plugin (Lua 5.4, plugin API v2).
--
-- Run from the repository root:
--   lua5.4 tests/run.lua
--
-- The harness supplies the same `luban` surface a v2 host exposes. It never
-- runs inside the app sandbox, so `os` and `io` are available here only, and
-- plain `require` loads the plugin modules from the repository root.

local PLUGIN_MAIN = os.getenv("PLUGIN_MAIN") or "main.lua"

-- Modules live at the repository root next to main.lua; make them requireable
-- no matter how the harness was invoked.
local script_dir = (arg and arg[0] or ""):match("^(.*)[/\\]") or "."
package.path = "./?.lua;" .. script_dir .. "/../?.lua;" .. package.path

local current_doc = nil
local current_settings = nil
local highlight_roles = true
local notifications = {}
local cursor_calls = {}
local command_calls = {}
local handlers = {}

local function make_luban()
  return {
    version = 2,
    features = {
      panel_tables = true,
      panel_tight_lines = true,
    },
    log = function(level, message)
      notifications[#notifications + 1] = "log:" .. level .. ":" .. message
    end,
    notify = function(message)
      notifications[#notifications + 1] = message
    end,
    document = {
      get = function()
        return current_doc
      end,
      set_text = function(text, sel_start, sel_end)
        if not current_doc then
          error("unsupported document")
        end
        current_doc.text = text
        return nil
      end,
      insert = function(text)
        if not current_doc then
          error("unsupported document")
        end
        current_doc.text = current_doc.text .. text
        return nil
      end,
      set_cursor = function(line, column)
        cursor_calls[#cursor_calls + 1] = { line = line, column = column }
        if current_doc then
          current_doc.line = line
          current_doc.column = column
        end
        return nil
      end,
    },
    settings = {
      get = function(key)
        if current_settings == nil then
          return nil
        end
        return current_settings[key]
      end,
      set = function(key, value)
        current_settings = current_settings or {}
        current_settings[key] = value
        return nil
      end,
    },
    panel = {
      open = function(id)
        notifications[#notifications + 1] = "open:" .. id
        return nil
      end,
      refresh = function(id)
        notifications[#notifications + 1] = "refresh:" .. id
        return nil
      end,
    },
    command = {
      run = function(id, args)
        command_calls[#command_calls + 1] = { id = id, args = args }
        return nil
      end,
    },
    events = {
      on = function(name, fn)
        if type(fn) ~= "function" then
          error("event handler must be a function")
        end
        handlers[name] = fn
        return nil
      end,
      off = function(name)
        handlers[name] = nil
        return nil
      end,
    },
    syntax = {
      highlight = function(text, language)
        if not highlight_roles then
          error("highlighting disabled")
        end
        -- A tiny stand-in for the host highlighter: split the first `fn` so
        -- the role plumbing has something to prove.
        if text:sub(1, 2) == "fn" then
          return {
            { text = "fn", role = "keyword" },
            { text = text:sub(3), role = "primary" },
          }
        end
        return { { text = text, role = "primary" } }
      end,
    },
  }
end

local function reset_luban()
  current_doc = nil
  current_settings = {}
  highlight_roles = true
  notifications = {}
  cursor_calls = {}
  command_calls = {}
  handlers = {}
  luban = make_luban()
end

reset_luban()

local ok, plugin = pcall(loadfile(PLUGIN_MAIN))
assert(ok and type(plugin) == "table", "cannot load " .. PLUGIN_MAIN .. ": " .. tostring(plugin))
local M = plugin

local PASSED = 0
local FAILED = 0
local CURRENT = ""

local function fail(message)
  error(message, 2)
end

local function eq(actual, expected, message)
  if actual ~= expected then
    fail((message or "values differ") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
  end
end

local function truthy(value, message)
  if not value then
    fail(message or "expected a truthy value")
  end
end

local function contains(text, needle, message)
  if type(text) ~= "string" or not text:find(needle, 1, true) then
    fail((message or "missing substring") .. ": " .. tostring(needle) .. " in " .. tostring(text))
  end
end

local function test(name, fn)
  CURRENT = name
  local ok_run, error_message = pcall(fn)
  if ok_run then
    PASSED = PASSED + 1
    io.write("ok   ", name, "\n")
  else
    FAILED = FAILED + 1
    io.write("FAIL ", name, "\n     ", tostring(error_message), "\n")
  end
end

local function check_panel(panel)
  truthy(type(panel) == "table", "panel is not a table")
  truthy(type(panel.lines) == "table", "panel.lines is not a table")
  if #panel.lines > 5000 then
    fail("panel has more than 5000 lines")
  end
  local allowed = {
    text = true, muted = true, h1 = true, h2 = true, h3 = true, h4 = true,
    h5 = true, h6 = true, code = true, quote = true, list = true,
    table = true, rule = true, image = true,
  }
  local aligns = { left = true, center = true, right = true }
  for index, line in ipairs(panel.lines) do
    truthy(type(line.text) == "string", "line " .. index .. " text is not a string")
    if #line.text > 4096 then
      fail("line " .. index .. " is longer than 4096 bytes")
    end
    if line.style ~= nil then
      truthy(allowed[line.style], "line " .. index .. " has unknown style " .. tostring(line.style))
    end
    if line.indent ~= nil then
      truthy(line.indent >= 0 and line.indent <= 8, "line " .. index .. " indent out of range")
    end
    if line.tight ~= nil then
      truthy(type(line.tight) == "boolean", "line " .. index .. " tight is not a boolean")
    end
    if line.break_before ~= nil then
      truthy(type(line.break_before) == "boolean",
        "line " .. index .. " break_before is not a boolean")
    end
    if line.image ~= nil then
      truthy(type(line.image) == "string", "line " .. index .. " image is not a string")
      truthy(#line.image > 0 and #line.image <= 4096, "line " .. index .. " image path is out of range")
    end
    if line.cells ~= nil then
      truthy(type(line.cells) == "table", "line " .. index .. " cells is not a table")
      truthy(#line.cells > 0 and #line.cells <= 32, "line " .. index .. " cell count out of range")
      for cell_index, cell in ipairs(line.cells) do
        truthy(type(cell) == "table", "line " .. index .. " cell is not a table")
        truthy(type(cell.text) == "string", "line " .. index .. " cell text is not a string")
        if #cell.text > 4096 then
          fail("line " .. index .. " cell is longer than 4096 bytes")
        end
        truthy(aligns[cell.align or "left"], "line " .. index .. " cell has unknown align")
        truthy(type(cell.header) == "boolean", "line " .. index .. " cell header is not a boolean")
        truthy(type(cell.weight) == "number"
          and cell.weight >= 1 and cell.weight <= 32,
          "line " .. index .. " cell weight out of range")
        if cell.spans then
          truthy(#cell.spans <= 512, "line " .. index .. " cell has too many spans")
          local parts = {}
          for _, span in ipairs(cell.spans) do
            truthy(type(span.text) == "string", "line " .. index .. " cell span text is not a string")
            parts[#parts + 1] = span.text
          end
          eq(table.concat(parts), cell.text, "line " .. index .. " cell spans do not match text")
        end
      end
    end
    if line.command ~= nil then
      truthy(type(line.command) == "table", "line " .. index .. " command is not a table")
      truthy(type(line.command.id) == "string", "line " .. index .. " command id is not a string")
      if line.command.args ~= nil then
        truthy(type(line.command.args) == "table", "line " .. index .. " command args is not a table")
      end
    end
    if line.spans then
      truthy(#line.spans <= 512, "line " .. index .. " has too many spans")
      local parts = {}
      for _, span in ipairs(line.spans) do
        truthy(type(span.text) == "string", "line " .. index .. " span text is not a string")
        parts[#parts + 1] = span.text
      end
      eq(table.concat(parts), line.text, "line " .. index .. " spans do not match text")
    end
  end
end

local function make_doc(path, text, line)
  return {
    path = path,
    language = "Markdown",
    text = text,
    line = line or 1,
    column = 1,
    selection_start = 1,
    selection_end = 1,
    modified = false,
  }
end

local function render(text, settings)
  current_doc = make_doc("/tmp/test.md", text)
  current_settings = settings or {}
  local panel = M.render_preview({})
  check_panel(panel)
  return panel
end

local function line_with(panel, style, needle)
  for _, line in ipairs(panel.lines) do
    local line_style = line.style or "text"
    if line_style == style and (not needle or line.text:find(needle, 1, true)) then
      return line
    end
  end
  return nil
end

local function style_has(line, flag, text)
  for _, span in ipairs(line.spans or {}) do
    if (not text or span.text == text) and (span.style or ""):find(flag, 1, true) then
      return true
    end
  end
  return false
end

local function role_has(line, role, text)
  for _, span in ipairs(line.spans or {}) do
    if (not text or span.text == text) and span.role == role then
      return true
    end
  end
  return false
end

local function line_texts(panel)
  local texts = {}
  for _, line in ipairs(panel.lines) do
    texts[#texts + 1] = line.text
  end
  return texts
end

-- ---------------------------------------------------------------------------

test("modules load and main assembles them", function()
  local text_mod = require("text")
  local inline_mod = require("inline")
  local parser_mod = require("parser")
  local renderer_mod = require("renderer")
  local highlight_mod = require("highlight")
  truthy(type(text_mod.display_width) == "function", "text module incomplete")
  truthy(type(inline_mod.parse_inline) == "function", "inline module incomplete")
  truthy(type(parser_mod.parse) == "function", "parser module incomplete")
  truthy(type(renderer_mod.render) == "function", "renderer module incomplete")
  truthy(type(highlight_mod.highlight) == "function", "highlight module incomplete")
  truthy(type(M.render_preview) == "function", "main missing render_preview")
  truthy(type(M.open_preview) == "function", "main missing open_preview")
  truthy(type(M.toggle_heading) == "function", "main missing toggle_heading")
  truthy(type(M.goto_source) == "function", "main missing goto_source")
  truthy(type(M.on_edit) == "function", "main missing on_edit")
  truthy(type(M.activate) == "function", "main missing activate")
end)

test("headings, setext headings and over-long ATX runs", function()
  local panel = render("# One\n\n## Two **bold**\n\n###### Six\n\n####### seven\n\nSetext\n======\n")
  local h1 = line_with(panel, "h1", "One")
  local h2 = line_with(panel, "h2", "Two")
  local h6 = line_with(panel, "h6", "Six")
  truthy(h1 and h2 and h6, "missing heading styles")
  truthy(style_has(h2, "bold", "bold"), "heading emphasis lost")
  truthy(line_with(panel, "text", "####### seven"), "7 hashes must stay a paragraph")
  truthy(line_with(panel, "h1", "Setext"), "setext heading missing")
end)

test("inline emphasis, code, strike and links", function()
  local panel = render("**bold** *italic* ***both*** `code` ~~gone~~ [label](https://e.com/a?b=1) and <https://e.com/x>\n", { show_link_targets = true })
  local line = line_with(panel, "text")
  truthy(line, "paragraph missing")
  truthy(style_has(line, "bold", "bold"), "bold span missing")
  truthy(style_has(line, "italic", "italic"), "italic span missing")
  truthy(style_has(line, "bold", "both") and style_has(line, "italic", "both"), "bold+italic span missing")
  truthy(style_has(line, "code", "code"), "code span missing")
  truthy(style_has(line, "strike", "gone"), "strike span missing")
  truthy(style_has(line, "link", "label"), "link span missing")
  contains(line.text, "label (https://e.com/a?b=1)")
  contains(line.text, "https://e.com/x")
  eq(select(2, line.text:gsub("%(https://e.com/x%)", "")), 0, "autolink target duplicated")
end)

test("link targets are hidden by default and can be shown", function()
  local hidden = render("[label](https://e.com)\n")
  local line = line_with(hidden, "text")
  eq(line.text, "label", "VSCode/IDEA previews do not append link destinations")
  truthy(style_has(line, "link", "label"), "link style missing")
  local shown = render("[label](https://e.com)\n", { show_link_targets = true })
  contains(line_with(shown, "text").text, "label (https://e.com)")
end)

test("standalone local images become image blocks", function()
  local panel = render("![alt text](pic.png)\n")
  local image = line_with(panel, "image")
  truthy(image, "standalone image block missing")
  eq(image.text, "alt text", "image alt text")
  eq(image.image, "pic.png", "image source")
end)

test("inline and remote images become readable placeholders", function()
  local inline = render("An image: ![alt text](pic.png)\n")
  local line = line_with(inline, "text")
  contains(line.text, "🖼 alt text")
  truthy(style_has(line, "muted"), "inline image placeholder should be muted")
  local remote = render("![remote](https://example.com/logo.png)\n")
  local remote_line = line_with(remote, "text")
  truthy(remote_line, "remote image must stay inline")
  contains(remote_line.text, "🖼 remote")
  truthy(not line_with(remote, "image"), "remote images must not become local image blocks")
  local shown = render("![alt text](pic.png)\n", { show_link_targets = true })
  local shown_image = line_with(shown, "image")
  truthy(shown_image, "image block missing with targets enabled")
  eq(shown_image.text, "alt text", "image alt text is not the target")
end)

test("unordered, ordered and task lists", function()
  local panel = render("- a\n  - b\n1. one\n2. two\n- [x] done\n- [ ] todo\n")
  truthy(line_with(panel, "list", "• a"), "unordered item missing")
  local nested = line_with(panel, "list", "◦ b")
  truthy(nested and nested.indent == 1, "nested item missing its indent")
  truthy(line_with(panel, "list", "1. one"), "ordered item missing")
  truthy(line_with(panel, "list", "☑ done"), "checked task missing")
  truthy(line_with(panel, "list", "☐ todo"), "unchecked task missing")
end)

test("block quotes nest and keep a depth", function()
  local panel = render("> quoted\n> > nested\n")
  local first = line_with(panel, "quote", "quoted")
  local second = line_with(panel, "quote", "nested")
  truthy(first and first.indent == 1, "first quote level missing")
  truthy(second and second.indent == 2, "nested quote level missing")
  truthy(first.tight, "the first quote line must be tight for a continuous bar")
  eq(second.tight, nil, "the last quote line keeps the block spacing")
end)

test("multi-paragraph quotes keep one continuous bar", function()
  local panel = render("> first paragraph\n>\n> second paragraph\n\nAfter.\n")
  local quote_lines = {}
  for _, line in ipairs(panel.lines) do
    if line.style == "quote" then
      quote_lines[#quote_lines + 1] = line
    end
  end
  eq(#quote_lines, 2, "quote paragraph count")
  truthy(quote_lines[1].tight, "the first quote paragraph must be tight")
  eq(quote_lines[2].tight, nil, "the last quote paragraph keeps its spacing")
end)

test("fenced code is highlighted and split by line", function()
  local panel = render("```rust\nfn main() {\n    println!(\"hi\");\n}\n```\n")
  local lines = {}
  for _, line in ipairs(panel.lines) do
    if line.style == "code" then
      lines[#lines + 1] = line
    end
  end
  eq(#lines, 3, "code line count")
  eq(lines[1].text, "fn main() {", "first code line")
  truthy(role_has(lines[1], "keyword", "fn"), "highlight role missing")
  truthy(style_has(lines[2], "code") == false, "code line spans should carry roles, not code style")
end)

test("code falls back to plain text without the host highlighter", function()
  local original = luban.syntax
  luban.syntax = nil
  local panel = render("```rust\nfn main() {}\n```\n")
  local line = line_with(panel, "code", "fn main")
  truthy(line, "plain code line missing")
  truthy(line.spans == nil, "plain fallback should not invent spans")
  luban.syntax = original
end)

test("indented code blocks are recognized", function()
  local panel = render("    indented code\n    second line\n")
  truthy(line_with(panel, "code", "indented code"), "indented code missing")
end)

test("tables render as structured rows with alignment and header flags", function()
  local panel = render("| Name | 值 | Note |\n|:-----|:--:|-----:|\n| a | 中文 | 1 |\n| longer cell | x | 22 |\n")
  local rows = {}
  for _, line in ipairs(panel.lines) do
    if line.style == "table" and line.cells then
      rows[#rows + 1] = line
    end
  end
  eq(#rows, 3, "table row count")
  eq(rows[1].cells[1].text, "Name", "header first cell")
  truthy(rows[1].cells[1].header, "header cell flag")
  truthy(not rows[2].cells[1].header, "body cell must not be a header")
  eq(rows[1].cells[2].align, "center", "center alignment")
  eq(rows[1].cells[3].align, "right", "right alignment")
  eq(rows[2].cells[2].text, "中文", "CJK cell")
  truthy(rows[2].cells[1].weight >= 1, "cell weight missing")
  truthy(rows[2].cells[1].weight > rows[2].cells[2].weight,
    "wider columns must get a larger weight")
end)

test("hosts without panel tables get the monospace fallback", function()
  local features = luban.features
  luban.features = nil
  local panel = render("| Name | 值 | Note |\n|:-----|:--:|-----:|\n| a | 中文 | 1 |\n| longer cell | x | 22 |\n")
  local widths = {}
  local header
  for _, line in ipairs(panel.lines) do
    if line.style == "table" then
      truthy(line.cells == nil, "fallback rows must not carry cells")
      widths[#widths + 1] = require("text").display_width(line.text)
      if line.text:find("Name", 1, true) then
        header = line
      end
    end
  end
  truthy(#widths >= 5, "fallback table lines missing")
  for _, width in ipairs(widths) do
    eq(width, widths[1], "fallback table line widths differ")
  end
  truthy(header, "fallback table header missing")
  truthy(style_has(header, "bold", "Name"), "fallback header cell should be bold")
  luban.features = features
end)

test("wide table cells keep their full text", function()
  local wide = string.rep("a", 80)
  local panel = render("| left | right |\n|---|---|\n| " .. wide .. " | " .. wide .. " |\n")
  local found = false
  for _, line in ipairs(panel.lines) do
    if line.style == "table" and line.cells then
      for _, cell in ipairs(line.cells) do
        if cell.text == wide then
          found = true
        end
      end
    end
  end
  truthy(found, "structured table cell was truncated")
end)

test("adjacent fenced blocks become separate code groups", function()
  local panel = render("```lua\na\n```\n\n```js\nb\n```\n")
  local groups = 0
  local previous_code = false
  local break_seen = false
  for _, line in ipairs(panel.lines) do
    if line.style == "code" then
      if not previous_code or line.break_before then
        groups = groups + 1
      end
      if line.break_before then
        break_seen = true
      end
      previous_code = true
    else
      previous_code = false
    end
  end
  eq(groups, 2, "each fenced block must be its own code group")
  truthy(break_seen, "the second code group must carry break_before")
end)

test("frontmatter is hidden by default and rendered on request", function()
  local hidden = render("---\ntitle: Demo\n---\n\n# Body\n")
  truthy(not line_with(hidden, "text", "title:"), "frontmatter leaked")
  truthy(line_with(hidden, "h1", "Body"), "body missing")
  local shown = render("---\ntitle: Demo\n---\n\n# Body\n", { show_frontmatter = true })
  truthy(line_with(shown, "muted", "Front matter"), "frontmatter label missing")
  truthy(line_with(shown, "code", "title: Demo"), "frontmatter code missing")
  truthy(line_with(shown, "h1", "Body"), "body missing after shown frontmatter")
end)

test("raw HTML blocks render visible text instead of tags", function()
  local panel = render(
    '<div class="x">\nraw <strong>text</strong>\n</div>\n\n<script>alert(1)</script>\n\n<p>Hello &amp; bye</p>\n\nA <span>tag</span> here.\n'
  )
  truthy(line_with(panel, "text", "raw text"), "HTML block text missing")
  truthy(not line_with(panel, "text", "<div"), "HTML tags leaked into the preview")
  truthy(not line_with(panel, "text", "alert"), "script bodies must stay hidden")
  truthy(line_with(panel, "text", "Hello & bye"), "HTML entities were not decoded")
  truthy(line_with(panel, "text", "A tag here."), "inline HTML was not stripped")
end)

test("hard breaks create separate lines; soft breaks join with spaces", function()
  local panel = render("one  \ntwo\nthree\n")
  local texts = line_texts(panel)
  eq(texts[1], "one", "hard break first line")
  eq(texts[2], "two three", "soft break should join with a space")
  eq(panel.lines[1].tight, true, "the line before a hard break must stay tight")
  eq(panel.lines[2].tight, nil, "the paragraph's last line keeps its spacing")
end)

test("fenced blocks keep their language and body separate from paragraphs", function()
  local panel = render("before\n\n```lua\nprint('x')\n```\n\nafter\n")
  local code
  for _, line in ipairs(panel.lines) do
    if line.style == "code" then
      code = line
    end
  end
  truthy(code, "code line missing")
  eq(code.text, "print('x')", "code body")
  eq(line_with(panel, "text", "before").tight, nil, "paragraph before")
  eq(line_with(panel, "text", "after").tight, nil, "paragraph after")
end)

test("empty and unsupported documents explain themselves", function()
  local empty = render("")
  local line = line_with(empty, "muted")
  truthy(line and line.text:find("empty", 1, true), "empty document message missing")
  current_doc = nil
  current_settings = {}
  local panel = M.render_preview({})
  check_panel(panel)
  local message = line_with(panel, "muted")
  truthy(message and message.text:find("not available", 1, true), "unsupported document message missing")
end)

test("the command opens the declared panel", function()
  M.open_preview({})
  eq(notifications[#notifications], "open:markdown.preview.panel")
end)

test("long lines and many spans stay within host limits", function()
  local words = {}
  for i = 1, 3000 do
    words[i] = (i % 2 == 0) and "**word" .. i .. "**" or "word" .. i
  end
  local panel = render(table.concat(words, " "))
  for _, line in ipairs(panel.lines) do
    truthy(#line.text <= 4096, "long line escaped the cap")
  end
  local plain = render(string.rep("a", 9000))
  for _, line in ipairs(plain.lines) do
    truthy(#line.text <= 4096, "plain long line escaped the cap")
  end
end)

test("large documents are truncated instead of failing", function()
  local chunks = {}
  for i = 1, 1200 do
    chunks[#chunks + 1] = "## Section " .. i .. "\n\nparagraph " .. i .. " with a [link](https://e.com/" .. i .. ")\n\n"
  end
  local panel = render(table.concat(chunks))
  truthy(#panel.lines <= 5000, "line cap exceeded")
  local last = panel.lines[#panel.lines]
  truthy(last and (last.text:find("truncated", 1, true) or #panel.lines < 4000), "truncation notice missing")
end)

test("source over 512 KiB is truncated", function()
  local panel = render(string.rep("x", 520 * 1024))
  local last = panel.lines[#panel.lines]
  truthy(last.text:find("512 KiB", 1, true), "source truncation notice missing")
end)

test("the rich fixture keeps every invariant", function()
  local file = assert(io.open("tests/fixtures/readme.md", "rb"))
  local text = file:read("*a")
  file:close()
  local panel = render(text)
  truthy(#panel.lines > 20, "fixture produced too few lines")
  truthy(line_with(panel, "h1"), "fixture h1 missing")
  local table_row
  for _, line in ipairs(panel.lines) do
    if line.style == "table" and line.cells then
      table_row = line
      break
    end
  end
  truthy(table_row, "fixture structured table missing")
  truthy(table_row.cells[1].header, "fixture table header missing")
  truthy(line_with(panel, "code"), "fixture code missing")
  truthy(line_with(panel, "list"), "fixture list missing")
end)

-- ---------------------------------------------------------------------------
-- v2 interactions: activation, cache, folds, source jumps
-- ---------------------------------------------------------------------------

test("activate registers on_edit and rejects pre-v2 hosts", function()
  local original_version = luban.version
  luban.version = 1
  local ok_run, error_message = pcall(M.activate, {})
  truthy(not ok_run, "activate must reject pre-v2 hosts")
  contains(tostring(error_message), "v2", "error message must mention v2")
  luban.version = original_version
  truthy(handlers["on_edit"] == nil, "no handler before activation")
  M.activate({})
  truthy(handlers["on_edit"] == M.on_edit, "activate must register the on_edit handler")
end)

test("on_edit invalidates the cache; two renders with the same text parse once", function()
  M.on_edit(nil)
  local parser_mod = require("parser")
  local original_parse = parser_mod.parse
  local calls = 0
  parser_mod.parse = function(text, opts)
    calls = calls + 1
    return original_parse(text, opts)
  end
  local text = "# Cache\n\nparagraph one\n"
  render(text)
  local after_first = calls
  truthy(after_first >= 1, "first render must parse")
  render(text)
  eq(calls, after_first, "second render must reuse the cached blocks")
  M.on_edit(current_doc)
  render(text)
  eq(calls, after_first + 1, "a render after on_edit must reparse")
  M.on_edit(nil)
  render(text)
  eq(calls, after_first + 2, "on_edit(nil) must clear the cache too")
  parser_mod.parse = original_parse
end)

test("on_edit handles a closed tab (nil payload) without breaking the next render", function()
  M.on_edit(make_doc("/tmp/edge.md", "## x\n"))
  M.on_edit(nil)
  current_doc = make_doc("/tmp/after-close.md", "# back\n")
  current_settings = {}
  local panel = M.render_preview({})
  check_panel(panel)
  truthy(line_with(panel, "h1", "back"), "render after a tab close must work")
end)

test("heading and paragraph lines carry their command and source line", function()
  local panel = render("# Title\n\nFirst paragraph.\n\n## Sub\n")
  local h1 = line_with(panel, "h1", "Title")
  truthy(h1.command, "heading line carries no command")
  eq(h1.command.id, "markdown.toggle-heading", "heading command id")
  eq(h1.command.args.index, 1, "heading sequence number")
  local para = line_with(panel, "text", "First paragraph.")
  truthy(para.command, "paragraph line carries no command")
  eq(para.command.id, "markdown.goto-source", "paragraph command id")
  eq(para.command.args.line, 3, "paragraph source line")
  local h2 = line_with(panel, "h2", "Sub")
  eq(h2.command.args.index, 2, "second heading sequence number")
end)

test("goto-source args account for frontmatter offsets", function()
  local panel = render("---\ntitle: Demo\n---\n\n# Body\n\nPara after frontmatter.\n")
  local h1 = line_with(panel, "h1", "Body")
  eq(h1.command.args.index, 1, "heading sequence after frontmatter")
  local para = line_with(panel, "text", "Para after frontmatter.")
  eq(para.command.args.line, 7, "paragraph line after frontmatter (offset by the frontmatter)")
end)

test("toggle_heading folds and unfolds a section and keeps sequence numbers", function()
  local fold_path = "/tmp/fold-test.md"
  local text = "# One\n\npara one\n\n## Two\n\npara two\n\n### Deep\n\npara deep\n\n# Three\n\npara three\n"
  current_doc = make_doc(fold_path, text)
  current_settings = {}

  local open_panel = M.render_preview({})
  check_panel(open_panel)
  truthy(line_with(open_panel, "text", "para two"), "para two missing while open")
  truthy(line_with(open_panel, "text", "para deep"), "para deep missing while open")
  local h2_open = line_with(open_panel, "h2", "Two")
  eq(h2_open.text, "Two", "open headings stay bare like the VSCode/IDEA preview")
  eq(h2_open.command.args.index, 2, "heading seq while open")

  M.toggle_heading({}, { index = 2 })
  truthy(notifications[#notifications] == "refresh:markdown.preview.panel",
    "toggle must refresh the preview panel")
  local folded = M.render_preview({})
  check_panel(folded)
  truthy(line_with(folded, "text", "para one"), "para one must stay visible")
  truthy(not line_with(folded, "text", "para two"), "para two must be suppressed while folded")
  truthy(not line_with(folded, "text", "para deep"), "nested children must be suppressed too")
  truthy(line_with(folded, "text", "para three"), "para three must stay visible")
  local h2_folded = line_with(folded, "h2", "Two")
  eq(h2_folded.text, "▸ Two", "folded heading should carry the fold indicator")
  local three = line_with(folded, "h1", "Three")
  truthy(three.command, "Three lost its command while another heading was folded")
  eq(three.command.args.index, 4, "heading sequence numbers must not shift while folded")

  M.toggle_heading({}, { index = 2 })
  local reopened = M.render_preview({})
  check_panel(reopened)
  truthy(line_with(reopened, "text", "para two"), "para two must come back after unfold")
  local h2_reopened = line_with(reopened, "h2", "Two")
  eq(h2_reopened.text, "Two", "reopened heading drops the fold indicator again")
  current_doc = nil
end)

test("toggle_heading without args folds the heading at or above the cursor", function()
  local fold_path = "/tmp/fold-cursor.md"
  local text = "# One\n\npara one\n\n## Two\n\npara two\n"
  current_doc = make_doc(fold_path, text, 3)
  current_settings = {}
  M.render_preview({})

  -- Cursor on "para one" (line 3): the enclosing heading is "# One"; folding
  -- an H1 swallows its nested H2 section too.
  M.toggle_heading({})
  local folded = M.render_preview({})
  truthy(not line_with(folded, "text", "para one"), "cursor inside section one must fold it")
  truthy(not line_with(folded, "text", "para two"), "an H1 fold must swallow the nested H2 section")
  M.toggle_heading({})
  local reopened = M.render_preview({})
  truthy(line_with(reopened, "text", "para one"), "second toggle must unfold")

  -- Cursor on "para two" (line 7): the enclosing heading is "## Two".
  current_doc = make_doc(fold_path, text, 7)
  M.toggle_heading({})
  local folded_two = M.render_preview({})
  truthy(line_with(folded_two, "text", "para one"), "cursor in section two must leave one open")
  truthy(not line_with(folded_two, "text", "para two"), "cursor in section two must fold two")
  current_doc = nil
end)

test("goto_source records set_cursor(line, 1) and falls back to the cursor's block", function()
  current_doc = make_doc("/tmp/jump.md", "# Head\n\nfirst para\n\nsecond para\n", 1)
  current_settings = {}
  M.goto_source({}, { line = 3 })
  local last = cursor_calls[#cursor_calls]
  truthy(last, "set_cursor was not called")
  eq(last.line, 3, "goto_source line")
  eq(last.column, 1, "goto_source column")

  current_doc = make_doc("/tmp/jump.md", "# Head\n\nfirst para\n\nsecond para\n", 4)
  M.goto_source({})
  last = cursor_calls[#cursor_calls]
  eq(last.line, 3, "cursor fallback should pick the block at or above the cursor")

  current_doc = make_doc("/tmp/jump.md", "# Head\n\nfirst para\n\nsecond para\n", 1)
  M.goto_source({})
  last = cursor_calls[#cursor_calls]
  eq(last.line, 1, "cursor above everything falls back to the first block")
end)

io.write(string.format("\n%d passed, %d failed\n", PASSED, FAILED))
if FAILED > 0 then
  os.exit(1)
end
