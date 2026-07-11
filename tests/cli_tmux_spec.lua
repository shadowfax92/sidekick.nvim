---@module 'luassert'

local Tmux = require("sidekick.cli.session.tmux")
local Config = require("sidekick.config")
local Session = require("sidekick.cli.session")
local Util = require("sidekick.util")

describe("tmux pane parsing", function()
  local original_exec

  before_each(function()
    original_exec = Util.exec
  end)

  after_each(function()
    Util.exec = original_exec
  end)

  local function panes(lines)
    Util.exec = function()
      return lines
    end
    return Tmux.panes()
  end

  it("parses the pane format including window activity", function()
    local pane = panes({ "$3:%42:1234:MAIN:CH:2:1:mink:1783619633:/repo/mink" })[1]

    assert.are.same({
      skid = "tmux 1234",
      pid = 1234,
      id = "%42",
      session_id = "$3",
      session_name = "MAIN",
      window_name = "CH",
      window_index = "2",
      pane_index = "1",
      pane_label = "mink",
      window_activity = 1783619633,
      cwd = "/repo/mink",
    }, pane)
  end)

  it("tolerates empty pane labels and missing activity", function()
    local pane = panes({ "$1:%1:7:gs/nvim/7f3a::0:0::" .. ":/tmp" })[1]
    assert.are.equal("", pane.pane_label)
    assert.are.equal("gs/nvim/7f3a", pane.session_name)
    assert.are.equal(0, pane.window_activity)
    assert.are.equal("/tmp", pane.cwd)
  end)

  it("keeps paths containing colons in the cwd field", function()
    local pane = panes({ "$1:%1:7:S:W:0:0:label:1:/tmp/a:b" })[1]
    assert.are.equal("label", pane.pane_label)
    assert.are.equal("/tmp/a:b", pane.cwd)
  end)
end)

