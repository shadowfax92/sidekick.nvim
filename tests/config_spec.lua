---@module 'luassert'

local Config = require("sidekick.config")

describe("config highlights", function()
  local create_autocmd
  local create_user_command
  local schedule
  local set_hl

  before_each(function()
    create_autocmd = vim.api.nvim_create_autocmd
    create_user_command = vim.api.nvim_create_user_command
    schedule = vim.schedule
    set_hl = Config.set_hl
  end)

  after_each(function()
    vim.api.nvim_create_autocmd = create_autocmd
    vim.api.nvim_create_user_command = create_user_command
    vim.schedule = schedule
    Config.set_hl = set_hl
  end)

  it("initializes highlights and their ColorScheme handler synchronously", function()
    local calls = {}
    local color_scheme
    local scheduled

    vim.api.nvim_create_user_command = function() end
    vim.api.nvim_create_autocmd = function(event, opts)
      calls[#calls + 1] = event
      if event == "ColorScheme" then
        color_scheme = opts.callback
      end
    end
    vim.schedule = function(fn)
      scheduled = fn
    end
    Config.set_hl = function()
      calls[#calls + 1] = "set_hl"
    end

    Config.setup({})

    assert.are.same({ "set_hl", "ColorScheme" }, calls)
    assert.are.equal("function", type(color_scheme))
    assert.are.equal("function", type(scheduled))

    color_scheme()
    assert.are.same({ "set_hl", "ColorScheme", "set_hl" }, calls)
  end)
end)
