local Affinity = require("sidekick.cli.affinity")
local Config = require("sidekick.config")
local Session = require("sidekick.cli.session")
local Util = require("sidekick.util")

---@class sidekick.cli.Select: sidekick.cli.With
---@field cb fun(state?:sidekick.cli.State)
---@field auto? boolean Automatically select a single match or unique same-pane affinity match

--- One semantic cell of a picker row.
---@class sidekick.cli.select.Column
---@field id "glyphs"|"tool"|"label"|"loc"|"badges"|"path"
---@field parts snacks.picker.Highlight[]
---@field search? boolean whether a fuzzy query should be matched against this column

local M = {}

local TOOL_WIDTH = 9
local LABEL_WIDTH = 22
local SESSION_WIDTH = 14
local WINDOW_WIDTH = 9
local LOC_WIDTH = 2 + SESSION_WIDTH + 3 + WINDOW_WIDTH
local BADGE_WIDTH = 24
local MIN_PATH_WIDTH = 12

local function sw(s)
  return vim.api.nvim_strwidth(s)
end

---Shorten a path from the left, keeping the most meaningful (rightmost) segments.
---@param path string
---@param max_width number
---@return string
local function shorten_path(path, max_width)
  if max_width <= 0 or sw(path) <= max_width then
    return path
  end
  local trimmed = path:gsub("/+$", "")
  path = trimmed ~= "" and trimmed or path
  local parts = vim.split(path, "/", { plain = true })
  while #parts > 1 do
    table.remove(parts, 1)
    local shortened = "…/" .. table.concat(parts, "/")
    if sw(shortened) <= max_width then
      return shortened
    end
  end
  return "…" .. path:sub(-(max_width - 1))
end

---@param text string
---@param width integer
local function truncate(text, width)
  if width <= 0 then
    return ""
  end
  if sw(text) <= width then
    return text
  end
  while sw(text) > width - 1 do
    text = vim.fn.strcharpart(text, 0, vim.fn.strchars(text) - 1)
  end
  return text .. "…"
end

---@param text string
---@param width integer
local function pad(text, width)
  return text .. (" "):rep(math.max(width - sw(text), 0))
end

