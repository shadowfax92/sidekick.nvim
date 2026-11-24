local Config = require("sidekick.config")
local Util = require("sidekick.util")

---@class sidekick.cli.muxer.Hc: sidekick.cli.Session
---@field hc_address string
---@field hc_space? string
---@field hc_tab? string
---@field _list_timeout? integer list timeout override for tests, in ms
---@field _timeout? integer per-request timeout override for tests, in ms
local M = {}
M.__index = M

local FRAME_HEADER = 9
local FRAME_MAX_PAYLOAD = 16 * 1024 * 1024
local FRAME_DATA = 0
local FRAME_CLOSE = 2
local HELLO_ID = 1
local ATTACH_ID = 2
local LIST_TIMEOUT_MS = 1000
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

---@class sidekick.hc.Stream
---@field pipe uv.uv_pipe_t
---@field timer uv.uv_timer_t
---@field close fun(self:sidekick.hc.Stream)
---@field write fun(self:sidekick.hc.Stream, data:string)

---@class sidekick.hc.SendRequest
---@field address string
---@field data string
---@field callback? fun(ok:boolean, error?:string)

---@class sidekick.hc.Connection
---@field request sidekick.hc.SendRequest
---@field stream? sidekick.hc.Stream
---@field buffer string
---@field phase "hello"|"attach"|"closing"
---@field channel? integer

local live = {} ---@type table<string, boolean>
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

