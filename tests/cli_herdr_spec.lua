---@module 'luassert'

local Config = require("sidekick.config")
local Herdr = require("sidekick.cli.session.herdr")
local Session = require("sidekick.cli.session")
local Util = require("sidekick.util")

local function snapshot()
  return {
    result = {
      snapshot = {
        focused_pane_id = "w2:p9",
        focused_tab_id = "w2:t4",
        focused_workspace_id = "w2",
        workspaces = {
          { workspace_id = "w2", label = "sidekick" },
        },
        tabs = {
          { tab_id = "w2:t4", workspace_id = "w2", label = "agents", number = 4 },
        },
        panes = {
          {
            pane_id = "w2:p9",
            tab_id = "w2:t4",
            workspace_id = "w2",
            label = "review",
            terminal_title_stripped = "codex",
          },
        },
        agents = {
          {
            agent = "codex",
            agent_status = "working",
            cwd = "/repo/sidekick",
            foreground_cwd = "/repo/sidekick/lua",
            focused = true,
            name = "add-herdr-support",
            pane_id = "w2:p9",
            state_change_seq = 42,
            tab_id = "w2:t4",
            terminal_id = "term_9",
            workspace_id = "w2",
          },
        },
      },
    },
  }
end

describe("herdr sessions", function()
  local env_keys = {
    "HERDR_BIN_PATH",
    "HERDR_PANE_ID",
    "HERDR_SCRATCH_SOURCE_PANE",
    "HERDR_SOCKET_PATH",
    "HERDR_SSH_PANES",
    "HERDR_TAB_ID",
    "HERDR_WORKSPACE_ID",
  }
  local original_env = {}
  local original_exec
  local original_request
  local original_error
  local original_new_pipe
  local original_system
  local errors
  local pipes

  before_each(function()
    for _, key in ipairs(env_keys) do
      original_env[key] = vim.env[key]
      vim.env[key] = nil
    end
    original_exec = Util.exec
    original_request = Herdr.request
    original_error = Util.error
    original_new_pipe = vim.uv.new_pipe
    original_system = vim.system
    errors = {}
    pipes = {}
    Util.error = function(message)
      errors[#errors + 1] = message
    end
    Herdr._reset()
  end)

  after_each(function()
    Util.exec = original_exec
    Herdr.request = original_request
    Herdr._reset()
    Util.error = original_error
    vim.uv.new_pipe = original_new_pipe
    vim.system = original_system
    for _, key in ipairs(env_keys) do
      vim.env[key] = original_env[key]
    end
  end)

  -- The fake transport never reaches a real server. Tests control each async
  -- handoff so a failed, possibly delivered send can be distinguished from new input.
  local function fake_pipes()
    vim.uv.new_pipe = function()
      local pipe = { writes = {}, closed = false }
      function pipe:connect(path, cb)
        self.path, self.on_connect = path, cb
      end
      function pipe:read_start(cb)
        self.on_read = cb
      end
      function pipe:write(payload, cb)
        self.writes[#self.writes + 1] = payload
        self.on_write = cb
      end
      function pipe:is_closing()
        return self.closed
      end
      function pipe:close()
        self.closed = true
      end
      pipes[#pipes + 1] = pipe
      return pipe
    end
    Util.exec = function()
      error("remote socket requests must not discover a server or use a subprocess")
    end
  end

  for _, socket in ipairs({ false, "/tmp/herdr-sp-missing.sock" }) do
    it("never falls back during remote discovery with socket " .. tostring(socket), function()
      vim.env.HERDR_SSH_PANES = "1"
      vim.env.HERDR_SOCKET_PATH = socket or nil
      local calls = 0
      Util.exec = function(cmd, opts)
        calls = calls + 1
        assert.are.same({ "herdr", "api", "snapshot" }, cmd)
        assert.is_not.equal(true, opts.clear_env)
        return nil
      end

      assert.are.same({}, Herdr.sessions())
      assert.are.equal(socket and 1 or 0, calls)
      assert.are.same({ "Herdr (laptop) unreachable: SSH link down" }, errors)
    end)
  end

  it("fails closed without a remote socket for input, focus, and read", function()
    vim.env.HERDR_SSH_PANES = "1"
    fake_pipes()
    local failed
    Herdr.request("pane.send_input", { pane_id = "w2:p9", text = "old" }, function(_, err)
      failed = err
    end)
    assert.is_true(vim.wait(100, function()
      return failed ~= nil
    end))
    assert.are.equal("Herdr (laptop) unreachable: SSH link down", failed)
    assert.are.equal(0, #pipes)
    assert.is_false(Herdr.focus({ herdr_pane_id = "w2:p9" }))
    assert.is_nil(setmetatable({ herdr_pane_id = "w2:p9" }, Herdr):dump())
    assert.are.equal(3, #errors)
  end)

  it("reports a broken forward with a real pipe and no subprocess fallback", function()
    vim.env.HERDR_SSH_PANES = "1"
    vim.env.HERDR_SOCKET_PATH = vim.fn.tempname() .. "/missing.sock"
    Util.exec = function()
      error("must not discover or fall back to a server")
    end
    local failed
    Herdr.request("pane.send_input", { pane_id = "w2:p9", text = "context" }, function(_, err)
      failed = err
    end)
    assert.is_true(vim.wait(1000, function()
      return failed ~= nil
    end))
    assert.are.equal("Herdr (laptop) unreachable: SSH link down", failed)
    assert.are.same({ failed }, errors)
  end)

  for _, failure in ipairs({ "connect", "read", "write", "eof" }) do
    it("reconnects lazily after remote " .. failure .. " failure without replaying input", function()
      vim.env.HERDR_SSH_PANES = "1"
      vim.env.HERDR_SOCKET_PATH = "/tmp/herdr-sp-stable.sock"
      fake_pipes()
      local failed
      Herdr.request("pane.send_input", { pane_id = "w2:p9", text = "old" }, function(_, err)
        failed = err
      end)
      local first = pipes[1]
      assert.are.equal(vim.env.HERDR_SOCKET_PATH, first.path)
      if failure == "connect" then
        first.on_connect("ECONNREFUSED")
      else
        first.on_connect(nil)
        assert.are.equal(1, #first.writes)
        if failure == "write" then
          first.on_write("EPIPE")
        else
          first.on_read(failure == "read" and "ECONNRESET" or nil, nil)
        end
      end
      assert.is_true(vim.wait(100, function()
        return failed ~= nil
      end))
      assert.are.equal("Herdr (laptop) unreachable: SSH link down", failed)
      assert.are.same({ failed }, errors)
      assert.is_true(first.closed)
      assert.are.equal(1, #pipes)

      Herdr.request("pane.send_input", { pane_id = "w2:p9", text = "new" })
      local second = pipes[2]
      assert.are.equal(vim.env.HERDR_SOCKET_PATH, second.path)
      second.on_connect(nil)
      assert.are.equal(1, #second.writes)
      assert.are.equal("new", vim.json.decode(second.writes[1]).params.text)
    end)
  end

  it("uses the payload binary for snapshot, read, and focus without server discovery", function()
    vim.env.HERDR_SSH_PANES = "1"
    vim.env.HERDR_BIN_PATH = "/payload/bin/herdr"
    vim.env.HERDR_SOCKET_PATH = "/tmp/herdr-sp-stable.sock"
    local calls = {}
    local encoded = vim.json.encode(snapshot())
    Util.exec = function(cmd, opts)
      calls[#calls + 1] = cmd
      assert.are.equal("/tmp/herdr-sp-stable.sock", opts.env.HERDR_SOCKET_PATH)
      return { encoded }, encoded
    end

    local sessions = Herdr.sessions()
    assert.are.equal(1, #sessions)
    assert.are.equal(encoded, setmetatable(sessions[1], Herdr):dump())
    assert.is_true(Herdr.focus(sessions[1]))
    assert.are.same({
      { "/payload/bin/herdr", "api", "snapshot" },
      { "/payload/bin/herdr", "agent", "read", "w2:p9", "--source", "recent", "--format", "ansi" },
      { "/payload/bin/herdr", "agent", "focus", "w2:p9" },
    }, calls)
  end)

  it("uses an overridden local binary for status discovery and focus", function()
    vim.env.HERDR_BIN_PATH = "/payload/bin/herdr"
    local calls = {}
    Util.exec = function(cmd, opts)
      assert.is_nil(opts.timeout)
      calls[#calls + 1] = cmd
      return { "socket: /tmp/local.sock" }, "socket: /tmp/local.sock"
    end
    assert.is_true(Herdr.focus({ herdr_pane_id = "w2:p9" }))
    assert.are.same({
      { "/payload/bin/herdr", "status", "server" },
      { "/payload/bin/herdr", "agent", "focus", "w2:p9" },
    }, calls)
  end)

  it("bounds remote snapshot, read and focus and reports timed out calls", function()
    vim.env.HERDR_SSH_PANES = "1"
    vim.env.HERDR_BIN_PATH = "/payload/bin/herdr"
    vim.env.HERDR_SOCKET_PATH = "/tmp/herdr-sp-stable.sock"
    Util.exec = original_exec
    local calls = {}
    vim.system = function(cmd, opts)
      assert.is_true(type(opts.timeout) == "number" and opts.timeout > 0 and opts.timeout <= 5000)
      calls[#calls + 1] = cmd
      return {
        wait = function()
          return { code = 124, signal = 15, stdout = "", stderr = "" }
        end,
      }
    end
    assert.are.same({}, Herdr.sessions())
    assert.is_nil(setmetatable({ herdr_pane_id = "w2:p9" }, Herdr):dump())
    assert.is_false(Herdr.focus({ herdr_pane_id = "w2:p9" }))
    assert.are.equal(3, #calls)
    assert.are.same({
      "Herdr (laptop) unreachable: SSH link down",
      "Herdr (laptop) unreachable: SSH link down",
      "Herdr (laptop) unreachable: SSH link down",
    }, errors)
  end)

  it("terminates a real unresponsive remote CLI without freezing discovery", function()
    local binary = vim.fn.tempname()
    vim.fn.writefile({ "#!/bin/sh", "exec sleep 30" }, binary)
    assert(vim.uv.fs_chmod(binary, 448))
    vim.env.HERDR_SSH_PANES = "1"
    vim.env.HERDR_BIN_PATH = binary
    vim.env.HERDR_SOCKET_PATH = "/tmp/herdr-sp-stable.sock"
    Util.exec = original_exec
    local start = vim.uv.hrtime()
    local ok, result = pcall(Herdr.sessions)
    local elapsed_ms = (vim.uv.hrtime() - start) / 1e6
    vim.fn.delete(binary)
    assert.is_true(ok)
    assert.are.same({}, result)
    assert.is_true(elapsed_ms < 6000)
    assert.are.same({ "Herdr (laptop) unreachable: SSH link down" }, errors)
  end)

  it("reports an unavailable remote payload without using PATH or socket fallback", function()
    vim.env.HERDR_SSH_PANES = "1"
    vim.env.HERDR_BIN_PATH = "/payload/bin/herdr"
    vim.env.HERDR_SOCKET_PATH = "/tmp/herdr-sp-stable.sock"
    local calls = 0
    Util.exec = function(cmd)
      calls = calls + 1
      assert.are.equal("/payload/bin/herdr", cmd[1])
      error("ENOENT")
    end
    assert.are.same({}, Herdr.sessions())
    assert.are.equal(1, calls)
    assert.are.same({ "Herdr (laptop) unreachable: SSH link down" }, errors)
  end)

  it("preserves SSH metadata without changing stock session shapes", function()
    local data = snapshot()
    local ssh = { host = "studio", link_id = "link-1", state = "live", local_cwd = "/laptop" }
    data.result.snapshot.agents[1].ssh = ssh
    local encoded = vim.json.encode(data)
    Util.exec = function()
      return { encoded }, encoded
    end
    assert.are.same(ssh, Herdr.sessions()[1].herdr_ssh)
  end)

  it("discovers named agents with workspace, tab, pane, and status metadata", function()
    local encoded = vim.json.encode(snapshot())
    Util.exec = function(cmd)
      assert.are.same({ "herdr", "api", "snapshot" }, cmd)
      return { encoded }, encoded
    end

    local sessions = Herdr.sessions()

    assert.are.equal(1, #sessions)
    assert.are.same({
      agent_status = "working",
      cwd = "/repo/sidekick/lua",
      external = true,
      herdr_agent_name = "add-herdr-support",
      herdr_focused = true,
      herdr_pane_id = "w2:p9",
      herdr_pane_label = "review",
      herdr_state_change_seq = 42,
      herdr_tab_id = "w2:t4",
      herdr_tab_label = "agents",
      herdr_terminal_id = "term_9",
      herdr_workspace_id = "w2",
      herdr_workspace_label = "sidekick",
      id = "herdr term_9",
      mux_session = "sidekick",
      priority = 100,
      tool = "codex",
    }, sessions[1])
    assert.is_true(setmetatable(sessions[1], Herdr):is_running())
    assert.are.same({ workspace_id = "w2", tab_id = "w2:t4", pane_id = "w2:p9" }, Herdr.current())
  end)

  it("falls back to pane metadata when an agent has no explicit name", function()
    local data = snapshot()
    data.result.snapshot.agents[1].name = nil
    local encoded = vim.json.encode(data)
    Util.exec = function()
      return { encoded }, encoded
    end

    local session = Herdr.sessions()[1]

    assert.is_nil(session.herdr_agent_name)
    assert.are.equal("review", session.herdr_pane_label)
  end)

  it("retries discovery without a stale Herdr socket override", function()
    vim.env.HERDR_SOCKET_PATH = "/tmp/stale-herdr.sock"
    local encoded = vim.json.encode(snapshot())
    local calls = {}
    Util.exec = function(cmd, opts)
      calls[#calls + 1] = { cmd = cmd, opts = opts }
      if #calls == 1 then
        return nil
      end
      return { encoded }, encoded
    end

    local sessions = Herdr.sessions()

    assert.are.equal(1, #sessions)
    assert.are.equal(2, #calls)
    assert.are.same({ vim.fn.exepath("herdr"), "api", "snapshot" }, calls[2].cmd)
    assert.is_true(calls[2].opts.clear_env)
    assert.is_nil(vim.tbl_filter(function(value)
      return value:match("^HERDR_SOCKET_PATH=")
    end, calls[2].opts.env)[1])
  end)

  it("uses the Scratch source pane instead of stale inherited Herdr context", function()
    vim.env.HERDR_PANE_ID = "w1:p1"
    vim.env.HERDR_TAB_ID = "w1:t1"
    vim.env.HERDR_WORKSPACE_ID = "w1"
    vim.env.HERDR_SCRATCH_SOURCE_PANE = "w2:p9"
    local encoded = vim.json.encode(snapshot())
    Util.exec = function()
      return { encoded }, encoded
    end

    Herdr.sessions()

    assert.are.same({ workspace_id = "w2", tab_id = "w2:t4", pane_id = "w2:p9" }, Herdr.current())
  end)

  it("queues bracketed input and Enter as ordered socket requests", function()
    local requests = {}
    Herdr.request = function(method, params)
      requests[#requests + 1] = { method = method, params = params }
    end
    local session = setmetatable({ herdr_pane_id = "w2:p9" }, Herdr)

    session:send("context\n")
    session:submit()

    assert.are.same({
      {
        method = "pane.send_input",
        params = { pane_id = "w2:p9", text = "context\n" },
      },
      {
        method = "pane.send_input",
        params = { keys = { "enter" }, pane_id = "w2:p9" },
      },
    }, requests)
  end)

  it("focuses the Herdr agent pane", function()
    local command
    Util.exec = function(cmd)
      command = cmd
      return {}
    end

    assert.is_true(Herdr.focus({ herdr_pane_id = "w2:p9" }))
    assert.are.same({ "herdr", "agent", "focus", "w2:p9" }, command)
  end)
end)

describe("session backend selection", function()
  local original_attached
  local original_backends
  local original_backend
  local original_enabled
  local original_setup

  before_each(function()
    original_attached = Session._attached
    original_backends = Session.backends
    original_backend = Config.cli.mux.backend
    original_enabled = Config.cli.mux.enabled
    original_setup = Session.setup
    Session._attached = {}
    Session.setup = function() end
  end)

  after_each(function()
    Session._attached = original_attached
    Session.backends = original_backends
    Session.setup = original_setup
    Config.cli.mux.backend = original_backend
    Config.cli.mux.enabled = original_enabled
  end)

  it("discovers every backend when Herdr is the creation backend", function()
    local called = {}
    local function backend(name)
      return {
        sessions = function()
          called[#called + 1] = name
          return {}
        end,
      }
    end
    Session.backends = {
      herdr = backend("herdr"),
      terminal = backend("terminal"),
      tmux = backend("tmux"),
      zellij = backend("zellij"),
    }
    Config.cli.mux.backend = "herdr"
    Config.cli.mux.enabled = true

    Session.sessions()
    table.sort(called)

    assert.are.same({ "herdr", "terminal", "tmux", "zellij" }, called)
  end)

  it("discovers every backend when tmux is the creation backend", function()
    local called = {}
    local function backend(name)
      return {
        sessions = function()
          called[#called + 1] = name
          return {}
        end,
      }
    end
    Session.backends = {
      herdr = backend("herdr"),
      terminal = backend("terminal"),
      tmux = backend("tmux"),
      zellij = backend("zellij"),
    }
    Config.cli.mux.backend = "tmux"
    Config.cli.mux.enabled = true

    Session.sessions()
    table.sort(called)

    assert.are.same({ "herdr", "terminal", "tmux", "zellij" }, called)
  end)
end)
