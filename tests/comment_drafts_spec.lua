---@module 'luassert'

local Config = require("sidekick.config")

local function clear_drafts()
  vim.fn.delete(Config.state("comment-drafts"), "rf")
end

describe("comment drafts", function()
  before_each(function()
    clear_drafts()
  end)

  after_each(function()
    clear_drafts()
  end)

  it("removes drafts older than the retention window", function()
    local Drafts = require("sidekick.cli.comment_drafts")
    local dir = Config.state("comment-drafts")
    vim.fn.mkdir(dir, "p")

    local old = dir .. "/old.md"
    local fresh = dir .. "/fresh.md"
    vim.fn.writefile({ "old" }, old)
    vim.fn.writefile({ "fresh" }, fresh)

    local now = os.time()
    vim.uv.fs_utime(old, now - Drafts.retention_seconds - 1, now - Drafts.retention_seconds - 1)
    vim.uv.fs_utime(fresh, now, now)

    Drafts.cleanup(now)

    assert.are.equal(0, vim.fn.filereadable(old))
    assert.are.equal(1, vim.fn.filereadable(fresh))
  end)

  it("keeps sent drafts with the resendable prompt", function()
    local Drafts = require("sidekick.cli.comment_drafts")
    local draft = Drafts.create({ "example.lua:L1-L2" })

    Drafts.mark_sent(draft, "please refactor this", "> please refactor this\n\nexample.lua:L1-L2")

    local saved = table.concat(vim.fn.readfile(draft.path), "\n")
    assert.matches("status: sent", saved, 1, true)
    assert.matches("## Prompt", saved, 1, true)
    assert.matches("> please refactor this", saved, 1, true)
  end)

  it("autosaves comment popup text to a draft file", function()
    local original_snacks = package.loaded.snacks
    local Comment = require("sidekick.cli.ui.comment")

    local closed = false
    local popup_buf
    package.loaded.snacks = {
      win = function(opts)
        local buf = vim.api.nvim_create_buf(false, true)
        popup_buf = buf
        local win = vim.api.nvim_open_win(buf, false, {
          relative = "editor",
          width = 40,
          height = 6,
          row = 0,
          col = 0,
          style = "minimal",
        })
        return {
          buf = buf,
          win = win,
          opts = opts,
          close = function(self)
            closed = true
            if self.opts.on_close then
              self.opts.on_close(self)
            end
            if vim.api.nvim_win_is_valid(win) then
              vim.api.nvim_win_close(win, true)
            end
          end,
        }
      end,
    }

    local callback_comment
    Comment.open({
      context_lines = { "example.lua:L1-L2", "local foo = 1" },
      cb = function(comment)
        callback_comment = comment
      end,
    })

    vim.api.nvim_buf_set_lines(popup_buf, 3, -1, false, { "please refactor this", "keep behavior" })
    vim.api.nvim_exec_autocmds("TextChanged", { buffer = popup_buf, modeline = false })

    local files = vim.fn.glob(Config.state("comment-drafts") .. "/*.md", false, true)
    assert.are.equal(1, #files)
    local saved = table.concat(vim.fn.readfile(files[1]), "\n")
    assert.matches("please refactor this", saved, 1, true)
    assert.matches("local foo = 1", saved, 1, true)

    for _, map in ipairs(vim.api.nvim_buf_get_keymap(popup_buf, "n")) do
      if map.lhs == "<CR>" then
        map.callback()
        break
      end
    end

    assert.is_true(closed)
    assert.are.equal("please refactor this\nkeep behavior", callback_comment)

    package.loaded.snacks = original_snacks
  end)
end)
