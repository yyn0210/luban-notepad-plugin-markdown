-- Block-level Markdown parsing: normalize the source, split front matter and
-- walk the lines into a block tree.
--
-- Split out of the original single-file plugin. Function bodies are the same
-- as in 1.0.1 except that every block records its 1-based source line
-- (`block.line`), threaded through quote recursion, and top-level headings
-- get a stable sequence number (`block.seq`) used by the fold feature.

local T = require("text")

local M = {}

local MAX_SOURCE_BYTES = 512 * 1024

local function atx_level(rest)
  local hashes = rest:match("^(#+)[ \t]+")
  if hashes and #hashes <= 6 then
    return #hashes
  end
  return nil
end

local function fence_info(rest)
  local run = rest:match("^(`+)")
  if run and #run >= 3 then
    return "`", #run, rest:sub(#run + 1)
  end
  run = rest:match("^(~+)")
  if run and #run >= 3 then
    return "~", #run, rest:sub(#run + 1)
  end
  return nil
end

local function is_thematic(rest)
  local compact = rest:gsub("%s", "")
  if #compact < 3 then
    return false
  end
  return compact:match("^%-+$") ~= nil
    or compact:match("^%*+$") ~= nil
    or compact:match("^_+$") ~= nil
end

local function is_setext_underline(line)
  return line:match("^ *[=]+ *$") ~= nil or line:match("^ *[-]+ *$") ~= nil
end

local function list_marker(rest)
  local marker, text = rest:match("^([%*%+%-])[ \t]+(.*)$")
  local ordered = false
  if not marker then
    marker, text = rest:match("^(%d+[%.%)])[ \t]+(.*)$")
    ordered = true
  end
  if not marker then
    return nil
  end
  local checked = nil
  local check, rest_text = text:match("^%[([ xX])%][ \t]+(.*)$")
  if check then
    checked = check ~= " "
    text = rest_text
  end
  return {
    marker = marker,
    ordered = ordered,
    text = text,
    checked = checked,
  }
end

