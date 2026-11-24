---@module 'luassert'

local Procs = require("sidekick.cli.procs")
local Session = require("sidekick.cli.session")
local Util = require("sidekick.util")

describe("opencode sessions", function()
  local original_exec
  local original_get_proc
  local original_cwd
  local original_pids
  local backend

  before_each(function()
    if not Session.backends.opencode then
      local file = assert(vim.api.nvim_get_runtime_file("sk/cli/opencode.lua", false)[1])
      dofile(file)
    end
    backend = assert(Session.backends.opencode, "opencode backend not registered")
    original_exec = Util.exec
    original_get_proc = vim.api.nvim_get_proc
    original_cwd = Procs.cwd
    original_pids = Procs.pids
    Procs.cwd = function()
      return "/Users/shadowfax"
    end
    Procs.pids = function(pid)
      return { pid }
    end
  end)

  after_each(function()
    Util.exec = original_exec
    vim.api.nvim_get_proc = original_get_proc
    Procs.cwd = original_cwd
    Procs.pids = original_pids
  end)

  for _, case in ipairs({
    {
      name = "keeps interactive opencode process",
      procs = {
        [60300] = { pid = 60300, ppid = 57134, name = "opencode" },
        [57134] = { pid = 57134, ppid = 1, name = "fish" },
      },
      args = { [60300] = "opencode" },
      expected_ids = { "opencode-60300" },
    },
    {
      name = "keeps interactive opencode with flags or project path named serve",
      procs = {
        [60310] = { pid = 60310, ppid = 57134, name = "opencode" },
        [57134] = { pid = 57134, ppid = 1, name = "fish" },
      },
      args = { [60310] = "/Users/shadowfax/.opencode/bin/opencode /repo/serve --continue" },
      expected_ids = { "opencode-60310" },
    },
    {
      name = "skips child opencode serve --service whose parent is opencode",
      procs = {
        [60302] = { pid = 60302, ppid = 60300, name = "opencode" },
        [60300] = { pid = 60300, ppid = 57134, name = "opencode" },
      },
      args = { [60302] = "/Users/shadowfax/.opencode/bin/opencode serve --service" },
      expected_ids = {},
    },
    {
      name = "skips standalone opencode serve --service",
      procs = {
        [60305] = { pid = 60305, ppid = 1, name = "opencode" },
        [1] = { pid = 1, ppid = 0, name = "launchd" },
      },
      args = { [60305] = "/Users/shadowfax/.opencode/bin/opencode serve --service" },
      expected_ids = {},
    },
    {
      name = "skips bare opencode serve subcommand",
      procs = {
        [60306] = { pid = 60306, ppid = 57134, name = "opencode" },
        [57134] = { pid = 57134, ppid = 1, name = "fish" },
      },
      args = { [60306] = "opencode serve" },
      expected_ids = {},
    },
    {
      name = "skips opencode serve preceded by flags",
      procs = {
        [60307] = { pid = 60307, ppid = 57134, name = "opencode" },
        [57134] = { pid = 57134, ppid = 1, name = "fish" },
      },
      args = { [60307] = "opencode --print-logs serve --port 4096" },
      expected_ids = {},
    },
    {
      name = "ignores non-opencode listeners",
      procs = {
        [70001] = { pid = 70001, ppid = 1, name = "node" },
      },
      args = { [70001] = "node server.js" },
      expected_ids = {},
    },
  }) do
    it(case.name, function()
      local lsof_lines = {}
      local port = 49000
      for pid in pairs(case.args) do
        port = port + 1
        lsof_lines[#lsof_lines + 1] = "p" .. pid
        lsof_lines[#lsof_lines + 1] = "n127.0.0.1:" .. port
      end

      vim.api.nvim_get_proc = function(pid)
        return case.procs[pid]
      end
      Util.exec = function(cmd)
        if cmd[1] == "lsof" then
          return lsof_lines
        end
        if cmd[1] == "ps" then
          local pid = tonumber(cmd[#cmd])
          local line = case.args[pid]
          return line and { line } or {}
        end
        error("unexpected exec: " .. table.concat(cmd, " "))
      end

      local ids = vim.tbl_map(function(s)
        return s.id
      end, backend.sessions())
      table.sort(ids)
      assert.are.same(case.expected_ids, ids)
    end)
  end
end)
