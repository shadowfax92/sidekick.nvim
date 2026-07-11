---@module 'luassert'

local Affinity = require("sidekick.cli.affinity")
local Config = require("sidekick.config")
local Session = require("sidekick.cli.session")
local Tmux = require("sidekick.cli.session.tmux")

describe("cli affinity", function()
  local env_keys = { "TMUX_PANE", "TMX_PARENT_PANE", "TMX_SCRATCH" }
  local original_cwd
  local original_project
  local original_panes
  local original_tmx_scratch
  local original_worktree_siblings
  local original_env

  before_each(function()
    original_cwd = Session.cwd
    original_project = Affinity.project
    original_panes = Tmux.panes
    original_tmx_scratch = Config.cli.mux.tmx_scratch
    original_worktree_siblings = Config.cli.mux.auto_attach.worktree_siblings
    original_env = {}
    for _, key in ipairs(env_keys) do
      original_env[key] = vim.env[key] or vim.NIL
    end
  end)

  after_each(function()
    Session.cwd = original_cwd
    Affinity.project = original_project
    Tmux.panes = original_panes
    Config.cli.mux.tmx_scratch = original_tmx_scratch
    Config.cli.mux.auto_attach.worktree_siblings = original_worktree_siblings
    for key, value in pairs(original_env) do
      vim.env[key] = value
    end
    Affinity.reset()
  end)

  it("scores same worktree project and tmux affinity with badges", function()
    local projects = {
      ["/repo/app"] = { cwd = "/repo/app", worktree_root = "/repo/app", git_common_dir = "/git/main" },
      ["/repo/app/subdir"] = { cwd = "/repo/app/subdir", worktree_root = "/repo/app", git_common_dir = "/git/main" },
    }
    Affinity.project = function(path)
      return projects[path]
    end

    local affinity = Affinity.score({
      cwd = "/repo/app",
      project = projects["/repo/app"],
      tmux_session = "main",
      tmux_window_index = "2",
      tmux_pane_id = "%1",
    }, {
      cwd = "/repo/app/subdir",
      mux_session = "main",
      tmux_window_index = "2",
      tmux_pane_id = "%2",
    })

    assert.is_false(affinity.exact_cwd)
    assert.is_true(affinity.same_git_root)
    assert.is_true(affinity.same_tmux_session)
    assert.is_true(affinity.same_tmux_window)
    assert.is_false(affinity.same_tmux_pane)
    assert.is_true(affinity.same_repo)
    assert.are.equal(1050, affinity.score)
    assert.are.same({
      { text = "root", hl = "SidekickCliAffinityRoot" },
      { text = "repo", hl = "SidekickCliAffinityRepo" },
      { text = "win", hl = "SidekickCliAffinityWindow" },
    }, affinity.badges)
  end)

  it("recognises tmx scratch sessions by their gs/ prefix", function()
    assert.is_true(Affinity.is_scratch({ mux_session = "gs/nvim/7f3a" }))
    assert.is_false(Affinity.is_scratch({ mux_session = "gs" }))
    assert.is_false(Affinity.is_scratch({ mux_session = "logs/gs/x" }))
    assert.is_false(Affinity.is_scratch({ mux_session = "MAIN" }))
    assert.is_false(Affinity.is_scratch({}))
    assert.is_false(Affinity.is_scratch(nil))
  end)

  it("recognizes sibling worktrees as the same repository", function()
    Config.cli.mux.auto_attach.worktree_siblings = true
    local projects = {
      ["/repo/.worktrees/task-a"] = { cwd = "/repo/.worktrees/task-a", worktree_root = "/repo/.worktrees/task-a", git_common_dir = "/repo/.git" },
      ["/repo/.worktrees/task-b"] = { cwd = "/repo/.worktrees/task-b", worktree_root = "/repo/.worktrees/task-b", git_common_dir = "/repo/.git" },
    }
    Affinity.project = function(path)
      return projects[path]
    end

    local affinity = Affinity.score({
      cwd = "/repo/.worktrees/task-a",
      project = projects["/repo/.worktrees/task-a"],
      tmux_session = "main",
      tmux_window_index = "2",
      tmux_pane_id = "%1",
    }, {
      cwd = "/repo/.worktrees/task-b",
      mux_session = "other",
      tmux_window_index = "7",
      tmux_pane_id = "%7",
    })

    assert.is_false(affinity.same_git_root)
    assert.is_true(affinity.same_repo)
    assert.are.equal(400, affinity.score)
    assert.is_true(Affinity.in_scope(affinity, "project"))
    assert.are.same({ { text = "repo", hl = "SidekickCliAffinityRepo" } }, affinity.badges)

    Config.cli.mux.auto_attach.worktree_siblings = false
    assert.is_false(Affinity.in_scope(affinity, "project"))
  end)

  it("does not match worktrees from different repositories", function()
    local projects = {
      ["/repo-a/task"] = { cwd = "/repo-a/task", worktree_root = "/repo-a/task", git_common_dir = "/repo-a/.git" },
      ["/repo-b/task"] = { cwd = "/repo-b/task", worktree_root = "/repo-b/task", git_common_dir = "/repo-b/.git" },
    }
    Affinity.project = function(path)
      return projects[path]
    end

    local affinity = Affinity.score({
      cwd = "/repo-a/task",
      project = projects["/repo-a/task"],
    }, {
      cwd = "/repo-b/task",
    })

    assert.is_false(affinity.same_git_root)
    assert.is_false(affinity.same_repo)
    assert.are.equal(0, affinity.score)
    assert.are.same({}, affinity.badges)
  end)

  it("treats exact cwd as both cwd and project scoped", function()
    local project = { cwd = "/repo/app", worktree_root = "/repo/app", git_common_dir = "/git/main" }
    Affinity.project = function()
      return project
    end

    local affinity = Affinity.score({
      cwd = "/repo/app",
      project = project,
      tmux_session = "main",
      tmux_window_index = "2",
      tmux_pane_id = "%1",
    }, {
      cwd = "/repo/app",
      mux_session = "other",
      tmux_window_index = "9",
      tmux_pane_id = "%9",
    })

    assert.is_true(Affinity.in_scope(affinity, "cwd"))
    assert.is_true(Affinity.in_scope(affinity, "project"))
    assert.are.same({
      { text = "cwd", hl = "SidekickCliAffinityCwd" },
      { text = "root", hl = "SidekickCliAffinityRoot" },
      { text = "repo", hl = "SidekickCliAffinityRepo" },
    }, affinity.badges)
  end)

  it("uses the tmx scratch parent pane as the current tmux pane", function()
    Config.cli.mux.tmx_scratch = true
    vim.env.TMUX_PANE = "%scratch"
    vim.env.TMX_SCRATCH = "1"
    vim.env.TMX_PARENT_PANE = "%16"
    Session.cwd = function()
      return "/repo/app"
    end
    Affinity.project = function(path)
      return { cwd = path }
    end
    Tmux.panes = function()
      return {
        { id = "%scratch", session_name = "gs/sh/%scratch", window_index = "1" },
        { id = "%16", session_name = "main", window_index = "3" },
      }
    end

    local scope = Affinity.current_scope()

    assert.are.equal("%16", scope.tmux_pane_id)
    assert.are.equal("main", scope.tmux_session)
    assert.are.equal("3", scope.tmux_window_index)
  end)

  it("keeps the real tmux pane when tmx scratch support is disabled", function()
    Config.cli.mux.tmx_scratch = false
    vim.env.TMUX_PANE = "%scratch"
    vim.env.TMX_SCRATCH = "1"
    vim.env.TMX_PARENT_PANE = "%16"
    Session.cwd = function()
      return "/repo/app"
    end
    Affinity.project = function(path)
      return { cwd = path }
    end
    Tmux.panes = function()
      return {
        { id = "%scratch", session_name = "gs/sh/%scratch", window_index = "1" },
        { id = "%16", session_name = "main", window_index = "3" },
      }
    end

    local scope = Affinity.current_scope()

    assert.are.equal("%scratch", scope.tmux_pane_id)
    assert.are.equal("gs/sh/%scratch", scope.tmux_session)
    assert.are.equal("1", scope.tmux_window_index)
  end)
end)