local function split_table_row(line)
  local text = T.trim(line)
  if text:sub(1, 1) == "|" then
    text = text:sub(2)
  end
  if text:sub(-1) == "|" and text:sub(-2) ~= "\\|" then
    text = text:sub(1, -2)
  end
  local cells = {}
  local buffer = {}
  local i = 1
  while i <= #text do
    local c = text:sub(i, i)
    if c == "\\" and text:sub(i + 1, i + 1) == "|" then
      buffer[#buffer + 1] = "|"
      i = i + 2
    elseif c == "|" then
      cells[#cells + 1] = T.trim(table.concat(buffer))
      buffer = {}
      i = i + 1
    else
      buffer[#buffer + 1] = c
      i = i + 1
    end
  end
  cells[#cells + 1] = T.trim(table.concat(buffer))
  return cells
end

local function table_aligns(line)
  local cells = split_table_row(line)
  if #cells == 0 then
    return nil
  end
  local aligns = {}
  for _, cell in ipairs(cells) do
    if not cell:match("^:?%-+:?$") then
      return nil
    end
    local align = "left"
    if cell:sub(1, 1) == ":" and cell:sub(-1) == ":" then
      align = "center"
    elseif cell:sub(-1) == ":" then
      align = "right"
    end
    aligns[#aligns + 1] = align
  end
  return aligns
end

local BLOCK_TAGS = {
  address = true, article = true, aside = true, base = true, basefont = true,
  blockquote = true, body = true, caption = true, center = true, col = true,
  colgroup = true, dd = true, details = true, dialog = true, dir = true,
  div = true, dl = true, dt = true, fieldset = true, figcaption = true,
  figure = true, footer = true, form = true, frame = true, frameset = true,
  h1 = true, h2 = true, h3 = true, h4 = true, h5 = true, h6 = true,
  head = true, header = true, hr = true, html = true, iframe = true,
  legend = true, li = true, link = true, main = true, menu = true,
  menuitem = true, nav = true, noframes = true, ol = true, optgroup = true,
  option = true, p = true, param = true, pre = true, section = true,
  source = true, summary = true, table = true, tbody = true, td = true,
  tfoot = true, th = true, thead = true, title = true, tr = true,
  track = true, ul = true, script = true, style = true, textarea = true,
}

local function is_html_block_start(rest)
  if rest:sub(1, 4) == "<!--" then
    return true
  end
  local name = rest:match("^<([%a][%w%-]*)")
  return name ~= nil and BLOCK_TAGS[name:lower()] == true
end

local function is_table_start(lines, i)
  local line = lines[i]
  if not line:find("|", 1, true) then
    return nil
  end
  local next_line = lines[i + 1]
  if not next_line then
    return nil
  end
  return table_aligns(next_line)
end

local function is_block_start(lines, i)
  local _, rest = T.expand_indent(lines[i])
  if fence_info(rest) then
    return true
  end
  if atx_level(rest) then
    return true
  end
  if rest:sub(1, 1) == ">" then
    return true
  end
  if list_marker(rest) then
    return true
  end
  if is_thematic(rest) then
    return true
  end
  if is_html_block_start(rest) then
    return true
  end
  if is_table_start(lines, i) then
    return true
  end
  return false
end

-- `lines` is the normalized document (front matter included); `from` is the
-- first line index to parse and `line_base` maps indices of a synthetic line
-- array (quote contents) back to document lines: absolute line = line_base + i.
local function parse_blocks(lines, opts, from, line_base)
  local blocks = {}
  local i = from or 1
  local n = #lines
  local base = line_base or 0
  while i <= n do
    local line = lines[i]
    if T.is_blank(line) then
      i = i + 1
    else
      local indent, rest = T.expand_indent(line)
      local fence_char, fence_len, fence_rest = fence_info(rest)
      if fence_char and indent <= 3 then
        local lang = (fence_rest or ""):match("^ *([^%s]+)") or ""
        local code = {}
        local start_line = base + i
        i = i + 1
        while i <= n do
          local candidate = lines[i]
          local cindent, crest = T.expand_indent(candidate)
          local run = crest:match("^" .. (fence_char == "`" and "`+" or "~+"))
          if cindent <= 3 and run and #run >= fence_len and crest:sub(#run + 1):match("^%s*$") then
            i = i + 1
            break
          end
          local content = candidate
          if indent > 0 and cindent >= indent then
            content = candidate:sub(indent + 1)
          end
          code[#code + 1] = content
          i = i + 1
        end
        blocks[#blocks + 1] = { kind = "code", lang = lang, lines = code, line = start_line }
      elseif indent <= 3 and atx_level(rest) then
        local level = atx_level(rest)
        local _, title = rest:match("^(#+)[ \t]+(.*)$")
        title = title:gsub("[ \t]+#+[ \t]*$", "")
        blocks[#blocks + 1] = { kind = "heading", level = level, text = title, line = base + i }
        i = i + 1
      elseif indent <= 3 and rest:sub(1, 1) == ">" then
        local quoted = {}
        local start_line = base + i
        while i <= n do
          local candidate = lines[i]
          local _, crest = T.expand_indent(candidate)
          if crest:sub(1, 1) == ">" then
            local content = crest:sub(2)
            content = content:gsub("^ ", "")
            quoted[#quoted + 1] = content
            i = i + 1
          else
            break
          end
        end
        blocks[#blocks + 1] = {
          kind = "quote",
          blocks = parse_blocks(quoted, opts, 1, start_line - 1),
          line = start_line,
        }
      elseif indent <= 3 and list_marker(rest) then
        local base_indent = indent
        local items = {}
        local current = nil
        local start_line = base + i
        while i <= n do
          local candidate = lines[i]
          if T.is_blank(candidate) then
            local j = i + 1
            while j <= n and T.is_blank(lines[j]) do
              j = j + 1
            end
            local next_indent, next_rest = j <= n and T.expand_indent(lines[j]) or 0, ""
            if j <= n then
              next_indent, next_rest = T.expand_indent(lines[j])
            end
            local next_marker = j <= n and list_marker(next_rest) or nil
            if next_marker and next_indent >= base_indent then
              i = j
            else
              break
            end
          else
            local cindent, crest = T.expand_indent(candidate)
            local marker = list_marker(crest)
            if marker and cindent >= base_indent then
              local depth = math.floor((cindent - base_indent) / 2)
              if depth < 0 then
                depth = 0
              elseif depth > 4 then
                depth = 4
              end
              current = {
                depth = depth,
                ordered = marker.ordered,
                marker = marker.marker,
                text = marker.text,
                checked = marker.checked,
              }
              items[#items + 1] = current
              i = i + 1
            elseif current and cindent > base_indent then
              current.text = current.text .. " " .. crest
              i = i + 1
            else
              break
            end
          end
        end
        blocks[#blocks + 1] = { kind = "list", items = items, line = start_line }
      elseif indent <= 3 and is_thematic(rest) then
        blocks[#blocks + 1] = { kind = "rule", line = base + i }
        i = i + 1
      elseif indent <= 3 and is_table_start(lines, i) then
        local header = split_table_row(rest)
        local aligns = is_table_start(lines, i)
        local start_line = base + i
        i = i + 2
        local rows = {}
        while i <= n and not T.is_blank(lines[i]) and lines[i]:find("|", 1, true) do
          rows[#rows + 1] = split_table_row(lines[i])
          i = i + 1
        end
        blocks[#blocks + 1] = {
          kind = "table",
          header = header,
          aligns = aligns,
          rows = rows,
          line = start_line,
        }
      elseif indent <= 3 and is_html_block_start(rest) then
        local html = {}
        local start_line = base + i
        while i <= n and not T.is_blank(lines[i]) do
          local _, hrest = T.expand_indent(lines[i])
          html[#html + 1] = hrest
          i = i + 1
        end
        blocks[#blocks + 1] = { kind = "html", lines = html, line = start_line }
      elseif indent >= 4 then
        local code = {}
        local start_line = base + i
        while i <= n do
          local candidate = lines[i]
          if T.is_blank(candidate) then
            code[#code + 1] = ""
            i = i + 1
          else
            local cindent = T.expand_indent(candidate)
            if cindent >= 4 then
              code[#code + 1] = candidate:sub(5)
              i = i + 1
            else
              break
            end
          end
        end
        while #code > 0 and code[#code] == "" do
          code[#code] = nil
        end
        blocks[#blocks + 1] = { kind = "code", lang = "", lines = code, line = start_line }
      else
        local paragraph = { rest }
        local start_line = base + i
        i = i + 1
        while i <= n do
          local candidate = lines[i]
          if T.is_blank(candidate) then
            break
          end
          if #paragraph == 1 and is_setext_underline(candidate) then
            break
          end
          if is_block_start(lines, i) then
            break
          end
          local _, crest = T.expand_indent(candidate)
          paragraph[#paragraph + 1] = crest
          i = i + 1
        end
        if #paragraph == 1 and i <= n and is_setext_underline(lines[i]) then
          local underline = lines[i]
          local level = underline:match("^ *[=]") and 1 or 2
          blocks[#blocks + 1] = {
            kind = "heading",
            level = level,
            text = paragraph[1],
            line = start_line,
          }
          i = i + 1
        else
          blocks[#blocks + 1] = {
            kind = "paragraph",
            text = table.concat(paragraph, "\n"),
            line = start_line,
          }
        end
      end
    end
  end
  return blocks
end

local function split_frontmatter(lines, show_frontmatter)
  if #lines == 0 or not lines[1]:match("^%-%-%-%s*$") then
    return nil, 1
  end
  local limit = math.min(#lines, 500)
  for i = 2, limit do
    if lines[i]:match("^%-%-%-%s*$") or lines[i]:match("^%.%.%.%s*$") then
      if not show_frontmatter then
        return nil, i + 1
      end
      local frontmatter = {}
      for j = 2, i - 1 do
        frontmatter[#frontmatter + 1] = lines[j]
      end
      return frontmatter, i + 1
    end
  end
  return nil, 1
end

-- M.parse(text, opts) -> { blocks, frontmatter, truncated }
--
-- `blocks` is the top-level block list; every block carries `line` (1-based
-- document line) and top-level headings carry `seq` (1-based heading number,
-- assigned in document order and independent of rendering, so fold state
-- survives collapsing). `frontmatter` is the raw YAML line list when
-- `opts.show_frontmatter` is set and the document opens with `---`.
function M.parse(text, opts)
  opts = opts or {}
  local normalized = T.normalize_text(type(text) == "string" and text or "")
  local truncated = false
  if #normalized > MAX_SOURCE_BYTES then
    normalized = T.utf8_prefix(normalized, MAX_SOURCE_BYTES)
    truncated = true
  end
  local lines = T.split_lines(normalized)
  local frontmatter, start = split_frontmatter(lines, opts.show_frontmatter)
  local blocks = parse_blocks(lines, opts, start, 0)
  local seq = 0
  for _, block in ipairs(blocks) do
    if block.kind == "heading" then
      seq = seq + 1
      block.seq = seq
    end
  end
  return {
    blocks = blocks,
    frontmatter = frontmatter,
    truncated = truncated,
  }
end

M._internals = {
  parse_blocks = parse_blocks,
  split_frontmatter = split_frontmatter,
}

return M
