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

  it("scores project and tmux affinity with badges", function()
    local projects = {
      ["/repo/app"] = { cwd = "/repo/app", worktree_root = "/repo/app", git_common_dir = "/git/main" },
      ["/repo/other"] = { cwd = "/repo/other", worktree_root = "/repo/other", git_common_dir = "/git/main" },
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
      cwd = "/repo/other",
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
