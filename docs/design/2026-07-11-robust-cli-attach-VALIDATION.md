# Robust CLI attach validation after `origin/upstream`

- **Date:** 2026-07-11
- **Validated tree:** merge commit `4f3b075` (`b0d8346` plus `origin/upstream` at `9f9e571`)
- **Baseline gate:** `./scripts/test` passed 170 cases; `nvim --headless -u NONE --cmd 'set rtp^=.' '+lua require("sidekick")' +qall` exited cleanly.

This addendum is the adversarial review of
`docs/design/2026-07-11-robust-cli-attach.md` after reconciling the fork. The
requirements remain binding; implementation details below replace pre-merge
file/line assumptions where upstream changed ownership.

## Root-cause verdicts

| root cause | verdict | merged-tree evidence |
|---|---|---|
| RC1: project scope drops linked-worktree agents | **still-correct** | `project_id()` still deliberately prefers `worktree_root` (`lua/sidekick/cli/affinity.lua:39-47`), `same_git_root` still compares those IDs (`affinity.lua:164-179`), and project scope still accepts only exact cwd or that relation (`affinity.lua:190-203`). `State.auto_attach()` still hard-filters through it (`lua/sidekick/cli/state.lua:250-258`). |
| RC2: foreign tmux sessions receive only a virtual attach | **still-correct** | `Tmux:attach()` still returns a command only when synthetic `sid == mux_session` (`lua/sidekick/cli/session/tmux.lua:57-62`). For a foreign pane, `Session.attach()` receives no command but still records the session as attached (`lua/sidekick/cli/session/init.lua:169-195`); `State.attach()` consequently has no terminal to show (`lua/sidekick/cli/state.lua:371-395`). Upstream's new `Tmux.focus()` is a separate picker jump action and does not repair Enter/attach. |
| RC3: grove shadow context exposes RC2 | **needs-adaptation** | The core conclusion remains: server-wide discovery still uses `tmux list-panes -a` (`tmux.lua:129-158`), and a target outside nvim's actual `gs/*` session still hits RC2. However, upstream now optionally maps `TMX_SCRATCH=1` to `TMX_PARENT_PANE` for affinity (`affinity.lua:112-158`), so the old claim that scoring always uses the popup's own pane is obsolete. Attach safety must compare against nvim's actual tmux session, not the affinity parent. |

## Design-pillar verdicts

| pillar | verdict | adaptation |
|---|---|---|
| 1. `same_repo` affinity and sibling-worktree scope | **still-correct** | Add the relation from cached, normalized `git_common_dir` equality; retain distinct worktree project IDs; add the default-on knob, score, badge, highlight, and tests as designed. |
| 2. Cross-session nested-client attach | **needs-adaptation** | Keep upstream's `Tmux.focus()` unchanged as the explicit Ctrl-O jump. Enter/attach still needs a same-server nested client, immutable tmux session ID propagation, `TMUX`/`TMUX_PANE` clearing, current-real-session mirror prevention, multi-client `ignore-size`, viewer suppression for bulk flows, and unique terminal IDs. The reconciled multiline pane record now has both `@layouts_title` and `window_activity`; new tests must preserve both. |
| 3. Rank-don't-hide picker and honest auto-attach UX | **needs-adaptation** | Upstream already solved pane-label search, a dedicated fzf-lua UI, affinity/recency ordering, and Ctrl-O tmux jump (`lua/sidekick/cli/ui/select/init.lua`, `ui/select/fzf.lua`). It did **not** solve partial-scope hiding (`select/init.lua:232-239`) or exact `session:window.pane` display (the merged location renders session plus window name at `select/init.lua:112-140`). Implement in the new selector directory, retain the searchable label column, include `[repo]`, and leave the jump action intact. Auto-attach still reports only counts by tool and stays silent when scope filters everything (`state.lua:250-280`), so the per-agent and outside-scope summaries remain required. |

No pillar is fully already-solved upstream. The picker subfeatures of pane-label
search, recency-aware affinity ordering, and Ctrl-O jump are already solved and
must be preserved rather than reimplemented.

## Required design corrections

1. **Startup zero notifications:** the original design said only explicit
   `cli.auto_attach()` should set `notify_empty`, but the startup hook itself calls
   that public function (`lua/sidekick/config.lua:265-278`). Add an internal/public
   `notify_empty` option that defaults on for direct calls, and have the startup
   hook pass `false`; on-demand calls inside `State.with()` continue to omit it.
2. **Notification metadata:** after a viewer command is wrapped, the returned
   state is a terminal whose tmux pane metadata lives on `session.parent`
   (`session/init.lua:181-190`). Summary formatting must resolve the parent (or
   retain the pre-attach state), otherwise `window.pane` would be missing.
3. **Picker location ownership:** the deleted `ui/select.lua` stays deleted.
   Rank-don't-hide, `[repo]`, and `session:window.pane` belong in
   `lua/sidekick/cli/ui/select/init.lua`; fzf field-scoped searching and jump
   behavior remain in `ui/select/fzf.lua`.
4. **Reconciled tmux format:** add `tmux_session_id` without regressing either
   local multiline `@layouts_title` parsing or upstream `window_activity`
   parsing/ranking.

## Adapted implementation order

1. Add `same_repo`, sibling-worktree configuration, score/badge/highlight, and
   focused affinity/config tests.
2. Propagate immutable tmux session IDs; implement nested-client attach and
   thread viewer options through session/state layers; add the attach matrix and
   terminal identity tests.
3. Restructure auto-attach around the unfiltered running set; add exact per-agent
   summaries, honest outside-scope zero summaries, startup silence, and tests.
4. Make the merged selector always consume affinity-ranked `State.get()` output;
   render `session:window.pane`, cwd, and `[repo]`; preserve label search and
   Ctrl-O jump; add routing/format tests.
5. Regenerate docs, run formatting where available, run the full test and
   headless gates, then conduct the required adversarial review loop.

## Scope check

The implementation remains additive and localized to the CLI affinity, tmux
session, session wrapper, state routing, selector, config/docs, and their tests.
Zellij, tool definitions, NES, and unrelated upstream picker behavior remain
untouched.
