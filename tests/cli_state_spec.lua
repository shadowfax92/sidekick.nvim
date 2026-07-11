---@module 'luassert'

local Affinity = require("sidekick.cli.affinity")
local Config = require("sidekick.config")
local Session = require("sidekick.cli.session")
local State = require("sidekick.cli.state")
local Util = require("sidekick.util")

describe("cli state routing", function()
  local original_attach
  local original_attached
  local original_auto_attach
  local original_cwd
  local original_current_scope
  local original_info
  local original_notify
  local original_score
  local original_select
  local original_sessions
  local original_schedule_wrap
  local original_terminal_get
  local original_tmx_parent_pane
  local original_tools
  local original_warn

  local function tool(name)
    return { name = name }
  end

  local function session(name, id)
    return {
      _attached = false,
      backend = "tmux",
      cwd = "/repo/" .. id,
      external = true,
      id = id,
      is_attached = function(self)
        return self._attached
      end,
      mux_session = "main",
      pids = { 1, 2, 3 },
      priority = 10,
      sid = name .. "-" .. id,
      started = true,
      tmux_pane_id = "%" .. id,
      tmux_pane_index = "0",
      tmux_window_index = "1",
      tool = tool(name),
    }
  end

  before_each(function()
    original_attach = Session.attach
    original_attached = Session.attached
    original_auto_attach = Config.cli.mux.auto_attach
    original_cwd = Session.cwd
    original_current_scope = Affinity.current_scope
    original_info = Util.info
    original_notify = Util.notify
    original_score = Affinity.score
    original_select = require("sidekick.cli.ui.select").select
    original_sessions = Session.sessions
    original_schedule_wrap = vim.schedule_wrap
    original_terminal_get = require("sidekick.cli.terminal").get
    original_tmx_parent_pane = Affinity.tmx_parent_pane
    original_tools = Config.tools
    original_warn = Util.warn

    Config.cli.mux.auto_attach = { on_demand = true, scope = "project", startup = true }
    Config.tools = function()
      return {}
    end
    Session.cwd = function()
      return "/repo/current"
    end
    Session.attach = function(s)
      s._attached = true
      return s
    end
    Session.attached = function()
      return {}
    end
    require("sidekick.cli.terminal").get = function()
      return nil
    end
    Affinity.current_scope = function()
      return { cwd = "/repo/current" }
    end
    Util.notify = function() end
    vim.schedule_wrap = function(cb)
      return cb
    end
  end)

  after_each(function()
    Affinity.current_scope = original_current_scope
    Affinity.score = original_score
    Affinity.tmx_parent_pane = original_tmx_parent_pane
    Config.cli.mux.auto_attach = original_auto_attach
    Config.tools = original_tools
    Session.attach = original_attach
    Session.attached = original_attached
    Session.cwd = original_cwd
    Session.sessions = original_sessions
    Util.info = original_info
    Util.notify = original_notify
    Util.warn = original_warn
    vim.schedule_wrap = original_schedule_wrap
    require("sidekick.cli.terminal").get = original_terminal_get
    require("sidekick.cli.ui.select").select = original_select
  end)

  it("auto_attaches all started sessions in project scope", function()
    local scoped_1 = session("claude", "scoped-1")
    local scoped_2 = session("codex", "scoped-2")
    local outside = session("claude", "outside")
    Session.sessions = function()
      return { scoped_1, scoped_2, outside }
    end
    Affinity.score = function(_, s)
      if s.id == "outside" then
        return { exact_cwd = false, same_git_root = false, same_tmux_session = false, same_tmux_window = false, same_tmux_pane = false, score = 0, badges = {} }
      end
      return { exact_cwd = s.id == "scoped-1", same_git_root = true, same_tmux_session = false, same_tmux_window = false, same_tmux_pane = false, score = 500, badges = {} }
    end

    local attached = State.auto_attach(nil, { multiple = true, scope = "project" })

    assert.are.equal(2, #attached)
    assert.is_true(scoped_1._attached)
    assert.is_true(scoped_2._attached)
    assert.is_false(outside._attached)
  end)

  it("suppresses viewers and reports every newly attached agent location", function()
    local scoped_1 = session("claude", "scoped-1")
    local scoped_2 = session("codex", "scoped-2")
    local attach_opts = {}
    local noted
    Session.sessions = function()
      return { scoped_1, scoped_2 }
    end
    Affinity.score = function()
      return { exact_cwd = false, same_git_root = true, same_repo = true, score = 900, badges = {} }
    end
    Session.attach = function(s, opts)
      attach_opts[#attach_opts + 1] = opts
      s._attached = true
      return s
    end
    Util.info = function(msg)
      noted = msg
    end

    State.auto_attach(nil, { multiple = true, scope = "project" })

    assert.are.same({ { viewer = false }, { viewer = false } }, attach_opts)
    assert.are.equal(table.concat({
      "Auto-attached 2 agents:",
      "- **claude** `main:1.0` — /repo/scoped-1",
      "- **codex** `main:1.0` — /repo/scoped-2",
    }, "\n"), noted)
  end)

  it("reports visible agents outside explicit auto-attach scope", function()
    local outside_1 = session("claude", "outside-1")
    local outside_2 = session("codex", "outside-2")
    local warned
    Session.sessions = function()
      return { outside_1, outside_2 }
    end
    Affinity.score = function()
      return { exact_cwd = false, same_git_root = false, same_repo = false, score = 0, badges = {} }
    end
    Util.warn = function(msg)
      warned = msg
    end

    local attached = State.auto_attach(nil, { multiple = true, notify_empty = true, scope = "project" })

    assert.are.same({}, attached)
    assert.are.equal(
      'Auto-attach: no agents in `project` scope — 2 running elsewhere. Use require("sidekick.cli").select()',
      warned
    )
  end)

  it("keeps empty startup and on-demand auto-attach paths silent", function()
    local outside = session("codex", "outside")
    local messages = {}
    Session.sessions = function()
      return { outside }
    end
    Affinity.score = function()
      return { exact_cwd = false, same_git_root = false, same_repo = false, score = 0, badges = {} }
    end
    Util.info = function(msg)
      messages[#messages + 1] = msg
    end
    Util.warn = function(msg)
      messages[#messages + 1] = msg
    end

    assert.are.same({}, State.auto_attach(nil, { multiple = true, scope = "project" }))
    Session.sessions = function()
      return {}
    end
    assert.are.same({}, State.auto_attach(nil, { multiple = true, notify_empty = true, scope = "project" }))
    assert.are.same({}, messages)
  end)

  it("auto_attaches only the unique tmx scratch parent when available", function()
    local parent = session("codex", "parent")
    local other = session("claude", "other")
    Session.sessions = function()
      return { parent, other }
    end
    Affinity.tmx_parent_pane = function()
      return "%parent"
    end
    Affinity.score = function(_, s)
      return {
        exact_cwd = false,
        same_git_root = true,
        same_tmux_session = false,
        same_tmux_window = false,
        same_tmux_pane = s.id == "parent",
        score = s.id == "parent" and 525 or 500,
        badges = {},
      }
    end

    local attached = State.auto_attach(nil, { multiple = true, scope = "project" })

    assert.are.equal(1, #attached)
    assert.are.equal("parent", attached[1].session.id)
    assert.is_true(parent._attached)
    assert.is_false(other._attached)
  end)

  it("multicast sends to every scoped session", function()
    local scoped_1 = session("claude", "scoped-1")
    local scoped_2 = session("codex", "scoped-2")
    local outside = session("claude", "outside")
    scoped_1._attached = true
    Session.sessions = function()
      return { scoped_1, scoped_2, outside }
    end
    Session.attached = function()
      return { scoped_1 }
    end
    Affinity.score = function(_, s)
      if s.id == "outside" then
        return { exact_cwd = false, same_git_root = false, same_tmux_session = false, same_tmux_window = false, same_tmux_pane = false, score = 0, badges = {} }
      end
      return { exact_cwd = s.id == "scoped-1", same_git_root = true, same_tmux_session = false, same_tmux_window = false, same_tmux_pane = false, score = 500, badges = {} }
    end

    local used = {}
    State.with(function(state)
      used[#used + 1] = state.session.id
    end, {
      attach = true,
      multicast = true,
      scope = "project",
    })

    table.sort(used)
    assert.are.same({ "scoped-1", "scoped-2" }, used)
    assert.is_true(scoped_2._attached)
    assert.is_false(outside._attached)
  end)

  it("multicast also sends to attached sessions outside scope", function()
    local scoped = session("claude", "scoped")
    local outside = session("codex", "outside")
    outside._attached = true
    Session.sessions = function()
      return { scoped, outside }
    end
    Session.attached = function()
      return { outside }
    end
    Affinity.score = function(_, s)
      if s.id == "scoped" then
        return { exact_cwd = false, same_git_root = true, same_tmux_session = false, same_tmux_window = false, same_tmux_pane = false, score = 500, badges = {} }
      end
      return { exact_cwd = false, same_git_root = false, same_tmux_session = false, same_tmux_window = false, same_tmux_pane = false, score = 0, badges = {} }
    end

    local used = {}
    State.with(function(state)
      used[#used + 1] = state.session.id
    end, {
      attach = true,
      multicast = true,
      scope = "project",
    })

    table.sort(used)
    assert.are.same({ "outside", "scoped" }, used)
    assert.is_true(scoped._attached)
  end)

  it("ranks running agents above startable tools, even outside the project", function()
    local remote = session("claude", "remote")
    remote.cwd = "/elsewhere"
    Session.sessions = function()
      return { remote }
    end
    Config.tools = function()
      return { codex = { name = "codex", cmd = { "sh" } } }
    end
    Affinity.score = function()
      return { exact_cwd = false, same_git_root = false, same_tmux_session = false, same_tmux_window = false, same_tmux_pane = false, score = 0, badges = {} }
    end

    local states = State.get()

    assert.are.equal(2, #states)
    assert.are.equal("claude", states[1].tool.name)
    assert.is_not_nil(states[1].session)
    assert.are.equal("codex", states[2].tool.name)
    assert.is_nil(states[2].session)
  end)

  it("breaks affinity ties by tmux window activity", function()
    local stale = session("claude", "stale")
    local fresh = session("claude", "fresh")
    stale.cwd, fresh.cwd = "/repo/current", "/repo/current"
    stale.tmux_window_activity, fresh.tmux_window_activity = 100, 200
    Session.sessions = function()
      return { stale, fresh }
    end
    Affinity.score = function()
      return { exact_cwd = true, same_git_root = true, same_tmux_session = false, same_tmux_window = false, same_tmux_pane = false, score = 1500, badges = {} }
    end

    local states = State.get()

    assert.are.equal("fresh", states[1].session.id)
    assert.are.equal("stale", states[2].session.id)
  end)

  it("falls back to scoped selection for single-target flows", function()
    local scoped_1 = session("claude", "scoped-1")
    local scoped_2 = session("codex", "scoped-2")
    scoped_1._attached = true
    scoped_2._attached = true
    Session.attached = function()
      return { scoped_1, scoped_2 }
    end
    Session.sessions = function()
      return { scoped_1, scoped_2 }
    end
    Affinity.score = function()
      return { exact_cwd = false, same_git_root = true, same_tmux_session = false, same_tmux_window = false, same_tmux_pane = false, score = 500, badges = {} }
    end

    local called = {}
    require("sidekick.cli.ui.select").select = function(opts)
      called = opts
    end

    State.with(function() end, {
      attach = true,
      scope = "project",
    })

    assert.are.equal("project", called.scope)
    assert.are.same({ attached = true }, called.filter)
  end)
end)
