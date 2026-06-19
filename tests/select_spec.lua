---@module 'luassert'

local Select = require("sidekick.cli.ui.select")
local State = require("sidekick.cli.state")

describe("cli select", function()
  local original_get
  local original_is_tmx_parent
  local original_ui_select

  local function candidate(name, parent)
    return {
      tool = { name = name },
      installed = true,
      tmx_parent = parent,
    }
  end

  local function run(tools, opts)
    local selected
    local picker_calls = 0
    State.get = function()
      return tools
    end
    State.is_tmx_parent = function(state)
      return state.tmx_parent == true
    end
    vim.ui.select = function(items, _, cb)
      picker_calls = picker_calls + 1
      cb(items[1])
    end

    Select.select(vim.tbl_extend("force", {
      auto = true,
      cb = function(state)
        selected = state
      end,
    }, opts or {}))

    return selected, picker_calls
  end

  before_each(function()
    original_get = State.get
    original_is_tmx_parent = State.is_tmx_parent
    original_ui_select = vim.ui.select
  end)

  after_each(function()
    State.get = original_get
    State.is_tmx_parent = original_is_tmx_parent
    vim.ui.select = original_ui_select
  end)

  it("auto-selects the unique tmx scratch parent candidate", function()
    local parent = candidate("codex", true)
    local other = candidate("codex", false)

    local selected, picker_calls = run({ other, parent })

    assert.are.equal(parent, selected)
    assert.are.equal(0, picker_calls)
  end)

  it("uses the picker when multiple candidates match the tmx scratch parent", function()
    local first = candidate("codex", true)
    local second = candidate("claude", true)

    local selected, picker_calls = run({ first, second })

    assert.are.equal(first, selected)
    assert.are.equal(1, picker_calls)
  end)

  it("keeps the existing single-candidate auto-selection fallback", function()
    local only = candidate("codex", false)

    local selected, picker_calls = run({ only })

    assert.are.equal(only, selected)
    assert.are.equal(0, picker_calls)
  end)
end)
