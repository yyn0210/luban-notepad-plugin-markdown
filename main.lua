-- Markdown Preview for Luban Notepad.
--
-- A self-contained GFM renderer for the sandboxed Lua plugin runtime. It never
-- touches the file system: the preview reads the active document through
-- luban.get_document() and returns styled panel lines.
--
-- Rich spans require Luban Notepad 1.0.0-preview.2 or newer. Older hosts ignore
-- style/spans/indent and render the plain `text` fallback, which this plugin
-- always fills in.

local M = {}

local MAX_SOURCE_BYTES = 512 * 1024
local MAX_RENDER_LINES = 4000
local MAX_HIGHLIGHT_BYTES = 64 * 1024
local MAX_HIGHLIGHT_TOTAL = 128 * 1024
local MAX_LINE_BYTES = 3500
local MAX_TABLE_WIDTH = 96
local MAX_TABLE_CELL = 32
local MAX_TABLE_COLUMNS = 10
local MAX_TARGET_BYTES = 512

-- ===========================================================================
-- Text helpers
-- ===========================================================================

local function normalize_text(text)
  text = text:gsub("\r\n", "\n"):gsub("\r", "\n"):gsub("\t", "    ")
  if text:sub(1, 3) == "\239\187\191" then
    text = text:sub(4)
  end
  return text
end

