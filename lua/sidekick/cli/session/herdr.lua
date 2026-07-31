local Util = require("sidekick.util")

---@class sidekick.cli.muxer.Herdr: sidekick.cli.Session
---@field herdr_pane_id string
local M = {}
M.__index = M

local live = {} ---@type table<string, boolean>
local context = {} ---@type table<string, string>
local socket_path
local request_id = 0
local client

local function new_client()
  return {
    buffer = "",
    callbacks = {},
    connected = false,
    connecting = false,
    outbox = {},
  }
end

client = new_client()

local function nonempty(value)
  return type(value) == "string" and value ~= "" and value or nil
end

local function index(items, key)
  local ret = {}
  for _, item in ipairs(items or {}) do
    if item[key] then
      ret[item[key]] = item
    end
  end
  return ret
end

local function decode_snapshot()
  local _, stdout = Util.exec({ "herdr", "api", "snapshot" }, { notify = false })
  if not stdout then
    return
  end
  local ok, response = pcall(vim.json.decode, stdout)
  if not ok or type(response) ~= "table" then
    Util.debug("Failed to decode Herdr session snapshot", response)
    return
  end
  return response.result and response.result.snapshot or nil
end

local function resolve_socket_path()
  if socket_path then
    return socket_path
  end
  socket_path = nonempty(vim.env.HERDR_SOCKET_PATH)
  if socket_path then
    return socket_path
  end
  local lines = Util.exec({ "herdr", "status", "server" }, { notify = false })
  for _, line in ipairs(lines or {}) do
    socket_path = line:match("^socket:%s+(.+)$")
    if socket_path then
      return socket_path
    end
  end
end

local function finish_callbacks(message)
  local callbacks = client.callbacks
  client.callbacks = {}
  for _, callback in pairs(callbacks) do
    vim.schedule(function()
      callback(nil, message)
    end)
  end
end

local function disconnect(pipe, message)
  if client.pipe ~= pipe then
    return
  end
  client.pipe = nil
  client.buffer = ""
  client.connected = false
  client.connecting = false
  client.outbox = {}
  if pipe and not pipe:is_closing() then
    pipe:close()
  end
  if message then
    finish_callbacks(message)
    Util.error(message)
  end
end

local function handle_response(line)
  local ok, response = pcall(vim.json.decode, line)
  if not ok or type(response) ~= "table" then
    Util.error("Herdr returned an invalid socket response")
    return
  end
  local callback = response.id and client.callbacks[response.id] or nil
  if response.id then
    client.callbacks[response.id] = nil
  end
  if callback then
    callback(response)
  elseif response.error then
    Util.error(("Herdr request failed: %s"):format(response.error.message or response.error.code or "unknown error"))
  end
end

local function read(pipe, err, data)
  if client.pipe ~= pipe then
    return
  end
  if err then
    disconnect(pipe, "Herdr socket read failed: " .. err)
    return
  end
  if not data then
    disconnect(pipe, next(client.callbacks) and "Herdr socket connection closed" or nil)
    return
  end
  client.buffer = client.buffer .. data
  while true do
    local stop = client.buffer:find("\n", 1, true)
    if not stop then
      return
    end
    local line = client.buffer:sub(1, stop - 1)
    client.buffer = client.buffer:sub(stop + 1)
    if line ~= "" then
      vim.schedule(function()
        handle_response(line)
      end)
    end
  end
end

local function flush()
  local pipe = client.pipe
  if not pipe or not client.connected or #client.outbox == 0 then
    return
  end
  local payload = table.concat(client.outbox)
  client.outbox = {}
  pipe:write(payload, function(err)
    if err then
      disconnect(pipe, "Herdr socket write failed: " .. err)
    end
  end)
end

local function connect()
  local path = resolve_socket_path()
  if not path then
    client.outbox = {}
    finish_callbacks("Could not resolve the Herdr socket path")
    Util.error("Could not resolve the Herdr socket path")
    return
  end
  local pipe = assert(vim.uv.new_pipe(false))
  client.pipe = pipe
  client.connecting = true
  pipe:connect(path, function(err)
    if client.pipe ~= pipe then
      if not pipe:is_closing() then
        pipe:close()
      end
      return
    end
    if err then
      disconnect(pipe, "Could not connect to Herdr: " .. err)
      return
    end
    client.connected = true
    client.connecting = false
    pipe:read_start(function(read_err, data)
      read(pipe, read_err, data)
    end)
    flush()
  end)
