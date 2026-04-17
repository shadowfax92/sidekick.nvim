---@module 'luassert'

local Cli = require("sidekick.cli")
local Config = require("sidekick.config")
local State = require("sidekick.cli.state")

describe("cli send defaults", function()
  local original_multicast
  local original_with

  before_each(function()
    original_multicast = Config.cli.multicast
    original_with = State.with
  end)

  after_each(function()
    Config.cli.multicast = original_multicast
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
end)
