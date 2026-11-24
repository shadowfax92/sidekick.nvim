local Config = require("sidekick.config")
local Util = require("sidekick.util")

---@class sidekick.cli.muxer.Hc: sidekick.cli.Session
---@field hc_address string
---@field hc_cols? integer
---@field hc_rows? integer
---@field hc_space? string
---@field hc_tab? string
---@field _timeout? integer per-request timeout override for tests, in ms
local M = {}
M.__index = M

local FRAME_HEADER = 9
local FRAME_MAX_PAYLOAD = 16 * 1024 * 1024
local FRAME_DATA = 0
local FRAME_CLOSE = 2
local DEFAULT_COLS = 200
local DEFAULT_ROWS = 120
local DUMP_LINES = 1000
local REQUEST_TIMEOUT_MS = 6000

local APP_TOOL = {
  ["claude-code"] = "claude",
  ["cursor-agent"] = "cursor",
}

local SCRATCH_KIND = {
  vim = "nvim",
  nvim = "nvim",
  sh = "shell",
  shell = "shell",
}

---@class sidekick.hc.SendRequest
---@field address string
---@field cols integer
---@field rows integer
---@field data string
---@field callback? fun(ok:boolean, error?:string)

---@class sidekick.hc.Connection
---@field request sidekick.hc.SendRequest
---@field pipe uv.uv_pipe_t
---@field timer uv.uv_timer_t
---@field buffer string
---@field phase "hello"|"attach"|"closing"
---@field channel? integer

local live = {} ---@type table<string, boolean>
local sizes = {} ---@type table<string, { cols: integer, rows: integer }>
local context = {} ---@type table<string, { space?: string, tab?: string }>
local queue = {} ---@type sidekick.hc.SendRequest[]
local active ---@type sidekick.hc.Connection?

local function nonempty(value)
  return type(value) == "string" and value ~= "" and value or nil
end

---@param n integer
---@return string
local function u32_le(n)
  local b0 = n % 256
  n = math.floor(n / 256)
  local b1 = n % 256
  n = math.floor(n / 256)
  local b2 = n % 256
  local b3 = math.floor(n / 256) % 256
  return string.char(b0, b1, b2, b3)
end

---@param buf string
---@param offset integer
---@return integer
local function read_u32_le(buf, offset)
  local b0, b1, b2, b3 = buf:byte(offset, offset + 3)
  return b0 + b1 * 256 + b2 * 65536 + b3 * 16777216
end

