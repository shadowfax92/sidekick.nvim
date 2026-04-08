# sidekick.nvim (fork)

Fork of [folke/sidekick.nvim](https://github.com/folke/sidekick.nvim) with enhanced tmux integration and send workflows.

For upstream docs, features, and configuration, see the [original README](https://github.com/folke/sidekick.nvim#readme).

## Fork Changes

### Send with Comment

New `cli.send_with_comment(opts)` function that opens a multiline floating popup (via `Snacks.win`) to add a comment before sending context to an AI tool.

- Context (file path, line range, code) is captured before the popup opens, so visual selections are preserved
- Context is shown as read-only preview lines at the top of the popup
- Comments are sent as blockquotes (`> comment`) prepended to the code context
- Keybinds: `<Esc>` then `<CR>` to send, `q` to cancel

```lua
require("sidekick.cli").send_with_comment({ msg = "{line}" })
```

### Visual Selection Sends File + Line Range + Code Fence

When sending a visual selection, the message now includes the file path and line range, with the code wrapped in a fenced code block:

```
@file.lua :L10-L20
` ` `
<selected code>
` ` `
```

This applies to both `send()` and `send_with_comment()` when triggered from visual mode.

### Absolute Path Context Placeholders

New context placeholders that resolve to the absolute file path instead of the cwd-relative one:

- `{file_abs}` — absolute file path
- `{line_abs}` — absolute file path with line number(s)
- `{position_abs}` — absolute file path with line:col

Useful when the AI tool is running outside the project's cwd (e.g., an attached tmux session in a different directory). Visual-mode auto-upgrade also applies: `msg = "{line_abs}"` in visual mode becomes `{line_abs}` + fenced `{selection}`.

### Better Tmux Pane Identification

The session picker now shows `window.pane` for external tmux sessions, matching standard tmux addressing:

```
[tmux:mysession:1.0]   ~/projects/myapp
```

The window and pane parts prefer human-readable names when available:

- Window: uses `#{window_name}` if non-empty, otherwise falls back to `#{window_index}`.
- Pane: uses the `@pane_label` tmux user option if set (`tmux set-option -p @pane_label panda`), otherwise falls back to `#{pane_index}`.

So a session with a renamed window (`editor`) and a labeled pane (`panda`) shows as:

```
[tmux:mysession:editor.panda]   ~/projects/myapp
```

No more monkey-patching `select_mod.format` to get pane numbers.

### Auto-Attach to External Sessions

When exactly one external session matches a filter (tool name + cwd), sidekick auto-attaches without showing the picker. A notification shows which tool was attached.

Controlled by config:

```lua
cli = {
  mux = {
    auto_attach = true, -- default
  },
}
```

### Visual Mode Fix

`send()` uses `vim.api.nvim_get_mode()` directly instead of `Util.visual_mode()` for reliable visual mode detection. When in visual mode with `msg = "{line}"`, it auto-upgrades to include the selection.

## Example Config (lazy.nvim)

```lua
{
  "folke/sidekick.nvim",
  url = "https://github.com/shadowfax92/sidekick.nvim",
  branch = "upstream",
  opts = {
    nes = { enabled = false },
    cli = {
      win = { layout = "right", split = { width = 0.4 } },
      mux = { backend = "tmux", enabled = true, auto_attach = true },
      tools = {
        claude = { cmd = { "claude", "--dangerously-skip-permissions" } },
        codex = { cmd = { "codex", "--yolo" } },
      },
    },
  },
  keys = {
    { "<leader>av", function() require("sidekick.cli").send({ msg = "{line}", filter = { name = "claude", cwd = true }, focus = false }) end, mode = { "n", "v" }, desc = "Send to Claude" },
    { "<leader>ax", function() require("sidekick.cli").send({ msg = "{line}", filter = { name = "codex", cwd = true }, focus = false }) end, mode = { "n", "v" }, desc = "Send to Codex" },
    { "<leader>ai", function() require("sidekick.cli").send_with_comment({ msg = "{line}" }) end, mode = { "n", "v" }, desc = "Send with Comment" },
    { "<leader>aI", function() require("sidekick.cli").send_with_comment({ msg = "{line_abs}" }) end, mode = { "n", "v" }, desc = "Send with Comment (abs path)" },
    { "<leader>aa", function() require("sidekick.cli").toggle({ focus = true }) end, mode = { "n", "v" }, desc = "Toggle CLI" },
    { "<leader>ac", function() require("sidekick.cli").toggle({ name = "claude", focus = true }) end, desc = "Toggle Claude" },
    { "<leader>as", function() require("sidekick.cli").select() end, desc = "Select CLI" },
    { "<leader>ad", function() require("sidekick.cli").close() end, desc = "Detach CLI" },
    { "<leader>ap", function() require("sidekick.cli").prompt() end, mode = { "n", "x" }, desc = "Select Prompt" },
    { "<M-/>", function() require("sidekick.cli").toggle() end, desc = "Toggle", mode = { "n", "t", "i", "x" } },
  },
}
```
