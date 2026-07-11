# Design: Sidekick Multi-Agent Workflow

Three independent, small changes. Ship in order: multicast → auto-attach → affinity picker.

## Files touched

| File | Why |
|---|---|
| `lua/sidekick/config.lua` | New options, highlight groups, VimEnter autocmd |
| `lua/sidekick/cli/init.lua` | Pass `all = multicast` to `State.with` in send paths |
| `lua/sidekick/cli/autoattach.lua` | **NEW** — project root + attach-all routine |
| `lua/sidekick/cli/session/tmux.lua` | Extend `PANE_FORMAT` with `#{window_id}` |
| `lua/sidekick/cli/ui/select.lua` | Compute caller context + render affinity badge + sort |

No changes needed to `state.lua` — it already honors `opts.all`.

---

## G1. Multicast

### Config (`config.lua`)
```lua
cli = {
  multicast = true,
}
```

### Wire-up (`cli/init.lua`)
In `M.send` and `M.send_with_comment`, change the `State.with` call:

```lua
State.with(function(state) ... end, {
  attach  = true,
  filter  = opts.filter,
  focus   = opts.focus,
  show    = true,
  all     = opts.multicast ~= false and Config.cli.multicast,
})
```

- `opts.multicast = false` → force picker even when config is on.
- `Config.cli.multicast = false` → restore upstream behavior.

### What does *not* change
`M.show`, `M.hide`, `M.toggle`, `M.focus`, `M.close` keep their current semantics — single-target when attached count > 1. Rationale: toggling 6 panes' visibility or closing 6 sessions from one keypress is a footgun.

### Tests to add
- `send({ filter = { name = "claude" } })` with 3 claude attached → 3 `session:send` calls.
- `send({ filter = { name = "claude" }, multicast = false })` with 3 claude attached → picker opens.
- `toggle()` with 2 attached → picker (unchanged).

---

## G2. Auto-attach project agents

### New module `lua/sidekick/cli/autoattach.lua`

```lua
local Config = require("sidekick.config")
local Session = require("sidekick.cli.session")
local State = require("sidekick.cli.state")
local Util = require("sidekick.util")

local M = {}

local function project_root(cwd)
  if Config.cli.mux.project_scope == "cwd" then return cwd end
  local git = vim.fs.find(".git", {
    path = cwd, upward = true, stop = vim.uv.os_homedir(),
  })[1]
  return git and vim.fs.dirname(git) or cwd
end

function M.scope_root()
  return project_root(Session.cwd())
end

--- Attach every started session whose cwd is at or under the project root.
--- Idempotent — already-attached sessions are skipped.
function M.attach_project(opts)
  opts = opts or {}
  if not Config.cli.mux.enabled then return 0 end

  local root = M.scope_root()
  local prefix = root:gsub("/+$", "") .. "/"
  local count = 0

  for _, state in ipairs(State.get({ started = true })) do
    if not state.attached and state.session then
      local scwd = state.session.cwd
      if scwd == root or vim.startswith(scwd, prefix) then
        State.attach(state)
        count = count + 1
      end
    end
  end

  if count > 0 and opts.notify ~= false then
    Util.info(("Auto-attached %d sidekick session(s)"):format(count))
  end
  return count
end

return M
```

### Startup hook (`config.lua` inside `M.setup`)

```lua
if config.cli.mux.enabled and config.cli.mux.auto_attach_on_load ~= false then
  vim.api.nvim_create_autocmd("VimEnter", {
    group = M.augroup,
    once  = true,
    callback = function()
      vim.defer_fn(function()
        require("sidekick.cli.autoattach").attach_project({ notify = false })
      end, 200)
    end,
  })
end
```

Deferred 200ms so we don't block the startup paint. `once = true` because reloading should not re-trigger.

### Public API (`cli/init.lua`)

```lua
function M.attach_project(opts)
  return require("sidekick.cli.autoattach").attach_project(opts)
end
```

### User keymap example (goes in the user's `sidekick.lua` config, not this repo)

```lua
{ "<leader>aA", function() require("sidekick.cli").attach_project() end, desc = "Sidekick Attach Project Agents" },
```

### Edge cases
- **Not in a git repo** → root = cwd; still attaches things in cwd subtree.
- **Nested repos / submodules** → nearest `.git` wins (stops at first hit walking up).
- **Tmux server not running** → `Session.sessions()` already returns `[]`; no-op.
- **Already attached sessions** → skipped via `state.attached` check.
- **Uninstalled tools** → `State.get` won't include them (existing filter).

---

## G3. Affinity-colored picker

### Step A — capture stable tmux ids

Current `PANE_FORMAT` in `tmux.lua:10-11`:
```
#{session_id}:#{pane_id}:#{pane_pid}:#{session_name}:#{window_name}:#{window_index}:#{pane_index}:#{@pane_label}:#{?pane_current_path,...}
```

Add `#{window_id}` after `window_index` so affinity comparison is stable under window reordering. Update the `line:match` regex and propagate `window_id` into the session state (`tmux_window_id`).