---@return { name: string, tool: sidekick.cli.Tool }[]
local function ordered_tools()
  local tools = Config.tools()
  local names = vim.tbl_keys(tools)
  table.sort(names)
  local ret = {} ---@type { name: string, tool: sidekick.cli.Tool }[]
  for _, name in ipairs(names) do
    ret[#ret + 1] = { name = name, tool = tools[name] }
  end
  return ret
end

--- Match tool patterns against the foreground program name only (`basename(argv[1])`),
--- never arguments, so editing e.g. `vim notes/gemini.md` does not match `gemini`.
---@param fg any
---@param pid any
---@param tools { name: string, tool: sidekick.cli.Tool }[]
---@return string?
local function match_foreground_tool(fg, pid, tools)
  if type(fg) ~= "table" or type(fg.argv) ~= "table" then
    return nil
  end
  local first = nonempty(fg.argv[1])
  if not first then
    return nil
  end
  local prog = vim.fs.basename(first)
  if not prog or prog == "" then
    return nil
  end
  local proc = {
    pid = type(fg.pid) == "number" and fg.pid or 0,
    ppid = type(pid) == "number" and pid or 0,
    cmd = prog,
    cwd = nonempty(fg.cwd),
  }
  for _, entry in ipairs(tools) do
    if entry.tool:is_proc(proc) then
      return entry.name
    end
  end
end

---@param terminal table
---@param get_tools fun(): { name: string, tool: sidekick.cli.Tool }[]
---@return string?
local function resolve_tool(terminal, get_tools)
  local status = type(terminal.status) == "table" and terminal.status or nil
  if status then
    return M.map_tool(status.app) or match_foreground_tool(terminal.foreground, terminal.pid, get_tools())
  end
  return match_foreground_tool(terminal.foreground, terminal.pid, get_tools())
end

--- Wrap text in bracketed paste markers, stripping any embedded end marker so pasted
--- text cannot break out early.
---@param text string
---@return string
local function bracketed_paste(text)
  return "\27[200~" .. text:gsub("\27%[201~", "") .. "\27[201~"
end

--- Shared Unix-socket connect, timeout, read, and close wrapper for `M.list` and sends.
---@param path string
---@param opts { timeout: integer, initial: string, on_data: fun(stream:sidekick.hc.Stream, data:string), on_eof: fun(stream:sidekick.hc.Stream), on_error: fun(stream:sidekick.hc.Stream, err:string) }
---@return sidekick.hc.Stream
local function open_stream(path, opts)
  local pipe = assert(vim.uv.new_pipe(false))
  local timer = assert(vim.uv.new_timer())
  local closed = false

  local stream = { pipe = pipe, timer = timer } ---@type sidekick.hc.Stream

  function stream:close()
    if closed then
      return
    end
    closed = true
    if not timer:is_closing() then
      timer:close()
    end
    if not pipe:is_closing() then
      pipe:close()
    end
  end

  local function fail_stream(msg)
    if closed then
      return
    end
    stream:close()
    opts.on_error(stream, msg)
  end

  function stream:write(data)
    if closed then
      return
    end
    pipe:write(data, function(write_err)
      if write_err then
        fail_stream("hc socket write failed: " .. write_err)
      end
    end)
  end

  timer:start(opts.timeout, 0, function()
    fail_stream("hc request timed out")
  end)

  local ok_conn, conn_err = pipe:connect(path, function(err)
    if closed then
      return
    end
    if err then
      return fail_stream("Could not connect to hc: " .. err)
    end
    pipe:read_start(function(read_err, data)
      if closed then
        return
      end
      if read_err then
        return fail_stream("hc socket read failed: " .. read_err)
      end
      if not data then
        stream:close()
        opts.on_eof(stream)
        return
      end
      opts.on_data(stream, data)
    end)
    stream:write(opts.initial)
  end)
  if ok_conn == nil then
    fail_stream("Could not connect to hc: " .. tostring(conn_err))
  end

  return stream
end

--- Query `terminal.list` directly over the herdr-core socket so discovery never spawns
--- `hc` (which would autostart a core if none is listening).
---@return table[]?
function M.list()
  local path = M.socket_path()
  if not path then
    return nil
  end
  local done = false
  local terminals ---@type table[]?
  local buffer = ""

  local function finish(result)
    if done then
      return
    end
    done = true
    terminals = result
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

  local timeout = M._list_timeout or M._timeout or LIST_TIMEOUT_MS
  local stream = open_stream(path, {
    timeout = timeout,
    initial = '{"jsonrpc":"2.0","id":1,"method":"terminal.list","params":{}}\n',
    on_data = function(s, data)
      buffer = buffer .. data
      local stop = buffer:find("\n", 1, true)
      if stop then
        s:close()
        handle_line(buffer:sub(1, stop - 1))
      end
    end,
    on_eof = function()
      if buffer ~= "" then
        handle_line(buffer)
      else
        finish(nil)
      end
    end,
    on_error = function()
      finish(nil)
    end,
  })

  vim.wait(timeout + 100, function()
    return done
  end, 5)
  stream:close()
  return terminals
end

--[[
herdr-core framed paste transport.

`terminal.send` always waits for quiet and submits with Enter, so pasting without
submitting opens one framed connection per send:

  connect -> plain `hello {framed:true}` -> wait reply line (`framed:true`)
          -> framed ch0 `terminal.attach {terminal, cols:0, rows:0, resumed:true}`
          -> wait ch0 reply matching id -> ch DATA (payload) + ch CLOSE
          -> wait empty ch CLOSE ack -> close

Passing 0x0 tells herdr-core to ignore our viewer size (`viewers.rs`), so a send
never resizes the agent. Requests are serialized one at a time on a queue, matching
`herdr.lua`, so `submit()` never overtakes the `send()` text ahead of it.
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
  if conn.stream then
    conn.stream:close()
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

---@param payload string
---@return string
local function close_reason(payload)
  local ok, info = pcall(vim.json.decode, payload)
  if ok and type(info) == "table" and nonempty(info.reason) then
    return info.reason
  end
  return payload
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
        if reply.id == ATTACH_ID then
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
          conn.stream:write(frames)
        end
      end
    elseif conn.phase == "closing" then
      if ch == conn.channel and kind == FRAME_CLOSE then
        if payload ~= "" then
          return finish_request(conn, false, "hc terminal closed: " .. close_reason(payload))
        end
        return finish_request(conn, true)
      end
    end
  end
end

---@param conn sidekick.hc.Connection
---@param data string
local function on_send_data(conn, data)
  if active ~= conn then
    return
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
    if type(reply.result) ~= "table" or reply.result.framed ~= true then
      return fail(conn, "hc did not switch to framed mode")
    end
    conn.phase = "attach"
    local attach = vim.json.encode({
      jsonrpc = "2.0",
      id = ATTACH_ID,
      method = "terminal.attach",
      params = {
        terminal = conn.request.address,
        cols = 0,
        rows = 0,
        resumed = true,
      },
    })
    conn.stream:write(M.encode_frame(0, FRAME_DATA, attach))
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
    buffer = "",
    phase = "hello",
  } ---@type sidekick.hc.Connection
  active = conn
  conn.stream = open_stream(path, {
    timeout = M._timeout or REQUEST_TIMEOUT_MS,
    initial = ('{"jsonrpc":"2.0","id":%d,"method":"hello","params":{"framed":true}}\n'):format(HELLO_ID),
    on_data = function(_, data)
      on_send_data(conn, data)
    end,
    on_eof = function()
      if active == conn then
        fail(conn, "hc socket connection closed before completion")
      end
    end,
    on_error = function(_, err)
      if active == conn then
        fail(conn, err)
      end
    end,
  })
end

---@param address string
---@param data string
---@param opts? { callback?: fun(ok:boolean, error?:string) }
function M.send_bytes(address, data, opts)
  opts = opts or {}
  queue[#queue + 1] = {
    address = address,
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
  context = {}
  if type(terminals) ~= "table" then
    return {}
  end

  local cached_tools ---@type { name: string, tool: sidekick.cli.Tool }[]?
  local function get_tools()
    if not cached_tools then
      cached_tools = ordered_tools()
    end
    return cached_tools
  end

  local sessions = {} ---@type sidekick.cli.session.State[]
  for _, terminal in ipairs(terminals) do
    if type(terminal) == "table" and terminal.state == "live" then
      local address = nonempty(terminal.address)
      -- Skip remote machines' terminals (`machine/t7`) so local project-scope
      -- matching can never route to an agent on another host with the same path.
      if address and not address:find("/", 1, true) then
        local labels = type(terminal.labels) == "table" and terminal.labels or {}
        local space = nonempty(labels["herdr.space"])
        local tab = nonempty(labels["herdr.tab"])
        if space or tab then
          context[address] = { space = space, tab = tab }
        end

        local tool = resolve_tool(terminal, get_tools)
        if tool then
          local fg = type(terminal.foreground) == "table" and terminal.foreground or {}
          local status = type(terminal.status) == "table" and terminal.status or nil
          local id = "hc " .. address
          sessions[#sessions + 1] = {
            agent_status = status and nonempty(status.state) or nil,
            cwd = nonempty(fg.cwd) or nonempty(terminal.cwd),
            external = true,
            hc_address = address,
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
  M.send_bytes(self.hc_address, bracketed_paste(text), { callback = callback })
end

---@param callback? fun(ok:boolean, error?:string)
function M:submit(callback)
  if not self.hc_address then
    Util.error("Session is missing hc terminal address")
    return
  end
  M.send_bytes(self.hc_address, "\r", { callback = callback })
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
  M._list_timeout = nil
  M._timeout = nil
  context = {}
  live = {}
end

return M
