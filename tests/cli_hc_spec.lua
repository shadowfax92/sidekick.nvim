---@module 'luassert'

local Affinity = require("sidekick.cli.affinity")
local Config = require("sidekick.config")
local Hc = require("sidekick.cli.session.hc")
local Session = require("sidekick.cli.session")
local State = require("sidekick.cli.state")
local Tmux = require("sidekick.cli.session.tmux")
local Util = require("sidekick.util")

local FRAME_DATA = 0
local FRAME_CLOSE = 2

local function terminal(overrides)
  local ret = vim.tbl_deep_extend("force", {
    address = "t3r",
    argv = { "/opt/homebrew/bin/fish", "-l" },
    cols = 237,
    cwd = "/Users/shadowfax",
    foreground = {
      argv = { "/Users/shadowfax/.local/bin/claude", "--resume", "abc" },
      cwd = "/Users/shadowfax/proj",
      name = "2.1.331",
      pid = 95377,
    },
    labels = {
      ["herdr.space"] = "sp-main",
      ["herdr.tab"] = "tb-6",
      where = "~ / 6",
    },
    pid = 16270,
    rows = 70,
    state = "live",
    status = {
      app = "claude-code",
      state = "done",
    },
  }, overrides or {})
  if overrides and overrides.labels ~= nil then
    ret.labels = overrides.labels
  end
  if overrides and overrides.foreground ~= nil then
    ret.foreground = overrides.foreground
  end
  return ret
end

