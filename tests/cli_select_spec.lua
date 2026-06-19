---@module 'luassert'

local Select = require("sidekick.cli.ui.select")

describe("cli select formatter", function()
  it("includes affinity badges in the formatted output", function()
    local parts = Select.format({
      affinity = {
        badges = {
          { text = "cwd", hl = "SidekickCliAffinityCwd" },
          { text = "win", hl = "SidekickCliAffinityWindow" },
        },
      },
      attached = true,
      external = true,
      installed = true,
      session = {
        backend = "tmux",
        cwd = "/tmp/project",
        mux_session = "main",
        tmux_pane_label = "panda",
        tmux_pane_index = "2",
        tmux_window_name = "editor",
        tmux_window_index = "1",
      },
      started = true,
      tool = { name = "codex" },
    })

    local text = table.concat(vim.tbl_map(function(part)
      return part[1]
    end, parts))

    assert.matches("%[cwd%]", text)
    assert.matches("%[win%]", text)
    assert.matches("%[tmux:main:1%(editor%).2%(panda%)%]", text)
    assert.is_true(vim.tbl_contains(vim.tbl_map(function(part)
      return part[2]
    end, parts), "SidekickCliAffinityCwd"))
    assert.is_true(vim.tbl_contains(vim.tbl_map(function(part)
      return part[2]
    end, parts), "SidekickCliAffinityWindow"))
  end)
end)

describe("cli select routing", function()
  local State = require("sidekick.cli.state")
  local original_get
  local original_scoped
  local original_ui_select

  local function candidate(name, same_pane)
    return {
      affinity = { same_tmux_pane = same_pane },
      installed = true,
      tool = { name = name },
    }
  end

  before_each(function()
    original_get = State.get
    original_scoped = State.scoped
    original_ui_select = vim.ui.select
  end)

  after_each(function()
    State.get = original_get
    State.scoped = original_scoped
    vim.ui.select = original_ui_select
  end)

  it("falls back to the unscoped picker when scoped matches are empty", function()
    local picked
    local all_tools = {
      { installed = true, tool = { name = "codex" } },
    }
    State.scoped = function()
      return {}
    end
    State.get = function()
      return all_tools
    end
    vim.ui.select = function(items, _, cb)
      picked = items
      cb(items[1])
    end

    Select.select({
      auto = false,
      cb = function() end,
      scope = "project",
    })

    assert.are.same(all_tools, picked)
  end)

  it("auto-selects a unique same-pane affinity match", function()
    local parent = candidate("codex", true)
    local other = candidate("claude", false)
    local selected
    local picker_calls = 0
    State.get = function()
      return { other, parent }
    end
    vim.ui.select = function(items, _, cb)
      picker_calls = picker_calls + 1
      cb(items[1])
    end

    Select.select({
      auto = true,
      cb = function(state)
        selected = state
      end,
    })

    assert.are.equal(parent, selected)
    assert.are.equal(0, picker_calls)
  end)

  it("uses the picker when multiple candidates match the same pane", function()
    local first = candidate("codex", true)
    local second = candidate("claude", true)
    local selected
    local picker_calls = 0
    State.get = function()
      return { first, second }
    end
    vim.ui.select = function(items, _, cb)
      picker_calls = picker_calls + 1
      cb(items[1])
    end

    Select.select({
      auto = true,
      cb = function(state)
        selected = state
      end,
    })

    assert.are.equal(first, selected)
    assert.are.equal(1, picker_calls)
  end)
end)
