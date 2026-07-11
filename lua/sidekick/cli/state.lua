local Affinity = require("sidekick.cli.affinity")
local Config = require("sidekick.config")
local Session = require("sidekick.cli.session")
local Terminal = require("sidekick.cli.terminal")
local Util = require("sidekick.util")

local M = {}

---@class sidekick.cli.State
---@field tool sidekick.cli.Tool
---@field attached? boolean
---@field affinity? sidekick.cli.Affinity
---@field external? boolean
---@field installed? boolean
---@field session? sidekick.cli.Session
---@field started? boolean
---@field terminal? sidekick.cli.Terminal

---@class sidekick.cli.Filter
---@field attached? boolean
---@field cwd? boolean
---@field external? boolean
---@field installed? boolean
---@field name? string
---@field session? string
---@field started? boolean
---@field terminal? boolean

---@class sidekick.cli.With
---@field filter? sidekick.cli.Filter
---@field show? boolean
---@field focus? boolean
---@field attach? boolean
---@field all? boolean
---@field multicast? boolean
---@field on_resolved? fun(states: sidekick.cli.State[])
---@field scope? "cwd"|"project"|"all"

local function affinity_score(state)
  return state.affinity and state.affinity.score or 0
end

--- Unix timestamp of the last activity in the session's tmux window, 0 when unknown.
local function recency(state)
  return state.session and state.session.tmux_window_activity or 0
end

local function auto_attach_config()
  return Config.cli.mux.auto_attach or {}
end

---@param kind "startup"|"on_demand"
local function auto_attach_enabled(kind)
  return auto_attach_config()[kind] == true
end

---@param opts sidekick.cli.With
local function scope_kind(opts)
  if opts.all then
    return "all"
  end
  return opts.scope or auto_attach_config().scope or "project"
end

---@param states sidekick.cli.State[]
local function decorate(states)
  local scope = Affinity.current_scope()
  for _, state in ipairs(states) do
    local session = state.session and (state.session.parent or state.session) or nil
    state.affinity = session and Affinity.score(scope, session) or nil
  end
end

---@param states sidekick.cli.State[]
---@param kind "cwd"|"project"|"all"
local function in_scope(states, kind)
  return vim.tbl_filter(function(state)
    return Affinity.in_scope(state.affinity, kind)
  end, states)
end

---@param states sidekick.cli.State[]
---@return sidekick.cli.State[]?
local function unique_tmx_parent(states)
  if not Affinity.tmx_parent_pane() then
    return
  end
  local matches = vim.tbl_filter(function(state)
    return state.affinity and state.affinity.same_tmux_pane
  end, states)
  return #matches == 1 and matches or nil
end

---@param state sidekick.cli.State
local function auto_attach_summary(state)
  local session = state.session
  session = session and (session.parent or session) or nil
  local location = session and (session.mux_session or session.backend) or "unknown"
  if session and session.tmux_window_index and session.tmux_pane_index then
    location = ("%s:%s.%s"):format(location, session.tmux_window_index, session.tmux_pane_index)
  end
  local cwd = session and vim.fn.fnamemodify(session.cwd, ":~") or "unknown cwd"
  return ("- **%s** `%s` — %s"):format(state.tool.name, location, cwd)
end

