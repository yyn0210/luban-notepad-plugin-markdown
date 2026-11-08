-- Text utilities shared by the Markdown preview modules.
--
-- Everything here is pure string/width math with no host dependency, so the
-- parser, the inline parser and the renderer can all require this module
-- without cycles.

local M = {}

function M.normalize_text(text)
  text = text:gsub("\r\n", "\n"):gsub("\r", "\n"):gsub("\t", "    ")
  if text:sub(1, 3) == "\239\187\191" then
    text = text:sub(4)
  end
  return text
end

function M.split_lines(text)
  local lines = {}
  if text == "" then
    return { "" }
  end
  for line in (text .. "\n"):gmatch("(.-)\n") do
    lines[#lines + 1] = line
  end
  return lines
end

function M.is_blank(line)
  return line:match("^%s*$") ~= nil
end

function M.trim(text)
  return (text:gsub("^%s+", ""):gsub("%s+$", ""))
end

function M.ltrim(text)
  return (text:gsub("^%s+", ""))
end

function M.utf8_prefix(text, max_bytes)
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
function M.codepoint_width(cp)
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

function M.display_width(text)
  local ok, width = pcall(function()
    local total = 0
    for _, cp in utf8.codes(text) do
      total = total + M.codepoint_width(cp)
    end
    return total
  end)
  if ok then
    return width
  end
  return #text
end

function M.truncate_display(text, width)
  if M.display_width(text) <= width then
    return text
  end
  local out = {}
  local used = 0
  local ok = pcall(function()
    for _, cp in utf8.codes(text) do
      local cw = M.codepoint_width(cp)
      if used + cw > width - 1 then
        break
      end
      out[#out + 1] = utf8.char(cp)
      used = used + cw
    end
  end)
  if not ok then
    return M.utf8_prefix(text, width - 1) .. "…"
  end
  return table.concat(out) .. "…"
end

function M.expand_indent(line)
  local spaces = line:match("^ *") or ""
  return #spaces, line:sub(#spaces + 1)
end

return M
