---@module 'luassert'

local Config = require("sidekick.config")
local Session = require("sidekick.cli.session")
local State = require("sidekick.cli.state")

describe("cli state", function()
  local env
  local original_tmx_scratch
  local original_sessions
  local original_cwd
  local original_tools

  local function set_env(values)
    for key, value in pairs(values) do
      vim.env[key] = value
    end
  end

  local function restore()
    for key, value in pairs(env) do
      vim.env[key] = value
    end
    Config.cli.mux.tmx_scratch = original_tmx_scratch
    Session.sessions = original_sessions
    Session.cwd = original_cwd
    Config.tools = original_tools
  end

  before_each(function()
    env = {
      TMX_SCRATCH = vim.env.TMX_SCRATCH,
      TMX_PARENT_PANE = vim.env.TMX_PARENT_PANE,
    }
    original_tmx_scratch = Config.cli.mux.tmx_scratch
    original_sessions = Session.sessions
    original_cwd = Session.cwd
    original_tools = Config.tools
    Config.cli.mux.tmx_scratch = true
    set_env({ TMX_SCRATCH = vim.NIL, TMX_PARENT_PANE = vim.NIL })
  end)

  after_each(restore)

  describe("tmx_parent_pane", function()
    it("returns the parent pane in a supported tmx scratch pane", function()
      set_env({ TMX_SCRATCH = "1", TMX_PARENT_PANE = "%16" })

      assert.are.equal("%16", State.tmx_parent_pane())
    end)

    it("returns nil when tmx scratch support is disabled", function()
      set_env({ TMX_SCRATCH = "1", TMX_PARENT_PANE = "%16" })
      Config.cli.mux.tmx_scratch = false

      assert.is_nil(State.tmx_parent_pane())
    end)

    it("returns nil outside a tmx scratch pane", function()
      set_env({ TMX_PARENT_PANE = "%16" })

      assert.is_nil(State.tmx_parent_pane())
    end)

    it("returns nil without a parent pane", function()
      set_env({ TMX_SCRATCH = "1" })

      assert.is_nil(State.tmx_parent_pane())
    end)
  end)

  it("sorts the tmx scratch parent pane before equivalent sessions", function()
    local cwd = "/tmp/sidekick"
    local codex = { name = "codex" }
    local function session(pane_id)
      return {
        id = "tmux " .. pane_id,
        sid = "codex sid",
        cwd = cwd,
        tool = codex,
        backend = "tmux",
        started = true,
        external = true,
        priority = 10,
        tmux_pane_id = pane_id,
        pids = { tonumber(pane_id:sub(2)) },
        is_attached = function()
          return false
        end,
      }
    end

    set_env({ TMX_SCRATCH = "1", TMX_PARENT_PANE = "%16" })
    Session.cwd = function()
      return cwd
    end
    Config.tools = function()
      return {}
    end
    Session.sessions = function()
      return { session("%42"), session("%16") }
    end

    local states = State.get({ started = true, name = "codex" })

    assert.are.equal("%16", states[1].session.tmux_pane_id)
    assert.are.equal("%42", states[2].session.tmux_pane_id)
  end)
end)
