local Config = require("sidekick.config")

local M = {}

M.retention_seconds = 24 * 60 * 60

local function dir()
  return Config.state("comment-drafts")
end

local function stamp(time)
  return os.date("%Y-%m-%d %H:%M:%S", time)
end

local function filename(time)
  return os.date("%Y-%m-%d-%H%M%S", time) .. "-" .. tostring(vim.uv.hrtime()):sub(-6) .. ".md"
end

local function lines_for(draft, comment, status, prompt)
  local lines = {
    "# Sidekick Comment Draft",
    "",
    ("- status: %s"):format(status or draft.status or "draft"),
    ("- created: %s"):format(stamp(draft.created)),
    "",
    "## Comment",
    "",
  }
  vim.list_extend(lines, vim.split(comment or "", "\n", { plain = true }))
  lines[#lines + 1] = ""
  lines[#lines + 1] = "## Context"
  lines[#lines + 1] = ""
  vim.list_extend(lines, draft.context_lines or {})
  if prompt and prompt ~= "" then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "## Prompt"
    lines[#lines + 1] = ""
    vim.list_extend(lines, vim.split(prompt, "\n", { plain = true }))
  end
  return lines
end

--- Create a recoverable draft file for a comment popup session.
---@param context_lines? string[]
---@return sidekick.cli.CommentDraft
function M.create(context_lines)
  M.cleanup()
  vim.fn.mkdir(dir(), "p")
  local time = os.time()
  local draft = {
    path = dir() .. "/" .. filename(time),
    created = time,
    context_lines = context_lines or {},
    status = "draft",
  }
  M.save(draft, "")
  return draft
end

--- Persist the current popup body so an accidental close can be recovered.
---@param draft sidekick.cli.CommentDraft
---@param comment string
---@param status? "draft"|"sent"
---@param prompt? string
function M.save(draft, comment, status, prompt)
  if not draft or not draft.path then
    return
  end
  draft.status = status or draft.status or "draft"
  vim.fn.mkdir(vim.fn.fnamemodify(draft.path, ":h"), "p")
  vim.fn.writefile(lines_for(draft, comment, draft.status, prompt), draft.path)
end

--- Mark a draft as sent while keeping it available for short-term resend.
---@param draft sidekick.cli.CommentDraft?
---@param comment string
---@param prompt string
function M.mark_sent(draft, comment, prompt)
  if draft then
    M.save(draft, comment, "sent", prompt)
  end
end

--- Remove expired draft files from the short-term comment history.
---@param now? integer
function M.cleanup(now)
  now = now or os.time()
  for _, path in ipairs(vim.fn.glob(dir() .. "/*.md", false, true)) do
    local stat = vim.uv.fs_stat(path)
    if stat and now - stat.mtime.sec > M.retention_seconds then
      vim.fn.delete(path)
    end
  end
end

--- Return recent drafts sorted newest first.
---@return { path:string, mtime:integer }[]
function M.list()
  M.cleanup()
  local drafts = {} ---@type { path:string, mtime:integer }[]
  for _, path in ipairs(vim.fn.glob(dir() .. "/*.md", false, true)) do
    local stat = vim.uv.fs_stat(path)
    if stat then
      drafts[#drafts + 1] = { path = path, mtime = stat.mtime.sec }
    end
  end
  table.sort(drafts, function(a, b)
    return a.mtime > b.mtime
  end)
  return drafts
end

--- Select a recent comment draft and open it for copying or resending.
function M.select()
  local drafts = M.list()
  if #drafts == 0 then
    require("sidekick.util").warn("No Sidekick comment drafts from the last 24 hours.")
    return
  end
  vim.ui.select(drafts, {
    prompt = "Sidekick comment drafts",
    format_item = function(item)
      return ("%s  %s"):format(stamp(item.mtime), vim.fn.fnamemodify(item.path, ":t"))
    end,
  }, function(item)
    if item then
      vim.cmd.edit(vim.fn.fnameescape(item.path))
    end
  end)
end

return M
