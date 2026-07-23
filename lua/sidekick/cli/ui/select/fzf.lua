local Select = require("sidekick.cli.ui.select")
local Util = require("sidekick.util")

--- fzf-lua front-end for the agent picker.
---
--- Invoked directly rather than through `vim.ui.select`, which cannot express
--- field-scoped search or extra key bindings, and which breaks whenever the
--- ui_select provider changes underneath us.
local M = {}

--- Columns are joined with a non-breaking space: fzf splits fields on it, terminals
--- render it as a plain space. A regular space would make every padding run a field.
local NBSP = "\194\160"

local WINDOW_WIDTH = 0.9

function M.available()
  return (pcall(require, "fzf-lua"))
end

---Wrap `{text, hl}` parts in the ANSI escapes for their highlight groups, so the
---picker tracks the colorscheme instead of hardcoding colors.
---@param utils table fzf-lua.utils
local function painter(utils)
  local cache = {} ---@type table<string, fun(s:string):string|false>
  ---@param parts snacks.picker.Highlight[]
  return function(parts)
    local ret = {}
    for _, part in ipairs(parts) do
      local text, hl = part[1], part[2]
      if hl and text ~= "" then
        if cache[hl] == nil then
          local _, _, escfn = utils.ansi_from_hl(hl, "")
          cache[hl] = escfn or false
        end
        text = cache[hl] and cache[hl](text) or text
      end
      ret[#ret + 1] = text
    end
    return table.concat(ret)
  end
end

---@param state sidekick.cli.State
local function jump(state)
  local session = state.session
  -- an attached mux session is wrapped in a terminal session; the pane lives on the parent
  if session and not session.tmux_pane_id then
    session = session.parent
  end
  if not session or (session.mux_backend or session.backend) ~= "tmux" then
    return Util.warn("No tmux pane to jump to")
  end
  require("sidekick.cli.session.tmux").focus(session)
end

---@param tools sidekick.cli.State[]
---@param on_select fun(state?:sidekick.cli.State)
function M.select(tools, on_select)
  local fzf = require("fzf-lua")
  local paint = painter(require("fzf-lua.utils"))

  local width = math.max(math.floor(vim.o.columns * WINDOW_WIDTH) - 6, 40)
  local entries = {} ---@type string[]
  local nth = {} ---@type integer[]

  for i, tool in ipairs(tools) do
    local cols = Select.columns(tool, { width = width })
    if i == 1 then
      -- `--with-nth` hides the leading index field, so column N is field N of the
      -- string fzf matches against. Columns are identical across rows.
      for c, col in ipairs(cols) do
        if col.search then
          nth[#nth + 1] = c
        end
      end
    end
    local fields = { tostring(i) }
    for _, col in ipairs(cols) do
      fields[#fields + 1] = paint(col.parts)
    end
    entries[#entries + 1] = table.concat(fields, NBSP)
  end

  ---@param selected string[]
  local function items(selected)
    local ret = {} ---@type sidekick.cli.State[]
    for _, line in ipairs(selected or {}) do
      local idx = tonumber(line:match("^(%d+)"))
      if idx and tools[idx] then
        ret[#ret + 1] = tools[idx]
      end
    end
    return ret
  end

  ---Run `fn` with the first picked state. Pane focus remains a single-target action.
  ---@param fn fun(state:sidekick.cli.State)
  local function with(fn)
    return function(selected)
      local state = items(selected)[1]
      if state then
        fn(state)
      end
    end
  end

  ---Run `fn` once for every picked state.
  ---@param fn fun(state:sidekick.cli.State)
  local function with_each(fn)
    return function(selected)
      for _, state in ipairs(items(selected)) do
        fn(state)
      end
    end
  end

  fzf.fzf_exec(entries, {
    prompt = "Agent> ",
    header = table.concat({
      ":: <tab> select",
      "<enter> attach",
      "<ctrl-o> jump to pane",
      "<ctrl-x> detach",
    }, " | "),
    winopts = { width = WINDOW_WIDTH, height = 0.6 },
    fzf_opts = {
      ["--ansi"] = true,
      ["--multi"] = true,
      ["--delimiter"] = NBSP,
      ["--with-nth"] = "2..",
      ["--nth"] = table.concat(nth, ","),
      -- keep the list in the order State.get() ranked it when the query is empty
      ["--tiebreak"] = "index",
    },
    actions = {
      ["enter"] = with_each(on_select),
      ["ctrl-o"] = with(jump),
      ["ctrl-x"] = with_each(function(state)
        require("sidekick.cli.state").detach(state)
      end),
    },
  })
end

return M
