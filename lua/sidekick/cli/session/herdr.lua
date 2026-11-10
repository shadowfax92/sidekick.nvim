local Util = require("sidekick.util")

---@class sidekick.cli.muxer.Herdr: sidekick.cli.Session
---@field herdr_pane_id string
---@field _timeout? integer per-request timeout override for tests, in ms
local M = {}
M.__index = M

local live = {} ---@type table<string, boolean>
local context = {} ---@type table<string, string>
local socket_path
local request_id = 0

-- Bounds one request from connect to reply. Herdr answers a local request
-- within its own 5s app timeout (APP_RESPONSE_TIMEOUT), so this only fires when
-- nothing is answering, e.g. a forwarded socket whose SSH link went quiet.
local REQUEST_TIMEOUT_MS = 6000

---@class sidekick.herdr.Request
---@field id string
---@field payload string one newline-terminated JSON line
---@field callback? fun(response?:table, error?:string)

---@class sidekick.herdr.Connection
---@field request sidekick.herdr.Request
---@field pipe uv.uv_pipe_t
---@field timer uv.uv_timer_t
---@field buffer string

---@type sidekick.herdr.Request[] requests not yet started, in call order
local queue = {}
---@type sidekick.herdr.Connection? the one request currently on the wire
local active

local function nonempty(value)
  return type(value) == "string" and value ~= "" and value or nil
end

local function remote()
  -- Socket callbacks run in fast events, where vim.env's Vimscript getter is unsafe.
  return vim.uv.os_getenv("HERDR_SSH_PANES") == "1"
end

local function connection_error(message)
  return remote() and "Herdr (laptop) unreachable: SSH link down" or message
end

