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
  local original_tools

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
    original_tools = Config.tools

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
    Config.cli.mux.auto_attach = original_auto_attach
    Config.tools = original_tools
    Session.attach = original_attach
    Session.attached = original_attached
    Session.cwd = original_cwd
    Session.sessions = original_sessions
    Util.info = original_info
    Util.notify = original_notify
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
