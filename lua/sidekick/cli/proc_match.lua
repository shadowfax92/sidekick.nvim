local M = {}

---@param cmd string?
---@return string?
function M.executable_name(cmd)
  local first = cmd and cmd:match("^%s*([^%s]+)")
  return first and vim.fs.basename(first)
end

--- Build a process matcher that checks argv[0], not arguments.
---@param name string
---@return fun(_: sidekick.cli.Tool, proc: sidekick.cli.Proc): boolean
function M.executable(name)
  return function(_, proc)
    return M.executable_name(proc.cmd) == name
  end
end

return M
