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
  local original_detach
  local original_current_scope
  local original_info
  local original_mux_enabled
  local original_nes_enabled
  local original_notify
  local original_score
  local original_select
  local original_sessions
  local original_schedule_wrap
  local original_terminal_get
  local original_tmx_parent_pane
  local original_tools
  local original_status_setup
  local configured

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
    original_detach = Session.detach
    original_current_scope = Affinity.current_scope
    original_info = Util.info
    original_mux_enabled = Config.cli.mux.enabled
    original_nes_enabled = Config.nes.enabled
    original_notify = Util.notify
    original_score = Affinity.score
    original_select = require("sidekick.cli.ui.select").select
    original_sessions = Session.sessions
    original_schedule_wrap = vim.schedule_wrap
    original_terminal_get = require("sidekick.cli.terminal").get
    original_tmx_parent_pane = Affinity.tmx_parent_pane
    original_tools = Config.tools
    original_status_setup = require("sidekick.status").setup
    configured = false

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
    Session.detach = function(s)
      s._attached = false
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
    Affinity.tmx_parent_pane = function() end
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
    Config.cli.mux.enabled = original_mux_enabled
    Config.nes.enabled = original_nes_enabled
    Config.tools = original_tools
    Session.attach = original_attach
    Session.attached = original_attached
    Session.cwd = original_cwd
    Session.detach = original_detach
    Session.sessions = original_sessions
    Util.info = original_info
    Util.notify = original_notify
    vim.schedule_wrap = original_schedule_wrap
    require("sidekick.cli.terminal").get = original_terminal_get
    require("sidekick.cli.ui.select").select = original_select
    require("sidekick.status").setup = original_status_setup
    if configured then
      vim.api.nvim_clear_autocmds({ group = Config.augroup })
    end
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
        return {
          exact_cwd = false,
          same_git_root = false,
          same_tmux_session = false,
          same_tmux_window = false,
          same_tmux_pane = false,
          score = 0,
          badges = {},
        }
      end
      return {
        exact_cwd = s.id == "scoped-1",
        same_git_root = true,
        same_tmux_session = false,
        same_tmux_window = false,
        same_tmux_pane = false,
        score = 500,
        badges = {},
      }
    end

    local attached = State.auto_attach(nil, { multiple = true, scope = "project" })

    assert.are.equal(2, #attached)
    assert.is_true(scoped_1._attached)
    assert.is_true(scoped_2._attached)
    assert.is_false(outside._attached)
  end)

  for _, scope in ipairs({ "cwd", "project", "all" }) do
    it("auto_attaches the cross-project scratch parent before " .. scope .. " scope", function()
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
          exact_cwd = s.id == "other",
          same_git_root = s.id == "other",
          same_tmux_session = false,
          same_tmux_window = false,
          same_tmux_pane = s.id == "parent",
          score = s.id == "parent" and 525 or 500,
          badges = {},
        }
      end

      local attached = State.auto_attach(nil, { multiple = true, scope = scope })

      assert.are.equal(1, #attached)
      assert.are.equal("parent", attached[1].session.id)
      assert.is_true(parent._attached)
      assert.is_false(other._attached)
    end)
  end

  for _, ambiguous in ipairs({ false, true }) do
    it("leaves scratch auto-attach empty when the parent is " .. (ambiguous and "ambiguous" or "absent"), function()
      local other = session("claude", "other")
      local parents = ambiguous and { session("codex", "parent-1"), session("claude", "parent-2") } or {}
      Session.sessions = function()
        return vim.list_extend({ other }, parents)
      end
      Affinity.tmx_parent_pane = function()
        return "%parent"
      end
      Affinity.score = function(_, s)
        return { exact_cwd = s == other, same_git_root = s == other, same_tmux_pane = s ~= other, score = 0 }
      end

      assert.are.same({}, State.auto_attach(nil, { multiple = true, scope = "project" }))
      assert.is_false(other._attached)
      for _, parent in ipairs(parents) do
        assert.is_false(parent._attached)
      end
    end)
  end

  for _, multicast in ipairs({ false, true }) do
    it("keeps on-demand scope fallback without a scratch parent (multicast=" .. tostring(multicast) .. ")", function()
      local other = session("claude", "other")
      local outside = session("codex", "outside")
      Session.sessions = function()
        return { other, outside }
      end
      Affinity.tmx_parent_pane = function()
        return "%parent"
      end
      Affinity.score = function(_, s)
        return { exact_cwd = s == other, same_git_root = s == other, same_tmux_pane = false, score = 0 }
      end
      local used = {}
      State.with(function(state)
        used[#used + 1] = state.session.id
      end, { attach = true, multicast = multicast, scope = "project" })

      assert.are.same({ "other" }, used)
      assert.is_true(other._attached)
      assert.is_false(outside._attached)
    end)
  end

  it("refreshes the scratch parent on every HerdrScratchContext event", function()
    local parent = session("codex", "parent")
    local other = session("claude", "other")
    local running = { other }
    Session.sessions = function()
      return running
    end
    Session.attached = function()
      return vim.tbl_filter(function(s)
        return s._attached
      end, running)
    end
    Affinity.tmx_parent_pane = function()
      return "%parent"
    end
    Affinity.score = function(_, s)
      return { exact_cwd = s == other, same_git_root = s == other, same_tmux_pane = s.id == "parent", score = 0 }
    end
    require("sidekick.status").setup = function() end
    configured = true
    Config.setup({ nes = { enabled = false }, cli = { mux = { enabled = true } } })
    -- Let setup and the startup retry settle before simulating an agent starting
    -- in the parent of an already-running scratch editor.
    vim.wait(150, function()
      return false
    end)
    assert.is_false(other._attached)
    State.with(function() end, { attach = true, scope = "project" })
    assert.is_true(other._attached)

    running = { other, parent }
    vim.api.nvim_exec_autocmds("User", { pattern = "HerdrScratchContext" })
    assert.is_true(parent._attached)
    assert.is_false(other._attached)

    for _, multicast in ipairs({ false, true }) do
      local used = {}
      State.with(function(state)
        used[#used + 1] = state.session.id
      end, { attach = true, multicast = multicast, scope = "project" })
      assert.are.same({ "parent" }, used)
    end

    parent = session("claude", "parent")
    running = { other, parent }
    vim.api.nvim_exec_autocmds("User", { pattern = "HerdrScratchContext" })
    assert.is_true(parent._attached)
    assert.is_false(other._attached)
  end)

  for _, multicast in ipairs({ false, true }) do
    it(
      "replaces a scratch fallback with the parent during routing (multicast=" .. tostring(multicast) .. ")",
      function()
        local other = session("claude", "other")
        local parent = session("codex", "parent")
        other._attached = true
        Session.sessions = function()
          return { other, parent }
        end
        Session.attached = function()
          return vim.tbl_filter(function(s)
            return s._attached
          end, { other, parent })
        end
        Affinity.tmx_parent_pane = function()
          return "%parent"
        end
        Affinity.score = function(_, s)
          return { exact_cwd = s == other, same_git_root = s == other, same_tmux_pane = s == parent, score = 0 }
        end
        local used = {}
        State.with(function(state)
          used[#used + 1] = state.session.id
        end, { attach = true, multicast = multicast, scope = "project" })

        assert.are.same({ "parent" }, used)
        assert.is_true(parent._attached)
        assert.is_false(other._attached)
      end
    )
  end

  for _, mode in ipairs({ "outside scratch", "startup disabled", "mux disabled" }) do
    it("ignores HerdrScratchContext with " .. mode, function()
      local discovered = 0
      Session.sessions = function()
        discovered = discovered + 1
        return {}
      end
      Affinity.tmx_parent_pane = function()
        return mode ~= "outside scratch" and "%parent" or nil
      end
      require("sidekick.status").setup = function() end
      configured = true
      Config.setup({
        nes = { enabled = false },
        cli = { mux = { enabled = mode ~= "mux disabled", auto_attach = { startup = mode ~= "startup disabled" } } },
      })
      vim.wait(150, function()
        return false
      end)
      discovered = 0

      vim.api.nvim_exec_autocmds("User", { pattern = "HerdrScratchContext" })

      assert.are.equal(0, discovered)
    end)
  end

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
        return {
          exact_cwd = false,
          same_git_root = false,
          same_tmux_session = false,
          same_tmux_window = false,
          same_tmux_pane = false,
          score = 0,
          badges = {},
        }
      end
      return {
        exact_cwd = s.id == "scoped-1",
        same_git_root = true,
        same_tmux_session = false,
        same_tmux_window = false,
        same_tmux_pane = false,
        score = 500,
        badges = {},
      }
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
        return {
          exact_cwd = false,
          same_git_root = true,
          same_tmux_session = false,
          same_tmux_window = false,
          same_tmux_pane = false,
          score = 500,
          badges = {},
        }
      end
      return {
        exact_cwd = false,
        same_git_root = false,
        same_tmux_session = false,
        same_tmux_window = false,
        same_tmux_pane = false,
        score = 0,
        badges = {},
      }
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
      return {
        exact_cwd = false,
        same_git_root = false,
        same_tmux_session = false,
        same_tmux_window = false,
        same_tmux_pane = false,
        score = 0,
        badges = {},
      }
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
      return {
        exact_cwd = true,
        same_git_root = true,
        same_tmux_session = false,
        same_tmux_window = false,
        same_tmux_pane = false,
        score = 1500,
        badges = {},
      }
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
      return {
        exact_cwd = false,
        same_git_root = true,
        same_tmux_session = false,
        same_tmux_window = false,
        same_tmux_pane = false,
        score = 500,
        badges = {},
      }
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
