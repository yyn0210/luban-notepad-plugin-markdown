-- Inline Markdown parsing: emphasis, code spans, links, images, autolinks,
-- strikethrough, hard breaks and inline HTML.
--
-- Split out of the original single-file plugin. Function bodies are the same
-- as in 1.0.1; shared text helpers come from `text.lua`.

local T = require("text")

local M = {}

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
M.new_flags = new_flags

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
M.plain_inline = plain_inline

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
  local text = T.trim(inside)
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

function M.parse_inline_into(text, flags, out, opts)
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
          M.parse_inline_into(text:sub(i + 2, close - 1), strike_flags, out, opts)
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
          M.parse_inline_into(text:sub(i + want, close - 1), inner_flags, out, opts)
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
  M.parse_inline_into(text, flags or new_flags(), out, opts)
  return out
end
M.parse_inline = parse_inline

return M
