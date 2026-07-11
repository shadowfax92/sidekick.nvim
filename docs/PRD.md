# PRD: Sidekick Multi-Agent Workflow

## Problem

I run 3 claude + 3 codex sessions in tmux per project. Today sidekick:

1. Forces a picker whenever more than one session is attached — sending one line to "all claude agents" takes multiple keystrokes.
2. Won't discover existing tmux agents automatically — every pane has to be manually selected before it can receive messages.
3. `<leader>as` list shows all agents as a flat list — I eyeball the path column to figure out which agent sits where.

## Goals

### G1. Multicast send
Prompts, files, and lines fan out to **every matched attached session** in one keystroke. Filter (`name`, `cwd`, etc.) still applies.

### G2. Auto-attach project agents
On nvim load (and on a keybind), discover every tmux pane running `claude` or `codex` whose cwd is inside the current **git root** and attach to all of them. No picker, no prompt.

### G3. Affinity-colored picker
In `<leader>as`, prefix each row with a colored badge by how "close" the agent is to the current editor context:

| Badge | Meaning | Example color |
|---|---|---|
| `●` | same tmux pane (this nvim's sidekick) | bright green |
| `◆` | same cwd | cyan |
| `◈` | same git root | accent |
| `◇` | same tmux window | blue |
| `○` | same tmux session | dim |
| ` ` | other | gray |

Rows sort by affinity, highest first.

## Non-goals

- Managing tmux pane lifecycle (creating/destroying panes).
- Zellij parity — tmux only in v1.
- Changing single-target ops (`toggle`, `focus`, `hide`, `show`, `close`) — those stay single-target because multicasting them is destructive or meaningless.

## User stories

1. **Broadcast a line.** Cursor on a line, `<leader>av` → all claude panes (cwd-filtered) receive the line. Codex panes untouched.
2. **Open nvim, everything attached.** 3 claude + 3 codex panes pre-running in tmux; `nvim .` → within ~200ms all 6 are attached.
3. **Scan picker fast.** `<leader>as` → color-coded list, eye lands on same-pane/same-cwd rows immediately.
4. **Manual re-scan.** Started a new agent after nvim load → `<leader>aA` attaches the new one.

## Success criteria

- Zero extra keystrokes to broadcast to all matching agents.
- Zero manual attaches for agents started before nvim loaded.
- Picker scannable in < 1s without reading paths.
- No regression in single-target flows (`<leader>ac`, `<leader>aa`, `<leader>ad`).

## Config additions (proposed defaults)

```lua
cli = {
  multicast = true,                      -- G1
  mux = {
    auto_attach_on_load = true,          -- G2
    project_scope = "git_root",          -- "git_root" | "cwd"
  },
  picker = {
    affinity = true,                     -- G3
  },
}
```

All three toggleable. Affinity is purely cosmetic and cheap; leave on.
