-- Panel rendering: turn a parsed block tree into styled panel lines.
--
-- Split out of the original single-file plugin. Function bodies are the same
-- as in 1.0.1 with three additions: top-level heading lines carry a
-- `markdown.toggle-heading` command and a fold indicator, top-level paragraph
-- lines carry a `markdown.goto-source` command, and collapsed headings
-- suppress their children.

local T = require("text")
local I = require("inline")

local M = {}

local MAX_RENDER_LINES = 4000
local MAX_HIGHLIGHT_BYTES = 64 * 1024
local MAX_HIGHLIGHT_TOTAL = 128 * 1024
local MAX_LINE_BYTES = 3500
local MAX_TABLE_WIDTH = 72
local MAX_TABLE_CELL = 32
local MAX_TABLE_COLUMNS = 10
local MAX_TARGET_BYTES = 512

local TOGGLE_COMMAND = "markdown.toggle-heading"
local GOTO_COMMAND = "markdown.goto-source"

-- ===========================================================================
-- Span plumbing
-- ===========================================================================

local function span_style(span)
  local parts = {}
  if span.bold then
    parts[#parts + 1] = "bold"
  end
  if span.italic then
    parts[#parts + 1] = "italic"
  end
  if span.strike then
    parts[#parts + 1] = "strike"
  end
  if span.code then
    parts[#parts + 1] = "code"
  end
  if span.link then
    parts[#parts + 1] = "link"
  end
  if span.muted then
    parts[#parts + 1] = "muted"
  end
  return table.concat(parts, " ")
end

local function to_panel_spans(spans, opts)
  local text = {}
  local panel = {}
  local i = 1
  while i <= #spans do
    local span = spans[i]
    if span.text ~= "" then
      text[#text + 1] = span.text
      panel[#panel + 1] = {
        text = span.text,
        style = span_style(span),
      }
    end
    if span.target and (i == #spans or spans[i + 1].target ~= span.target) then
      if opts.show_link_targets and not span.autolink then
        local target = span.target
        if #target > MAX_TARGET_BYTES then
          target = T.utf8_prefix(target, MAX_TARGET_BYTES - 1) .. "…"
        end
        local suffix = " (" .. target .. ")"
        text[#text + 1] = suffix
        panel[#panel + 1] = { text = suffix, style = "muted" }
      end
    end
    i = i + 1
  end
  return table.concat(text), panel
end

local function make_line(spans, style, indent, opts)
  local text, panel = to_panel_spans(spans, opts)
  local line = { text = text }
  if style and style ~= "text" then
    line.style = style
  end
  if indent and indent > 0 then
    line.indent = indent
  end
  if #panel > 0 then
    -- The host refuses lines with more than 512 spans; a pathological line
    -- falls back to plain text rather than failing the whole preview.
    if #panel <= 400 then
      line.spans = panel
    end
  end
  return line
end

local function split_spans_at_newlines(spans)
  local segments = { {} }
  for _, span in ipairs(spans) do
    local text = span.text
    local start = 1
    while true do
      local newline = text:find("\n", start, true)
      local part = newline and text:sub(start, newline - 1) or text:sub(start)
      if part ~= "" then
        local copy = {}
        for key, value in pairs(span) do
          copy[key] = value
        end
        copy.text = part
        segments[#segments][#segments[#segments] + 1] = copy
      end
      if not newline then
        break
      end
      segments[#segments + 1] = {}
      start = newline + 1
    end
  end
  return segments
end

local function split_long_segment(spans, max_bytes)
  local lines = { {} }
  local used = 0
  for _, span in ipairs(spans) do
    local text = span.text
    local start = 1
    while start <= #text do
      local room = max_bytes - used
      if room < 1 then
        lines[#lines + 1] = {}
        used = 0
        room = max_bytes
      end
      local part = text:sub(start, start + room - 1)
      part = T.utf8_prefix(part, #part)
      if part == "" then
        part = text:sub(start, start)
      end
      local copy = {}
      for key, value in pairs(span) do
        copy[key] = value
      end
      copy.text = part
      lines[#lines][#lines[#lines] + 1] = copy
      used = used + #part
      start = start + #part
    end
  end
  return lines
end

local function push_line(renderer, line)
  if renderer.count >= MAX_RENDER_LINES then
    renderer.overflow = true
    return false
  end
  renderer.lines[#renderer.lines + 1] = line
  renderer.count = renderer.count + 1
  return true
end

local function render_inline_lines(spans, style, indent, renderer, opts, command)
  local segments = split_spans_at_newlines(spans)
  for _, segment in ipairs(segments) do
    local chunks = split_long_segment(segment, MAX_LINE_BYTES)
    if #chunks == 0 then
      chunks = { {} }
    end
    for _, chunk in ipairs(chunks) do
      local line = make_line(chunk, style, indent, opts)
      if command then
        line.command = command
      end
      if not push_line(renderer, line) then
        return
      end
    end
  end
end

local LANG_ALIASES = {
  js = "js",
  javascript = "js",
  jsx = "jsx",
  ts = "ts",
  typescript = "ts",
  py = "python",
  rb = "ruby",
  rs = "rust",
  sh = "shell",
  bash = "shell",
  zsh = "shell",
  yml = "yaml",
  cpp = "c++",
  ["c++"] = "c++",
  cs = "csharp",
  ["c#"] = "csharp",
  htm = "html",
  md = "markdown",
  plain = "",
  text = "",
}

local function split_highlighted_spans(spans)
  local lines = { {} }
  for _, span in ipairs(spans) do
    local text = span.text or ""
    local role = span.role
    local start = 1
    while true do
      local newline = text:find("\n", start, true)
      local part = newline and text:sub(start, newline - 1) or text:sub(start)
      if part ~= "" then
        lines[#lines][#lines[#lines] + 1] = { text = part, role = role }
      end
      if not newline then
        break
      end
      lines[#lines + 1] = {}
      start = newline + 1
    end
  end
  return lines
end

local function render_code(renderer, code, lang, opts)
  local lines = T.split_lines(code)
  if code == "" then
    lines = { "" }
  end
  local highlighted = nil
  local normalized = LANG_ALIASES[lang] or lang
  if opts.highlight
    and normalized ~= ""
    and #code > 0
    and #code <= MAX_HIGHLIGHT_BYTES
    and renderer.highlight_budget >= #code
  then
    local ok, spans = pcall(opts.highlight, code, normalized)
    if ok and type(spans) == "table" then
      highlighted = split_highlighted_spans(spans)
      renderer.highlight_budget = renderer.highlight_budget - #code
    end
  end
  if highlighted then
    for _, spans in ipairs(highlighted) do
      local text = {}
      for _, span in ipairs(spans) do
        text[#text + 1] = span.text
      end
      local line_text = table.concat(text)
      if #line_text > MAX_LINE_BYTES then
        push_line(renderer, { text = T.utf8_prefix(line_text, MAX_LINE_BYTES - 1) .. "…", style = "code" })
      elseif #spans > 0 and #spans <= 400 then
        push_line(renderer, { text = line_text, style = "code", spans = spans })
      else
        push_line(renderer, { text = line_text, style = "code" })
      end
      if renderer.overflow then
        return
      end
    end
  else
    for _, line in ipairs(lines) do
      local text = line
      if #text > MAX_LINE_BYTES then
        text = T.utf8_prefix(text, MAX_LINE_BYTES - 1) .. "…"
      end
      push_line(renderer, { text = text, style = "code" })
      if renderer.overflow then
        return
      end
    end
  end
end

local function pad(text, width, align)
  local used = T.display_width(text)
  if used >= width then
    return "", text, ""
  end
  local missing = width - used
  if align == "right" then
    return string.rep(" ", missing), text, ""
  elseif align == "center" then
    local left = math.floor(missing / 2)
    return string.rep(" ", left), text, string.rep(" ", missing - left)
  end
  return "", text, string.rep(" ", missing)
end

local function table_cell(cell, width, align, opts, header)
  local spans = I.parse_inline(cell, {}, opts)
  local plain = I.plain_inline(spans)
  if T.display_width(plain) > width then
    plain = T.truncate_display(plain, width)
    spans = { { text = plain } }
  end
  local left, content, right = pad(plain, width, align)
  local out = {}
  if left ~= "" then
    out[#out + 1] = { text = left }
  end
  for _, span in ipairs(spans) do
    local copy = {}
    for key, value in pairs(span) do
      copy[key] = value
    end
    if header then
      copy.bold = true
    end
    out[#out + 1] = copy
  end
  if right ~= "" then
    out[#out + 1] = { text = right }
  end
  return out
end

local function table_line(parts)
  local text = {}
  local spans = {}
  for _, part in ipairs(parts) do
    if part.text ~= "" then
      text[#text + 1] = part.text
      spans[#spans + 1] = { text = part.text, style = span_style(part) }
    end
  end
  return table.concat(text), spans
end

local function render_table(block, renderer, opts)
  local columns = #block.header
  if columns == 0 then
    return
  end
  if columns > MAX_TABLE_COLUMNS then
    columns = MAX_TABLE_COLUMNS
  end
  local rows = {}
  for _, row in ipairs(block.rows) do
    local cells = {}
    for column = 1, columns do
      cells[column] = row[column] or ""
    end
    rows[#rows + 1] = cells
  end
  local widths = {}
  for column = 1, columns do
    local width = math.max(3, T.display_width(block.header[column] or ""))
    for _, row in ipairs(rows) do
      local cell_width = T.display_width(row[column] or "")
      if cell_width > width then
        width = cell_width
      end
    end
    widths[column] = math.min(width, MAX_TABLE_CELL)
  end
  local function total_width()
    local total = 1
    for column = 1, columns do
      total = total + widths[column] + 3
    end
    return total
  end
  while total_width() > MAX_TABLE_WIDTH do
    local widest = 1
    for column = 2, columns do
      if widths[column] > widths[widest] then
        widest = column
      end
    end
    if widths[widest] <= 3 then
      break
    end
    widths[widest] = widths[widest] - 1
  end
  local function border(left, middle, right)
    local parts = { left }
    for column = 1, columns do
      parts[#parts + 1] = string.rep("─", widths[column] + 2)
      if column < columns then
        parts[#parts + 1] = middle
      end
    end
    parts[#parts + 1] = right
    return table.concat(parts)
  end
  local function row_line(cells, header)
    local parts = { { text = "│ " } }
    for column = 1, columns do
      local cell_spans = table_cell(cells[column] or "", widths[column], block.aligns[column] or "left", opts, header)
      for _, span in ipairs(cell_spans) do
        parts[#parts + 1] = span
      end
      parts[#parts + 1] = { text = column < columns and " │ " or " │" }
    end
    local text, spans = table_line(parts)
    return text, spans
  end
  local function push_table(text, spans)
    if #text > MAX_LINE_BYTES then
      text = T.utf8_prefix(text, MAX_LINE_BYTES - 1) .. "…"
      spans = nil
    elseif spans and #spans > 400 then
      spans = nil
    end
    push_line(renderer, { text = text, style = "table", spans = spans })
  end
  push_table(border("┌", "┬", "┐"), nil)
  local header_text, header_spans = row_line(block.header, true)
  push_table(header_text, header_spans)
  push_table(border("├", "┼", "┤"), nil)
  for _, row in ipairs(rows) do
    local text, spans = row_line(row, false)
    push_table(text, spans)
    if renderer.overflow then
      return
    end
  end
  push_table(border("└", "┴", "┘"), nil)
end

local function list_bullet(depth)
  local bullets = { "•", "◦", "▪", "‣", "·" }
  return bullets[(depth % #bullets) + 1]
end

-- ===========================================================================
-- Folding
-- ===========================================================================

-- Index of the next top-level heading that closes the section opened by the
-- heading at `start`: a heading of the same or higher level, or the end.
local function fold_end(blocks, start)
  local level = blocks[start].level or 6
  for i = start + 1, #blocks do
    local block = blocks[i]
    if block.kind == "heading" and (block.level or 6) <= level then
      return i
    end
  end
  return #blocks + 1
end

-- ===========================================================================
-- Block rendering
-- ===========================================================================

-- Forward declaration: quote blocks recurse into render_blocks.
local render_blocks

local function render_heading(block, renderer, opts)
  local seq = block.seq or 0
  local collapsed = opts.collapsed ~= nil and opts.collapsed[seq] == true
  local spans = { { text = collapsed and "▸ " or "▾ ", muted = true } }
  for _, span in ipairs(I.parse_inline(block.text, {}, opts)) do
    spans[#spans + 1] = span
  end
  render_inline_lines(spans, "h" .. (block.level or 6), 0, renderer, opts, {
    id = TOGGLE_COMMAND,
    args = { index = seq },
  })
end

local function render_paragraph(block, renderer, opts)
  local spans = I.parse_inline(block.text, {}, opts)
  if block.line then
    render_inline_lines(spans, "text", 0, renderer, opts, {
      id = GOTO_COMMAND,
      args = { line = block.line },
    })
  else
    render_inline_lines(spans, "text", 0, renderer, opts)
  end
end

local function render_block(block, renderer, opts, quote_depth)
  if block.kind == "heading" then
    local spans = I.parse_inline(block.text, {}, opts)
    if quote_depth > 0 then
      for _, span in ipairs(spans) do
        span.bold = true
      end
      render_inline_lines(spans, "quote", quote_depth, renderer, opts)
    else
      render_heading(block, renderer, opts)
    end
  elseif block.kind == "paragraph" then
    local spans = I.parse_inline(block.text, {}, opts)
    if quote_depth > 0 then
      render_inline_lines(spans, "quote", quote_depth, renderer, opts)
    else
      render_paragraph(block, renderer, opts)
    end
  elseif block.kind == "code" then
    render_code(renderer, table.concat(block.lines, "\n"), block.lang or "", opts)
  elseif block.kind == "list" then
    for _, item in ipairs(block.items) do
      local spans = {}
      local marker
      if item.checked ~= nil then
        marker = item.checked and "☑ " or "☐ "
        spans[#spans + 1] = { text = marker, muted = true }
      elseif item.ordered then
        marker = item.marker .. " "
        spans[#spans + 1] = { text = marker, muted = true }
      else
        marker = list_bullet(item.depth) .. " "
        spans[#spans + 1] = { text = marker, muted = true }
      end
      local content = I.parse_inline(item.text, {}, opts)
      for _, span in ipairs(content) do
        spans[#spans + 1] = span
      end
      render_inline_lines(spans, "list", item.depth + quote_depth, renderer, opts)
    end
  elseif block.kind == "quote" then
    render_blocks(block.blocks, renderer, opts, quote_depth + 1)
  elseif block.kind == "table" then
    render_table(block, renderer, opts)
  elseif block.kind == "rule" then
    push_line(renderer, { text = "", style = "rule" })
  elseif block.kind == "html" then
    for _, line in ipairs(block.lines) do
      push_line(renderer, { text = line, style = "muted" })
      if renderer.overflow then
        return
      end
    end
  end
end

-- Forward declaration: quote blocks recurse into render_blocks.
render_blocks = function(blocks, renderer, opts, quote_depth)
  quote_depth = quote_depth or 0
  local i = 1
  while i <= #blocks do
    local block = blocks[i]
    if quote_depth == 0 and block.kind == "heading" then
      render_heading(block, renderer, opts)
      if opts.collapsed ~= nil and opts.collapsed[block.seq or 0] == true then
        i = fold_end(blocks, i)
      else
        i = i + 1
      end
    elseif quote_depth == 0 and block.kind == "paragraph" then
      render_paragraph(block, renderer, opts)
      i = i + 1
    else
      render_block(block, renderer, opts, quote_depth)
      i = i + 1
    end
    if renderer.overflow then
      return
    end
  end
end

-- ===========================================================================
-- Render entry
-- ===========================================================================

-- M.render(parsed, opts) -> { lines = ... }
--
-- `parsed` is the table returned by parser.parse; `opts` carries
-- show_link_targets / show_frontmatter / highlight (host wrapper) and the
-- optional `collapsed` set ({ [heading seq] = true }).
function M.render(parsed, opts)
  opts = opts or {}
  local renderer = {
    lines = {},
    count = 0,
    overflow = false,
    highlight_budget = MAX_HIGHLIGHT_TOTAL,
  }
  if parsed.frontmatter then
    push_line(renderer, { text = "Front matter", style = "muted" })
    render_code(renderer, table.concat(parsed.frontmatter, "\n"), "yaml", opts)
  end
  render_blocks(parsed.blocks, renderer, opts, 0)
  if parsed.truncated then
    renderer.lines[#renderer.lines + 1] = {
      text = "Preview truncated: the document is larger than 512 KiB.",
      style = "muted",
    }
  end
  if renderer.overflow then
    renderer.lines[#renderer.lines + 1] = {
      text = "Preview truncated: too many rendered lines.",
      style = "muted",
    }
  end
  if #renderer.lines == 0 then
    renderer.lines[1] = { text = "This document is empty.", style = "muted" }
  end
  return { lines = renderer.lines }
end

M._internals = {
  fold_end = fold_end,
}

return M