local function split_lines(text)
  local lines = {}
  if text == "" then
    return { "" }
  end
  for line in (text .. "\n"):gmatch("(.-)\n") do
    lines[#lines + 1] = line
  end
  return lines
end

local function is_blank(line)
  return line:match("^%s*$") ~= nil
end

local function trim(text)
  return (text:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function ltrim(text)
  return (text:gsub("^%s+", ""))
end

local function utf8_prefix(text, max_bytes)
  if #text <= max_bytes then
    return text
  end
  local cut = max_bytes
  while cut > 0 do
    local byte = text:byte(cut + 1)
    if byte and byte >= 0x80 and byte < 0xC0 then
      cut = cut - 1
    else
      break
    end
  end
  if cut <= 0 then
    return ""
  end
  return text:sub(1, cut)
end

-- Columns occupied by one codepoint in a monospace cell. Combining marks and
-- control characters take none; CJK/fullwidth/emoji take two.
local function codepoint_width(cp)
  if cp == 0 then
    return 0
  end
  if cp < 32 or (cp >= 0x7F and cp < 0xA0) then
    return 0
  end
  if (cp >= 0x0300 and cp <= 0x036F)
    or (cp >= 0x1AB0 and cp <= 0x1AFF)
    or (cp >= 0x1DC0 and cp <= 0x1DFF)
    or (cp >= 0x20D0 and cp <= 0x20FF)
    or (cp >= 0xFE20 and cp <= 0xFE2F)
  then
    return 0
  end
  if (cp >= 0x1100 and cp <= 0x115F)
    or (cp >= 0x2E80 and cp <= 0xA4CF and cp ~= 0x303F)
    or (cp >= 0xAC00 and cp <= 0xD7A3)
    or (cp >= 0xF900 and cp <= 0xFAFF)
    or (cp >= 0xFE10 and cp <= 0xFE19)
    or (cp >= 0xFE30 and cp <= 0xFE6F)
    or (cp >= 0xFF00 and cp <= 0xFF60)
    or (cp >= 0xFFE0 and cp <= 0xFFE6)
    or (cp >= 0x1F300 and cp <= 0x1F64F)
    or (cp >= 0x1F900 and cp <= 0x1F9FF)
    or (cp >= 0x20000 and cp <= 0x3FFFD)
  then
    return 2
  end
  return 1
end

local function display_width(text)
  local ok, width = pcall(function()
    local total = 0
    for _, cp in utf8.codes(text) do
      total = total + codepoint_width(cp)
    end
    return total
  end)
  if ok then
    return width
  end
  return #text
end

local function truncate_display(text, width)
  if display_width(text) <= width then
    return text
  end
  local out = {}
  local used = 0
  local ok = pcall(function()
    for _, cp in utf8.codes(text) do
      local cw = codepoint_width(cp)
      if used + cw > width - 1 then
        break
      end
      out[#out + 1] = utf8.char(cp)
      used = used + cw
    end
  end)
  if not ok then
    return utf8_prefix(text, width - 1) .. "…"
  end
  return table.concat(out) .. "…"
end

local function expand_indent(line)
  local spaces = line:match("^ *") or ""
  return #spaces, line:sub(#spaces + 1)
end

-- ===========================================================================
-- Inline parser
-- ===========================================================================

local function new_flags(base)
  base = base or {}
  return {
    bold = base.bold or false,
    italic = base.italic or false,
    code = base.code or false,
    strike = base.strike or false,
    link = base.link or false,
    muted = base.muted or false,
    target = base.target,
    autolink = base.autolink or false,
    image = base.image or false,
  }
end

local function same_flags(a, b)
  return (a.bold == b.bold)
    and (a.italic == b.italic)
    and (a.code == b.code)
    and (a.strike == b.strike)
    and (a.link == b.link)
    and (a.muted == b.muted)
    and (a.target == b.target)
    and (a.autolink == b.autolink)
    and (a.image == b.image)
end

local function push_span(out, text, flags)
  if text == nil or text == "" then
    return
  end
  local last = out[#out]
  if last and same_flags(last, flags) then
    last.text = last.text .. text
    return
  end
  out[#out + 1] = {
    text = text,
    bold = flags.bold,
    italic = flags.italic,
    code = flags.code,
    strike = flags.strike,
    link = flags.link,
    muted = flags.muted,
    target = flags.target,
    autolink = flags.autolink,
    image = flags.image,
  }
end

local function plain_inline(spans)
  local parts = {}
  for _, span in ipairs(spans) do
    parts[#parts + 1] = span.text
  end
  return table.concat(parts)
end

local function code_run_length(text, i)
  local run = 0
  while text:sub(i + run, i + run) == "`" do
    run = run + 1
  end
  return run
end

local function skip_code_span(text, i)
  local run = code_run_length(text, i)
  if run == 0 then
    return i + 1
  end
  local needle = string.rep("`", run)
  local pos = i + run
  while true do
    local start, finish = text:find(needle, pos, true)
    if not start then
      return i + run
    end
    local before = start > 1 and text:sub(start - 1, start - 1) or ""
    local after = finish < #text and text:sub(finish + 1, finish + 1) or ""
    if before ~= "`" and after ~= "`" then
      return finish + 1
    end
    pos = finish + 1
  end
end

local function find_matching_bracket(text, start)
  local depth = 0
  local i = start
  while i <= #text do
    local c = text:sub(i, i)
    if c == "\\" then
      i = i + 2
    elseif c == "`" then
      i = skip_code_span(text, i)
    elseif c == "[" then
      depth = depth + 1
      i = i + 1
    elseif c == "]" then
      depth = depth - 1
      if depth == 0 then
        return i
      end
      i = i + 1
    else
      i = i + 1
    end
  end
  return nil
end

local function find_close_paren(text, start)
  local depth = 0
  local quote = nil
  local i = start
  while i <= #text do
    local c = text:sub(i, i)
    if quote then
      if c == "\\" then
        i = i + 2
      elseif c == quote then
        quote = nil
        i = i + 1
      else
        i = i + 1
      end
    elseif c == "\\" then
      i = i + 2
    elseif c == "<" then
      local close = text:find(">", i + 1, true)
      i = close and close + 1 or i + 1
    elseif c == '"' or c == "'" then
      quote = c
      i = i + 1
    elseif c == "(" then
      depth = depth + 1
      i = i + 1
    elseif c == ")" then
      depth = depth - 1
      if depth == 0 then
        return i
      end
      i = i + 1
    else
      i = i + 1
    end
  end
  return nil
end

local function parse_link_destination(inside)
  local text = trim(inside)
  local dest = nil
  if text:sub(1, 1) == "<" then
    local close = text:find(">", 2, true)
    if close then
      dest = text:sub(2, close - 1)
    end
  else
    dest = text:match("^([^%s]+)")
  end
  if not dest or dest == "" then
    return nil
  end
  return dest
end

local function can_open_emphasis(text, i, ch, run)
  local next_c = text:sub(i + run, i + run)
  if next_c == "" or next_c:match("[ \t\n]") then
    return false
  end
  if ch == "_" then
    local prev = text:sub(i - 1, i - 1)
    if prev ~= "" and prev:match("[%w]") then
      return false
    end
  end
  return true
end

-- Find the closing run for an emphasis opener. `want` is 1 (italic), 2 (bold)
-- or 3 (both). Runs longer than `want` keep their unused delimiters inside the
-- inner text so nested emphasis survives the naive recursion.
local function find_emphasis_close(text, from, ch, want)
  local i = from
  local n = #text
  while i <= n do
    local c = text:sub(i, i)
    if c == "\\" then
      i = i + 2
    elseif c == "`" then
      i = skip_code_span(text, i)
    elseif c == ch then
      local run_start = i
      while text:sub(i, i) == ch do
        i = i + 1
      end
      local run = i - run_start
      if run >= want then
        local prev = text:sub(run_start - 1, run_start - 1)
        local next_c = text:sub(i, i)
        local can_close = prev ~= "" and not prev:match("[ \t\n]")
        if ch == "_" and next_c ~= "" and next_c:match("[%w]") then
          can_close = false
        end
        if can_close then
          local use_start = run_start
          if want == 2 and run == 3 then
            use_start = run_start + 1
          elseif want == 1 and run == 3 then
            use_start = run_start + 2
          end
          return use_start
        end
      end
    else
      i = i + 1
    end
  end
  return nil
end

local function is_html_tag(text, i)
  local close = text:find(">", i + 1, true)
  if not close then
    return nil
  end
  local tag = text:sub(i, close)
  -- Require whitespace, `/` or `>` after the name so `<https://...>` is left
  -- for the autolink branch instead of being treated as a tag named "https".
  local name = tag:match("^</?([%a][%w%-]*)[%s/>]")
  if not name then
    return nil
  end
  return close, name:lower()
end

local parse_inline

local function parse_inline_into(text, flags, out, opts)
  local i = 1
  local n = #text
  while i <= n do
    local c = text:sub(i, i)
    if c == "\\" then
      local next_c = text:sub(i + 1, i + 1)
      if next_c:match("[\\`%*_{}%[%]%(%)#%+%-%.!|>~]") then
        push_span(out, next_c, flags)
        i = i + 2
      else
        push_span(out, "\\", flags)
        i = i + 1
      end
    elseif c == "`" then
      local run = code_run_length(text, i)
      local needle = string.rep("`", run)
      local pos = i + run
      local close_start = nil
      local close_end = nil
      while true do
        local start, finish = text:find(needle, pos, true)
        if not start then
          break
        end
        local before = start > 1 and text:sub(start - 1, start - 1) or ""
        local after = finish < n and text:sub(finish + 1, finish + 1) or ""
        if before ~= "`" and after ~= "`" then
          close_start = start
          close_end = finish
          break
        end
        pos = finish + 1
      end
      if close_start then
        local inner = text:sub(i + run, close_start - 1):gsub("\n", " ")
        if inner:sub(1, 1) == " " and inner:sub(-1) == " " and inner:match("%S") then
          inner = inner:sub(2, -2)
        end
        local code_flags = new_flags(flags)
        code_flags.code = true
        push_span(out, inner, code_flags)
        i = close_end + 1
      else
        push_span(out, text:sub(i, i + run - 1), flags)
        i = i + run
      end
    elseif c == "!" and text:sub(i + 1, i + 1) == "[" then
      local close = find_matching_bracket(text, i + 1)
      if close and text:sub(close + 1, close + 1) == "(" then
        local paren = find_close_paren(text, close + 1)
        if paren then
          local dest = parse_link_destination(text:sub(close + 2, paren - 1))
          if dest then
            local alt = plain_inline(parse_inline(text:sub(i + 2, close - 1), {}, opts))
            local image_flags = new_flags(flags)
            image_flags.image = true
            image_flags.muted = true
            image_flags.target = dest
            push_span(out, "🖼 " .. (alt ~= "" and alt or "image"), image_flags)
            i = paren + 1
          else
            push_span(out, "!", flags)
            i = i + 1
          end
        else
          push_span(out, "!", flags)
          i = i + 1
        end
      else
        push_span(out, "!", flags)
        i = i + 1
      end
    elseif c == "[" then
      local close = find_matching_bracket(text, i)
      if close and text:sub(close + 1, close + 1) == "(" then
        local paren = find_close_paren(text, close + 1)
        if paren then
          local dest = parse_link_destination(text:sub(close + 2, paren - 1))
          if dest then
            local label = text:sub(i + 1, close - 1)
            local label_spans = parse_inline(label, {}, opts)
            for _, span in ipairs(label_spans) do
              span.link = true
              span.target = dest
              span.autolink = false
              out[#out + 1] = span
            end
            i = paren + 1
          else
            push_span(out, "[", flags)
            i = i + 1
          end
        else
          push_span(out, "[", flags)
          i = i + 1
        end
      else
        push_span(out, "[", flags)
        i = i + 1
      end
    elseif c == "<" then
      if text:sub(i, i + 3) == "<!--" then
        local close = text:find("-->", i + 4, true)
        i = close and close + 3 or n + 1
      else
        local close, name = is_html_tag(text, i)
        if close then
          if name == "br" then
            push_span(out, " ", flags)
          end
          i = close + 1
        else
          local bracket = text:find(">", i + 1, true)
          local inner = bracket and text:sub(i + 1, bracket - 1) or ""
          local autolink = nil
          if inner:match("^[%w+.-]+://[^%s]+$") then
            autolink = inner
          elseif inner:match("^mailto:[^%s]+$") then
            autolink = inner
          elseif inner:find("@", 1, true) and not inner:find("[%s]", 1) then
            autolink = "mailto:" .. inner
          end
          if bracket and autolink then
            local link_flags = new_flags(flags)
            link_flags.link = true
            link_flags.target = autolink
            link_flags.autolink = true
            push_span(out, inner, link_flags)
            i = bracket + 1
          else
            push_span(out, "<", flags)
            i = i + 1
          end
        end
      end
    elseif c == "~" then
      if text:sub(i + 1, i + 1) == "~" then
        local close = find_emphasis_close(text, i + 2, "~", 2)
        if close then
          local strike_flags = new_flags(flags)
          strike_flags.strike = true
          parse_inline_into(text:sub(i + 2, close - 1), strike_flags, out, opts)
          i = close + 2
        else
          push_span(out, "~~", flags)
          i = i + 2
        end
      else
        push_span(out, "~", flags)
        i = i + 1
      end
    elseif c == "!" then
      push_span(out, "!", flags)
      i = i + 1
    elseif c == "*" or c == "_" then
      local run = 1
      while text:sub(i + run, i + run) == c do
        run = run + 1
      end
      local want = math.min(run, 3)
      if can_open_emphasis(text, i, c, want) then
        local close = find_emphasis_close(text, i + want, c, want)
        if close then
          local inner_flags = new_flags(flags)
          if want >= 3 then
            inner_flags.bold = true
            inner_flags.italic = true
          elseif want == 2 then
            inner_flags.bold = true
          else
            inner_flags.italic = true
          end
          parse_inline_into(text:sub(i + want, close - 1), inner_flags, out, opts)
          i = close + want
        else
          push_span(out, text:sub(i, i + want - 1), flags)
          i = i + want
        end
      else
        push_span(out, text:sub(i, i + want - 1), flags)
        i = i + want
      end
    elseif c == "\n" then
      local last = out[#out]
      local hard = false
      if last then
        if last.text:sub(-2) == "  " then
          last.text = last.text:sub(1, -3)
          hard = true
        elseif last.text:sub(-1) == "\\" then
          last.text = last.text:sub(1, -2)
          hard = true
        end
        if last.text == "" then
          table.remove(out)
        end
      end
      push_span(out, hard and "\n" or " ", flags)
      i = i + 1
    else
      local stop = text:find("[\\`%[<!~*_\n]", i)
      if not stop then
        stop = n + 1
      end
      if stop <= i then
        stop = i + 1
      end
      push_span(out, text:sub(i, stop - 1), flags)
      i = stop
    end
  end
end

parse_inline = function(text, flags, opts)
  local out = {}
  parse_inline_into(text, flags or new_flags(), out, opts)
  return out
end

-- ===========================================================================
-- Block parser
-- ===========================================================================

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
  local text = trim(line)
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
      cells[#cells + 1] = trim(table.concat(buffer))
      buffer = {}
      i = i + 1
    else
      buffer[#buffer + 1] = c
      i = i + 1
    end
  end
  cells[#cells + 1] = trim(table.concat(buffer))
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
  local _, rest = expand_indent(lines[i])
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

local function parse_blocks(lines, opts)
  local blocks = {}
  local i = 1
  local n = #lines
  while i <= n do
    local line = lines[i]
    if is_blank(line) then
      i = i + 1
    else
      local indent, rest = expand_indent(line)
      local fence_char, fence_len, fence_rest = fence_info(rest)
      if fence_char and indent <= 3 then
        local lang = (fence_rest or ""):match("^ *([^%s]+)") or ""
        local code = {}
        i = i + 1
        while i <= n do
          local candidate = lines[i]
          local cindent, crest = expand_indent(candidate)
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
        blocks[#blocks + 1] = { kind = "code", lang = lang, lines = code }
      elseif indent <= 3 and atx_level(rest) then
        local level = atx_level(rest)
        local _, title = rest:match("^(#+)[ \t]+(.*)$")
        title = title:gsub("[ \t]+#+[ \t]*$", "")
        blocks[#blocks + 1] = { kind = "heading", level = level, text = title }
        i = i + 1
      elseif indent <= 3 and rest:sub(1, 1) == ">" then
        local quoted = {}
        while i <= n do
          local candidate = lines[i]
          local _, crest = expand_indent(candidate)
          if crest:sub(1, 1) == ">" then
            local content = crest:sub(2)
            content = content:gsub("^ ", "")
            quoted[#quoted + 1] = content
            i = i + 1
          else
            break
          end
        end
        blocks[#blocks + 1] = { kind = "quote", blocks = parse_blocks(quoted, opts) }
      elseif indent <= 3 and list_marker(rest) then
        local base_indent = indent
        local items = {}
        local current = nil
        while i <= n do
          local candidate = lines[i]
          if is_blank(candidate) then
            local j = i + 1
            while j <= n and is_blank(lines[j]) do
              j = j + 1
            end
            local next_indent, next_rest = j <= n and expand_indent(lines[j]) or 0, ""
            if j <= n then
              next_indent, next_rest = expand_indent(lines[j])
            end
            local next_marker = j <= n and list_marker(next_rest) or nil
            if next_marker and next_indent >= base_indent then
              i = j
            else
              break
            end
          else
            local cindent, crest = expand_indent(candidate)
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
        blocks[#blocks + 1] = { kind = "list", items = items }
      elseif indent <= 3 and is_thematic(rest) then
        blocks[#blocks + 1] = { kind = "rule" }
        i = i + 1
      elseif indent <= 3 and is_table_start(lines, i) then
        local header = split_table_row(rest)
        local aligns = is_table_start(lines, i)
        i = i + 2
        local rows = {}
        while i <= n and not is_blank(lines[i]) and lines[i]:find("|", 1, true) do
          rows[#rows + 1] = split_table_row(lines[i])
          i = i + 1
        end
        blocks[#blocks + 1] = {
          kind = "table",
          header = header,
          aligns = aligns,
          rows = rows,
        }
      elseif indent <= 3 and is_html_block_start(rest) then
        local html = {}
        while i <= n and not is_blank(lines[i]) do
          local _, hrest = expand_indent(lines[i])
          html[#html + 1] = hrest
          i = i + 1
        end
        blocks[#blocks + 1] = { kind = "html", lines = html }
      elseif indent >= 4 then
        local code = {}
        while i <= n do
          local candidate = lines[i]
          if is_blank(candidate) then
            code[#code + 1] = ""
            i = i + 1
          else
            local cindent = expand_indent(candidate)
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
        blocks[#blocks + 1] = { kind = "code", lang = "", lines = code }
      else
        local paragraph = { rest }
        i = i + 1
        while i <= n do
          local candidate = lines[i]
          if is_blank(candidate) then
            break
          end
          if #paragraph == 1 and is_setext_underline(candidate) then
            break
          end
          if is_block_start(lines, i) then
            break
          end
          local _, crest = expand_indent(candidate)
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
          }
          i = i + 1
        else
          blocks[#blocks + 1] = {
            kind = "paragraph",
            text = table.concat(paragraph, "\n"),
          }
        end
      end
    end
  end
  return blocks
end

-- ===========================================================================
-- Panel rendering
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
          target = utf8_prefix(target, MAX_TARGET_BYTES - 1) .. "…"
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
      part = utf8_prefix(part, #part)
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

local function render_inline_lines(spans, style, indent, renderer, opts)
  local segments = split_spans_at_newlines(spans)
  for _, segment in ipairs(segments) do
    local chunks = split_long_segment(segment, MAX_LINE_BYTES)
    if #chunks == 0 then
      chunks = { {} }
    end
    for _, chunk in ipairs(chunks) do
      local line = make_line(chunk, style, indent, opts)
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
  local lines = split_lines(code)
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
        push_line(renderer, { text = utf8_prefix(line_text, MAX_LINE_BYTES - 1) .. "…", style = "code" })
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
        text = utf8_prefix(text, MAX_LINE_BYTES - 1) .. "…"
      end
      push_line(renderer, { text = text, style = "code" })
      if renderer.overflow then
        return
      end
    end
  end
end

local function pad(text, width, align)
  local used = display_width(text)
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
  local spans = parse_inline(cell, {}, opts)
  local plain = plain_inline(spans)
  if display_width(plain) > width then
    plain = truncate_display(plain, width)
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
    local width = math.max(3, display_width(block.header[column] or ""))
    for _, row in ipairs(rows) do
      local cell_width = display_width(row[column] or "")
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
      text = utf8_prefix(text, MAX_LINE_BYTES - 1) .. "…"
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

local function render_blocks(blocks, renderer, opts, quote_depth)
  quote_depth = quote_depth or 0
  for _, block in ipairs(blocks) do
    if block.kind == "heading" then
      local spans = parse_inline(block.text, {}, opts)
      if quote_depth > 0 then
        for _, span in ipairs(spans) do
          span.bold = true
        end
        render_inline_lines(spans, "quote", quote_depth, renderer, opts)
      else
        render_inline_lines(spans, "h" .. block.level, 0, renderer, opts)
      end
    elseif block.kind == "paragraph" then
      local spans = parse_inline(block.text, {}, opts)
      if quote_depth > 0 then
        render_inline_lines(spans, "quote", quote_depth, renderer, opts)
      else
        render_inline_lines(spans, "text", 0, renderer, opts)
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
        local content = parse_inline(item.text, {}, opts)
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
    if renderer.overflow then
      return
    end
  end
end

-- ===========================================================================
-- Document entry points
-- ===========================================================================

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

local function document_title(doc)
  local path = doc.path
  if type(path) == "string" and path ~= "" then
    local name = path:match("([^/\\]+)$") or path
    return name .. " — Preview"
  end
  return "Markdown Preview"
end

local function render_document(doc, opts)
  local text = normalize_text(type(doc.text) == "string" and doc.text or "")
  local truncated = false
  if #text > MAX_SOURCE_BYTES then
    text = utf8_prefix(text, MAX_SOURCE_BYTES)
    truncated = true
  end
  local lines = split_lines(text)
  local frontmatter, start = split_frontmatter(lines, opts.show_frontmatter)
  local body = {}
  for i = start, #lines do
    body[#body + 1] = lines[i]
  end
  local blocks = parse_blocks(body, opts)
  local renderer = {
    lines = {},
    count = 0,
    overflow = false,
    highlight_budget = MAX_HIGHLIGHT_TOTAL,
  }
  if frontmatter then
    push_line(renderer, { text = "Front matter", style = "muted" })
    render_code(renderer, table.concat(frontmatter, "\n"), "yaml", opts)
  end
  render_blocks(blocks, renderer, opts, 0)
  if truncated then
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
  return {
    title = document_title(doc),
    lines = renderer.lines,
  }
end

local function setting_bool(key, default)
  local value = luban.settings.get(key)
  if type(value) == "boolean" then
    return value
  end
  return default
end

local function syntax_highlight()
  if type(luban) == "table" and type(luban.syntax) == "table" and type(luban.syntax.highlight) == "function" then
    return luban.syntax.highlight
  end
  return nil
end

function M.open_preview(ctx)
  if type(luban) == "table" and type(luban.panel) == "table" and type(luban.panel.open) == "function" then
    local ok, err = luban.panel.open("markdown.preview.panel")
    if not ok then
      luban.notify(err or "cannot open the Markdown preview")
    end
  else
    luban.notify("Markdown Preview: open the panel from the Plugins menu")
  end
end

function M.render_preview(ctx)
  if type(luban) ~= "table" then
    return { title = "Markdown Preview", lines = { { text = "Plugin host is unavailable." } } }
  end
  local doc = luban.get_document()
  if not doc then
    return {
      title = "Markdown Preview",
      lines = { { text = "Preview is not available for this document.", style = "muted" } },
    }
  end
  local opts = {
    show_link_targets = setting_bool("show_link_targets", true),
    show_frontmatter = setting_bool("show_frontmatter", false),
    highlight = syntax_highlight(),
  }
  local ok, result = pcall(render_document, doc, opts)
  if not ok then
    if type(luban.log) == "function" then
      luban.log("error", "markdown preview failed: " .. tostring(result))
    end
    return {
      title = "Markdown Preview",
      lines = { { text = "Preview failed: " .. tostring(result), style = "muted" } },
    }
  end
  return result
end

function M.activate(ctx)
  if type(luban.log) == "function" then
    luban.log("info", "Markdown Preview activated")
  end
end

M._internals = {
  parse_blocks = parse_blocks,
  parse_inline = parse_inline,
  display_width = display_width,
  normalize_text = normalize_text,
  split_lines = split_lines,
}

return M