end

---@param method string
---@param params table
---@param callback? fun(response?:table, error?:string)
function M.request(method, params, callback)
  request_id = request_id + 1
  local id = "sidekick:" .. request_id
  local ok, payload = pcall(vim.json.encode, { id = id, method = method, params = params })
  if not ok then
    Util.error("Failed to encode Herdr request")
    return
  end
  if callback then
    client.callbacks[id] = callback
  end
  client.outbox[#client.outbox + 1] = payload .. "\n"
  if client.connected then
    flush()
  elseif not client.connecting then
    connect()
  end
  return id
end

function M:init()
  self.external = self.started == true
  self.priority = self.external and 100 or 50
end

function M:start()
  return { cmd = self.tool.cmd, env = self.tool.env }
end

function M:attach() end

function M:is_running()
  return live[self.id] == true
end

function M.sessions()
  local snapshot = decode_snapshot()
  live = {}
  if not snapshot then
    context = {}
    return {}
  end

  context = {
    workspace_id = snapshot.focused_workspace_id,
    tab_id = snapshot.focused_tab_id,
    pane_id = snapshot.focused_pane_id,
  }

  local workspaces = index(snapshot.workspaces, "workspace_id")
  local tabs = index(snapshot.tabs, "tab_id")
  local panes = index(snapshot.panes, "pane_id")
  local sessions = {}

  for _, agent in ipairs(snapshot.agents or {}) do
    if agent.agent and agent.terminal_id and agent.pane_id then
      local workspace = workspaces[agent.workspace_id] or {}
      local tab = tabs[agent.tab_id] or {}
      local pane = panes[agent.pane_id] or {}
      local id = "herdr " .. agent.terminal_id
      local cwd = nonempty(agent.foreground_cwd)
        or nonempty(agent.cwd)
        or nonempty(pane.foreground_cwd)
        or nonempty(pane.cwd)
      local pane_label = nonempty(pane.label)
        or nonempty(agent.title)
        or nonempty(pane.title)
        or nonempty(agent.terminal_title_stripped)
        or nonempty(pane.terminal_title_stripped)
        or agent.pane_id
      local workspace_label = nonempty(workspace.label) or agent.workspace_id
      local session = {
        agent_status = agent.agent_status or "unknown",
        cwd = cwd,
        external = true,
        herdr_agent_name = nonempty(agent.name),
        herdr_focused = agent.focused == true,
        herdr_pane_id = agent.pane_id,
        herdr_pane_label = pane_label,
        herdr_state_change_seq = tonumber(agent.state_change_seq) or 0,
        herdr_tab_id = agent.tab_id,
        herdr_tab_label = nonempty(tab.label) or agent.tab_id,
        herdr_terminal_id = agent.terminal_id,
        herdr_workspace_id = agent.workspace_id,
        herdr_workspace_label = workspace_label,
        id = id,
        mux_session = workspace_label,
        priority = 100,
        tool = agent.agent,
      }
      sessions[#sessions + 1] = session
      live[id] = true
    end
  end

  return sessions
end

function M.current()
  return {
    workspace_id = nonempty(vim.env.HERDR_WORKSPACE_ID) or context.workspace_id,
    tab_id = nonempty(vim.env.HERDR_TAB_ID) or context.tab_id,
    pane_id = nonempty(vim.env.HERDR_PANE_ID) or context.pane_id,
  }
end

function M:send(text)
  M.request("pane.send_input", { pane_id = self.herdr_pane_id, text = text })
end

function M:submit()
  M.request("pane.send_input", { pane_id = self.herdr_pane_id, keys = { "enter" } })
end

function M:dump()
  local _, stdout = Util.exec(
    { "herdr", "agent", "read", self.herdr_pane_id, "--source", "recent", "--format", "ansi" },
    { notify = false }
  )
  return stdout
end

---@param session sidekick.cli.session.State
function M.focus(session)
  if not session.herdr_pane_id then
    Util.warn("Session is not running in a Herdr pane")
    return false
  end
  return Util.exec({ "herdr", "agent", "focus", session.herdr_pane_id }) ~= nil
end

function M._reset()
  local pipe = client.pipe
  if pipe and not pipe:is_closing() then
    pipe:close()
  end
  client = new_client()
  context = {}
  live = {}
  request_id = 0
  socket_path = nil
end

return M
