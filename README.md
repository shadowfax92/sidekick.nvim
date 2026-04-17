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

The session picker now shows the tmux window and pane address for external sessions:

```
[tmux:mysession:1.0]   ~/projects/myapp
```

If a human-readable name exists, Sidekick keeps the numeric address and appends the name:

- Window: `#{window_index}` or `#{window_index}(#{window_name})`
- Pane: `#{pane_index}` or `#{pane_index}(@pane_label)`

So a session with a renamed window (`editor`) and a labeled pane (`panda`) shows as:

```
[tmux:mysession:1(editor).0(panda)]   ~/projects/myapp
```

This keeps the stable tmux address visible while still surfacing the names you care about.

### Auto-Attach to External Sessions

Sidekick now auto-discovers matching tmux agents in the current project and attaches them automatically:

- on `VimEnter`, if startup auto-attach is enabled
- on demand, when a send/toggle/focus flow needs a target
- manually, via `require("sidekick.cli").auto_attach()`

Send flows multicast to all attached sessions by default. The configured scope is still used for startup and on-demand auto-attach, so current-project agents are added automatically before send dispatch.

Controlled by config:

```lua
cli = {
  multicast = true, -- default
  mux = {
    auto_attach = {
      startup = true,
      on_demand = true,
      scope = "project",
    },
  },
}
```

### Send Notifications

Every successful send-family operation shows a short confirmation notification for about one second.

Example:

```text
Sent comment to 3 agents · ~/project/file.lua:L12-L18
```

The notification includes:

