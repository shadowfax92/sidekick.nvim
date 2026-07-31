# sidekick.nvim (fork)

**A Neovim AI sidekick, tuned for multi-agent tmux and Herdr workflows.**

Personal fork of [folke/sidekick.nvim](https://github.com/folke/sidekick.nvim). All credit and thanks to [@folke](https://github.com/folke) — the original plugin does the heavy lifting; this fork just layers on a few tweaks I wanted for driving multiple agents across tmux or Herdr panes.

See the [upstream README](https://github.com/folke/sidekick.nvim#readme) for everything else.

## What this fork adds

- **Send with comment** — `cli.send_with_comment()` opens a multiline popup (via `Snacks.win`) so you can add a note before sending; the comment goes in as a blockquote above the context block
- **Tmux and Herdr multicast + auto-attach** — sends fan out to every matching agent in the project scope; auto-attach runs on `VimEnter`, on-demand, or via `cli.auto_attach()`
- **tmx scratch affinity** — Neovim inside a `tmx` scratch pane prefers the parent pane's agent by default
- **Herdr agent discovery** — reads Herdr's native snapshot, displays agent names and lifecycle status with workspace/tab context, sends through Herdr's bracketed-input API, and focuses the selected Herdr pane
- **Agent picker** — `cli.select()` gets a native fzf-lua front-end: colored columns (`status · tool · agent or pane label · workspace/session › tab/window · badges · cwd`), fuzzy search scoped to the tool, `⧉` for agents living in `tmx` popups, the current location in green, `<ctrl-o>` to jump to the agent pane, `<ctrl-x>` to detach. Running agents always sort above "start a new tool"; ties break on backend activity. Falls back to `vim.ui.select` when fzf-lua isn't installed
- **Absolute-path placeholders** — `{file_abs}`, `{line_abs}`, `{position_abs}` for when the agent runs outside the project cwd
- **Richer visual sends** — selections include `@file :Lstart-Lend` and wrap code in a fenced block
- **Confirmation toasts** — short notification per send (`Sent comment to 3 agents · ~/proj/file.lua:L12-L18`)
- **Smaller fixes** — reliable visual-mode detection, shortened long paths/session names in pickers, deferred startup auto-attach

The picker's colors come from highlight groups, so they follow your colorscheme. Override any of
`SidekickPickerCurrent`, `SidekickPickerPopup`, `SidekickPickerLabel`, `SidekickPickerLoc`,
`SidekickPickerPath`, `SidekickToolClaude` or `SidekickToolCodex` to retune them; add
`SidekickTool<Name>` to give another tool its own color.

## Install (lazy.nvim)

```lua
{
  "folke/sidekick.nvim",
  url = "https://github.com/shadowfax92/sidekick.nvim",
  opts = {
    cli = {
      multicast = true,
      mux = {
        backend = vim.env.HERDR_ENV == "1" and "herdr" or "tmux",
        enabled = true,
        tmx_scratch = true,
        auto_attach = { startup = true, on_demand = true, scope = "project" },
      },
    },
  },
  keys = {
    { "<leader>av", function() require("sidekick.cli").send({ msg = "{line}", filter = { name = "claude", cwd = true }, focus = false }) end, mode = { "n", "v" }, desc = "Send to Claude" },
    { "<leader>ai", function() require("sidekick.cli").send_with_comment({ msg = "{line}" }) end, mode = { "n", "v" }, desc = "Send with Comment" },
    { "<leader>aA", function() require("sidekick.cli").auto_attach() end, desc = "Auto Attach Project Agents" },
    { "<M-/>", function() require("sidekick.cli").toggle() end, desc = "Toggle", mode = { "n", "t", "i", "x" } },
  },
}
```

For the full config surface, see the [upstream README](https://github.com/folke/sidekick.nvim#readme).
