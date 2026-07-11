---@module 'luassert'

local Tool = require("sidekick.cli.tool")

describe("cli tool process detection", function()
  it("matches tool executable names", function()
    assert.is_true(Tool.get("claude"):is_proc({ cmd = "claude --dangerously-skip-permissions" }))
    assert.is_true(Tool.get("codex"):is_proc({
      cmd = "/Users/shadowfax/.local/bin/codex --dangerously-bypass-approvals-and-sandbox",
    }))
  end)

  it("does not match tool names from process arguments", function()
    local proc = {
      cmd = table.concat({
        "/Users/shadowfax/.local/share/nvm/v22.18.0/bin/node",
        "--max-old-space-size=3072",
        "/Users/shadowfax/code/browseros-project/grove-ref/browseros-main/.grove/worktrees/fix/codex-claude-acpx-dirs/packages/browseros-agent/node_modules/typescript/lib/tsserver.js",
      }, " "),
    }

    assert.is_false(Tool.get("claude"):is_proc(proc))
    assert.is_false(Tool.get("codex"):is_proc(proc))
  end)
end)
