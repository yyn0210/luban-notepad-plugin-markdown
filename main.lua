-- Markdown Preview for Luban Notepad (plugin API v2).
--
-- Assembly only: the parse/render machinery lives in the sibling modules
-- (text.lua, inline.lua, parser.lua, renderer.lua, highlight.lua). This file
-- wires the manifest-declared entries, caches the parsed block tree between
-- renders and implements the fold / source-jump interactions.
--
-- The preview reads the active document through luban.document.get() and
-- never touches the file system; no permissions are requested. Requires a
-- host with luban.version == 2.

local I = require("inline")
local P = require("parser")
local R = require("renderer")
local H = require("highlight")
local T = require("text")

local M = {}

local PANEL_ID = "markdown.preview.panel"
local TOGGLE_COMMAND = "markdown.toggle-heading"
local GOTO_COMMAND = "markdown.goto-source"

-- Resident parse cache: on_edit drops the block tree and refreshes the text
-- hash, so the next render reparses only once per edit; renders without an
-- intervening edit (fold toggles, manual refresh) reuse the cached blocks.
local cache = { hash = nil, blocks = nil, show_frontmatter = nil }

-- Fold state as a set of heading sequence numbers, keyed by document path so
-- each document keeps its own folds across edits.
local collapsed = {}

-- ===========================================================================
-- Helpers
-- ===========================================================================

-- FNV-1a 32-bit over the text: cheap, deterministic, stable across runs.
local FNV_OFFSET = 2166136261
local FNV_PRIME = 16777619

local function hash_text(text)
  if type(text) ~= "string" then
    return nil
  end
  local hash = FNV_OFFSET
  for i = 1, #text do
    hash = ((hash ~ string.byte(text, i)) * FNV_PRIME) % 0x100000000
  end
  return hash
end

local function doc_key(doc)
  if doc and type(doc.path) == "string" and doc.path ~= "" then
    return doc.path
  end
  return ""
end

local function setting_bool(key, default)
  local value = luban.settings.get(key)
  if type(value) == "boolean" then
    return value
  end
  return default
end

local function build_opts()
  local show_frontmatter = setting_bool("show_frontmatter", false)
  return {
    show_link_targets = setting_bool("show_link_targets", true),
    show_frontmatter = show_frontmatter,
    highlight = H.highlight,
  }
end

local function ensure_blocks(doc)
  local text = doc and doc.text or ""
  local h = hash_text(text)
  local show_frontmatter = setting_bool("show_frontmatter", false)
  if cache.blocks == nil
    or cache.hash ~= h
    or cache.show_frontmatter ~= show_frontmatter
  then
    cache.blocks = P.parse(text, { show_frontmatter = show_frontmatter })
    cache.hash = h
    cache.show_frontmatter = show_frontmatter
  end
  return cache.blocks
end

local function document_title(doc)
  local path = doc.path
  if type(path) == "string" and path ~= "" then
    local name = path:match("([^/\\]+)$") or path
    return name .. " — Preview"
  end
  return "Markdown Preview"
end

-- Sequence number of the top-level heading at or above the cursor line, or
-- nil when the cursor sits before the first heading.
local function heading_seq_at_cursor(doc, parsed)
  local cursor = doc.line
  if type(cursor) ~= "number" then
    return nil
  end
  local best = nil
  for _, block in ipairs(parsed.blocks) do
    if block.kind == "heading" then
      if (block.line or 0) <= cursor then
        best = block.seq
      else
        break
      end
    end
  end
  return best
end

-- Source line of the nearest block at or above the cursor (falls back to the
-- first block when the cursor sits above everything parsed).
local function nearest_block_line(doc, parsed)
  local cursor = doc.line
  if type(cursor) ~= "number" then
    cursor = 0
  end
  local best = nil
  for _, block in ipairs(parsed.blocks) do
    if block.line and block.line <= cursor then
      best = block.line
    elseif block.line then
      break
    end
  end
  if not best and #parsed.blocks > 0 then
    best = parsed.blocks[1].line
  end
  return best
end

-- ===========================================================================
-- Document entry points
-- ===========================================================================

function M.open_preview(ctx)
  luban.panel.open(PANEL_ID)
end

function M.render_preview(ctx)
  local doc = luban.document.get()
  if not doc then
    return {
      title = "Markdown Preview",
      lines = { { text = "Preview is not available for this document.", style = "muted" } },
    }
  end
  local parsed = ensure_blocks(doc)
  local opts = build_opts()
  opts.collapsed = collapsed[doc_key(doc)]
  local ok, result = pcall(R.render, parsed, opts)
  if not ok then
    luban.log("error", "markdown preview failed: " .. tostring(result))
    return {
      title = document_title(doc),
      lines = { { text = "Preview failed: " .. tostring(result), style = "muted" } },
    }
  end
  result.title = document_title(doc)
  return result
end

-- args = { index = N } toggles the Nth top-level heading (the sequence number
-- carried by the heading's panel line). Without args, the heading at or above
-- the cursor toggles instead. Refresh keeps the panel scroll position.
function M.toggle_heading(ctx, args)
  local doc = luban.document.get()
  local index = nil
  if type(args) == "table" and type(args.index) == "number" then
    index = math.floor(args.index)
  elseif doc then
    index = heading_seq_at_cursor(doc, ensure_blocks(doc))
  end
  if not index or index < 1 then
    return
  end
  local key = doc_key(doc)
  local set = collapsed[key]
  if set and set[index] == true then
    set[index] = nil
  else
    if not set then
      set = {}
      collapsed[key] = set
    end
    set[index] = true
  end
  luban.panel.refresh(PANEL_ID)
end

-- args = { line = N } jumps to source line N (the value carried by paragraph
-- panel lines). Without args, the nearest block at or above the cursor is
-- used instead.
function M.goto_source(ctx, args)
  local doc = luban.document.get()
  if not doc then
    return
  end
  local line = nil
  if type(args) == "table" and type(args.line) == "number" then
    line = math.floor(args.line)
  else
    line = nearest_block_line(doc, ensure_blocks(doc))
  end
  if not line or line < 1 then
    return
  end
  luban.document.set_cursor(line, 1)
end

-- on_edit payload: the document snapshot after the edit, or nil when a tab
-- closed. Cache invalidation only — the host re-renders the panel itself.
function M.on_edit(doc)
  cache.hash = doc and hash_text(doc.text) or nil
  cache.blocks = nil
end

function M.activate(ctx)
  if type(luban) ~= "table" or (luban.version or 0) < 2 then
    error("Markdown Preview requires plugin API v2 (luban.version >= 2); got "
      .. tostring(luban and luban.version or "no luban")
      .. ". Update Luban Notepad to a v2 host.")
  end
  luban.events.on("on_edit", M.on_edit)
  luban.log("info", "Markdown Preview activated")
end

-- Kept for the test harness and introspection; not part of the manifest.
M._internals = {
  hash_text = hash_text,
  ensure_blocks = ensure_blocks,
  parse_inline = I.parse_inline,
  display_width = T.display_width,
  normalize_text = T.normalize_text,
  split_lines = T.split_lines,
}

M._commands = {
  toggle = TOGGLE_COMMAND,
  goto_source = GOTO_COMMAND,
}

return M
