---@module 'luassert'

local Tmux = require("sidekick.cli.session.tmux")
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
