local M = {}

---@class sidekick.cli.CommentOpts
---@field context_lines? string[] read-only context preview lines
---@field cb fun(comment?: string) called with multiline comment or nil on cancel

---@param opts sidekick.cli.CommentOpts
function M.open(opts)
  local ok, Snacks = pcall(require, "snacks")
  if not ok then
    -- fallback to vim.ui.input when snacks is not available
    vim.ui.input({ prompt = "Comment: " }, function(input)
      opts.cb(input and input ~= "" and input or nil)
    end)
    return
  end

  local ctx = opts.context_lines or {}
  local separator = ctx[1] and "---" or nil

  -- pre-fill buffer: context preview (commented) + separator + empty line for editing
  local lines = {} ---@type string[]
  for _, line in ipairs(ctx) do
    lines[#lines + 1] = "# " .. line
  end
  if separator then
    lines[#lines + 1] = separator
  end
  lines[#lines + 1] = ""

  local edit_start = #lines -- 1-indexed line where user starts typing

  local win = Snacks.win({
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
  })

  if not win or not win.buf then
    opts.cb(nil)
    return
  end

  vim.api.nvim_buf_set_lines(win.buf, 0, -1, false, lines)

  -- make context lines read-only via extmarks
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

  -- place cursor at the editable line
  if win.win and vim.api.nvim_win_is_valid(win.win) then
    vim.api.nvim_win_set_cursor(win.win, { edit_start, 0 })
    vim.cmd.startinsert()
  end

  -- submit: <CR> in normal mode (type comment, <Esc>, then <CR> to send)
  vim.keymap.set("n", "<CR>", function()
    if not vim.api.nvim_buf_is_valid(win.buf) then
      return
    end
    local all = vim.api.nvim_buf_get_lines(win.buf, 0, -1, false)
    -- extract only user-written lines (after the context + separator)
    local comment_lines = vim.list_slice(all, edit_start)
    -- trim trailing empty lines
    while #comment_lines > 0 and comment_lines[#comment_lines] == "" do
      table.remove(comment_lines)
    end
    win:close()
    local comment = table.concat(comment_lines, "\n")
    opts.cb(comment ~= "" and comment or nil)
  end, { buffer = win.buf, desc = "Send comment" })
end

return M