---@param states sidekick.cli.State[]
---@return sidekick.cli.State[]
local function dedupe(states)
  local seen = {} ---@type table<string, boolean>
  local ret = {} ---@type sidekick.cli.State[]
  for _, state in ipairs(states) do
    local id = state.session and state.session.id or state.tool.name
    if not seen[id] then
      seen[id] = true
      ret[#ret + 1] = state
    end
  end
  return ret
end

---@param t sidekick.cli.State
---@param filter? sidekick.cli.Filter
function M.is(t, filter)
  filter = filter or {}
  return (filter.attached == nil or filter.attached == t.attached)
    and (filter.cwd == nil or (t.session and t.session.cwd == Session.cwd()))
    and (filter.external == nil or filter.external == t.external)
    and (filter.installed == nil or filter.installed == t.installed)
    and (filter.name == nil or filter.name == t.tool.name)
    and (filter.session == nil or (t.session and t.session.id == filter.session))
    and (filter.started == nil or filter.started == t.started)
    and (filter.terminal == nil or filter.terminal == (t.terminal ~= nil))
end

---@param session sidekick.cli.Session
function M.get_state(session)
  ---@type sidekick.cli.State
  return setmetatable({
    session = session,
    installed = true, -- it's running, so it must be installed
  }, {
    __index = function(_, k)
      if k == "tool" or k == "started" or k == "external" then
        return session[k]
      elseif k == "attached" then
        return session:is_attached()
      elseif k == "terminal" then
        return session.backend == "terminal" and Terminal.get(session.id) or nil
      end
    end,
  })
end

---@param filter? sidekick.cli.Filter
---@return sidekick.cli.State[]
function M.get(filter)
  filter = filter or {}
  local all = {} ---@type sidekick.cli.State[]
  local sids = {} ---@type table<string, boolean>
  local sessions = filter.attached and Session.attached() or Session.sessions()

  for _, s in pairs(sessions) do
    -- if not attached, skip if another session with higher priority
    -- is running with overlapping pids
    local skip = false
    if not s:is_attached() then
      for _, s2 in pairs(sessions) do
        local duplicate = s2.parent and s2.parent.id == s.id
          or (not s2.parent and Util.overlaps(s2.pids or {}, s.pids or {}))
        if s2 ~= s and duplicate and s2.priority > s.priority then
          skip = true
          break
        end
      end
    end

    if not skip then
      local ss = M.get_state(s)
      all[#all + 1] = ss
      if not ss.external then
        sids[s.sid] = true
      end
    end
  end

  if not filter.attached then
    for name, tool in pairs(Config.tools()) do
      local sid = Session.sid({ tool = name })
      if not sids[sid] then
        all[#all + 1] = {
          tool = tool,
          installed = vim.fn.executable(tool.cmd[1]) == 1,
        }
      end
    end
  end

  local cwd = Session.cwd()

  ---@type sidekick.cli.State[]
  ---@param t sidekick.cli.State
  local ret = vim.tbl_filter(function(t)
    return M.is(t, filter)
  end, all)
  decorate(ret)
  table.sort(ret, function(a, b)
    if a.installed ~= b.installed then
      return a.installed
    end
    -- a running agent is always a better answer than "start a new one", however
    -- remote it is: without this, session-less tools win every affinity tiebreak
    local a_running, b_running = a.session ~= nil, b.session ~= nil
    if a_running ~= b_running then
      return a_running
    end
    if affinity_score(a) ~= affinity_score(b) then
      return affinity_score(a) > affinity_score(b)
    end
    if a_running then
      local a_cwd = a.session.cwd == cwd
      local b_cwd = b.session.cwd == cwd
      if a_cwd ~= b_cwd then
        return a_cwd
      end
    end
    if recency(a) ~= recency(b) then
      return recency(a) > recency(b)
    end
    if a.started ~= b.started then
      return a.started
    end
    if (a.terminal ~= nil) ~= (b.terminal ~= nil) then
      return a.terminal ~= nil
    end
    if a.external ~= b.external then
      return not a.external
    end
    return a.tool.name < b.tool.name
  end)
  return ret
end

---@param filter? sidekick.cli.Filter
---@param scope "cwd"|"project"|"all"
---@return sidekick.cli.State[]
function M.scoped(filter, scope)
  return in_scope(M.get(filter), scope)
end

---@param filter? sidekick.cli.Filter
---@param opts? {scope?:"cwd"|"project"|"all", show?:boolean, focus?:boolean, multiple?:boolean, notify_empty?:boolean}
---@return sidekick.cli.State[]
function M.auto_attach(filter, opts)
  opts = opts or {}
  local scope = opts.scope or "project"
  local all_states = M.get(Util.merge(filter, { started = true }))
  local states = in_scope(all_states, scope)
  local outside = #all_states - #states
  if #states == 0 then
    if opts.notify_empty and outside > 0 then
      Util.warn((
        'Auto-attach: no agents in `%s` scope — %d running elsewhere. Use require("sidekick.cli").select()'
      ):format(scope, outside))
    end
    return {}
  end
  states = unique_tmx_parent(states) or states
  if opts.multiple == false and #states ~= 1 then
    return {}
  end

  local attached = {} ---@type sidekick.cli.State[]
  local newly_attached = {} ---@type sidekick.cli.State[]
  for _, state in ipairs(states) do
    local ret, did_attach = M.attach(state, { show = opts.show, focus = opts.focus, notify = false, viewer = false })
    attached[#attached + 1] = ret
    if did_attach then
      newly_attached[#newly_attached + 1] = state
    end
  end

  if #newly_attached > 0 then
    local lines = { ("Auto-attached %d agent%s:"):format(#newly_attached, #newly_attached == 1 and "" or "s") }
    vim.list_extend(lines, vim.tbl_map(auto_attach_summary, newly_attached))
    Util.info(table.concat(lines, "\n"))
  end

  return attached
end

--- Executes a callback with one or more attached sessions.
---@param cb fun(state: sidekick.cli.State, attached?: boolean):any?
---@param opts? sidekick.cli.With
function M.with(cb, opts)
  opts = opts or {}
  cb = vim.schedule_wrap(cb)
  local on_resolved = opts.on_resolved or function() end

  ---@param state sidekick.cli.State
  local use = vim.schedule_wrap(function(state)
    if not state then
      return
    end
    local ret, attached = M.attach(state, { show = opts.show, focus = opts.focus })
    cb(ret, attached)
  end)

  ---@param states sidekick.cli.State[]
  local function apply(states)
    if #states == 0 then
      return
    end
    on_resolved(states)
    vim.tbl_map(use, states)
  end

  ---@param filter sidekick.cli.Filter?
  ---@param scope_override? "cwd"|"project"|"all"
  local function pick(filter, scope_override)
    require("sidekick.cli.ui.select").select({
      auto = true,
      filter = filter,
      cb = function(state)
        if state then
          apply({ state })
        end
      end,
      scope = scope_override,
    })
  end

  local filter_attached = Util.merge(opts.filter, { attached = true })
  local scope = scope_kind(opts)
  local attached_all = M.get(filter_attached)
  local attached = in_scope(attached_all, scope)

  if opts.multicast then
    local targets = attached_all
    if opts.attach and auto_attach_enabled("on_demand") then
      targets = dedupe(vim.list_extend(vim.deepcopy(attached_all), M.auto_attach(
        opts.filter,
        { focus = opts.focus, multiple = true, scope = scope, show = opts.show }
      )))
    end

    if #targets > 0 then
      apply(targets)
    elseif opts.attach then
      pick(opts.filter, scope)
    end
    return
  end

  if #attached == 0 and opts.attach and auto_attach_enabled("on_demand") then
    local auto = M.auto_attach(opts.filter, { focus = opts.focus, multiple = false, scope = scope, show = opts.show })
    if #auto == 1 then
      use(auto[1])
      return
    end
  end

  if #attached == 0 and #attached_all > 0 then
    if #attached_all > 1 and not opts.all then
      pick(filter_attached)
    else
      apply(attached_all)
    end
  elseif #attached == 0 and opts.attach then
    pick(opts.filter, scope)
  elseif #attached > 1 and not opts.all then
    pick(filter_attached, scope)
  else
    apply(attached)
  end
end

---@param state sidekick.cli.State
---@param opts? {show?:boolean, focus?:boolean, notify?:boolean, viewer?:boolean}
---@return sidekick.cli.State state, boolean attached whether we just attached
function M.attach(state, opts)
  opts = opts or {}
  local attached = state.session == nil or not state.attached
  local tool = state.tool

  -- if the session is already attached, the below is a no-op
  local session = state.session or Session.new({ tool = tool.name })
  session = Session.attach(session, { viewer = opts.viewer })

  state = M.get_state(session) -- update state
  local terminal = state.terminal
  if terminal then
    if opts.show then
      terminal:show()
      if opts.focus ~= false and terminal:is_running() then
        terminal:focus()
      end
    end
  elseif attached and opts.notify ~= false then
    Util.info("Attached to `" .. state.tool.name .. "`")
  end
  return state, attached
end

---@param state sidekick.cli.State
function M.detach(state)
  if state.session and state.attached then
    if state.terminal then
      state.terminal:close()
    else
      Session.detach(state.session)
      Util.info("Detached from `" .. state.tool.name .. "`")
    end
  end
  return state
end

return M
