# Robust CLI attach: any claude/codex, anywhere on the tmux server

- **Date:** 2026-07-11
- **Status:** Design (verified against `feat/sk-attach-design` @ `492326b`) — NOT implemented
- **Scope:** tmux backend only. Zellij untouched. No upstream rebase/vendoring.

All `file:line` citations below are against this branch's checkout at `492326b`.
External citations reference the user's tfmux CLI source at
`~/Workspaces/build/SELF_IMPROVE/tmux-factory/src/mux.rs`.

## 1. Problem

The user runs agents in three topologies on one tmux server:

1. **Normal panes/windows** of their interactive session (e.g. `SELF_IMPROVE-GROVE`).
2. **Detached factory sessions** (`sf_<slug>_codex` / `sf_<slug>_claude`) created by
   the tmux-factory launcher, each running in an **isolated linked git worktree**
   (`<repo>.feat-<slug>` sibling directory), viewed through a *nested client* window
   (`env -u TMUX tmux attach-session -t sf_…` — mux.rs:271).
3. **Grove shadow popups**: nvim runs inside its own tmux session named
   `gs/vim/<pane>` (verified live on the default server: `gs/vim/1215`,
   `gs/vim/701`), with cwd set to the parent pane's project.

Symptoms: from a grove popup (or anywhere), `<leader>as`
(`require("sidekick.cli").select()`) and `<leader>aa`
(`auto_attach({ scope = "project", focus = false })`) cannot find/attach a codex
running in a nested factory session, and auto-attach gives no feedback about what
it did (or didn't) connect to.

## 2. Verified root-cause analysis

### RC1 — `scope = "project"` hard-drops agents in sibling worktrees

Chain, each link verified:

1. `<leader>aa` → `lua/sidekick/cli/init.lua:203-211` (`M.auto_attach` →
   `State.auto_attach`).
2. `lua/sidekick/cli/state.lua:228`:
   `in_scope(M.get(Util.merge(filter, { started = true })), opts.scope or "project")`
   — `in_scope` (state.lua:70-74) is a **hard filter**, not a ranking.
3. `lua/sidekick/cli/affinity.lua:170-181` — `in_scope(…, "project")` returns
   `affinity.exact_cwd or affinity.same_git_root` (line 180).
4. `same_git_root` is computed at `affinity.lua:154-157` as equality of
   `project_id()` values.
5. `project_id()` at `affinity.lua:38-46` returns
   `project.worktree_root or project.git_common_dir`, with the deliberate comment
   (line 44): *"Linked worktrees share git_common_dir, but they should not
   collapse into one Sidekick project scope."* (fork commit `c1e6a97`).

Factory agents always run in linked-worktree siblings, so their `worktree_root`
differs from the current project's → `same_git_root = false` → **excluded from
project scope**, even though the pane sweep sees them. Verified live on this very
repo:

```
$ git -C sidekick.nvim.feat-sk-attach-design rev-parse --path-format=absolute --show-toplevel --git-common-dir
/Users/felarof01/Workspaces/build/SELF_IMPROVE/sidekick.nvim.feat-sk-attach-design   ← worktree_root (differs)
/Users/felarof01/Workspaces/build/SELF_IMPROVE/sidekick.nvim/.git                    ← git_common_dir (shared)

$ git -C sidekick.nvim rev-parse --path-format=absolute --show-toplevel --git-common-dir
/Users/felarof01/Workspaces/build/SELF_IMPROVE/sidekick.nvim
/Users/felarof01/Workspaces/build/SELF_IMPROVE/sidekick.nvim/.git
```

`Affinity.project()` already fetches **both** values in one cached git call
(`affinity.lua:98-107`), so sibling detection costs nothing extra.

Contributing defect — **silent zero**: when the filter drops everything,
`state.lua:229-231` returns `{}` with no message, and the success notification at
`state.lua:246-252` only fires `if #newly_attached > 0`. The user cannot tell
"no agents exist" from "agents exist but were filtered".

### RC2 — cross-session attach guard: foreign sessions get an invisible "attach"

`lua/sidekick/cli/session/tmux.lua:53-57`:

```lua
function M:attach()
  if self.sid == self.mux_session then
    return { cmd = { "tmux", "attach-session", "-t", self.sid } }
  end
end
```

`sid` is sidekick's synthetic id `"<tool> <sha256(cwd) prefix>"`
(`lua/sidekick/cli/session/init.lua:104-108`). It equals the tmux session name
**only** for sessions sidekick itself created via `tmux new -A -s <id>`
(tmux.lua:70-77, with `id` defaulting to `sid` at session/init.lua:91, and
`mux_session = sid` set at tmux.lua:64). For every discovered foreign session —
factory `sf_*`, grove `gs/*`, or the user's own interactive session —
`mux_session` is the real tmux session name (tmux.lua:195), never equal to `sid`,
so `M:attach()` returns `nil`.

Consequence of `nil`: in `Session.attach` (`session/init.lua:169-196`), `cmd` is
nil at line 177 so the terminal-spawn block (181-192) is skipped, yet line 193
still marks `M._attached[session.id] = session`. Then in `State.attach`
(`state.lua:346-368`) `state.terminal` is nil for the tmux backend, so
`show = true` / `focus` do nothing; the only observable effect is
`Util.info("Attached to `codex`")` at state.lua:365. **The user picks the agent in
the picker, gets a toast, and nothing opens** — this is the "can't attach"
symptom. (The "virtual attach" is not useless — the agent becomes a send target —
but it is invisible.)

Two facts that make the fix cheap:

- Discovery is already server-wide: `tmux list-panes -a` (tmux.lua:128), so
  factory/grove agents **are** in the list `select()` shows (with the default
  keymap, `select()` passes no scope, so `ui/select.lua:48` takes the unfiltered
  `State.get` branch).
- `#{session_id}` is already captured per pane (PANE_FORMAT tmux.lua:14, parsed
  at tmux.lua:132, stored at tmux.lua:142) but **dropped** when building session
  state (tmux.lua:184-197) — we need it for rename-proof `-t '$N'` targeting.

Why a nested client must unset `TMUX`: tmux refuses to run `attach-session` /
`new-session` from inside a client when `$TMUX` is set (the "sessions should be
nested with care, unset $TMUX to force" guard). The user's tfmux CLI does exactly
this for its factory viewer windows —
`env -u TMUX tmux attach-session -t <session>` (mux.rs:271, inside
`attach_session_in_new_window`, mux.rs:261-280). Sidekick's terminal layer today
does **not** strip `TMUX`: the job env is built from `vim.uv.os_environ()` plus
tool env (`lua/sidekick/cli/terminal.lua:282-295`) and passed to `jobstart`
(terminal.lua:296-301). This means even the existing same-session fast path
(tmux.lua:55) and mux `create = "terminal"` start path (tmux.lua:72) launch a
nested tmux **with `TMUX` still set** whenever nvim itself runs inside tmux — a
latent defect this design fixes in passing. The plumbing already exists: a
`terminal.Cmd` may carry `env` (terminal.lua:5-8), `Session.attach` clones the
tool with it (session/init.lua:183), and `env = false` values are explicitly
cleared (terminal.lua:290-295; type at `lua/sidekick/cli/init.lua:19`).

### RC3 — grove popup context: discovery and scoping survive; the attach guard is what breaks

Verified that popups do *not* break discovery or scoring:

- `Affinity.current_tmux()` (`affinity.lua:111-125`) resolves `vim.env.TMUX_PANE`
  against the **server-wide** pane sweep, so it finds the popup's own pane inside
  `gs/vim/<pane>` just fine.
- `Affinity.current_scope()` (`affinity.lua:127-137`) takes `cwd` from
  `Session.cwd()` (`session/init.lua:99-101` — nvim's cwd), which in a grove
  popup is the parent pane's project directory. So `exact_cwd` / `same_git_root`
  compute correctly from popups.
- The popup's session being `gs/vim/<pane>` only makes
  `same_tmux_session = false` (affinity.lua:147), which costs 100 ranking points
  (affinity.lua:75-77) — ranking, not filtering.

What actually breaks in a popup is RC2 in its purest form: **every** agent on the
server — including ones in the parent interactive session — is session-foreign to
`gs/vim/<pane>`, so `M:attach()` returns nil for all of them. Plus RC1 for
factory-worktree agents under `scope = "project"`.

## 3. Design

Three pillars, all additive:

1. **Affinity learns worktree siblings** (`same_repo`) — fixes RC1, improves
   ranking everywhere.
2. **Cross-session attach via a nested tmux client** in the terminal split,
   mirroring tfmux — fixes RC2 and RC3.
3. **Honest auto-attach notification + rank-don't-hide select** — fixes the
   silent-zero defect and the "can't find" experience.

### 3.1 Affinity: `same_repo` (worktree siblings)

Add one boolean to `sidekick.cli.Affinity` (affinity.lua:24-31):

```lua
-- in M.score (affinity.lua:139-166), alongside same_git_root:
affinity.same_repo = scope_project ~= nil and session_project ~= nil
  and scope_project.git_common_dir ~= nil
  and scope_project.git_common_dir == session_project.git_common_dir
```

- **Scoring** (affinity.lua:66-85): `same_repo` adds **+400** — between
  `same_git_root` (+500) and `same_tmux_session` (+100). Since `same_git_root`
  implies `same_repo`, a same-root agent scores ≥900 and always outranks a
  sibling-worktree agent (400): ranking stays intuitive.
- **Badge** (affinity.lua:48-64): `[repo]` with a new `SidekickCliAffinityRepo`
  highlight group, defined alongside the existing `SidekickCliAffinity*` groups.
- **Scope** (affinity.lua:168-181): project scope becomes

```lua
return affinity.exact_cwd or affinity.same_git_root
  or (Config.cli.mux.auto_attach.worktree_siblings ~= false and affinity.same_repo)
```

**Why `git-common-dir` equality and not path heuristics:** the values are already
computed and cached per cwd by `Affinity.project()` (affinity.lua:98-107) — zero
additional git invocations; equality of the absolute `--git-common-dir` is the
*definition* of "linked worktree of the same repository". A path heuristic
(`<repo>.feat-*` sibling naming) would hard-code tmux-factory naming conventions
into the plugin, silently miss grove worktrees created elsewhere, and false-match
unrelated directories. Rejected.

This deliberately does **not** revert `c1e6a97`: `project_id()` keeps
distinguishing worktrees (each worktree is still its own *project*), `same_repo`
is a new, weaker relation with its own scope rule and knob.

### 3.2 Cross-session attach: nested client in the terminal split

Replace `M:attach()` (tmux.lua:52-57) with (design-level; helpers below):

```lua
---@param opts? { viewer?: boolean }
---@return sidekick.cli.terminal.Cmd?
function M:attach(opts)
  local env = { TMUX = false, TMUX_PANE = false }
  -- fast path: session created by sidekick itself (unchanged shape, now nest-safe)
  if self.sid == self.mux_session then
    return { cmd = { "tmux", "attach-session", "-t", self.sid }, env = env }
  end
  if Config.cli.mux.attach.cross_session == false then
    return -- legacy behavior: virtual attach only
  end
  if opts and opts.viewer == false then
    return -- bulk flows (auto_attach): mark as send target, never open splits
  end
  if self.mux_session == M.current_session() then
    return -- pane lives in the session this client already displays:
           -- a nested client here can mirror itself; keep virtual attach
  end
  local target = self.tmux_session_id or self.mux_session
  if not Util.exec({ "tmux", "has-session", "-t", target }, { notify = false }) then
    Util.warn(("**%s** exited (`%s` is gone)"):format(self.tool.name, self.mux_session))
    return
  end
  local cmd = { "tmux" }
  local socket = M.socket()
  if socket then
    vim.list_extend(cmd, { "-S", socket })
  end
  local shared = #(M.clients()[self.tmux_session_id] or {}) > 0
  if not shared and self.tmux_window_index then
    -- surface the agent's window before connecting; safe: no other viewer to disturb
    vim.list_extend(cmd, { "select-window", "-t", ("%s:%s"):format(target, self.tmux_window_index), ";" })
  end
  cmd[#cmd + 1] = "attach-session"
  if shared then
    vim.list_extend(cmd, { "-f", "ignore-size" })
  end
  vim.list_extend(cmd, { "-t", target })
  return { cmd = cmd, env = env }
end
```

Exact argv produced (arrays passed to `jobstart` — no shell, no quoting concerns;
the `";"` token is tmux command-chaining, precedent at tmux.lua:75-76):

| case | argv | env |
|---|---|---|
| sidekick-owned session (fast path) | `tmux attach-session -t "claude 1a2b3c4d"` | `TMUX`/`TMUX_PANE` unset |
| foreign, detached (factory default) | `tmux -S /private/tmp/tmux-501/default select-window -t "$42:1" ";" attach-session -t "$42"` | `TMUX`/`TMUX_PANE` unset |
| foreign, already viewed elsewhere | `tmux -S /private/tmp/tmux-501/default attach-session -f ignore-size -t "$42"` | `TMUX`/`TMUX_PANE` unset |

Supporting changes:

- **`tmux_session_id` propagation** — one line in `M.sessions()`
  (tmux.lua:184-197): `tmux_session_id = pane.session_id`. Targeting by `$N` id
  is immune to session renames and to tmux's name prefix-matching; names like
  `gs/vim/1215` also contain `/` which `-t` would treat as a window separator in
  some forms — ids sidestep the whole class.
- **`M.socket()`** — `local s = vim.env.TMUX and vim.env.TMUX:match("^([^,]+)")`;
  returns the socket path (first comma-field of `$TMUX`). Passing `-S <socket>`
  pins the nested client to the *same server* nvim is on, instead of assuming the
  default socket (tfmux solves this with `-L`, mux.rs:273-276; `-S` is the
  full-path equivalent). When nvim runs outside tmux, `TMUX` is unset → omit
  `-S` → default socket, which is also what discovery talked to.
- **`M.current_session()`** — the session name of the pane hosting nvim:
  `Util.exec({ "tmux", "display-message", "-p", "-t", vim.env.TMUX_PANE, "#{session_name}" })`,
  nil when `TMUX_PANE` is unset, cached per call-site invocation. Needed because
  `external` (tmux.lua:61) is true for *any* discovered pane, including panes in
  windows of the session already on screen — those must keep today's virtual
  attach (they're reachable with normal tmux navigation, and a nested client of
  your own session can render the window that contains the viewer itself —
  infinite mirror).

**Multi-client sizing choice.** tmux sizes windows per the `window-size` option
(default `latest`), so a plain second client would shrink the factory viewer's
window to sidekick's split — the exact annoyance to avoid. Decision:

- Session already has clients (`M.clients()`, tmux.lua:155-167) → attach with
  `-f ignore-size` ("the client does not affect the size of other clients",
  tmux 3.5a man; requires tmux ≥ 3.2): we observe at the other client's size,
  clipped if our split is smaller. We never fight over geometry.
- Session detached (typical factory case) → attach plainly: our split defines the
  size; if a factory viewer attaches later it becomes `latest` and takes over.
- **Read-write shared attach**, not `-r`: `-r` is an alias for
  `read-only,ignore-size` and would block typing into the agent from the split.
  Anyone wanting read-only can layer it later; not a v1 knob.

**Viewer policy (`opts.viewer`).** `B:attach()` (session/init.lua:47-50) gains an
optional `opts` param, threaded from `Session.attach(session, opts)`
(session/init.lua:169). `State.auto_attach` passes `viewer = false` so bulk
auto-attach keeps today's semantics (external agents become send targets, **no**
splits — attaching 4 factory agents must not open 4 windows). Explicit
single-target flows (`select`, `show`, `toggle`, `focus`, `State.with` use-path)
default `viewer = true` and get the nested client. The sid==mux_session fast path
ignores `viewer` — startup re-attach of sidekick-owned terminals keeps working.

**Terminal identity fix.** `session/init.lua:186` keys the wrapping terminal as
`"terminal: " .. session.sid`; `sid` is tool+cwd-derived (session/init.lua:104-108),
so two codex agents in the *same cwd* (common: retry runs in one worktree) would
collide in `M.terminals` (terminal.lua:110). Change to
`"terminal: " .. session.id` — `id` is the pane-pid-based skid `"tmux <pid>"`
(tmux.lua:138), unique per agent; for non-mux flows `id == sid`
(session/init.lua:91) so nothing else changes.

**Where this works, by construction:**

- *Normal pane* → foreign `sf_*` session: nested client, same server via `-S`.
- *Grove popup* (`gs/vim/<pane>`): every target is foreign → nested client. No
  mirror risk: the popup's nvim pane belongs to `gs/vim/<pane>`, not to the
  session being viewed.
- *Nvim inside a nested factory client* (nvim in a pane of `sf_*`): targets in
  other sessions are foreign → nested client; targets in the same `sf_*` session
  stay virtual (same-session rule).
- *Same-session fast path*: branch order preserved; argv unchanged; adding
  `env.TMUX = false` additionally makes it work when nvim itself is inside tmux
  (see RC2 latent defect).

### 3.3 UX: select list and auto-attach notification

**`select()` ranks, never hides.** `ui/select.lua:48-51` currently applies
`opts.scope` as a filter with an all-fallback only when the scoped list is empty
— partial scope matches still hide the rest. Change to always list
`State.get(opts.filter)`; the affinity sort (state.lua:189-212) already floats
in-scope entries to the top because `exact_cwd`/`same_git_root`/`same_repo`
dominate the score. `opts.scope` stays in the signature (callers at
state.lua:285-296 unchanged) but no longer filters. Entries already render
`session:window.pane` and cwd (fork patches; select.lua:150-177) plus affinity
badges (select.lua:180-183) — the new `[repo]` badge makes factory agents
recognizable at a glance:

```
 1. ▶ codex    [tmux:sf_grove_popup_codex:1.0]  [repo]  ~/W/b/SELF_IMPROVE/grove.feat-popup
 2. ▶ claude   [tmux:SELF_IMPROVE-GROVE:2.1]    [root]  ~/Workspaces/build/SELF_IMPROVE/grove
 3. ▶ codex    [tmux:BOS-GATEWAY:0.0]                   ~/Workspaces/build/BOS/gateway
```

**Auto-attach summary.** Rework the notification block (state.lua:236-252):

- Compute `outside = #all_started - #in_scope` before filtering (restructure the
  first lines of `M.auto_attach` to keep the unfiltered list).
- Success — one line per newly attached agent: tool, `session:window.pane`, cwd:

  ```
  Auto-attached 2 agents:
  - **codex** `sf_grove_popup_codex:1.0` — ~/W/build/SELF_IMPROVE/grove.feat-popup
  - **claude** `SELF_IMPROVE-GROVE:2.1` — ~/Workspaces/build/SELF_IMPROVE/grove
  ```

  (fields available on session state: `mux_session`, `tmux_window_index`,
  `tmux_pane_index`, `cwd` — tmux.lua:184-197; path via `fnamemodify(cwd, ":~")`.)
- Zero with visible others (`Util.warn`):

  ```
  Auto-attach: no agents in `project` scope — 3 running elsewhere. Use require("sidekick.cli").select()
  ```

  The plugin cannot know the user's `<leader>as` mapping, so the hint names the
  API; the doc for the option mentions users can rely on their select keymap.
- Zero with nothing running anywhere: stay silent (today's behavior).
- **`notify_empty` opt** on `State.auto_attach`: `true` only for the explicit
  `cli.auto_attach()` entry point (cli/init.lua:203-211 — the `<leader>aa` path).
  The startup hook (config.lua:253-266) and the on-demand paths inside
  `State.with` (state.lua:305-309, 320-326) pass nothing → silent on zero, since
  those flows either run at VimEnter or fall through to the picker anyway
  (state.lua:315, 335), which now lists everything.

## 4. Config surface

Consistent with the existing `cli.mux` shape (config.lua:110-129):

```lua
mux = {
  backend = "tmux",
  enabled = false,
  create = "terminal",
  split = { vertical = true, size = 0.5 },
  attach = {
    -- open agents living in other tmux sessions via a nested client
    -- (`env TMUX= tmux attach…`) inside the sidekick terminal split
    cross_session = true,
  },
  auto_attach = {
    startup = true,
    on_demand = true,
    scope = "project",
    -- linked git worktrees of the current repo count as `project` scope
    worktree_siblings = true,
  },
}
```

- Both default **on** in this fork (they are the point of the fork); the knobs
  exist so the diff is upstreamable with `cross_session = false` /
  `worktree_siblings = false` defaults if folke prefers.
- `normalize_auto_attach` (config.lua:7-26) must gain
  `worktree_siblings = true` in its `defaults` table, or the `auto_attach = true|false`
  shorthand would drop the key.
- Validators (config.lua:268-275): add
  `M.validate("cli.mux.attach.cross_session", "boolean")` and
  `M.validate("cli.mux.auto_attach.worktree_siblings", "boolean")`.
- `sidekick.cli.terminal.Cmd.env` annotation (terminal.lua:8) widens to
  `table<string, string|false>` to match actual behavior (terminal.lua:290-295).

## 5. Upstream-diff strategy

The fork merges upstream periodically; every change is additive and localized:

| file | change | est. LOC |
|---|---|---|
| `lua/sidekick/cli/affinity.lua` | `same_repo` field, +400 score, `[repo]` badge, scope rule | ~20 |
| `lua/sidekick/cli/session/tmux.lua` | `tmux_session_id` propagation; `socket()`/`current_session()` helpers; `M:attach(opts)` rewrite | ~55 |
| `lua/sidekick/cli/session/init.lua` | thread `opts` through `M.attach`/`B:attach`; terminal id `session.id` | ~6 |
| `lua/sidekick/cli/state.lua` | `auto_attach`: viewer=false, outside-count, notification block | ~30 |
| `lua/sidekick/cli/ui/select.lua` | rank-don't-hide (drop scoped-filter branch) | ~4 |
| `lua/sidekick/config.lua` | defaults + normalize + validators | ~12 |

No changes to `terminal.lua` logic (annotation only), `zellij.lua`, tool configs,
or any NES code. No file rewrites; every hunk sits next to code the fork already
patched (`c1e6a97`, `46554f9`, `47be2da`, `0333faa`), so upstream merges conflict
in files the user already owns conflicts in.

## 6. Edge cases

- **Agent exits before attach**: `has-session` preflight fails → `Util.warn`,
  return nil (falls back to virtual/no-op instead of spawning a dying terminal).
  Exit *between* preflight and client start: the nested client prints tmux's
  error; the terminal window's error-close delay (terminal.lua:33-34) makes it
  readable, and the next `Session.sessions()` sweep detaches the stale entry
  (session/init.lua:149-153).
- **Agent exits while viewed**: factory sessions usually end when the agent's
  shell ends → tmux kills the session → nested client exits → terminal closes via
  the existing job-exit path. Session sweep cleans `_attached`.
- **Duplicate attach**: `Session.attach` early-returns when already attached
  (session/init.lua:171-173). Two agents sharing tool+cwd no longer collide on
  terminal identity (§3.2 terminal identity fix).
- **Detached-only session**: plain attach; our client sizes it;
  `select-window` pre-targets the agent's window (single-window in practice for
  `sf_*`/`gs/*` sessions).
- **Session already viewed elsewhere** (factory viewer window): `-f ignore-size`,
  and *no* `select-window` — changing the current window would yank every other
  client of that session to it.
- **Closing the split**: kills the nested client process → clean tmux detach; the
  agent keeps running (factory unaffected). Sidekick-side detach flow unchanged
  (state.lua:370-381).
- **nvim outside tmux**: `TMUX` unset → no `-S`, no nesting concern; behavior
  equals today's plus cross-session reach.
- **Renamed sessions / names with `/` `:` `.`** (e.g. `gs/vim/1215`): targeted by
  immutable `$N` session id, not name.
- **Zellij**: `cross_session` is read only inside the tmux backend; zellij's
  `M:attach` (zellij.lua:73-77) untouched; `worktree_siblings` applies to zellij
  sessions too via affinity (backend-agnostic, correct).
- **Non-git cwds**: `git_common_dir` nil → `same_repo` false → behavior unchanged.
- **`window-size` exotic configs** (`manual`, `aggressive-resize`): we only ever
  *add* `ignore-size`; we never set session/window options on foreign sessions
  (they're shared property of the factory).

## 7. Test plan

Runner: `./scripts/test` (mini.test via lazy.minit — AGENTS.md; busted-style
`describe/it` + `luassert`, see `tests/tmux_spec.lua`, `tests/cli_state_spec.lua`).
All tmux interaction is mocked by swapping `Util.exec` (pattern:
tmux_spec.lua:8-16) and projects by swapping `Affinity.project` (pattern:
cli_affinity_spec.lua:16-24). No live tmux needed.

1. **`tests/tmux_spec.lua`** — `M:attach()` matrix. Fixture: fake `Util.exec`
   returning canned `list-panes -a` / `list-clients` / `has-session` /
   `display-message` output; `vim.env.TMUX`/`TMUX_PANE` stubbed per case.
   - owned fast path: exact argv, `env.TMUX == false`; unchanged when
     `cross_session = false`.
   - foreign detached: argv includes `-S <socket>`, `select-window`, `-t $N`; no
     `ignore-size`.
   - foreign with clients: `-f ignore-size`, no `select-window`.
   - same-outer-session pane: returns nil (virtual attach preserved).
   - `viewer = false`: returns nil for foreign, cmd for owned.
   - `has-session` failure: nil + warn.
   - `sessions()` propagates `tmux_session_id`.
2. **`tests/cli_affinity_spec.lua`** — `same_repo`: true for shared
   `git_common_dir` + different `worktree_root`; false across repos; score 400 /
   badge `[repo]`; `in_scope("project")` honors `worktree_siblings` on/off.
3. **`tests/cli_state_spec.lua`** — extend the existing harness
   (cli_state_spec.lua:49-104): sibling-worktree session attaches under project
   scope; capture `Util.info`/`Util.warn` to assert the success summary lines
   (tool + `session:window.pane` + cwd) and the zero-case message with outside
   count; `notify_empty` default-off paths stay silent; auto_attach passes
   `viewer = false` (assert via `Session.attach` spy receiving opts).
4. **`tests/cli_select_spec.lua`** — with `opts.scope` set and mixed
   in/out-of-scope sessions, all entries are listed and in-scope ones rank first.

## 8. Implementation plan (one codex run)

Ordered so each step lands green before the next:

1. `affinity.lua`: `same_repo` + score + badge + scope rule; config defaults,
   `normalize_auto_attach`, validators. Extend `cli_affinity_spec`. (~30 min)
2. `tmux.lua`: `tmux_session_id` propagation; `M.socket()` /
   `M.current_session()`; `M:attach(opts)` per §3.2. Extend `tmux_spec`. (~1 h)
3. `session/init.lua`: `M.attach(session, opts)` → `session:attach(opts)`;
   terminal id `"terminal: " .. session.id`; widen `Cmd.env` annotation. (~15 min)
4. `state.lua`: `M.attach(state, opts)` threads `viewer`; `M.auto_attach`
   restructure (unfiltered count, `viewer = false`, notification block,
   `notify_empty`); `cli/init.lua` passes `notify_empty = true`. Extend
   `cli_state_spec`. (~45 min)
5. `ui/select.lua`: rank-don't-hide. Extend `cli_select_spec`. (~10 min)
6. `./scripts/test`, `stylua lua tests`, `./scripts/docs` (config annotations
   feed README). (~15 min)
7. Manual smoke per §3.2 table: from a normal pane, a grove popup, and a nested
   factory client, `select()` a factory codex → split shows the live session;
   `<leader>aa` → summary notification; close split → factory session survives
   (`tmux list-clients` empty again).

## 9. Non-goals

- Rebasing/vendoring upstream (explicitly out of scope).
- Zellij cross-session attach.
- Auto-opening viewer splits from bulk auto-attach (deliberate: virtual attach +
  summary; the picker is one keypress away).
- Jump-to-pane focus for same-session agents (natural follow-up: `select-window`
  + `select-pane` on `focus()`; not required here).
- Attaching across different tmux *servers/sockets* than the one nvim (or its
  `$TMUX`) points at — discovery itself is single-server today (tmux.lua:128).

## 10. Requirement → design map

| requirement (task) | where |
|---|---|
| select lists every agent on the server, ranked, never hidden | §3.3 (select.lua:48-51 change); discovery already server-wide (tmux.lua:128) |
| entries show session:window.pane + cwd | already in fork (select.lua:150-177); `[repo]` badge added (§3.1) |
| auto-attach with worktree-sibling awareness | §3.1 (`same_repo`, `worktree_siblings`) |
| notify summary: tool, session:window, cwd; honest zero-case | §3.3 |
| cross-session attach from normal pane / popup / nested client | §3.2 (works-by-construction list) |
| no same-session fast-path regression | §3.2 (branch order preserved; argv unchanged) |
| exact tmux argv incl. TMUX-unset nested client | §3.2 argv table |
| multi-client sizing choice | §3.2 (`-f ignore-size` iff shared; read-write; rationale) |
| config knobs consistent with existing shape | §4 |
| small, isolated upstream diff | §5 |
| edge cases incl. zellij untouched | §6 |
| test plan per repo conventions | §7 |
| one-codex-run implementation plan | §8 |
