---@module 'luassert'

local Cli = require("sidekick.cli")
local Config = require("sidekick.config")
local State = require("sidekick.cli.state")
local Util = require("sidekick.util")

describe("cli send defaults", function()
  local original_comment_open
  local original_multicast
  local original_render
  local original_info
  local original_schedule
  local original_warn
  local original_with

  before_each(function()
    original_comment_open = require("sidekick.cli.ui.comment").open
    original_multicast = Config.cli.multicast
    original_render = Cli.render
    original_info = Util.info
    original_schedule = vim.schedule
    original_warn = Util.warn
    original_with = State.with
  end)

  after_each(function()
    require("sidekick.cli.ui.comment").open = original_comment_open
    Config.cli.multicast = original_multicast
    Cli.render = original_render
    Util.info = original_info
    vim.schedule = original_schedule
    Util.warn = original_warn
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

  it("send_with_comment captures the current file window before stale non-file windows", function()
    local tmp = vim.fn.tempname() .. ".lua"
    vim.fn.writefile({ "local foo = 1" }, tmp)

    local file_buf = vim.fn.bufadd(tmp)
    vim.fn.bufload(file_buf)
    vim.bo[file_buf].buflisted = true

    local file_win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(file_win, file_buf)
    vim.api.nvim_win_set_cursor(file_win, { 1, 0 })

    local scratch_buf = vim.api.nvim_create_buf(false, true)
    local scratch_win = vim.api.nvim_open_win(scratch_buf, false, {
      relative = "editor",
      width = 20,
      height = 1,
      row = 0,
      col = 0,
    })

    vim.w[file_win].sidekick_visit = 1
    vim.w[scratch_win].sidekick_visit = 2
    vim.api.nvim_set_current_win(file_win)

    local opened
    local warned
    require("sidekick.cli.ui.comment").open = function(opts)
      opened = opts
    end
    Util.warn = function(msg)
      warned = msg
    end

    Cli.send_with_comment({ msg = "{line}" })

    assert.is_nil(warned)
    assert.is_truthy(opened)
    assert.is_truthy(opened.context_lines[1]:find(vim.fn.fnamemodify(tmp, ":t"), 1, true))

    vim.api.nvim_win_close(scratch_win, true)
    vim.api.nvim_buf_delete(scratch_buf, { force = true })
    vim.api.nvim_buf_delete(file_buf, { force = true })
    vim.fn.delete(tmp)
  end)

  it("send_with_comment uses visual selection when line context is unavailable", function()
    local scratch_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(scratch_buf, 0, -1, false, {
      "selected one",
      "selected two",
    })
    local win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, scratch_buf)
    vim.api.nvim_win_set_cursor(win, { 1, 0 })
    vim.cmd("normal! V")
    vim.api.nvim_win_set_cursor(win, { 2, 0 })

    local opened
    local warned
    require("sidekick.cli.ui.comment").open = function(opts)
      opened = opts
    end
    Util.warn = function(msg)
      warned = msg
    end

    Cli.send_with_comment({ msg = "{line}" })

    assert.is_nil(warned)
    assert.is_truthy(opened)
    assert.are.same({ "selected one", "selected two" }, opened.context_lines)

    vim.api.nvim_buf_delete(scratch_buf, { force = true })
  end)
end)
