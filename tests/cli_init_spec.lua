---@module 'luassert'

local Cli = require("sidekick.cli")
local Config = require("sidekick.config")
local State = require("sidekick.cli.state")
local Util = require("sidekick.util")

describe("cli send defaults", function()
  local original_multicast
  local original_render
  local original_info
  local original_schedule
  local original_with

  before_each(function()
    original_multicast = Config.cli.multicast
    original_render = Cli.render
    original_info = Util.info
    original_schedule = vim.schedule
    original_with = State.with
  end)

  after_each(function()
    Config.cli.multicast = original_multicast
    Cli.render = original_render
    Util.info = original_info
    vim.schedule = original_schedule
    State.with = original_with
  end)

  it("uses config multicast defaults without requiring callers to pass them", function()
    local called
    Config.cli.multicast = true
    State.with = function(_, opts)
      called = opts
    end

    Cli.send({
      text = { { { "hello" } } },
    })

    assert.is_truthy(called)
    assert.is_true(called.multicast)
    assert.is_true(called.attach)
    assert.is_true(called.show)
  end)

  it("reports sent targets and rendered context after dispatch", function()
    local noted
    vim.schedule = function(cb)
      cb()
    end
    Cli.render = function()
      return "/tmp/example.lua:L12-L18", { { { "hello" } } }
    end
    Util.info = function(msg, opts)
      noted = { msg = msg, opts = opts }
    end
    State.with = function(use, opts)
      local sent = 0
      local states = {
        { tool = { name = "claude", format = function() return "hello" end }, session = { send = function() end } },
        { tool = { name = "codex", format = function() return "hello" end }, session = { send = function() end } },
        { tool = { name = "codex", format = function() return "hello" end }, session = { send = function() end } },
      }
      opts.on_resolved(states)
      assert.is_nil(noted)
      for _, state in ipairs(states) do
        sent = sent + 1
        assert.has_no.errors(function()
          use(state)
        end)
        if sent < #states then
          assert.is_nil(noted)
        end
      end
    end

    Cli.send({ msg = "{line_abs}" })

    assert.are.same({
      msg = "Sent line to 3 agents · /tmp/example.lua:L12-L18",
      opts = { timeout = 1000 },
    }, noted)
  end)
end)
