local ProcMatch = require("sidekick.cli.proc_match")

---@type sidekick.cli.Config
return {
  cmd = { "codex" },
  is_proc = ProcMatch.executable("codex"),
  url = "https://github.com/openai/codex",
  resume = { "resume" },
  continue = { "resume", "--last" },
}
