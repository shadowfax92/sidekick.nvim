---@module 'luassert'

local Affinity = require("sidekick.cli.affinity")

describe("cli affinity", function()
  local original_project

  before_each(function()
    original_project = Affinity.project
  end)

  after_each(function()
    Affinity.project = original_project
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
    assert.are.equal(650, affinity.score)
    assert.are.same({
      { text = "root", hl = "SidekickCliAffinityRoot" },
      { text = "win", hl = "SidekickCliAffinityWindow" },
    }, affinity.badges)
  end)

  it("does not treat sibling worktrees as the same project", function()
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
    assert.is_false(Affinity.in_scope(affinity, "project"))
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
    }, affinity.badges)
  end)
end)