- how many agents received the send
- what kind of send it was (`line`, `file`, `comment`, etc.)
- a brief context summary, usually the file and line range

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
      multicast = true,
      mux = {
        backend = "tmux",
        enabled = true,
        auto_attach = {
          startup = true,
          on_demand = true,
          scope = "project",
        },
      },
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
    { "<leader>aA", function() require("sidekick.cli").auto_attach() end, desc = "Auto Attach Project Agents" },
    { "<leader>ac", function() require("sidekick.cli").toggle({ name = "claude", focus = true }) end, desc = "Toggle Claude" },
    { "<leader>as", function() require("sidekick.cli").select() end, desc = "Select CLI" },
    { "<leader>ad", function() require("sidekick.cli").close() end, desc = "Detach CLI" },
    { "<leader>ap", function() require("sidekick.cli").prompt() end, mode = { "n", "x" }, desc = "Select Prompt" },
    { "<M-/>", function() require("sidekick.cli").toggle() end, desc = "Toggle", mode = { "n", "t", "i", "x" } },
  },
}
```

## Generated Reference

### Config

<!-- config:start -->

```lua
---@class sidekick.Config
local defaults = {
  nes = {
    ---@type boolean|fun(buf:integer):boolean?
    enabled = function(buf)
      return vim.g.sidekick_nes ~= false and vim.b.sidekick_nes ~= false
    end,
    debounce = 100,
    trigger = {
      -- events that trigger sidekick next edit suggestions
      events = { "ModeChanged i:n", "TextChanged", "User SidekickNesDone" },
    },
    clear = {
      -- events that clear the current next edit suggestion
      events = { "TextChangedI", "InsertEnter" },
      esc = true, -- clear next edit suggestions when pressing <Esc>
    },
    ---@class sidekick.diff.Opts
    ---@field inline? "words"|"chars"|false Enable inline diffs
    ---@field show? "always"|"cursor" `cursor` will only show the diff when the cursor is at the edit position.
    diff = {
      inline = "words",
      show = "always",
    },
    signs = true, -- show signs for next edit suggestions
    jumplist = true, -- add an entry to the jumplist
  },
  -- Work with AI cli tools directly from within Neovim
  cli = {
    multicast = true, -- send to all matching sessions in the current project scope
    watch = true, -- notify Neovim of file changes done by AI CLI tools
    ---@class sidekick.win.Opts
    win = {
      --- This is run when a new terminal is created, before starting it.
      --- Here you can change window options `terminal.opts`.
      ---@param terminal sidekick.cli.Terminal
      config = function(terminal) end,
      wo = {}, ---@type vim.wo
      bo = {}, ---@type vim.bo
      layout = "right", ---@type "float"|"left"|"bottom"|"top"|"right"
      --- Options used when layout is "float"
      ---@type vim.api.keyset.win_config
      float = {
        width = 0.9,
        height = 0.9,
      },
      -- Options used when layout is "left"|"bottom"|"top"|"right"
      ---@type vim.api.keyset.win_config
      split = {
        width = 80, -- set to 0 for default split width
        height = 20, -- set to 0 for default split height
      },
      --- CLI Tool Keymaps (default mode is `t`)
      ---@type table<string, sidekick.cli.Keymap|false>
      keys = {
        buffers       = { "<c-b>", "buffers"   , mode = "nt", desc = "open buffer picker" },
        files         = { "<c-f>", "files"     , mode = "nt", desc = "open file picker" },
        hide_n        = { "q"    , "hide"      , mode = "n" , desc = "hide the terminal window" },
        hide_ctrl_q   = { "<c-q>", "hide"      , mode = "n" , desc = "hide the terminal window" },
        hide_ctrl_dot = { "<c-.>", "hide"      , mode = "nt", desc = "hide the terminal window" },
        hide_ctrl_z   = { "<c-z>", "blur"      , mode = "nt", desc = "go back to the previous window without hiding the terminal" },
        prompt        = { "<c-p>", "prompt"    , mode = "t" , desc = "insert prompt or context" },
        stopinsert    = { "<c-q>", "stopinsert", mode = "t" , desc = "enter normal mode" },
        -- Navigate windows in terminal mode. Only active when:
        -- * layout is not "float"
        -- * there is another window in the direction
        -- With the default layout of "right", only `<c-h>` will be mapped
        nav_left      = { "<c-h>", "nav_left"  , expr = true, desc = "navigate to the left window" },
        nav_down      = { "<c-j>", "nav_down"  , expr = true, desc = "navigate to the below window" },
        nav_up        = { "<c-k>", "nav_up"    , expr = true, desc = "navigate to the above window" },
        nav_right     = { "<c-l>", "nav_right" , expr = true, desc = "navigate to the right window" },
      },
      ---@type fun(dir:"h"|"j"|"k"|"l")?
      --- Function that handles navigation between windows.
      --- Defaults to `vim.cmd.wincmd`. Used by the `nav_*` keymaps.
      nav = nil,
    },
    ---@class sidekick.cli.AutoAttach
    ---@field startup? boolean auto-attach matching sessions on `VimEnter`
    ---@field on_demand? boolean auto-attach matching sessions when a CLI flow requests a target
    ---@field scope? "cwd"|"project"|"all" scope used for startup and on-demand auto-attach
    ---@class sidekick.cli.Mux
    ---@field backend? "tmux"|"zellij" Multiplexer backend to persist CLI sessions
    mux = {
      backend = vim.env.ZELLIJ and "zellij" or "tmux", -- default to tmux unless zellij is detected
      enabled = false,
      -- terminal: new sessions will be created for each CLI tool and shown in a Neovim terminal
      -- window: when run inside a terminal multiplexer, new sessions will be created in a new tab
      -- split: when run inside a terminal multiplexer, new sessions will be created in a new split
      -- NOTE: zellij only supports `terminal`
      create = "terminal", ---@type "terminal"|"window"|"split"
      split = {
        vertical = true, -- vertical or horizontal split
        size = 0.5, -- size of the split (0-1 for percentage)
      },
      auto_attach = {
        startup = true,
        on_demand = true,
        scope = "project",
      },
    },
    --- Actual cli tool config is loaded from the runtime path `sk/cli/{tool}.lua` and merged with the config below.
    --- For default configs, see https://github.com/folke/sidekick.nvim/tree/main/sk/cli
    ---@type table<string, sidekick.cli.Config|{}>
    tools = {
      aider    = {},
      amazon_q = {},
      claude   = {},
      codex    = {},
      copilot  = {},
      crush    = {},
      cursor   = {},
      gemini   = {},
      grok     = {},
      opencode = {},
      pi       = {},
      qwen     = {},
    },
    --- Add custom context. See `lua/sidekick/context/init.lua`
    ---@type table<string, sidekick.context.Fn>
    context = {},
    ---@type table<string, sidekick.Prompt|string|fun(ctx:sidekick.context.ctx):(string?)>
    prompts = {
      changes         = "Can you review my changes?",
      diagnostics     = "Can you help me fix the diagnostics in {file}?\n{diagnostics}",
      diagnostics_all = "Can you help me fix these diagnostics?\n{diagnostics_all}",
      document        = "Add documentation to {function|line}",
      explain         = "Explain {this}",
      fix             = "Can you fix {this}?",
      optimize        = "How can {this} be optimized?",
      review          = "Can you review {file} for any issues or improvements?",
      tests           = "Can you write tests for {this}?",
      -- simple context prompts
      buffers         = "{buffers}",
      file            = "{file}",
      line            = "{line}",
      position        = "{position}",
      quickfix        = "{quickfix}",
      selection       = "{selection}",
      ["function"]    = "{function}",
      class           = "{class}",
    },
    -- preferred picker for selecting files
    ---@alias sidekick.picker "snacks"|"telescope"|"fzf-lua"
    picker = "snacks", ---@type sidekick.picker
  },
  copilot = {
    -- track copilot's status with `didChangeStatus`
    status = {
      enabled = true,
      level = vim.log.levels.WARN,
      -- set to vim.log.levels.OFF to disable notifications
      -- level = vim.log.levels.OFF,
    },
  },
  ui = {
    icons = {
      nes               = " ",
      attached          = " ",
      started           = " ",
      installed         = " ",
      missing           = " ",
      external_attached = "󰖩 ",
      external_started  = "󰖪 ",
      terminal_attached = " ",
      terminal_started  = " ",
    },
  },
  debug = false, -- enable debug logging
}
```

<!-- config:end -->

### Setup Base

<!-- setup_base:start -->

```lua
{
  "folke/sidekick.nvim",
  opts = {
    -- add any options here
    cli = {
      mux = {
        backend = "zellij",
        enabled = true,
      },
    },
  },
  keys = {
    {
      "<tab>",
      function()
        -- if there is a next edit, jump to it, otherwise apply it if any
        if not require("sidekick").nes_jump_or_apply() then
          return "<Tab>" -- fallback to normal tab
        end
      end,
      expr = true,
      desc = "Goto/Apply Next Edit Suggestion",
    },
    {
      "<c-.>",
      function() require("sidekick.cli").focus() end,
      desc = "Sidekick Focus",
      mode = { "n", "t", "i", "x" },
    },
    {
      "<leader>aa",
      function() require("sidekick.cli").toggle() end,
      desc = "Sidekick Toggle CLI",
    },
    {
      "<leader>as",
      function() require("sidekick.cli").select() end,
      -- Or to select only installed tools:
      -- require("sidekick.cli").select({ filter = { installed = true } })
      desc = "Select CLI",
    },
    {
      "<leader>ad",
      function() require("sidekick.cli").close() end,
      desc = "Detach a CLI Session",
    },
    {
      "<leader>at",
      function() require("sidekick.cli").send({ msg = "{this}" }) end,
      mode = { "x", "n" },
      desc = "Send This",
    },
    {
      "<leader>af",
      function() require("sidekick.cli").send({ msg = "{file}" }) end,
      desc = "Send File",
    },
    {
      "<leader>av",
      function() require("sidekick.cli").send({ msg = "{selection}" }) end,
      mode = { "x" },
      desc = "Send Visual Selection",
    },
    {
      "<leader>ap",
      function() require("sidekick.cli").prompt() end,
      mode = { "n", "x" },
      desc = "Sidekick Select Prompt",
    },
    -- Example of a keybinding to open Claude directly
    {
      "<leader>ac",
      function() require("sidekick.cli").toggle({ name = "claude", focus = true }) end,
      desc = "Sidekick Toggle Claude",
    },
  },
}
```

<!-- setup_base:end -->

### Setup Custom

<!-- setup_custom:start -->

```lua
{
  "folke/sidekick.nvim",
  opts = {
    -- add any options here
  },
  keys = {
    {
      "<tab>",
      function()
        -- if there is a next edit, jump to it, otherwise apply it if any
        if require("sidekick").nes_jump_or_apply() then
          return -- jumped or applied
        end

        -- if you are using Neovim's native inline completions
        if vim.lsp.inline_completion.get() then
          return
        end

        -- any other things (like snippets) you want to do on <tab> go here.

        -- fall back to normal tab
        return "<tab>"
      end,
      mode = { "i", "n" },
      expr = true,
      desc = "Goto/Apply Next Edit Suggestion",
    },
  },
}
```

<!-- setup_custom:end -->

### Setup Blink

<!-- setup_blink:start -->

```lua
{
  "saghen/blink.cmp",
  ---@module 'blink.cmp'
  ---@type blink.cmp.Config
  opts = {

    keymap = {
      ["<Tab>"] = {
        "snippet_forward",
        function() -- sidekick next edit suggestion
          return require("sidekick").nes_jump_or_apply()
        end,
        function() -- if you are using Neovim's native inline completions
          return vim.lsp.inline_completion.get()
        end,
        "fallback",
      },
    },
  },
}
```

<!-- setup_blink:end -->

### Setup Lualine

<!-- setup_lualine:start -->

```lua
{
  "nvim-lualine/lualine.nvim",
  opts = function(_, opts)
    opts.sections = opts.sections or {}
    opts.sections.lualine_c = opts.sections.lualine_c or {}

    -- Copilot status
    table.insert(opts.sections.lualine_c, {
      function()
        return " "
      end,
      color = function()
        local status = require("sidekick.status").get()
        if status then
          return status.kind == "Error" and "DiagnosticError" or status.busy and "DiagnosticWarn" or "Special"
        end
      end,
      cond = function()
        local status = require("sidekick.status")
        return status.get() ~= nil
      end,
    })

    -- CLI session status
    table.insert(opts.sections.lualine_x, 2, {
      function()
        local status = require("sidekick.status").cli()
        return " " .. (#status > 1 and #status or "")
      end,
      cond = function()
        return #require("sidekick.status").cli() > 0
      end,
      color = function()
        return "Special"
      end,
    })
  end,
}
```

<!-- setup_lualine:end -->

### Snacks Picker

<!-- snacks_picker:start -->

```lua
{
  "folke/snacks.nvim",
  optional = true,
  opts = {
    picker = {
      actions = {
        sidekick_send = function(...)
          return require("sidekick.cli.picker.snacks").send(...)
        end,
      },
      win = {
        input = {
          keys = {
            ["<a-a>"] = {
              "sidekick_send",
              mode = { "n", "i" },
            },
          },
        },
      },
    },
  },
}
```

<!-- snacks_picker:end -->

### CLI API

<!-- api_cli:start -->

<table><tr><th>Cmd</th><th>Lua</th></tr>
<tr><td><code>:Sidekick cli auto_attach</code> </td><td>


```lua
---@param opts? sidekick.cli.Show
require("sidekick.cli").auto_attach(opts)
```

</td></tr>
<tr><td><code>:Sidekick cli close</code> </td><td>


```lua
---@param opts? sidekick.cli.Hide
---@overload fun(name: string)
require("sidekick.cli").close(opts)
```

</td></tr>
<tr><td><code>:Sidekick cli focus</code> Toggle focus of the terminal window if it is already open</td><td>


```lua
---@param opts? sidekick.cli.Show
---@overload fun(name: string)
require("sidekick.cli").focus(opts)
```

</td></tr>
<tr><td><code>:Sidekick cli hide</code> </td><td>


```lua
---@param opts? sidekick.cli.Hide
---@overload fun(name: string)
require("sidekick.cli").hide(opts)
```

</td></tr>
<tr><td><code>:Sidekick cli prompt</code> Select a prompt to send</td><td>


```lua
---@param opts? sidekick.cli.Prompt|{cb:nil}
---@overload fun(cb:fun(msg?:string))
require("sidekick.cli").prompt(opts)
```

</td></tr>
<tr><td> Render a message template or prompt</td><td>


```lua
---@param opts? sidekick.cli.Message|string
require("sidekick.cli").render(opts)
```

</td></tr>
<tr><td><code>:Sidekick cli select</code> Start or attach to a CLI tool</td><td>


```lua
---@param opts? sidekick.cli.Select|{cb:nil}|{focus?:boolean}
---@overload fun(cb:fun(state?:sidekick.cli.State))
require("sidekick.cli").select(opts)
```

</td></tr>
<tr><td><code>:Sidekick cli send</code> Send a message or prompt to a CLI</td><td>


```lua
---@param opts? sidekick.cli.Send
---@overload fun(msg:string)
require("sidekick.cli").send(opts)
```

</td></tr>
<tr><td> Send context with a multiline comment popup</td><td>


```lua
---@param opts? sidekick.cli.Send
---@overload fun(msg:string)
require("sidekick.cli").send_with_comment(opts)
```

</td></tr>
<tr><td><code>:Sidekick cli show</code> </td><td>


```lua
---@param opts? sidekick.cli.Show
---@overload fun(name: string)
require("sidekick.cli").show(opts)
```

</td></tr>
<tr><td><code>:Sidekick cli toggle</code> </td><td>


```lua
---@param opts? sidekick.cli.Show
---@overload fun(name: string)
require("sidekick.cli").toggle(opts)
```

</td></tr>
</table>

<!-- api_cli:end -->

### NES API

<!-- api_nes:start -->

<table><tr><th>Cmd</th><th>Lua</th></tr>
<tr><td><code>:Sidekick nes apply</code> Apply active text edits</td><td>


```lua
---@return boolean applied
require("sidekick.nes").apply()
```

</td></tr>
<tr><td><code>:Sidekick nes clear</code> Clear all active edits</td><td>


```lua
require("sidekick.nes").clear()
```

</td></tr>
<tr><td><code>:Sidekick nes disable</code> </td><td>


```lua

require("sidekick.nes").disable()
```

</td></tr>
<tr><td><code>:Sidekick nes enable</code> </td><td>


```lua
---@param enable? boolean
require("sidekick.nes").enable(enable)
```

</td></tr>
<tr><td> Check if any edits are active in the current buffer</td><td>


```lua
require("sidekick.nes").have()
```

</td></tr>
<tr><td><code>:Sidekick nes jump</code> Jump to the start of the active edit</td><td>


```lua
---@return boolean jumped
require("sidekick.nes").jump()
```

</td></tr>
<tr><td><code>:Sidekick nes toggle</code> </td><td>


```lua

require("sidekick.nes").toggle()
```

</td></tr>
<tr><td><code>:Sidekick nes update</code> Request new edits from the LSP server (if any)</td><td>


```lua
require("sidekick.nes").update()
```

</td></tr>
</table>

<!-- api_nes:end -->