### Step B — caller context (in `ui/select.lua`)

Cached once per picker open:

```lua
local function caller_ctx()
  local cwd = require("sidekick.cli.session").cwd()
  local git = vim.fs.find(".git", { path = cwd, upward = true, stop = vim.uv.os_homedir() })[1]
  local root = git and vim.fs.dirname(git) or cwd

  local tmux
  if vim.env.TMUX and vim.env.TMUX_PANE then
    local function q(fmt)
      local r = vim.fn.system({ "tmux", "display-message", "-p", "-t", vim.env.TMUX_PANE, fmt })
      return (r or ""):gsub("%s+$", "")
    end
    tmux = { session = q("#S"), window_id = q("#{window_id}"), pane_id = vim.env.TMUX_PANE }
  end
  return { cwd = cwd, root = root, tmux = tmux }
end
```

### Step C — affinity classifier

```lua
local LEVELS = {
  same_pane    = { rank = 5, hl = "SidekickCliAffinitySamePane",    icon = "●" },
  same_cwd     = { rank = 4, hl = "SidekickCliAffinitySameCwd",     icon = "◆" },
  same_git     = { rank = 3, hl = "SidekickCliAffinitySameGit",     icon = "◈" },
  same_window  = { rank = 2, hl = "SidekickCliAffinitySameWin",     icon = "◇" },
  same_session = { rank = 1, hl = "SidekickCliAffinitySameSess",    icon = "○" },
  other        = { rank = 0, hl = "SidekickCliAffinityOther",       icon = " " },
}

local function affinity(state, ctx)
  local s = state.session
  if not s then return "other" end
  if ctx.tmux and s.tmux_pane_id and s.tmux_pane_id == ctx.tmux.pane_id then return "same_pane" end
  if s.cwd == ctx.cwd then return "same_cwd" end
  if ctx.root and (s.cwd == ctx.root or vim.startswith(s.cwd, ctx.root .. "/")) then return "same_git" end
  if ctx.tmux and s.tmux_window_id and s.tmux_window_id == ctx.tmux.window_id then return "same_window" end
  if ctx.tmux and s.mux_session and s.mux_session == ctx.tmux.session then return "same_session" end
  return "other"
end
```

### Step D — render + sort

In `M.select`:
```lua
local ctx = Config.cli.picker.affinity and caller_ctx() or nil
if ctx then
  table.sort(tools, function(a, b)
    local ra = LEVELS[affinity(a, ctx)].rank
    local rb = LEVELS[affinity(b, ctx)].rank
    if ra ~= rb then return ra > rb end
    return (a.tool.name) < (b.tool.name)
  end)
end
```

In `M.format`, after the index cell:
```lua
if ctx then
  local lvl = LEVELS[affinity(state, ctx)]
  ret[#ret + 1] = { lvl.icon .. " ", lvl.hl }
end
```

`ctx` is captured in a closure around `format_item` / `snacks.format` so the sub-process calls share the same value.

### Step E — highlight groups (`config.lua` `set_hl`)

```lua
CliAffinitySamePane  = "DiagnosticOk",
CliAffinitySameCwd   = "DiagnosticInfo",
CliAffinitySameGit   = "Special",
CliAffinitySameWin   = "DiagnosticHint",
CliAffinitySameSess  = "Comment",
CliAffinityOther     = "NonText",
```

---

## Rollout

1. **Phase 1 — multicast.** One-file change; reversible via config. Confirms the new `send` shape works for the user.
2. **Phase 2 — auto-attach.** New module; guarded by config flag. Low risk.
3. **Phase 3 — affinity picker.** Needs `PANE_FORMAT` extension; purely additive.

Each phase can ship as a separate commit on the `upstream` branch.

## Test plan

- [ ] 3 claude + 3 codex panes running in a project; open nvim → all 6 attached after <500ms.
- [ ] `<leader>av` (claude, cwd filter) → all 3 claude agents receive the line; codex untouched.
- [ ] `<leader>ac` (toggle claude, cwd filter) → still opens picker if >1 claude attached.
- [ ] `<leader>as` → first rows carry green `●` / cyan `◆` badges; bottom rows dim `○`.
- [ ] `nvim` outside tmux → no errors; no attaches.
- [ ] `nvim` in repo with zero agents → silent.
- [ ] `<leader>aA` after starting a new agent → attaches the new one only.
- [ ] Colorscheme change → affinity highlights re-link via `ColorScheme` autocmd.

## Risks

- **Accidental broadcast with loose filter.** Mitigation: filter stays mandatory on keymaps (user's existing bindings already pass `filter = { name = ..., cwd = true }`).
- **Startup cost.** Auto-attach calls `tmux list-panes -a` once; ~30ms on a laptop. Deferred 200ms after VimEnter keeps startup clean.
- **Window id fragility across tmux versions.** `#{window_id}` is stable across all modern tmux (≥1.9). If missing, affinity falls back to `same_session` only.