--- Encode one herdr-core framed message: `[ch u32 LE][kind u8][len u32 LE][payload]`.
---@param channel integer
---@param kind integer
---@param payload? string
---@return string
function M.encode_frame(channel, kind, payload)
  payload = payload or ""
  return u32_le(channel) .. string.char(kind) .. u32_le(#payload) .. payload
end

--- Decode the next complete frame from `buf`.
--- Returns `channel, kind, payload, rest`, `nil` when incomplete, or `nil, error`.
---@param buf string
---@return integer? channel
---@return integer|string? kind_or_err
---@return string? payload
---@return string? rest
function M.decode_frame(buf)
  if #buf < FRAME_HEADER then
    return nil
  end
  local channel = read_u32_le(buf, 1)
  local kind = buf:byte(5)
  local len = read_u32_le(buf, 6)
  if len > FRAME_MAX_PAYLOAD then
    return nil, ("hc frame payload exceeds %d bytes"):format(FRAME_MAX_PAYLOAD)
  end
  if #buf < FRAME_HEADER + len then
    return nil
  end
  return channel, kind, buf:sub(FRAME_HEADER + 1, FRAME_HEADER + len), buf:sub(FRAME_HEADER + len + 1)
end

--- Resolve the herdr-core socket path from environment without ever starting a core.
---@return string?
function M.socket_path()
  -- Socket callbacks run in fast events, where vim.env's Vimscript getter is unsafe.
  return nonempty(vim.uv.os_getenv("HC_SOCKET")) or nonempty(vim.uv.os_getenv("HC_TERMINAL_SOCKET"))
end

--- Map a herdr-core OSC 7501 `status.app` name to a Sidekick tool name.
---@param app any
---@return string?
function M.map_tool(app)
  app = nonempty(app)
  if not app then
    return nil
  end
  return APP_TOOL[app] or app
end

---@param fg any
---@param pid any
---@return string?
local function match_foreground_tool(fg, pid)
  if type(fg) ~= "table" or type(fg.argv) ~= "table" or #fg.argv == 0 then
    return nil
  end
  local argv = {} ---@type string[]
  for _, arg in ipairs(fg.argv) do
    if type(arg) == "string" then
      argv[#argv + 1] = arg
    end
  end
  if #argv == 0 then
    return nil
  end
  local proc = {
    pid = type(fg.pid) == "number" and fg.pid or 0,
    ppid = type(pid) == "number" and pid or 0,
    cmd = table.concat(argv, " "),
    cwd = nonempty(fg.cwd),
  }
  local tools = Config.tools()
  local names = vim.tbl_keys(tools)
  table.sort(names)
  for _, name in ipairs(names) do
    if tools[name]:is_proc(proc) then
      return name
    end
  end
end

---@param terminal table
---@return string?
local function resolve_tool(terminal)
  local status = type(terminal.status) == "table" and terminal.status or nil
  if status then
    return M.map_tool(status.app) or match_foreground_tool(terminal.foreground, terminal.pid)
  end
  return match_foreground_tool(terminal.foreground, terminal.pid)
end

--- Wrap text in bracketed paste markers, stripping any embedded end marker so pasted
--- text cannot break out early.
---@param text string
---@return string
local function bracketed_paste(text)
  return "\27[200~" .. text:gsub("\27%[201~", "") .. "\27[201~"
end

--- Query `terminal.list` directly over the herdr-core socket so discovery never spawns
--- `hc` (which would autostart a core if none is listening).
---@return table[]?
function M.list()
  local path = M.socket_path()
  if not path then
    return nil
  end
  local pipe = assert(vim.uv.new_pipe(false))
  local done = false
  local terminals ---@type table[]?
  local buffer = ""

  local function finish(result)
    if done then
      return
    end
    done = true
    terminals = result
    if not pipe:is_closing() then
      pipe:close()
    end
  end

  local function handle_line(line)
    local ok, response = pcall(vim.json.decode, line)
    if
      ok
      and type(response) == "table"
      and type(response.result) == "table"
      and type(response.result.terminals) == "table"
    then
      finish(response.result.terminals)
    else
      finish(nil)
    end
  end

  local ok_conn = pipe:connect(path, function(err)
    if done then
      return
    end
    if err then
      return finish(nil)
    end
    pipe:read_start(function(read_err, data)
      if done then
        return
      end
      if read_err then
        return finish(nil)
      end
      if not data then
        if buffer ~= "" then
          handle_line(buffer)
        else
          finish(nil)
        end
        return
      end
      buffer = buffer .. data
      local stop = buffer:find("\n", 1, true)
      if stop then
        handle_line(buffer:sub(1, stop - 1))
      end
    end)
    pipe:write('{"jsonrpc":"2.0","id":1,"method":"terminal.list","params":{}}\n', function(write_err)
      if write_err and not done then
        finish(nil)
      end
    end)
  end)
  if ok_conn == nil then
    finish(nil)
  end

  vim.wait(M._timeout or REQUEST_TIMEOUT_MS, function()
    return done
  end, 5)
  if not done then
    finish(nil)
  end
  return terminals
end

--[[
herdr-core framed paste transport.

`terminal.send` always waits for quiet and submits with Enter, so pasting without
submitting opens one framed connection per send:

  connect -> plain `hello {framed:true}` -> wait reply line
          -> framed ch0 `terminal.attach {terminal, cols, rows, resumed:true}` -> wait ch0 reply (gives ch)
          -> framed ch DATA (payload) + ch CLOSE -> wait ch CLOSE ack -> close

Requests are serialized one at a time on a queue, matching `herdr.lua`: the next
connection opens only after the previous one completes or fails, so `submit()` never
overtakes the `send()` text ahead of it.
]]

---@param callback? fun(ok:boolean, error?:string)
---@param ok boolean
---@param message? string
local function deliver(callback, ok, message)
  if callback then
    vim.schedule(function()
      callback(ok, message)
    end)
  end
end

local pump

---@param conn sidekick.hc.Connection
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

---@param conn sidekick.hc.Connection
---@param ok boolean
---@param err_msg? string
local function finish_request(conn, ok, err_msg)
  close_connection(conn)
  if not ok then
    if conn.request.callback then
      deliver(conn.request.callback, false, err_msg)
    elseif err_msg then
      Util.error(err_msg)
    end
  else
    deliver(conn.request.callback, true)
  end
  vim.schedule(pump)
end

---@param conn? sidekick.hc.Connection
---@param message string
local function fail(conn, message)
  local failed = {} ---@type sidekick.hc.SendRequest[]
  if conn then
    close_connection(conn)
    failed[1] = conn.request
  end
  vim.list_extend(failed, queue)
  queue = {}
  for _, request in ipairs(failed) do
    deliver(request.callback, false, message)
  end
  Util.error(message)
end

---@param conn sidekick.hc.Connection
local function process_frames(conn)
  while active == conn do
    local ch, kind, payload, rest = M.decode_frame(conn.buffer)
    if not ch then
      if kind then
        return fail(conn, kind --[[@as string]])
      end
      return
    end
    conn.buffer = rest --[[@as string]]
    if conn.phase == "attach" then
      if ch == 0 and kind == FRAME_DATA then
        local ok, reply = pcall(vim.json.decode, payload)
        if not ok or type(reply) ~= "table" then
          return fail(conn, "hc returned an invalid attach response")
        end
        if type(reply.error) == "table" then
          local msg = ("hc attach failed: %s"):format(
            nonempty(reply.error.message) or tostring(reply.error.code or "unknown error")
          )
          return finish_request(conn, false, msg)
        end
        local channel = type(reply.result) == "table" and reply.result.channel or nil
        if type(channel) ~= "number" then
          return fail(conn, "hc attach reply missing channel")
        end
        conn.channel = channel
        conn.phase = "closing"
        local frames = M.encode_frame(channel, FRAME_DATA, conn.request.data)
          .. M.encode_frame(channel, FRAME_CLOSE, "")
        conn.pipe:write(frames, function(write_err)
          if write_err and active == conn then
            fail(conn, "hc socket write failed: " .. write_err)
          end
        end)
      end
    elseif conn.phase == "closing" then
      if ch == conn.channel and kind == FRAME_CLOSE then
        return finish_request(conn, true)
      end
    end
  end
end

---@param conn sidekick.hc.Connection
local function read(conn, err, data)
  if active ~= conn then
    return
  end
  if err then
    return fail(conn, "hc socket read failed: " .. err)
  end
  if not data then
    return fail(conn, "hc socket connection closed before completion")
  end
  conn.buffer = conn.buffer .. data
  if conn.phase == "hello" then
    local stop = conn.buffer:find("\n", 1, true)
    if not stop then
      return
    end
    local line = conn.buffer:sub(1, stop - 1)
    conn.buffer = conn.buffer:sub(stop + 1)
    local ok, reply = pcall(vim.json.decode, line)
    if not ok or type(reply) ~= "table" then
      return fail(conn, "hc returned an invalid hello response")
    end
    if type(reply.error) == "table" then
      local msg = ("hc hello failed: %s"):format(
        nonempty(reply.error.message) or tostring(reply.error.code or "unknown error")
      )
      return fail(conn, msg)
    end
    conn.phase = "attach"
    local attach = vim.json.encode({
      jsonrpc = "2.0",
      id = 2,
      method = "terminal.attach",
      params = {
        terminal = conn.request.address,
        cols = conn.request.cols,
        rows = conn.request.rows,
        resumed = true,
      },
    })
    conn.pipe:write(M.encode_frame(0, FRAME_DATA, attach), function(write_err)
      if write_err and active == conn then
        fail(conn, "hc socket write failed: " .. write_err)
      end
    end)
  end
  if active == conn and conn.phase ~= "hello" then
    process_frames(conn)
  end
end

function pump()
  if active or #queue == 0 then
    return
  end
  local path = M.socket_path()
  if not path then
    return fail(nil, "Could not resolve the hc socket path")
  end
  local request = table.remove(queue, 1)
  local conn = {
    request = request,
    pipe = assert(vim.uv.new_pipe(false)),
    timer = assert(vim.uv.new_timer()),
    buffer = "",
    phase = "hello",
  } ---@type sidekick.hc.Connection
  active = conn
  conn.timer:start(M._timeout or REQUEST_TIMEOUT_MS, 0, function()
    if active == conn then
      fail(conn, "hc request timed out")
    end
  end)
  local ok_conn, conn_err = conn.pipe:connect(path, function(err)
    if active ~= conn then
      return
    end
    if err then
      return fail(conn, "Could not connect to hc: " .. err)
    end
    conn.pipe:read_start(function(read_err, data)
      read(conn, read_err, data)
    end)
    conn.pipe:write('{"jsonrpc":"2.0","id":1,"method":"hello","params":{"framed":true}}\n', function(write_err)
      if write_err and active == conn then
        fail(conn, "hc socket write failed: " .. write_err)
      end
    end)
  end)
  if ok_conn == nil then
    fail(conn, "Could not connect to hc: " .. tostring(conn_err))
  end
end

---@param address string
---@param data string
---@param opts? { cols?: integer, rows?: integer, callback?: fun(ok:boolean, error?:string) }
function M.send_bytes(address, data, opts)
  opts = opts or {}
  local size = sizes[address]
  queue[#queue + 1] = {
    address = address,
    cols = opts.cols or (size and size.cols) or DEFAULT_COLS,
    rows = opts.rows or (size and size.rows) or DEFAULT_ROWS,
    data = data,
    callback = opts.callback,
  }
  pump()
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
  local terminals = M.list()
  live = {}
  sizes = {}
  context = {}
  if type(terminals) ~= "table" then
    return {}
  end

  local sessions = {} ---@type sidekick.cli.session.State[]
  for _, terminal in ipairs(terminals) do
    if type(terminal) == "table" and terminal.state == "live" then
      local address = nonempty(terminal.address)
      if address then
        local labels = type(terminal.labels) == "table" and terminal.labels or {}
        local space = nonempty(labels["herdr.space"])
        local tab = nonempty(labels["herdr.tab"])
        if space or tab then
          context[address] = { space = space, tab = tab }
        end

        local cols = type(terminal.cols) == "number" and terminal.cols > 0 and terminal.cols or nil
        local rows = type(terminal.rows) == "number" and terminal.rows > 0 and terminal.rows or nil
        if cols and rows then
          sizes[address] = { cols = cols, rows = rows }
        end

        local tool = resolve_tool(terminal)
        if tool then
          local fg = type(terminal.foreground) == "table" and terminal.foreground or {}
          local status = type(terminal.status) == "table" and terminal.status or nil
          local id = "hc " .. address
          sessions[#sessions + 1] = {
            agent_status = status and nonempty(status.state) or nil,
            cwd = nonempty(fg.cwd) or nonempty(terminal.cwd),
            external = true,
            hc_address = address,
            hc_cols = cols,
            hc_rows = rows,
            hc_space = space,
            hc_tab = tab,
            id = id,
            priority = 100,
            tool = tool,
          }
          live[id] = true
        end
      end
    end
  end

  return sessions
end

--- Return cached space/tab labels for a terminal address from the last list.
---@param address? string
---@return { space?: string, tab?: string }
function M.context(address)
  return address and context[address] or {}
end

---@param text string
---@param callback? fun(ok:boolean, error?:string)
function M:send(text, callback)
  if not self.hc_address then
    Util.error("Session is missing hc terminal address")
    return
  end
  local size = sizes[self.hc_address]
  M.send_bytes(self.hc_address, bracketed_paste(text), {
    cols = (size and size.cols) or self.hc_cols,
    rows = (size and size.rows) or self.hc_rows,
    callback = callback,
  })
end

---@param callback? fun(ok:boolean, error?:string)
function M:submit(callback)
  if not self.hc_address then
    Util.error("Session is missing hc terminal address")
    return
  end
  local size = sizes[self.hc_address]
  M.send_bytes(self.hc_address, "\r", {
    cols = (size and size.cols) or self.hc_cols,
    rows = (size and size.rows) or self.hc_rows,
    callback = callback,
  })
end

function M:dump()
  if not self.hc_address then
    return
  end
  local path = M.socket_path()
  if not path then
    return
  end
  local _, stdout = Util.exec({
    "hc",
    "read",
    self.hc_address,
    "--lines",
    tostring(DUMP_LINES),
  }, {
    notify = false,
    env = { HC_SOCKET = path },
  })
  return stdout
end

---@param session sidekick.cli.session.State
function M.focus(session)
  local address = session and session.hc_address
  if not address then
    Util.warn("Session is not running in an hc terminal")
    return false
  end
  if vim.env.TMX_SCRATCH == "1" and vim.env.TMX_PARENT_PANE == address then
    local kind = SCRATCH_KIND[vim.env.TMX_SCRATCH_TYPE or ""]
    if kind then
      return Util.exec({ "herdr-app", "do", "shadowfax.scratch_" .. kind }, { notify = false }) ~= nil
    end
  end
  return Util.exec({ "herdr-app", "do", "agent.focus", "--terminal", address }, { notify = false }) ~= nil
end

function M._reset()
  if active then
    close_connection(active)
  end
  queue = {}
  M._timeout = nil
  context = {}
  live = {}
  sizes = {}
end

return M
