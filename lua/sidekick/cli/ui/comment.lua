local M = {}

---@class sidekick.cli.CommentOpts
---@field context_lines? string[] read-only context preview lines
---@field cb fun(comment?: string, draft?: sidekick.cli.CommentDraft) called with multiline comment or nil on cancel

---@class sidekick.cli.CommentDraft
---@field path string
---@field created integer
---@field context_lines string[]
---@field status "draft"|"sent"

--- Open the multiline comment popup and keep a recoverable draft while it is edited.
---@param opts sidekick.cli.CommentOpts
function M.open(opts)
  local ok, Snacks = pcall(require, "snacks")
  if not ok then
    vim.ui.input({ prompt = "Comment: " }, function(input)
      opts.cb(input and input ~= "" and input or nil)
    end)
    return
  end

  local Drafts = require("sidekick.cli.comment_drafts")
  local ctx = opts.context_lines or {}
  local draft = Drafts.create(ctx)
  local separator = ctx[1] and "---" or nil

  local lines = {} ---@type string[]
  for _, line in ipairs(ctx) do
    lines[#lines + 1] = "# " .. line
  end
  if separator then
    lines[#lines + 1] = separator
  end
  lines[#lines + 1] = ""

  local edit_start = #lines
  local last_comment = ""
  local sent = false
  local win

  local function read_comment()
    if not vim.api.nvim_buf_is_valid(win.buf) then
      return last_comment
    end
    local all = vim.api.nvim_buf_get_lines(win.buf, 0, -1, false)
    local comment_lines = vim.list_slice(all, edit_start)
    while #comment_lines > 0 and comment_lines[#comment_lines] == "" do
      table.remove(comment_lines)
    end
    last_comment = table.concat(comment_lines, "\n")
    return last_comment
  end

  local function save()
    Drafts.save(draft, read_comment())
  end

  win = Snacks.win({
    position = "float",
    width = 0.6,
    height = math.min(20, edit_start + 5),
    border = "rounded",
    title = " Comment  <Esc> then <CR> to send | q to cancel ",
    title_pos = "center",
    backdrop = 60,
    wo = {
      wrap = true,
      spell = false,
      number = false,
      relativenumber = false,
      cursorline = true,
      signcolumn = "no",
    },
    bo = {
      buftype = "nofile",
      filetype = "markdown",
      modifiable = true,
    },
    keys = {
      q = "close",
    },
    on_close = function()
      save()
      if not sent and last_comment ~= "" then
        require("sidekick.util").info("Sidekick comment draft saved: " .. draft.path, { timeout = 2000 })
      end
    end,
  })

  if not win or not win.buf then
    opts.cb(nil)
    return
  end

  vim.api.nvim_buf_set_lines(win.buf, 0, -1, false, lines)

  if #ctx > 0 then
    local ns = vim.api.nvim_create_namespace("sidekick_comment_ctx")
    for i = 0, #ctx - 1 do
      vim.api.nvim_buf_set_extmark(win.buf, ns, i, 0, {
        hl_group = "Comment",
        end_row = i,
        end_col = #lines[i + 1],
      })
    end
  end

  if win.win and vim.api.nvim_win_is_valid(win.win) then
    vim.api.nvim_win_set_cursor(win.win, { edit_start, 0 })
    vim.cmd.startinsert()
  end

  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "BufLeave" }, {
    buffer = win.buf,
    callback = save,
  })

  vim.keymap.set("n", "<CR>", function()
    if not vim.api.nvim_buf_is_valid(win.buf) then
      return
    end
    local comment = read_comment()
    sent = comment ~= ""
    win:close()
    opts.cb(comment ~= "" and comment or nil, draft)
  end, { buffer = win.buf, desc = "Send comment" })
end

return M
