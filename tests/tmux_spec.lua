---@module 'luassert'

local Tmux = require("sidekick.cli.session.tmux")
local Util = require("sidekick.util")

describe("tmux session parser", function()
  local original_exec

  before_each(function()
    original_exec = Util.exec
  end)

  after_each(function()
    Util.exec = original_exec
  end)

  it("keeps panes whose tmux layout title contains a newline", function()
    local field_sep = "\tSIDEKICK_FIELD\t"
    local record_sep = "\tSIDEKICK_RECORD\t"
    local stdout = table.concat({
      "$3",
      "%274",
      "85258",
      "@build_work_weave-v04",
      "auctor e2e",
      "1",
      "0",
      "",
      "auctor e2e\npaperclip.1.1 akita",
      "1783619633",
      "/Users/felarof01/Workspaces/build/COMPANY_ADMIN/auctor-v4",
    }, field_sep) .. record_sep .. "\n"

    Util.exec = function(cmd)
      assert.are.same({ "tmux", "list-panes", "-a", "-F" }, vim.list_slice(cmd, 1, 4))
      assert.is_truthy(cmd[5]:find(field_sep, 1, true))
      assert.is_truthy(cmd[5]:find(record_sep, 1, true))

      return vim.split(stdout, "\n", { plain = true, trimempty = true }), stdout
    end

    local panes = Tmux.panes()

    assert.are.equal(1, #panes)
    assert.are.equal("%274", panes[1].id)
    assert.are.equal(85258, panes[1].pid)
    assert.are.equal("@build_work_weave-v04", panes[1].session_name)
    assert.are.equal("auctor e2e", panes[1].window_name)
    assert.are.equal("auctor e2e paperclip.1.1 akita", panes[1].layouts_title)
    assert.are.equal(1783619633, panes[1].window_activity)
    assert.are.equal("/Users/felarof01/Workspaces/build/COMPANY_ADMIN/auctor-v4", panes[1].cwd)
  end)
end)