---@param parts snacks.picker.Highlight[]
---@param width integer
local function pad_parts(parts, width)
  local total = 0
  for _, part in ipairs(parts) do
    total = total + sw(part[1])
  end
  if total < width then
    parts[#parts + 1] = { (" "):rep(width - total) }
  end
  return parts
end

---Per-tool color, e.g. `SidekickToolClaude`. Tools without one share a neutral group.
---@param name string
local function tool_hl(name)
  local hl = "SidekickTool" .. name:sub(1, 1):upper() .. name:sub(2)
  return vim.fn.hlexists(hl) == 1 and hl or "SidekickPickerTool"
end

---The primary handle for a row. Pane labels can be unset or duplicated, so fall back
---to the window name and finally to the `window.pane` indexes. Never returns nil.
---@param session sidekick.cli.Session
local function pane_label(session)
  if (session.mux_backend or session.backend) == "herdr" then
    return session.herdr_agent_name or session.herdr_pane_label or session.herdr_pane_id or ""
  end
  local label = session.tmux_pane_label
  if label and label ~= "" then
    return label
  end
  local window = session.tmux_window_name
  if window and window ~= "" then
    return window
  end
  if session.tmux_window_index and session.tmux_pane_index then
    return ("%s.%s"):format(session.tmux_window_index, session.tmux_pane_index)
  end
  return ""
end

---`session › window`, with the tokens matching the current pane's scope in green.
---@param state sidekick.cli.State
---@return snacks.picker.Highlight[]
local function location(state)
  local session = state.session
  local affinity = state.affinity or {}
  local function hl(current)
    return current and "SidekickPickerCurrent" or "SidekickPickerLoc"
  end

  local ret = { { affinity.same_tmux_window and "● " or "  ", "SidekickPickerCurrent" } }

  local herdr = (session.mux_backend or session.backend) == "herdr"
  local mux = herdr and session.herdr_workspace_label or session.mux_session
  if not mux or mux == "" then
    ret[#ret + 1] = { session.mux_backend or session.backend or "", "SidekickPickerLoc" }
    return ret
  end

  ret[#ret + 1] = { truncate(mux, SESSION_WIDTH), hl(affinity.same_tmux_session) }
  local window = herdr and session.herdr_tab_label or session.tmux_window_name
  if not window or window == "" then
    window = session.tmux_window_index and tostring(session.tmux_window_index) or nil
  end
  if window and window ~= "" then
    ret[#ret + 1] = { " › ", "SidekickPickerLoc" }
    ret[#ret + 1] = { truncate(window, WINDOW_WIDTH), hl(affinity.same_tmux_window) }
  end
  return ret
end

---@param state sidekick.cli.State
---@return snacks.picker.Highlight[]
local function badges(state)
  local ret = {} ---@type snacks.picker.Highlight[]
  local agent_status = state.session and state.session.agent_status or nil
  if agent_status then
    local name = agent_status:sub(1, 1):upper() .. agent_status:sub(2)
    ret[#ret + 1] = { "[" .. agent_status .. "]", "SidekickCliAgent" .. name }
    ret[#ret + 1] = { " " }
  end
  if Affinity.is_scratch(state.session) then
    ret[#ret + 1] = { Config.ui.icons.popup, "SidekickPickerPopup" }
  end
  for _, badge in ipairs(state.affinity and state.affinity.badges or {}) do
    -- `win`/`pane` affinity is already carried by the green tokens in the location column
    if badge.text == "cwd" or badge.text == "root" then
      ret[#ret + 1] = { "[" .. badge.text .. "]", badge.hl }
      ret[#ret + 1] = { " " }
    end
  end
  return ret
end

---@param picker? snacks.Picker
local function line_width(picker)
  if picker and picker.list and picker.list.win and picker.list.win.win then
    local ok, w = pcall(vim.api.nvim_win_get_width, picker.list.win.win)
    if ok and w > 0 then
      return w
    end
  end
  -- `format_item` runs before non-snacks picker windows exist. Estimate conservatively
  -- so the row fits without horizontal scrolling, which would hide the tool names.
  return math.floor(vim.o.columns * 0.5)
end

---The semantic cells of one row, shared by every picker front-end.
---Column count, order and identity are stable across rows so the fzf front-end can
---address them by field number with `--nth`.
---@param state sidekick.cli.State
---@param opts? {width?:integer}
---@return sidekick.cli.select.Column[]
function M.columns(state, opts)
  local width = (opts or {}).width or line_width()
  local session = state.session

  local status = state.attached and "attached"
    or state.started and "started"
    or state.installed and "installed"
    or "missing"
  local status_hl = "SidekickCli" .. status:gsub("^%l", string.upper)

  local glyphs = { { Config.ui.icons[status], status_hl } }
  glyphs[#glyphs + 1] = session
      and { Config.ui.icons[(state.external and "external_" or "terminal_") .. status] or "  ", status_hl }
    or { "  " }

  local cols = { { id = "glyphs", parts = glyphs } } ---@type sidekick.cli.select.Column[]

  cols[#cols + 1] = {
    id = "tool",
    search = true,
    parts = { { pad(truncate(state.tool.name, TOOL_WIDTH), TOOL_WIDTH), tool_hl(state.tool.name) } },
  }

  local label = session and pane_label(session) or ""
  cols[#cols + 1] = {
    id = "label",
    search = true,
    parts = { { pad(truncate(label, LABEL_WIDTH), LABEL_WIDTH), "SidekickPickerLabel" } },
  }

  local loc = session and location(state) or { { "  " }, { "start new agent", "SidekickPickerHint" } }
  cols[#cols + 1] = { id = "loc", search = true, parts = pad_parts(loc, LOC_WIDTH) }

  cols[#cols + 1] = { id = "badges", parts = pad_parts(badges(state), BADGE_WIDTH) }

  -- `path` is still to come, so the row ends up with `#cols + 1` columns and `#cols` gaps
  local used = #cols
  for _, col in ipairs(cols) do
    for _, part in ipairs(col.parts) do
      used = used + sw(part[1])
    end
  end

  -- deliberately not searchable: a query like `claude mink` must land on the agent
  -- whose pane is labelled `mink`, not on every agent that happens to live under a
  -- directory named `mink`. The path is here to be read, not matched.
  local cwd = vim.fn.fnamemodify(session and session.cwd or Session.cwd(), ":p:~")
  cols[#cols + 1] = {
    id = "path",
    parts = { { shorten_path(cwd, math.max(width - used, MIN_PATH_WIDTH)), "SidekickPickerPath" } },
  }
  return cols
end

---@param opts sidekick.cli.Select
function M.select(opts)
  assert(type(opts) == "table", "opts must be a table")
  local State = require("sidekick.cli.state")
  local tools = opts.scope and State.scoped(opts.filter, opts.scope) or State.get(opts.filter)
  if opts.scope and #tools == 0 then
    tools = State.get(opts.filter)
  end

  ---@param state? sidekick.cli.State
  local on_select = function(state)
    if state and not state.installed then
      M.on_missing(state.tool)
      state = nil
    end
    opts.cb(state)
  end

  if #tools == 0 then
    Util.warn("No tools match the given filter")
    return
  elseif opts.auto then
    local same_pane = vim.tbl_filter(function(tool)
      return tool.affinity and tool.affinity.same_tmux_pane
    end, tools)
    if #same_pane == 1 then
      on_select(same_pane[1])
      return
    end
    if #tools == 1 then
      on_select(tools[1])
      return
    end
  end

  local Fzf = require("sidekick.cli.ui.select.fzf")
  if Fzf.available() then
    Fzf.select(tools, on_select)
    return
  end

  ---@type snacks.picker.ui_select.Opts
  local select_opts = {
    prompt = "Select CLI tool:",
    kind = "sidekick_cli",
    ---@param tool sidekick.cli.State
    format_item = function(tool)
      local parts = M.format(tool)
      return table.concat(vim.tbl_map(function(p)
        return p[1]
      end, parts))
    end,
    snacks = { format = M.format },
  }

  vim.ui.select(tools, select_opts, on_select)
end

---@param tool sidekick.cli.Tool
function M.on_missing(tool)
  Util.error(("Tool `%s` is not installed"):format(tool.name))
  if tool.url then
    local ok, err = vim.ui.open(tool.url)
    if ok then
      Util.info(("Opening %s in your browser..."):format(tool.url))
    else
      Util.error(("Failed to open %s: %s"):format(tool.url, err))
    end
  end
end

---Flatten a row into `{text, hl}` parts, for `vim.ui.select` and the snacks picker.
---@param state sidekick.cli.State|snacks.picker.Item
---@param picker? snacks.Picker
function M.format(state, picker)
  local ret = {} ---@type snacks.picker.Highlight[]

  if picker then
    local count = picker:count()
    local idx = tostring(state.idx)
    idx = (" "):rep(#tostring(count) - #idx) .. idx
    ret[#ret + 1] = { idx .. ".", "SnacksPickerIdx" }
    ret[#ret + 1] = { " " }
  end

  for i, col in ipairs(M.columns(state, { width = line_width(picker) })) do
    if i > 1 then
      ret[#ret + 1] = { " " }
    end
    if col.id == "path" and picker then
      local item = setmetatable({}, state) --[[@as snacks.picker.Item]]
      item.file = col.parts[1][1]
      item.dir = true
      vim.list_extend(ret, require("snacks").picker.format.filename(item, picker))
    else
      vim.list_extend(ret, col.parts)
    end
  end
  return ret
end

return M
