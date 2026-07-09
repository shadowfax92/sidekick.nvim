local Config = require("sidekick.config")
local Util = require("sidekick.util")

---@class sidekick.cli.muxer.Tmux: sidekick.cli.Session
---@field tmux_pane_id string
---@field tmux_pid number
local M = {}
M.__index = M

-- `window_activity` is a unix timestamp; tmux has no pane-level equivalent, so this
-- is the finest-grained recency signal available for ranking panes in the picker.
local PANE_FORMAT =
  "#{session_id}:#{pane_id}:#{pane_pid}:#{session_name}:#{window_name}:#{window_index}:#{pane_index}:#{@pane_label}:#{window_activity}:#{?pane_current_path,#{pane_current_path},#{pane_start_path}}"

---@return sidekick.cli.terminal.Cmd?
function M:attach()
  if self.sid == self.mux_session then
    return { cmd = { "tmux", "attach-session", "-t", self.sid } }
  end
end

function M:init()
  if self.started then
    self.external = self.sid ~= self.mux_session
  else
    self.external = vim.env.TMUX and Config.cli.mux.create ~= "terminal"
    self.mux_session = self.sid
  end
  self.priority = self.external and 10 or 50
end

---@return sidekick.cli.terminal.Cmd?
function M:start()
  if not self.external then
    local cmd = { "tmux", "new", "-A", "-s", self.id }
    vim.list_extend(cmd, { "-c", self.cwd })
    self:add_cmd(cmd)
    vim.list_extend(cmd, { ";", "set-option", "status", "off" })
    vim.list_extend(cmd, { ";", "set-option", "detach-on-destroy", "on" })
    return { cmd = cmd }
  elseif Config.cli.mux.create == "window" then
    local cmd = { "tmux", "new-window", "-dP", "-c", self.cwd, "-F", PANE_FORMAT }
    self:add_cmd(cmd)
    self:spawn(cmd)
    Util.info(("Started **%s** in a new tmux window"):format(self.tool.name))
  elseif Config.cli.mux.create == "split" then
    local cmd = { "tmux", "split-window", "-dP", "-c", self.cwd, "-F", PANE_FORMAT }
    cmd[#cmd + 1] = Config.cli.mux.split.vertical and "-h" or "-v"
    local size = Config.cli.mux.split.size
    vim.list_extend(cmd, { "-l", tostring(size <= 1 and ((size * 100) .. "%") or size) })
    self:add_cmd(cmd)
    self:spawn(cmd)
    Util.info(("Started **%s** in a new tmux split"):format(self.tool.name))
  end
end

--- Execute the given tmux command and update the session info,
--- based on the first pane returned.
---@param cmd string[]
function M:spawn(cmd)
  local pane = M.panes({ cmd = cmd, notify = true })[1]
  if pane then
    self.id = pane.skid
    self.tmux_pane_id = pane.id
    self.mux_session = pane.session_name
    self.tmux_pid = pane.pid
    self.started = true
  end
end

function M:is_running()
  return self.tmux_pid and vim.api.nvim_get_proc(self.tmux_pid) ~= nil
end

---@param ret string[]
function M:add_cmd(ret)
  for key, value in pairs(self.tool.env or {}) do
    if value == false then
      vim.list_extend(ret, { "-u", key }) -- unset
    else
      vim.list_extend(ret, { "-e", ("%s=%s"):format(key, tostring(value)) })
    end
  end
  vim.list_extend(ret, self.tool.cmd)
end

---@param opts? { cmd?:string[], notify?:boolean }
function M.panes(opts)
  opts = opts or {}
  -- List all panes in current session with their command and cwd
  local cmd = opts.cmd or { "tmux", "list-panes", "-a", "-F", PANE_FORMAT }
  local lines = Util.exec(cmd, { notify = opts.notify == true })
  local panes = {} ---@type sidekick.tmux.Pane[]
  for _, line in ipairs(lines or {}) do
    local session_id, id, pid, session_name, window_name, window_index, pane_index, pane_label, activity, cwd =
      line:match("^(%$%d+):(%%%d+):(%d+):(.-):(.-):(%d+):(%d+):(.-):(%d*):(.*)$")
    if id and pid and session_name and cwd then
      pid = assert(tonumber(pid), "invalid tmux pane_pid: " .. pid) --[[@as number]]
      ---@class sidekick.tmux.Pane
      panes[#panes + 1] = {
        skid = ("tmux %s"):format(pid), -- unique id for the pane
        pid = pid, -- process id of the pane
        id = id, -- tmux pane id
        session_name = session_name,
        session_id = session_id,
        window_name = window_name,
        window_index = window_index,
        pane_index = pane_index,
        pane_label = pane_label,
        window_activity = tonumber(activity) or 0,
        cwd = cwd,
      }
    end
  end
  return panes
end

--- Move the current tmux client to the pane hosting `session`.
--- `tmx` scratch sessions only exist behind a popup, so re-open the popup the way
--- `tmx` does instead of switching a client into them. `display-popup` blocks until
--- the popup closes, hence the async spawn.
---@param session sidekick.cli.session.State
---@return boolean focused
function M.focus(session)
  if not vim.env.TMUX then
    Util.warn("Not running inside tmux")
    return false
  end

  local name = session.mux_session
  if name and require("sidekick.cli.affinity").is_scratch(session) then
    vim.system({ "tmux", "display-popup", "-E", ("exec tmux attach-session -t '=%s'"):format(name) })
    return true
  end

  local pane = session.tmux_pane_id
  if not pane then
    Util.warn("Session is not running in a tmux pane")
    return false
  end
  if name then
    Util.exec({ "tmux", "switch-client", "-t", "=" .. name })
  end
  Util.exec({ "tmux", "select-window", "-t", pane })
  Util.exec({ "tmux", "select-pane", "-t", pane })
  return true
end

function M.clients()
  local lines = Util.exec({ "tmux", "list-clients", "-F", "#{session_id}:#{client_pid}" }, { notify = false })
  local ret = {} ---@type table<string, integer>[]
  for _, line in ipairs(lines or {}) do
    local session_id, pid = line:match("^(%$%d+):(%d+)$")
    if session_id and pid then
      pid = assert(tonumber(pid), "invalid tmux client_pid: " .. pid) --[[@as number]]
      ret[session_id] = ret[session_id] or {}
      table.insert(ret[session_id], pid)
    end
  end
  return ret
end

function M.sessions()
  local panes = M.panes()
  local ret = {} ---@type sidekick.cli.session.State[]
  local tools = Config.tools()

  local clients = M.clients()

  local Procs = require("sidekick.cli.procs")
  local procs = Procs.new()
  for _, pane in ipairs(panes) do
    procs:walk(pane.pid, function(proc)
      for _, tool in pairs(tools) do
        if tool:is_proc(proc) then
          local pids = Procs.pids(pane.pid)
          vim.list_extend(pids, clients[pane.session_id] or {})
          ret[#ret + 1] = {
            id = pane.skid,
            cwd = proc.cwd or pane.cwd,
            tool = tool,
            tmux_pane_id = pane.id,
            tmux_pid = pane.pid,
            tmux_window_name = pane.window_name,
            tmux_window_index = pane.window_index,
            tmux_pane_index = pane.pane_index,
            tmux_pane_label = pane.pane_label,
            tmux_window_activity = pane.window_activity,
            mux_session = pane.session_name,
            pids = pids,
          }
          return true
        end
      end
    end)
  end

  return ret
end

function M:pane_id()
  if self.tmux_pane_id then
    return self.tmux_pane_id
  end
  if not self.external then
    self:spawn({ "tmux", "list-panes", "-s", "-F", PANE_FORMAT, "-t", self.mux_session })
  end
  return self.tmux_pane_id
end

---Send text to a tmux pane
function M:send(text)
  local function send()
    local buffer = "sidekick-" .. self.tmux_pane_id
    Util.exec({ "tmux", "load-buffer", "-b", buffer, "-" }, { stdin = text })
    Util.exec({ "tmux", "paste-buffer", "-b", buffer, "-d", "-p", "-r", "-t", self.tmux_pane_id })
  end

  if self.tool.mux_focus then
    -- Send focus-in event first (some TUI apps like qwen ignore input when unfocused)
    Util.exec({ "tmux", "send-keys", "-t", self.tmux_pane_id, "Escape", "[", "I" })
    vim.defer_fn(send, 50) -- slight delay to ensure focus event is processed first
  else
    send()
  end
end

---Send text to a tmux pane
function M:submit()
  Util.exec({ "tmux", "send-keys", "-t", self.tmux_pane_id, "Enter" })
end

function M:dump()
  local pane_id = self:pane_id()
  if not pane_id then
    return
  end
  local _, ret = Util.exec({ "tmux", "capture-pane", "-p", "-t", pane_id, "-S", "-", "-E", "-", "-e" })
  return ret
end

return M
