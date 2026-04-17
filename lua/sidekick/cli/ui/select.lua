local Config = require("sidekick.config")
local Util = require("sidekick.util")

---@class sidekick.cli.Select: sidekick.cli.With
---@field cb fun(state?:sidekick.cli.State)
---@field auto? boolean Automatically select if only one tool matches the filter

local M = {}

---Shorten a path from the left, keeping the most meaningful (rightmost) segments.
---@param path string
---@param max_width number
---@return string
local function shorten_path(path, max_width)
  local sw = vim.api.nvim_strwidth
  if max_width <= 0 or sw(path) <= max_width then
    return path
  end
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

---@param index string|number?
---@param label string?
---@return string?
local function tmux_part(index, label)
  if index == nil then
    return
  end
  index = tostring(index)
  if label and label ~= "" then
    return ("%s(%s)"):format(index, label)
  end
  return index
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
  elseif #tools == 1 and opts.auto then
    on_select(tools[1])
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

---@param state sidekick.cli.State|snacks.picker.Item
---@param picker? snacks.Picker
function M.format(state, picker)
  local sw = vim.api.nvim_strwidth
  local ret = {} ---@type snacks.picker.Highlight[]

  local status = state.attached and "attached"
    or state.started and "started"
    or state.installed and "installed"
    or "missing"

  local status_hl = "SidekickCli" .. status:gsub("^%l", string.upper)

  if picker then
    local count = picker:count()
    local idx = tostring(state.idx)
    idx = (" "):rep(#tostring(count) - #idx) .. idx
    ret[#ret + 1] = { idx .. ".", "SnacksPickerIdx" }
    ret[#ret + 1] = { " " }
  end
  ret[#ret + 1] = { Config.ui.icons[status], status_hl }
  ret[#ret + 1] = { " " }
  ret[#ret + 1] = { state.tool.name }
  local len = sw(state.tool.name) + 2
  if state.session then
    ret[#ret + 1] = { string.rep(" ", 12 - len) }

    if state.external then
      ret[#ret + 1] = { Config.ui.icons["external_" .. status], status_hl }
    else
      ret[#ret + 1] = { Config.ui.icons["terminal_" .. status], status_hl }
    end
    len = len + 2

    -- Keep this for debugging purposes
    -- ret[#ret + 1] = { table.concat(state.session.pids or {}, ",") }

    -- Determine available line width
    local win_width
    if picker and picker.list and picker.list.win and picker.list.win.win then
      local ok, w = pcall(vim.api.nvim_win_get_width, picker.list.win.win)
      if ok and w > 0 then win_width = w end
    end
    -- For non-snacks pickers (fzf-lua, telescope), format_item is called
    -- before the picker window exists. Use a conservative estimate so the
    -- full line fits without horizontal scrolling (which hides tool names).
    if not win_width then
      win_width = math.floor(vim.o.columns * 0.5)
    end

    local backends = {} ---@type string[]
    backends[#backends + 1] = state.session.mux_backend or state.session.backend
    if state.external then
      backends[#backends + 1] = state.session.mux_session
      if state.session.tmux_window_index and state.session.tmux_pane_index then
        local window_part = tmux_part(state.session.tmux_window_index, state.session.tmux_window_name)
        local pane_part = tmux_part(state.session.tmux_pane_index, state.session.tmux_pane_label)
        backends[#backends + 1] = window_part .. "." .. pane_part
      end
    end
    local backend = ("[%s]"):format(table.concat(backends, ":"))

    -- Shorten session name if backend is too long for available width
    if state.external and backends[2] then
      local fixed = math.max(sw(state.tool.name) + 2, 12) + 2
      if picker then fixed = fixed + sw(tostring(state.idx)) + 2 end
      local min_path = 20
      if fixed + sw(backend) + min_path > win_width then
        local overhead = sw(backend) - sw(backends[2])
        local max_session = math.max(win_width - fixed - min_path - overhead, 5)
        backends[2] = shorten_path(backends[2], max_session)
        backend = ("[%s]"):format(table.concat(backends, ":"))
      end
    end

    ret[#ret + 1] = { backend, "Special" }
    len = 12 + sw(backend)
    ret[#ret + 1] = { string.rep(" ", math.max(40 - len, 1)) }
    for _, badge in ipairs(state.affinity and state.affinity.badges or {}) do
      ret[#ret + 1] = { "[" .. badge.text .. "]", badge.hl }
      ret[#ret + 1] = { " " }
    end

    -- Compute actual prefix width from accumulated parts
    local actual_prefix = 0
    for _, part in ipairs(ret) do
      actual_prefix = actual_prefix + sw(part[1])
    end

    local cwd = vim.fn.fnamemodify(state.session.cwd, ":p:~")
    local max_path = math.max(win_width - actual_prefix - 2, 10)
    if picker then
      local item = setmetatable({}, state) --[[@as snacks.picker.Item]]
      item.file = shorten_path(cwd, max_path)
      item.dir = true
      vim.list_extend(ret, require("snacks").picker.format.filename(item, picker))
    else
      ret[#ret + 1] = { shorten_path(cwd, max_path), "Directory" }
    end
  end
  return ret
end

return M
