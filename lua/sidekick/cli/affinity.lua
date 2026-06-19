local Config = require("sidekick.config")
local Session = require("sidekick.cli.session")
local Util = require("sidekick.util")

local M = {}

local project_cache = {} ---@type table<string, sidekick.cli.Project>

---@class sidekick.cli.Project
---@field cwd string
---@field worktree_root? string
---@field git_common_dir? string

---@class sidekick.cli.Scope
---@field cwd string
---@field project? sidekick.cli.Project
---@field tmux_session? string
---@field tmux_window_index? string
---@field tmux_pane_id? string

---@class sidekick.cli.AffinityBadge
---@field text string
---@field hl string

---@class sidekick.cli.Affinity
---@field exact_cwd boolean
---@field same_git_root boolean
---@field same_tmux_session boolean
---@field same_tmux_window boolean
---@field same_tmux_pane boolean
---@field score integer
---@field badges sidekick.cli.AffinityBadge[]

---@param path string?
local function normalize(path)
  return path and vim.fs.normalize(path) or nil
end

---@param project sidekick.cli.Project?
---@return string?
local function project_id(project)
  if not project then
    return
  end
  -- Linked worktrees share git_common_dir, but they should not collapse into one Sidekick project scope.
  return project.worktree_root or project.git_common_dir
end

---@param affinity sidekick.cli.Affinity
local function badges(affinity)
  local ret = {} ---@type sidekick.cli.AffinityBadge[]
  if affinity.exact_cwd then
    ret[#ret + 1] = { text = "cwd", hl = "SidekickCliAffinityCwd" }
  end
  if affinity.same_git_root then
    ret[#ret + 1] = { text = "root", hl = "SidekickCliAffinityRoot" }
  end
  if affinity.same_tmux_window then
    ret[#ret + 1] = { text = "win", hl = "SidekickCliAffinityWindow" }
  end
  if affinity.same_tmux_pane then
    ret[#ret + 1] = { text = "pane", hl = "SidekickCliAffinityPane" }
  end
  return ret
end

---@param affinity sidekick.cli.Affinity
local function score(affinity)
  local ret = 0
  if affinity.exact_cwd then
    ret = ret + 1000
  end
  if affinity.same_git_root then
    ret = ret + 500
  end
  if affinity.same_tmux_session then
    ret = ret + 100
  end
  if affinity.same_tmux_window then
    ret = ret + 50
  end
  if affinity.same_tmux_pane then
    ret = ret + 25
  end
  return ret
end

---@param path string?
---@return sidekick.cli.Project?
function M.project(path)
  path = normalize(path)
  if not path then
    return
  end
  local cached = project_cache[path]
  if cached ~= nil then
    return cached
  end
  local lines = Util.exec(
    { "git", "-C", path, "rev-parse", "--path-format=absolute", "--show-toplevel", "--git-common-dir" },
    { notify = false }
  )
  local project = { cwd = path } ---@type sidekick.cli.Project
  if lines and lines[1] then
    project.worktree_root = normalize(lines[1])
    project.git_common_dir = normalize(lines[2])
  end
  project_cache[path] = project
  return project
end

---@return sidekick.tmux.Pane?
function M.current_tmux()
  local pane_id = M.tmx_parent_pane() or vim.env.TMUX_PANE
  if not pane_id then
    return
  end
  local ok, Tmux = pcall(require, "sidekick.cli.session.tmux")
  if not ok then
    return
  end
  for _, pane in ipairs(Tmux.panes({ notify = false })) do
    if pane.id == pane_id then
      return pane
    end
  end
end

--- Resolve the tmx scratch parent pane Sidekick should treat as current.
---@return string?
function M.tmx_parent_pane()
  if Config.cli.mux.tmx_scratch ~= true or vim.env.TMX_SCRATCH ~= "1" then
    return
  end
  local pane = vim.env.TMX_PARENT_PANE
  return pane ~= "" and pane or nil
end

---@return sidekick.cli.Scope
function M.current_scope()
  local parent_pane = M.tmx_parent_pane()
  local pane = M.current_tmux()
  return {
    cwd = Session.cwd(),
    project = M.project(Session.cwd()),
    tmux_session = pane and pane.session_name or nil,
    tmux_window_index = pane and pane.window_index or nil,
    tmux_pane_id = pane and pane.id or parent_pane or vim.env.TMUX_PANE or nil,
  }
end

---@param scope sidekick.cli.Scope
---@param session sidekick.cli.Session|sidekick.cli.session.State
---@return sidekick.cli.Affinity
function M.score(scope, session)
  local session_project = M.project(session.cwd)
  local affinity = {
    exact_cwd = scope.cwd == session.cwd,
    same_git_root = false,
    same_tmux_session = scope.tmux_session ~= nil and scope.tmux_session == session.mux_session,
    same_tmux_window = false,
    same_tmux_pane = scope.tmux_pane_id ~= nil and scope.tmux_pane_id == session.tmux_pane_id,
    score = 0,
    badges = {},
  } ---@type sidekick.cli.Affinity

  local scope_project = scope.project
  if scope_project and session_project then
    affinity.same_git_root = project_id(scope_project) ~= nil and project_id(scope_project) == project_id(session_project)
  end

  if affinity.same_tmux_session and scope.tmux_window_index ~= nil then
    affinity.same_tmux_window = tostring(scope.tmux_window_index) == tostring(session.tmux_window_index)
  end

  affinity.score = score(affinity)
  affinity.badges = badges(affinity)
  return affinity
end

---@param affinity sidekick.cli.Affinity?
---@param scope "cwd"|"project"|"all"
function M.in_scope(affinity, scope)
  if scope == "all" then
    return true
  end
  if not affinity then
    return false
  end
  if scope == "cwd" then
    return affinity.exact_cwd
  end
  return affinity.exact_cwd or affinity.same_git_root
end

function M.reset()
  project_cache = {}
end

return M