local function without_socket_environment()
  local ret = {}
  for key, value in pairs(vim.fn.environ()) do
    if key ~= "HERDR_SOCKET_PATH" then
      ret[#ret + 1] = ("%s=%s"):format(key, value)
    end
  end
  return ret
end

local function absolute_command(cmd)
  local ret = vim.deepcopy(cmd)
  local executable = vim.fn.exepath(ret[1])
  if executable ~= "" then
    ret[1] = executable
  end
  return ret
end

local function retry_without_socket(cmd)
  local lines, stdout = Util.exec(cmd, { notify = false })
  if stdout or not nonempty(vim.env.HERDR_SOCKET_PATH) then
    return lines, stdout
  end
  return Util.exec(absolute_command(cmd), {
    notify = false,
    env = without_socket_environment(),
    clear_env = true,
  })
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

local function resolve_socket_path()
  -- Remote scratch owns only a forwarded laptop socket. Server discovery or
  -- dropping this override could reach the Studio's server with colliding pane ids.
  if remote() then
    return nonempty(vim.env.HERDR_SOCKET_PATH)
  end
  if socket_path then
    return socket_path
  end
  local lines = retry_without_socket({ vim.env.HERDR_BIN_PATH or "herdr", "status", "server" })
  for _, line in ipairs(lines or {}) do
    socket_path = line:match("^socket:%s+(.+)$")
    if socket_path then
      return socket_path
    end
  end
  socket_path = nonempty(vim.env.HERDR_SOCKET_PATH)
  return socket_path
end

local function exec(cmd)
  local path = resolve_socket_path()
  if remote() and not path then
    Util.error(connection_error())
    return
  end
  local opts = {
    notify = false,
    env = path and { HERDR_SOCKET_PATH = path } or nil,
  }
  if not remote() then
    return Util.exec(cmd, opts)
  end
  -- A forwarded socket can accept a connection after its SSH link stops
  -- answering. Bound every remote CLI wait so discovery/read/focus cannot
  -- freeze the editor; the existing failure path never discovers another server.
  opts.timeout = 3000
  local ok, lines, stdout = pcall(Util.exec, cmd, opts)
  if not ok or not stdout then
    Util.error(connection_error())
    return
  end
  return lines, stdout
end

local function decode_snapshot()
  local cmd = { vim.env.HERDR_BIN_PATH or "herdr", "api", "snapshot" }
  local _, stdout
  if remote() then
    _, stdout = exec(cmd)
  else
    _, stdout = retry_without_socket(cmd)
  end
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

--[[
Herdr socket transport.

Herdr's API socket serves exactly one request per connection: the server reads
one newline-terminated JSON line, writes one JSON reply line, and closes. Any
further bytes on that connection are never read, and writing after the close
fails with EPIPE. So every request gets its own connection:

  M.request -> queue -> pump -> connect -> write line -> read reply line -> close
                         ^                                                   |
                         +---------- next queued request (scheduled) <-------+

The server handles each connection on its own thread, so two open connections
can be served in either order. Requests therefore run strictly one at a time:
the next connection opens only after the previous one has its reply or has
failed. Removing that serialization lets Enter overtake the text it submits.
]]

---@param callback? fun(response?:table, error?:string)
local function deliver(callback, response, message)
  if callback then
    vim.schedule(function()
      callback(response, message)
    end)
  end
end

local pump

---@param conn sidekick.herdr.Connection
local function close_connection(conn)
  if active == conn then
    active = nil
  end
  if not conn.timer:is_closing() then
    conn.timer:close()
  end
  if not conn.pipe:is_closing() then
    conn.pipe:close()
  end
end

---@param conn sidekick.herdr.Connection
---@param line string
local function complete(conn, line)
  close_connection(conn)
  local ok, response = pcall(vim.json.decode, line)
  if not ok or type(response) ~= "table" then
    deliver(conn.request.callback, nil, "Herdr returned an invalid socket response")
    Util.error("Herdr returned an invalid socket response")
  elseif conn.request.callback then
    deliver(conn.request.callback, response)
  elseif response.error then
    Util.error(("Herdr request failed: %s"):format(response.error.message or response.error.code or "unknown error"))
  end
  -- The server answered, so it is reachable: an error reply for one pane must
  -- not cost the other queued targets their input. Resolution runs Vimscript,
  -- which is unsafe in this libuv callback, hence the schedule.
  vim.schedule(pump)
end

-- A connection-level failure (no socket, refused, reset, closed without reply,
-- timeout) fails the request on the wire and every request queued behind it,
-- with a single notification. Queued requests are dropped rather than tried:
-- they are usually the rest of one user action (Enter after its text, the
-- other multicast targets), the transport just proved unreachable or stalled,
-- and continuing would submit an Enter whose text may be missing or cost each
-- queued request its own timeout. Nothing is ever replayed either: a failed
-- write or read may already have delivered input to an agent, so only the next
-- user action opens a new connection.
---@param conn? sidekick.herdr.Connection
---@param message string
local function fail(conn, message)
  local failed = {}
  if conn then
    close_connection(conn)
    failed[1] = conn.request
  end
  vim.list_extend(failed, queue)
  queue = {}
  message = connection_error(message)
  for _, request in ipairs(failed) do
    deliver(request.callback, nil, message)
  end
  Util.error(message)
end

---@param conn sidekick.herdr.Connection
local function read(conn, err, data)
  if active ~= conn then
    return
  end
  if err then
    return fail(conn, "Herdr socket read failed: " .. err)
  end
  if not data then
    -- Herdr ends every reply with a newline; tolerate a final line without one.
    if conn.buffer ~= "" then
      return complete(conn, conn.buffer)
    end
    return fail(conn, "Herdr socket connection closed before a response")
  end
  conn.buffer = conn.buffer .. data
  local stop = conn.buffer:find("\n", 1, true)
  if stop then
    complete(conn, conn.buffer:sub(1, stop - 1))
  end
end

-- Starts the next queued request unless one is already on the wire. Always
-- runs on the main loop: socket path resolution may shell out to `herdr`.
function pump()
  if active or #queue == 0 then
    return
  end
  local path = resolve_socket_path()
  if not path then
    return fail(nil, "Could not resolve the Herdr socket path")
  end
  local request = table.remove(queue, 1)
  local conn = {
    request = request,
    pipe = assert(vim.uv.new_pipe(false)),
    timer = assert(vim.uv.new_timer()),
    buffer = "",
  }
  active = conn
  conn.timer:start(M._timeout or REQUEST_TIMEOUT_MS, 0, function()
    if active == conn then
      fail(conn, "Herdr request timed out")
    end
  end)
  conn.pipe:connect(path, function(err)
    if active ~= conn then
      return
    end
    if err then
      return fail(conn, "Could not connect to Herdr: " .. err)
    end
    conn.pipe:read_start(function(read_err, data)
      read(conn, read_err, data)
    end)
    conn.pipe:write(request.payload, function(write_err)
      if write_err and active == conn then
        fail(conn, "Herdr socket write failed: " .. write_err)
      end
    end)
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
  queue[#queue + 1] = { id = id, payload = payload .. "\n", callback = callback }
  pump()
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

  local workspaces = index(snapshot.workspaces, "workspace_id")
  local tabs = index(snapshot.tabs, "tab_id")
  local panes = index(snapshot.panes, "pane_id")
  local source_pane_id = nonempty(vim.env.HERDR_SCRATCH_SOURCE_PANE)
  local source_pane = source_pane_id and panes[source_pane_id] or nil
  context = {
    workspace_id = source_pane and source_pane.workspace_id or snapshot.focused_workspace_id,
    tab_id = source_pane and source_pane.tab_id or snapshot.focused_tab_id,
    pane_id = source_pane_id or snapshot.focused_pane_id,
  }
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
        herdr_ssh = agent.ssh or pane.ssh,
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
  local source_pane_id = nonempty(vim.env.HERDR_SCRATCH_SOURCE_PANE)
  if source_pane_id then
    return {
      workspace_id = context.workspace_id,
      tab_id = context.tab_id,
      pane_id = source_pane_id,
    }
  end
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
  local _, stdout = exec({
    vim.env.HERDR_BIN_PATH or "herdr",
    "agent",
    "read",
    self.herdr_pane_id,
    "--source",
    "recent",
    "--format",
    "ansi",
  })
  return stdout
end

---@param session sidekick.cli.session.State
function M.focus(session)
  if not session.herdr_pane_id then
    Util.warn("Session is not running in a Herdr pane")
    return false
  end
  return exec({ vim.env.HERDR_BIN_PATH or "herdr", "agent", "focus", session.herdr_pane_id }) ~= nil
end

function M._reset()
  if active then
    close_connection(active)
  end
  queue = {}
  M._timeout = nil
  context = {}
  live = {}
  request_id = 0
  socket_path = nil
end

return M
