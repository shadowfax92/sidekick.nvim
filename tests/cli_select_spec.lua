---@module 'luassert'

local Select = require("sidekick.cli.ui.select")

local function text(parts)
  return table.concat(vim.tbl_map(function(part)
    return part[1]
  end, parts))
end

local function hls(parts)
  return vim.tbl_map(function(part)
    return part[2]
  end, parts)
end

---@param cols sidekick.cli.select.Column[]
local function by_id(cols)
  local ret = {}
  for _, col in ipairs(cols) do
    ret[col.id] = col
  end
  return ret
end

-- wide enough that the path column is never shortened
local function columns(state)
  return Select.columns(state, { width = 120 })
end

local function agent(session, overrides)
  return vim.tbl_deep_extend("force", {
    affinity = { badges = {} },
    attached = true,
    external = true,
    installed = true,
    session = vim.tbl_deep_extend("force", {
      backend = "tmux",
      cwd = "/tmp/project",
      mux_session = "MAIN",
      tmux_pane_index = "2",
      tmux_pane_label = "panda",
      tmux_window_index = "1",
      tmux_window_name = "editor",
    }, session or {}),
    started = true,
    tool = { name = "codex" },
  }, overrides or {})
end

describe("cli select columns", function()
  it("lays out stable columns with the pane label as the primary handle", function()
    local cols = columns(agent())

    assert.are.same(
      { "glyphs", "tool", "label", "loc", "badges", "path" },
      vim.tbl_map(function(col)
        return col.id
      end, cols)
    )

    local col = by_id(cols)
    assert.matches("codex", text(col.tool.parts))
    assert.matches("panda", text(col.label.parts))
    assert.matches("MAIN › editor", text(col.loc.parts))
    assert.matches("/tmp/project", text(col.path.parts))
  end)

  it("searches tool, label and location, but never the path", function()
    local searchable = {}
    for _, col in ipairs(columns(agent())) do
      if col.search then
        searchable[#searchable + 1] = col.id
      end
    end
    -- a query like `codex panda` must not be satisfied by a directory named `panda`
    assert.are.same({ "tool", "label", "loc" }, searchable)
  end)

  it("falls back from pane label to window name to indexes, never nil", function()
    local col = by_id(columns(agent({ tmux_pane_label = "" })))
    assert.matches("editor", text(col.label.parts))

    col = by_id(columns(agent({ tmux_pane_label = "", tmux_window_name = "" })))
    assert.matches("1%.2", text(col.label.parts))

    local bare = agent()
    bare.session.tmux_pane_label = ""
    bare.session.tmux_window_name = ""
    bare.session.tmux_window_index = nil
    bare.session.tmux_pane_index = nil
    col = by_id(columns(bare))
    assert.are.equal("", vim.trim(text(col.label.parts)))
  end)

  it("greens the session and window tokens of the current pane", function()
    local cols = columns(agent(nil, {
      affinity = { badges = {}, same_tmux_session = true, same_tmux_window = true },
    }))
    local loc = by_id(cols).loc
    assert.matches("● ", text(loc.parts))
    for _, part in ipairs(loc.parts) do
      if part[1] == "MAIN" or part[1] == "editor" then
        assert.are.equal("SidekickPickerCurrent", part[2])
      end
    end
  end)

  it("badges tmx scratch sessions and keeps only cwd/root affinity badges", function()
    local cols = columns(agent({ mux_session = "gs/nvim/7f3a" }, {
      affinity = {
        badges = {
          { text = "cwd", hl = "SidekickCliAffinityCwd" },
          { text = "root", hl = "SidekickCliAffinityRoot" },
          { text = "win", hl = "SidekickCliAffinityWindow" },
          { text = "pane", hl = "SidekickCliAffinityPane" },
        },
      },
    }))
    local badges = by_id(cols).badges
    assert.matches("⧉", text(badges.parts))
    assert.matches("%[cwd%]", text(badges.parts))
    assert.matches("%[root%]", text(badges.parts))
    assert.is_nil(text(badges.parts):find("%[win%]"))
    assert.is_nil(text(badges.parts):find("%[pane%]"))
    assert.is_true(vim.tbl_contains(hls(badges.parts), "SidekickPickerPopup"))
  end)

  it("renders a start hint for tools without a session", function()
    local cols = columns({ installed = true, tool = { name = "claude" } })
    local col = by_id(cols)
    assert.matches("claude", text(col.tool.parts))
    assert.matches("start new agent", text(col.loc.parts))
    assert.are.equal("", vim.trim(text(col.label.parts)))
    assert.is_true(#vim.trim(text(col.path.parts)) > 0)
  end)
end)

describe("cli select formatter", function()
  it("flattens columns into highlighted parts", function()
    local parts = Select.format(agent(nil, {
      affinity = { badges = { { text = "cwd", hl = "SidekickCliAffinityCwd" } } },
    }))

    local line = text(parts)
    assert.matches("codex", line)
    assert.matches("panda", line)
    assert.matches("MAIN › editor", line)
    assert.matches("%[cwd%]", line)
    assert.is_true(vim.tbl_contains(hls(parts), "SidekickCliAffinityCwd"))
    assert.is_true(vim.tbl_contains(hls(parts), "SidekickPickerLabel"))
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