describe("tmux attach", function()
  local original_attach
  local original_exec
  local original_pane
  local original_tmux
  local original_warn

  local function target(overrides)
    return setmetatable(vim.tbl_extend("force", {
      mux_session = "sf_task_codex",
      sid = "codex deadbeef",
      tmux_session_id = "$42",
      tmux_window_index = "1",
      tool = { name = "codex" },
    }, overrides or {}), Tmux)
  end

  before_each(function()
    original_attach = Config.cli.mux.attach
    original_exec = Util.exec
    original_pane = vim.env.TMUX_PANE
    original_tmux = vim.env.TMUX
    original_warn = Util.warn
    Config.cli.mux.attach = { cross_session = true }
    vim.env.TMUX = "/private/tmp/tmux-501/default,123,0"
    vim.env.TMUX_PANE = "%current"
  end)

  after_each(function()
    Config.cli.mux.attach = original_attach
    Util.exec = original_exec
    Util.warn = original_warn
    vim.env.TMUX = original_tmux
    vim.env.TMUX_PANE = original_pane
  end)

  it("keeps owned attach nest-safe even when cross-session attach is disabled", function()
    Config.cli.mux.attach.cross_session = false
    local cmd = target({ mux_session = "codex deadbeef" }):attach({ viewer = false })

    assert.are.same({ "tmux", "attach-session", "-t", "codex deadbeef" }, cmd.cmd)
    assert.are.same({ TMUX = false, TMUX_PANE = false }, cmd.env)
  end)

  it("attaches a detached foreign session on the current socket and window", function()
    local calls = {}
    Util.exec = function(cmd)
      calls[#calls + 1] = cmd
      if cmd[2] == "display-message" then
        return { "MAIN" }
      elseif cmd[2] == "list-clients" then
        return {}
      end
      return {}
    end

    local cmd = target():attach()

    assert.are.same({
      "tmux",
      "-S",
      "/private/tmp/tmux-501/default",
      "select-window",
      "-t",
      "$42:1",
      ";",
      "attach-session",
      "-t",
      "$42",
    }, cmd.cmd)
    assert.are.same({ TMUX = false, TMUX_PANE = false }, cmd.env)
    assert.are.same({ "tmux", "has-session", "-t", "$42" }, calls[2])
  end)

  it("does not resize or retarget a foreign session with existing clients", function()
    Util.exec = function(cmd)
      if cmd[2] == "display-message" then
        return { "MAIN" }
      elseif cmd[2] == "list-clients" then
        return { "$42:999" }
      end
      return {}
    end

    local cmd = target():attach()

    assert.are.same({
      "tmux",
      "-S",
      "/private/tmp/tmux-501/default",
      "attach-session",
      "-f",
      "ignore-size",
      "-t",
      "$42",
    }, cmd.cmd)
  end)

  it("keeps same-session, viewer-disabled, and config-disabled foreign targets virtual", function()
    local execs = 0
    Util.exec = function(cmd)
      execs = execs + 1
      if cmd[2] == "display-message" then
        return { "MAIN" }
      end
      return {}
    end

    assert.is_nil(target({ mux_session = "MAIN" }):attach())
    assert.is_nil(target():attach({ viewer = false }))
    Config.cli.mux.attach.cross_session = false
    assert.is_nil(target():attach())
    assert.are.equal(1, execs)
  end)

  it("warns and stays virtual when the target session exited", function()
    local warned
    Util.warn = function(msg)
      warned = msg
    end
    Util.exec = function(cmd)
      if cmd[2] == "display-message" then
        return { "MAIN" }
      elseif cmd[2] == "has-session" then
        return nil
      end
      error("unexpected command: " .. table.concat(cmd, " "))
    end

    assert.is_nil(target():attach())
    assert.matches("codex", warned)
    assert.matches("sf_task_codex", warned)
  end)
end)

describe("tmux session metadata", function()
  local Procs = require("sidekick.cli.procs")
  local original_clients
  local original_new
  local original_panes
  local original_pids
  local original_tools

  before_each(function()
    original_clients = Tmux.clients
    original_new = Procs.new
    original_panes = Tmux.panes
    original_pids = Procs.pids
    original_tools = Config.tools
  end)

  after_each(function()
    Tmux.clients = original_clients
    Tmux.panes = original_panes
    Procs.new = original_new
    Procs.pids = original_pids
    Config.tools = original_tools
  end)

  it("propagates the immutable tmux session id from discovered panes", function()
    Tmux.panes = function()
      return {
        {
          cwd = "/repo/task",
          id = "%9",
          pane_index = "0",
          pid = 99,
          session_id = "$42",
          session_name = "sf_task_codex",
          skid = "tmux 99",
          window_index = "1",
        },
      }
    end
    Tmux.clients = function()
      return {}
    end
    Config.tools = function()
      return {
        codex = {
          is_proc = function()
            return true
          end,
        },
      }
    end
    Procs.new = function()
      return {
        walk = function(_, _, cb)
          cb({ cwd = "/repo/task" })
        end,
      }
    end
    Procs.pids = function()
      return { 99 }
    end

    local sessions = Tmux.sessions()

    assert.are.equal(1, #sessions)
    assert.are.equal("$42", sessions[1].tmux_session_id)
  end)
end)

describe("session attach options", function()
  local original_attached
  local original_new

  before_each(function()
    original_attached = Session._attached
    original_new = Session.new
    Session._attached = {}
  end)

  after_each(function()
    Session._attached = original_attached
    Session.new = original_new
  end)

  it("threads viewer policy and keys terminal wrappers by unique session id", function()
    local backend_opts
    local wrapper_opts
    local source = {
      cwd = "/repo/task",
      id = "tmux 99",
      mux_session = "sf_task_codex",
      sid = "codex deadbeef",
      started = true,
      tool = {
        clone = function(_, opts)
          return { name = "codex", opts = opts }
        end,
      },
      attach = function(_, opts)
        backend_opts = opts
        return { cmd = { "tmux" }, env = { TMUX = false } }
      end,
    }
    Session.new = function(opts)
      wrapper_opts = opts
      return vim.tbl_extend("force", opts, {
        is_running = function()
          return true
        end,
        start = function() end,
      })
    end

    local attached = Session.attach(source, { viewer = false })

    assert.are.same({ viewer = false }, backend_opts)
    assert.are.equal("terminal: tmux 99", wrapper_opts.id)
    assert.are.equal(source, wrapper_opts.parent)
    assert.are.equal("terminal: tmux 99", attached.id)
  end)
end)

describe("tmux focus", function()
  local original_exec
  local original_system
  local original_tmux

  before_each(function()
    original_exec = Util.exec
    original_system = vim.system
    original_tmux = vim.env.TMUX
    vim.env.TMUX = "/tmp/tmux-501/default,1,0"
  end)

  after_each(function()
    Util.exec = original_exec
    vim.system = original_system
    vim.env.TMUX = original_tmux
  end)

  it("switches the client to the pane of a normal session", function()
    local calls = {}
    Util.exec = function(cmd)
      calls[#calls + 1] = table.concat(cmd, " ")
      return {}
    end

    assert.is_true(Tmux.focus({ mux_session = "MAIN", tmux_pane_id = "%42", backend = "tmux" }))
    assert.are.same({
      "tmux switch-client -t =MAIN",
      "tmux select-window -t %42",
      "tmux select-pane -t %42",
    }, calls)
  end)

  it("re-opens the popup for tmx scratch sessions instead of switching into them", function()
    local spawned
    Util.exec = function()
      error("scratch sessions must not switch the client")
    end
    vim.system = function(cmd)
      spawned = cmd
    end

    assert.is_true(Tmux.focus({ mux_session = "gs/nvim/7f3a", tmux_pane_id = "%9", backend = "tmux" }))
    assert.are.same({
      "tmux",
      "display-popup",
      "-E",
      "exec tmux attach-session -t '=gs/nvim/7f3a'",
    }, spawned)
  end)

  it("refuses to focus a session without a pane", function()
    Util.exec = function()
      error("should not run tmux")
    end
    local notified = false
    local original_warn = Util.warn
    Util.warn = function()
      notified = true
    end

    assert.is_false(Tmux.focus({ mux_session = "MAIN", backend = "tmux" }))
    assert.is_true(notified)
    Util.warn = original_warn
  end)
end)