describe("hc sessions", function()
  local env_keys = {
    "HC_SOCKET",
    "HC_TERMINAL_ID",
    "HC_TERMINAL_SOCKET",
    "HERDR_BIN_PATH",
    "TMX_PARENT_PANE",
    "TMX_SCRATCH",
    "TMX_SCRATCH_TYPE",
  }
  local original_env = {}
  local original_list
  local original_exec
  local original_warn
  local original_error
  local original_did_setup
  local original_backends
  local original_tools
  local warnings
  local errors

  before_each(function()
    for _, key in ipairs(env_keys) do
      original_env[key] = vim.env[key]
      vim.env[key] = nil
    end
    original_list = Hc.list
    original_exec = Util.exec
    original_warn = Util.warn
    original_error = Util.error
    original_did_setup = Session.did_setup
    original_backends = Session.backends
    original_tools = Config.tools
    warnings = {}
    errors = {}
    Util.warn = function(message)
      warnings[#warnings + 1] = message
    end
    Util.error = function(message)
      errors[#errors + 1] = message
    end
    Hc._reset()
  end)

  after_each(function()
    Hc.list = original_list
    Hc._reset()
    Util.exec = original_exec
    Util.warn = original_warn
    Util.error = original_error
    Session.did_setup = original_did_setup
    Session.backends = original_backends
    Config.tools = original_tools
    for _, key in ipairs(env_keys) do
      vim.env[key] = original_env[key]
    end
  end)

  for _, case in ipairs({
    { name = "none set", hc_socket = nil, term_socket = nil, expected = nil },
    { name = "empty strings", hc_socket = "", term_socket = "", expected = nil },
    { name = "HC_TERMINAL_SOCKET only", hc_socket = nil, term_socket = "/tmp/term.sock", expected = "/tmp/term.sock" },
    { name = "HC_SOCKET only", hc_socket = "/tmp/override.sock", term_socket = nil, expected = "/tmp/override.sock" },
    {
      name = "HC_SOCKET takes precedence over HC_TERMINAL_SOCKET",
      hc_socket = "/tmp/override.sock",
      term_socket = "/tmp/term.sock",
      expected = "/tmp/override.sock",
    },
  }) do
    it("resolves socket path and registration: " .. case.name, function()
      vim.env.HC_SOCKET = case.hc_socket
      vim.env.HC_TERMINAL_SOCKET = case.term_socket
      assert.are.equal(case.expected, Hc.socket_path())

      Session.did_setup = false
      Session.backends = {}
      Session.setup()
      assert.are.equal(case.expected ~= nil, Session.backends.hc ~= nil)
    end)
  end

  for _, case in ipairs({
    { app = "claude-code", expected = "claude" },
    { app = "cursor-agent", expected = "cursor" },
    { app = "codex", expected = "codex" },
    { app = "pi", expected = "pi" },
    { app = "opencode", expected = "opencode" },
    { app = "custom-agent", expected = "custom-agent" },
    { app = "", expected = nil },
    { app = nil, expected = nil },
    { app = vim.NIL, expected = nil },
  }) do
    it("maps status.app " .. tostring(case.app) .. " -> " .. tostring(case.expected), function()
      assert.are.equal(case.expected, Hc.map_tool(case.app))
    end)
  end

  for _, case in ipairs({
    {
      name = "live agent reporting claude-code status",
      entry = terminal(),
      expected = {
        agent_status = "done",
        cwd = "/Users/shadowfax/proj",
        external = true,
        hc_address = "t3r",
        hc_space = "sp-main",
        hc_tab = "tb-6",
        id = "hc t3r",
        priority = 100,
        tool = "claude",
      },
    },
    {
      name = "live agent reporting cursor-agent status",
      entry = terminal({
        address = "t4a",
        status = { app = "cursor-agent", state = "working" },
      }),
      expected = {
        agent_status = "working",
        cwd = "/Users/shadowfax/proj",
        external = true,
        hc_address = "t4a",
        hc_space = "sp-main",
        hc_tab = "tb-6",
        id = "hc t4a",
        priority = 100,
        tool = "cursor",
      },
    },
    {
      name = "live terminal without status matched by foreground program name",
      entry = terminal({
        address = "t5b",
        status = vim.NIL,
        foreground = {
          argv = { "/opt/homebrew/bin/codex", "--yolo" },
          cwd = "/repo/codex",
          name = "codex",
          pid = 555,
        },
        labels = { ["herdr.space"] = "sp-2", ["herdr.tab"] = "tb-2" },
      }),
      expected = {
        cwd = "/repo/codex",
        external = true,
        hc_address = "t5b",
        hc_space = "sp-2",
        hc_tab = "tb-2",
        id = "hc t5b",
        priority = 100,
        tool = "codex",
      },
    },
    {
      name = "live terminal with empty status.app falls back to foreground program name",
      entry = terminal({
        address = "t6c",
        status = { app = "", state = "working" },
        foreground = {
          argv = { "/Users/shadowfax/.local/bin/claude" },
          cwd = vim.NIL,
        },
        cwd = "/repo/fallback",
        labels = {},
      }),
      expected = {
        agent_status = "working",
        cwd = "/repo/fallback",
        external = true,
        hc_address = "t6c",
        id = "hc t6c",
        priority = 100,
        tool = "claude",
      },
    },
    {
      name = "live terminal running gemini executable matches gemini",
      entry = terminal({
        address = "t6g",
        status = vim.NIL,
        foreground = {
          argv = { "/opt/homebrew/bin/gemini", "--model", "pro" },
          cwd = "/repo/app",
          pid = 600,
        },
        labels = {},
      }),
      expected = {
        cwd = "/repo/app",
        external = true,
        hc_address = "t6g",
        id = "hc t6g",
        priority = 100,
        tool = "gemini",
      },
    },
    {
      name = "vim editing notes/gemini.md does not match gemini",
      entry = terminal({
        address = "t7v",
        status = vim.NIL,
        foreground = {
          argv = { "/opt/homebrew/bin/vim", "notes/gemini.md" },
          cwd = "/repo/app",
          pid = 701,
        },
        labels = {},
      }),
      expected = nil,
    },
    {
      name = "tool name in executable parent directory does not match",
      entry = terminal({
        address = "t7p",
        status = vim.NIL,
        foreground = {
          argv = { "/Users/me/gemini/bin/vim", "README.md" },
          cwd = "/repo/app",
          pid = 702,
        },
        labels = {},
      }),
      expected = nil,
    },
    {
      name = "copilot-language-server is filtered out",
      entry = terminal({
        address = "t7l",
        status = vim.NIL,
        foreground = {
          argv = { "/usr/local/bin/copilot-language-server", "--stdio" },
          cwd = "/repo/app",
          pid = 703,
        },
        labels = {},
      }),
      expected = nil,
    },
    {
      name = "live plain shell is filtered out",
      entry = terminal({
        address = "t7d",
        status = vim.NIL,
        foreground = {
          argv = { "/opt/homebrew/bin/fish", "-l" },
          cwd = "/Users/shadowfax",
          name = "fish",
          pid = 777,
        },
      }),
      expected = nil,
    },
    {
      name = "live scratch tmux terminal is filtered out",
      entry = terminal({
        address = "t6x",
        status = vim.NIL,
        foreground = {
          argv = { "tmux", "-L", "herdr-scratch", "new-session", "-A", "-s", "nvim-t3r", "nvim" },
          cwd = "/Users/shadowfax",
          name = "tmux",
          pid = 4021,
        },
        labels = {},
      }),
      expected = nil,
    },
    {
      name = "finished terminal is filtered out even with status",
      entry = terminal({
        address = "t8e",
        state = "finished",
      }),
      expected = nil,
    },
    {
      name = "remote machine terminal address with slash is skipped",
      entry = terminal({
        address = "studio/t7",
        cwd = "/Users/shadowfax",
        foreground = {
          argv = { "/Users/shadowfax/.local/bin/claude" },
          cwd = "/Users/shadowfax",
          pid = 999,
        },
        status = { app = "claude-code", state = "done" },
      }),
      expected = nil,
    },
  }) do
    it("filters and maps terminal: " .. case.name, function()
      Hc.list = function()
        return { case.entry }
      end
      local sessions = Hc.sessions()
      if case.expected then
        assert.are.equal(1, #sessions)
        assert.are.same(case.expected, sessions[1])
        assert.is_true(setmetatable(sessions[1], Hc):is_running())
      else
        assert.are.same({}, sessions)
      end
    end)
  end

  it("builds the tool list at most once per sessions() call", function()
    local calls = 0
    Config.tools = function()
      calls = calls + 1
      return original_tools()
    end
    Hc.list = function()
      return {
        terminal({ address = "t1", status = vim.NIL, foreground = { argv = { "fish" } } }),
        terminal({ address = "t2", status = vim.NIL, foreground = { argv = { "vim", "notes/gemini.md" } } }),
        terminal({ address = "t3", status = vim.NIL, foreground = { argv = { "/usr/local/bin/codex" } } }),
      }
    end
    local sessions = Hc.sessions()
    assert.are.equal(1, #sessions)
    assert.are.equal("hc t3", sessions[1].id)
    assert.are.equal(1, calls)
  end)

  it("tracks is_running membership against the latest list", function()
    Hc.list = function()
      return { terminal({ address = "t3r" }) }
    end
    local session = setmetatable(Hc.sessions()[1], Hc)
    assert.is_true(session:is_running())

    Hc.list = function()
      return { terminal({ address = "t9z" }) }
    end
    Hc.sessions()
    assert.is_false(session:is_running())
  end)

  for _, case in ipairs({
    {
      name = "scratch parent with vim scratch hides nvim popup",
      env = { TMX_SCRATCH = "1", TMX_PARENT_PANE = "t3r", TMX_SCRATCH_TYPE = "vim" },
      target = { hc_address = "t3r" },
      expected = { "herdr-app", "do", "shadowfax.scratch_nvim" },
    },
    {
      name = "scratch parent with sh scratch hides shell popup",
      env = { TMX_SCRATCH = "1", TMX_PARENT_PANE = "t3r", TMX_SCRATCH_TYPE = "sh" },
      target = { hc_address = "t3r" },
      expected = { "herdr-app", "do", "shadowfax.scratch_shell" },
    },
    {
      name = "other terminal from inside scratch uses agent.focus",
      env = { TMX_SCRATCH = "1", TMX_PARENT_PANE = "t3r", TMX_SCRATCH_TYPE = "vim" },
      target = { hc_address = "t9x" },
      expected = { "herdr-app", "do", "agent.focus", "--terminal", "t9x" },
    },
    {
      name = "outside scratch uses agent.focus",
      env = {},
      target = { hc_address = "t3r" },
      expected = { "herdr-app", "do", "agent.focus", "--terminal", "t3r" },
    },
  }) do
    it("focuses hc terminal: " .. case.name, function()
      for k, v in pairs(case.env) do
        vim.env[k] = v
      end
      local command
      Util.exec = function(cmd)
        command = cmd
        return {}
      end
      assert.is_true(Hc.focus(case.target))
      assert.are.same(case.expected, command)
    end)
  end

  it("warns and returns false when focusing a session without hc_address", function()
    Util.exec = function()
      error("should not run herdr-app")
    end
    assert.is_false(Hc.focus({}))
    assert.are.equal(1, #warnings)
  end)
end)

describe("hc frame encoding", function()
  for _, case in ipairs({
    {
      name = "channel 0 DATA with JSON payload",
      channel = 0,
      kind = FRAME_DATA,
      payload = '{"ok":true}',
      header_bytes = { 0, 0, 0, 0, 0, 11, 0, 0, 0 },
    },
    {
      name = "channel 1 DATA with bracketed paste",
      channel = 1,
      kind = FRAME_DATA,
      payload = "\27[200~hi\27[201~",
      header_bytes = { 1, 0, 0, 0, 0, 14, 0, 0, 0 },
    },
    {
      name = "multi-byte channel LE and CLOSE with empty payload",
      channel = 0x01020304,
      kind = FRAME_CLOSE,
      payload = "",
      header_bytes = { 4, 3, 2, 1, 2, 0, 0, 0, 0 },
    },
    {
      name = "multi-byte payload length LE",
      channel = 7,
      kind = FRAME_DATA,
      payload = string.rep("x", 300),
      header_bytes = { 7, 0, 0, 0, 0, 44, 1, 0, 0 },
    },
  }) do
    it("encodes and round-trips: " .. case.name, function()
      local encoded = Hc.encode_frame(case.channel, case.kind, case.payload)
      assert.are.equal(9 + #case.payload, #encoded)
      assert.are.same(case.header_bytes, { encoded:byte(1, 9) })
      assert.are.equal(case.payload, encoded:sub(10))

      local ch, kind, payload, rest = Hc.decode_frame(encoded .. "tail")
      assert.are.equal(case.channel, ch)
      assert.are.equal(case.kind, kind)
      assert.are.equal(case.payload, payload)
      assert.are.equal("tail", rest)
    end)
  end

  it("handles incomplete frames and rejects oversized headers", function()
    local frame = Hc.encode_frame(1, FRAME_DATA, "hello")
    assert.is_nil(Hc.decode_frame(frame:sub(1, 4)))
    assert.is_nil(Hc.decode_frame(frame:sub(1, 11)))

    local huge = string.char(0, 0, 0, 0, 0, 0xff, 0xff, 0xff, 0x7f)
    local ch, err = Hc.decode_frame(huge)
    assert.is_nil(ch)
    assert.is_truthy(err and err:find("exceeds", 1, true))
  end)
end)

describe("hc socket transport", function()
  local env_keys = { "HC_SOCKET", "HC_TERMINAL_SOCKET" }
  local original_env = {}
  local original_error
  local errors
  local server

  ---@param opts? {mode?: "normal"|"silent"|"close"|"close_on_data"|"hello_error"|"hello_unframed"|"attach_error"|"close_reason", terminals?: table[], first_paint?: string, stray_ch0?: table}
  local function start_server(opts)
    opts = opts or {}
    local path = vim.fn.tempname() .. ".sock"
    local listener = assert(vim.uv.new_pipe(false))
    assert(listener:bind(path))
    local srv = {
      path = path,
      listener = listener,
      connections = 0,
      events = {},
      clients = {},
    }
    assert(listener:listen(16, function(err)
      assert(not err, err)
      local conn = assert(vim.uv.new_pipe(false))
      listener:accept(conn)
      srv.connections = srv.connections + 1
      local index = srv.connections
      srv.clients[#srv.clients + 1] = conn
      local buffer = ""
      local framed = false
      local next_ch = 0
      local attached = {}

      conn:read_start(function(read_err, data)
        if read_err or not data then
          if not conn:is_closing() then
            conn:close()
          end
          return
        end
        buffer = buffer .. data
        if not framed then
          local stop = buffer:find("\n", 1, true)
          if not stop then
            return
          end
          local line = buffer:sub(1, stop - 1)
          buffer = buffer:sub(stop + 1)
          local req = vim.json.decode(line)
          srv.events[#srv.events + 1] = { connection = index, kind = "plain", request = req }
          if opts.mode == "silent" then
            return
          end
          if opts.mode == "close" then
            conn:close()
            return
          end
          if req.method == "terminal.list" then
            local reply = vim.json.encode({
              jsonrpc = "2.0",
              id = req.id,
              result = { terminals = opts.terminals or {}, hidden_finished = 0, machines = {} },
            }) .. "\n"
            conn:write(reply)
            return
          end
          if req.method == "hello" then
            if opts.mode == "hello_error" then
              local reply = vim.json.encode({
                jsonrpc = "2.0",
                id = req.id,
                error = { code = -32000, message = "unsupported_generation" },
              }) .. "\n"
              conn:write(reply)
              return
            end
            if opts.mode == "hello_unframed" then
              local reply = vim.json.encode({
                jsonrpc = "2.0",
                id = req.id,
                result = { framed = false },
              }) .. "\n"
              conn:write(reply)
              return
            end
            local reply = vim.json.encode({
              jsonrpc = "2.0",
              id = req.id,
              result = { framed = req.params and req.params.framed == true },
            }) .. "\n"
            framed = req.params and req.params.framed == true
            conn:write(reply)
          end
        end

        while framed do
          local ch, kind, payload, rest = Hc.decode_frame(buffer)
          if not ch then
            return
          end
          buffer = rest
          if ch == 0 and kind == FRAME_DATA then
            local req = vim.json.decode(payload)
            srv.events[#srv.events + 1] = { connection = index, kind = "rpc", request = req }
            if req.method == "terminal.attach" then
              if opts.mode == "attach_error" and index == 1 then
                local reply = vim.json.encode({
                  jsonrpc = "2.0",
                  id = req.id,
                  error = { code = -32000, message = "not_found" },
                })
                conn:write(Hc.encode_frame(0, FRAME_DATA, reply))
              else
                next_ch = next_ch + 1
                attached[next_ch] = req.params.terminal
                local out = ""
                if opts.stray_ch0 then
                  out = out .. Hc.encode_frame(0, FRAME_DATA, vim.json.encode(opts.stray_ch0))
                end
                local reply = vim.json.encode({
                  jsonrpc = "2.0",
                  id = req.id,
                  result = { channel = next_ch },
                })
                out = out .. Hc.encode_frame(0, FRAME_DATA, reply)
                if opts.first_paint then
                  out = out .. Hc.encode_frame(next_ch, FRAME_DATA, opts.first_paint)
                end
                conn:write(out)
              end
            end
          elseif kind == FRAME_DATA then
            srv.events[#srv.events + 1] = {
              connection = index,
              kind = "data",
              channel = ch,
              terminal = attached[ch],
              data = payload,
            }
            if opts.mode == "close_on_data" then
              conn:close()
              return
            end
          elseif kind == FRAME_CLOSE then
            srv.events[#srv.events + 1] = {
              connection = index,
              kind = "close",
              channel = ch,
              terminal = attached[ch],
            }
            if opts.mode == "close_reason" and index == 1 then
              conn:write(Hc.encode_frame(ch, FRAME_CLOSE, '{"reason":"exited"}'))
            else
              conn:write(Hc.encode_frame(ch, FRAME_CLOSE, ""))
            end
          end
        end
      end)
    end))
    return srv
  end

  local function stop_server()
    if not server then
      return
    end
    for _, conn in ipairs(server.clients) do
      if not conn:is_closing() then
        conn:close()
      end
    end
    if not server.listener:is_closing() then
      server.listener:close()
    end
    vim.fn.delete(server.path)
    server = nil
  end

  before_each(function()
    for _, key in ipairs(env_keys) do
      original_env[key] = vim.env[key]
      vim.env[key] = nil
    end
    original_error = Util.error
    errors = {}
    Util.error = function(message)
      errors[#errors + 1] = message
    end
    Hc._reset()
  end)

  after_each(function()
    Hc._reset()
    stop_server()
    Util.error = original_error
    for _, key in ipairs(env_keys) do
      vim.env[key] = original_env[key]
    end
  end)

  it("lists local terminals over the real socket and skips remote ones", function()
    server = start_server({
      terminals = {
        terminal({ address = "t3r" }),
        terminal({ address = "studio/t7" }),
      },
    })
    vim.env.HC_TERMINAL_SOCKET = server.path

    local sessions = Hc.sessions()
    assert.are.equal(1, #sessions)
    assert.are.equal("hc t3r", sessions[1].id)
    assert.are.equal("claude", sessions[1].tool)
  end)

  it("returns empty sessions promptly when the core socket is absent", function()
    vim.env.HC_SOCKET = vim.fn.tempname() .. "/missing.sock"
    local start = vim.uv.hrtime()
    assert.are.same({}, Hc.sessions())
    local elapsed_ms = (vim.uv.hrtime() - start) / 1e6
    assert.is_true(elapsed_ms < 500)
  end)

  it("times out a silent core during listing without freezing Neovim", function()
    server = start_server({ mode = "silent" })
    vim.env.HC_SOCKET = server.path
    Hc._list_timeout = 150
    local start = vim.uv.hrtime()
    assert.are.same({}, Hc.sessions())
    local elapsed_ms = (vim.uv.hrtime() - start) / 1e6
    assert.is_true(elapsed_ms < 1000)
    assert.are.equal(1, server.connections)
  end)

  it("serializes bracketed send then submit at 0x0 size and matches attach reply by id", function()
    server = start_server({
      terminals = { terminal({ address = "t3r", cols = 237, rows = 70 }) },
      first_paint = "\27[2Jprompt> ",
      stray_ch0 = { jsonrpc = "2.0", id = 999, result = { channel = 99 } },
    })
    vim.env.HC_TERMINAL_SOCKET = server.path
    local session = setmetatable(Hc.sessions()[1], Hc)

    local results = {}
    session:send("hello \27[201~world\n", function(ok)
      results[1] = ok
    end)
    session:submit(function(ok)
      results[2] = ok
    end)

    assert.is_true(vim.wait(3000, function()
      return results[1] == true and results[2] == true
    end))
    assert.are.same({}, errors)
    assert.are.equal(3, server.connections) -- 1 list + 2 serialized sends

    local data_events = vim.tbl_filter(function(ev)
      return ev.kind == "data"
    end, server.events)
    assert.are.same({
      { connection = 2, kind = "data", channel = 1, terminal = "t3r", data = "\27[200~hello world\n\27[201~" },
      { connection = 3, kind = "data", channel = 1, terminal = "t3r", data = "\r" },
    }, data_events)

    local attach_events = vim.tbl_filter(function(ev)
      return ev.kind == "rpc" and ev.request.method == "terminal.attach"
    end, server.events)
    assert.are.equal(2, #attach_events)
    for _, ev in ipairs(attach_events) do
      assert.are.same({
        terminal = "t3r",
        cols = 0,
        rows = 0,
        resumed = true,
      }, ev.request.params)
    end
  end)

  for _, case in ipairs({
    {
      name = "close after hello",
      mode = "close",
      expected_err = "hc socket connection closed before completion",
    },
    {
      name = "close mid-send after DATA",
      mode = "close_on_data",
      expected_err = "hc socket connection closed before completion",
    },
    {
      name = "hello JSON-RPC error",
      mode = "hello_error",
      expected_err = "hc hello failed: unsupported_generation",
    },
    {
      name = "hello without framed:true",
      mode = "hello_unframed",
      expected_err = "hc did not switch to framed mode",
    },
  }) do
    it("fails and drops the queue without replay on " .. case.name, function()
      server = start_server({ mode = case.mode })
      vim.env.HC_SOCKET = server.path
      local errs = {}
      Hc.send_bytes("t3r", "a", {
        callback = function(_, err)
          errs[1] = err
        end,
      })
      Hc.send_bytes("t3r", "\r", {
        callback = function(_, err)
          errs[2] = err
        end,
      })

      assert.is_true(vim.wait(2000, function()
        return errs[1] ~= nil and errs[2] ~= nil
      end))
      assert.are.equal(case.expected_err, errs[1])
      assert.are.equal(errs[1], errs[2])
      assert.are.same({ case.expected_err }, errors)
      assert.are.equal(1, server.connections)
    end)
  end

  it("treats CLOSE carrying a reason as failure and keeps serving queued targets", function()
    server = start_server({ mode = "close_reason" })
    vim.env.HC_SOCKET = server.path
    local first_ok, first_err, second_ok
    Hc.send_bytes("t-ended", "a", {
      callback = function(ok, err)
        first_ok, first_err = ok, err
      end,
    })
    Hc.send_bytes("t3r", "b", {
      callback = function(ok)
        second_ok = ok
      end,
    })

    assert.is_true(vim.wait(2000, function()
      return first_ok ~= nil and second_ok == true
    end))
    assert.is_false(first_ok)
    assert.are.equal("hc terminal closed: exited", first_err)
    assert.are.same({}, errors)
  end)

  it("reports attach error and continues serving queued targets", function()
    server = start_server({ mode = "attach_error" })
    vim.env.HC_SOCKET = server.path
    local second_ok
    Hc.send_bytes("t-gone", "a")
    Hc.send_bytes("t3r", "b", {
      callback = function(ok)
        second_ok = ok
      end,
    })

    assert.is_true(vim.wait(2000, function()
      return second_ok == true
    end))
    assert.are.same({ "hc attach failed: not_found" }, errors)
  end)

  it("times out a silent server and drops queued requests with one error", function()
    server = start_server({ mode = "silent" })
    vim.env.HC_SOCKET = server.path
    Hc._timeout = 200
    local errs = {}
    Hc.send_bytes("t3r", "a", {
      callback = function(_, err)
        errs[1] = err
      end,
    })
    Hc.send_bytes("t3r", "\r", {
      callback = function(_, err)
        errs[2] = err
      end,
    })

    assert.is_true(vim.wait(2000, function()
      return errs[1] ~= nil and errs[2] ~= nil
    end))
    assert.are.equal("hc request timed out", errs[1])
    assert.are.equal(errs[1], errs[2])
    assert.are.same({ "hc request timed out" }, errors)
    assert.are.equal(1, server.connections)
  end)
end)

describe("hc scratch parent matching", function()
  local env_keys = {
    "HC_SOCKET",
    "HC_TERMINAL_ID",
    "HC_TERMINAL_SOCKET",
    "HERDR_BIN_PATH",
    "TMUX_PANE",
    "TMX_PARENT_PANE",
    "TMX_SCRATCH",
  }
  local original_env = {}
  local original_cwd
  local original_project
  local original_panes
  local original_list
  local original_tmx_scratch
  local original_sessions
  local original_attached
  local original_attach
  local original_detach
  local original_tools
  local original_notify

  before_each(function()
    for _, key in ipairs(env_keys) do
      original_env[key] = vim.env[key]
      vim.env[key] = nil
    end
    original_cwd = Session.cwd
    original_project = Affinity.project
    original_panes = Tmux.panes
    original_list = Hc.list
    original_tmx_scratch = Config.cli.mux.tmx_scratch
    original_sessions = Session.sessions
    original_attached = Session.attached
    original_attach = Session.attach
    original_detach = Session.detach
    original_tools = Config.tools
    original_notify = Util.notify

    Config.cli.mux.tmx_scratch = true
    Tmux.panes = function()
      return {}
    end
    Session.cwd = function()
      return "/repo/scratch"
    end
    Affinity.project = function(path)
      return { cwd = path }
    end
    Util.notify = function() end
    Hc._reset()
  end)

  after_each(function()
    Session.cwd = original_cwd
    Affinity.project = original_project
    Tmux.panes = original_panes
    Hc.list = original_list
    Config.cli.mux.tmx_scratch = original_tmx_scratch
    Session.sessions = original_sessions
    Session.attached = original_attached
    Session.attach = original_attach
    Session.detach = original_detach
    Config.tools = original_tools
    Util.notify = original_notify
    Hc._reset()
    Affinity.reset()
    for _, key in ipairs(env_keys) do
      vim.env[key] = original_env[key]
    end
  end)

  for _, case in ipairs({
    {
      name = "matches TMX_PARENT_PANE across projects and ignores stale HC_TERMINAL_ID",
      parent = "t3r",
      hc_terminal_id = "t6w",
      tmx_scratch = true,
      expected_id = "hc t3r",
    },
    {
      name = "attaches nothing passively when TMX_PARENT_PANE has no agent",
      parent = "t-shell",
      hc_terminal_id = "t6w",
      tmx_scratch = true,
      expected_id = nil,
    },
    {
      name = "falls back to cwd/project scoping when tmx_scratch is disabled",
      parent = "t3r",
      hc_terminal_id = "t6w",
      tmx_scratch = false,
      expected_id = "hc t6w",
    },
  }) do
    it(case.name, function()
      Config.cli.mux.tmx_scratch = case.tmx_scratch
      vim.env.TMX_SCRATCH = "1"
      vim.env.TMX_PARENT_PANE = case.parent
      vim.env.HC_TERMINAL_ID = case.hc_terminal_id

      Hc.list = function()
        return {
          terminal({
            address = "t3r",
            foreground = { argv = { "claude" }, cwd = "/repo/other-project" },
            status = { app = "claude-code", state = "done" },
            labels = { ["herdr.space"] = "sp-1", ["herdr.tab"] = "tb-1" },
          }),
          terminal({
            address = "t6w",
            foreground = { argv = { "codex" }, cwd = "/repo/scratch" },
            status = { app = "codex", state = "idle" },
            labels = { ["herdr.space"] = "sp-2", ["herdr.tab"] = "tb-2" },
          }),
        }
      end

      local discovered = {}
      for _, s in ipairs(Hc.sessions()) do
        s.backend = "hc"
        s.started = true
        s.tool = Config.get_tool(s.tool)
        s._attached = false
        s.is_attached = function(self)
          return self._attached
        end
        discovered[#discovered + 1] = s
      end

      Session.sessions = function()
        return discovered
      end
      Session.attached = function()
        return {}
      end
      Session.attach = function(s)
        s._attached = true
        return s
      end
      Session.detach = function(s)
        s._attached = false
        return s
      end
      Config.tools = function()
        return {}
      end

      local attached = State.auto_attach(nil, { multiple = true, scope = "project" })
      if case.expected_id then
        assert.are.equal(1, #attached)
        assert.are.equal(case.expected_id, attached[1].session.id)
      else
        assert.are.same({}, attached)
      end
    end)
  end
end)
