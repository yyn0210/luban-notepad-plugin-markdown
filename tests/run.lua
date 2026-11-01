-- Standalone tests for main.lua (Lua 5.4).
--
-- Run from the repository root:
--   lua5.4 tests/run.lua
--
-- The harness supplies the same `luban` surface the host exposes. It never
-- runs inside the app sandbox, so `os` and `io` are available here only.

local PLUGIN_MAIN = os.getenv("PLUGIN_MAIN") or "main.lua"

local current_doc = nil
local current_settings = {}
local highlight_roles = true
local notifications = {}

local function reset_luban()
  current_doc = nil
  current_settings = {}
  highlight_roles = true
  notifications = {}
  luban = {
    log = function(level, message) end,
    notify = function(message)
      notifications[#notifications + 1] = message
    end,
    get_document = function()
      return current_doc
    end,
    settings = {
      get = function(key)
        return current_settings[key]
      end,
    },
    panel = {
      open = function(id)
        notifications[#notifications + 1] = "open:" .. id
        return true
      end,
    },
    syntax = {
      highlight = function(text, language)
        if not highlight_roles then
          return nil, "highlighting disabled"
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
    table = true, rule = true,
  }
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

local function render(text, settings)
  current_doc = { path = "/tmp/test.md", language = "Markdown", text = text }
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
  local panel = render("**bold** *italic* ***both*** `code` ~~gone~~ [label](https://e.com/a?b=1) and <https://e.com/x>\n")
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

test("link targets can be hidden", function()
  local panel = render("[label](https://e.com)\n", { show_link_targets = false })
  local line = line_with(panel, "text")
  eq(line.text, "label")
  truthy(style_has(line, "link", "label"), "link style missing")
end)

test("images become readable placeholders", function()
  local panel = render("![alt text](pic.png)\n")
  local line = line_with(panel, "text")
  contains(line.text, "🖼 alt text")
  contains(line.text, "pic.png")
  truthy(style_has(line, "muted"), "image placeholder should be muted")
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

test("tables align columns by display width including CJK", function()
  local panel = render("| Name | 值 | Note |\n|:-----|:--:|-----:|\n| a | 中文 | 1 |\n| longer cell | x | 22 |\n")
  local widths = {}
  local header
  for _, line in ipairs(panel.lines) do
    if line.style == "table" then
      widths[#widths + 1] = M._internals.display_width(line.text)
      if line.text:find("Name", 1, true) then
        header = line
      end
    end
  end
  truthy(#widths >= 5, "table lines missing")
  for _, width in ipairs(widths) do
    eq(width, widths[1], "table line widths differ")
  end
  truthy(header, "table header missing")
  truthy(style_has(header, "bold", "Name"), "header cell should be bold")
  truthy(line_with(panel, "table", "中文"), "CJK cell missing")
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

test("raw HTML blocks are shown as muted text and inline tags are stripped", function()
  local panel = render("<div class=\"x\">\nraw\n</div>\n\nA <span>tag</span> here.\n")
  truthy(line_with(panel, "muted", "<div"), "HTML block missing")
  local paragraph = line_with(panel, "text", "A tag here.")
  truthy(paragraph, "inline HTML was not stripped")
end)

test("hard breaks create separate lines; soft breaks join with spaces", function()
  local panel = render("one  \ntwo\nthree\n")
  local texts = line_texts(panel)
  eq(texts[1], "one", "hard break first line")
  eq(texts[2], "two three", "soft break should join with a space")
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

test("the command opens the declared panel, with a menu fallback on old hosts", function()
  M.open_preview({})
  eq(notifications[#notifications], "open:markdown.preview.panel")
  local original = luban.panel
  luban.panel = nil
  M.open_preview({})
  truthy(notifications[#notifications]:find("Plugins menu", 1, true), "old host fallback missing")
  luban.panel = original
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
  truthy(line_with(panel, "table"), "fixture table missing")
  truthy(line_with(panel, "code"), "fixture code missing")
  truthy(line_with(panel, "list"), "fixture list missing")
end)

io.write(string.format("\n%d passed, %d failed\n", PASSED, FAILED))
if FAILED > 0 then
  os.exit(1)
end
