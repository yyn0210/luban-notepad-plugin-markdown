-- Feature-safe wrapper around luban.syntax.highlight (plugin API v2).
--
-- The v2 host raises on highlight failures (including the 64 KiB per-call
-- cap); the preview degrades to plain code rendering instead of failing, so
-- every call here is caught and nil is returned when no highlighter exists or
-- the host rejects the call.

local M = {}

local function host_highlighter()
  if type(luban) == "table"
    and type(luban.syntax) == "table"
    and type(luban.syntax.highlight) == "function"
  then
    return luban.syntax.highlight
  end
  return nil
end

function M.available()
  return host_highlighter() ~= nil
end

-- M.highlight(text, lang) -> spans|nil
--
-- spans is the host's { { text, role }, ... } list on success, nil otherwise.
function M.highlight(text, lang)
  local fn = host_highlighter()
  if not fn then
    return nil
  end
  local ok, spans = pcall(fn, text, lang)
  if ok and type(spans) == "table" then
    return spans
  end
  return nil
end

return M
