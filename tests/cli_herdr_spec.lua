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
    "HERDR_PANE_ID",
    "HERDR_SCRATCH_SOURCE_PANE",
    "HERDR_SOCKET_PATH",
    "HERDR_TAB_ID",
    "HERDR_WORKSPACE_ID",
  }
  local original_env = {}
  local original_exec
  local original_request

  before_each(function()
    for _, key in ipairs(env_keys) do
      original_env[key] = vim.env[key]
      vim.env[key] = nil
    end
    original_exec = Util.exec
    original_request = Herdr.request
    Herdr._reset()
  end)

  after_each(function()
    Util.exec = original_exec
    Herdr.request = original_request
    Herdr._reset()
    for _, key in ipairs(env_keys) do
      vim.env[key] = original_env[key]
    end
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
