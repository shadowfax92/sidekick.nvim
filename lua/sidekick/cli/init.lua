local Context = require("sidekick.cli.context")
local Config = require("sidekick.config")
local State = require("sidekick.cli.state")
local Util = require("sidekick.util")

local M = {}

---@class sidekick.Prompt
---@field msg string

---@class sidekick.cli.Message
---@field msg? string
---@field prompt? string
---@field text? sidekick.Text[]

---@class sidekick.cli.Config
---@field cmd string[] Command to run the CLI tool
---@field env? table<string, string|false> Environment variables to set when running the command
---@field url? string Web URL to open when the tool is not installed
---@field keys? table<string, sidekick.cli.Keymap|false>
---@field is_proc? (fun(self:sidekick.cli.Tool, proc:sidekick.cli.Proc):boolean)|string Regex or function to identity a running process
---@field mux_focus? boolean wether the tool needs to be focused in order to receive input
---@field format? fun(text:sidekick.Text[], str:string):string?
---@field native_scroll? boolean whether the tool handles scrolling natively

---@class sidekick.cli.Show
---@field name? string
---@field focus? boolean
---@field filter? sidekick.cli.Filter
---@field all? boolean
---@field scope? "cwd"|"project"|"all"

---@class sidekick.cli.Hide
---@field name? string
---@field filter? sidekick.cli.Filter
---@field all? boolean

---@class sidekick.cli.Send: sidekick.cli.Show,sidekick.cli.Message
---@field multicast? boolean
---@field submit? boolean

--- Keymap options similar to `vim.keymap.set` and `lazy.nvim` mappings
---@class sidekick.cli.Keymap: vim.keymap.set.Opts
---@field [1] string keymap
---@field [2] string|sidekick.cli.Action
---@field mode? string|string[]

--- Upgrade msg to {line} + {selection} when in visual mode
---@param opts {msg?:string, prompt?:string}
local function resolve_visual_msg(opts)
  local mode = vim.api.nvim_get_mode().mode
  local is_visual = mode == "v" or mode == "V" or mode == "\22"
  if is_visual then
    if not opts.msg and not opts.prompt then
      opts.msg = "{line}\n```\n{selection}\n```"
    elseif opts.msg == "{line}" then
      opts.msg = "{line}\n```\n{selection}\n```"
    elseif opts.msg == "{line_abs}" then
      opts.msg = "{line_abs}\n```\n{selection}\n```"
    end
  end
end

local FILTER_KEYS = { "attached", "cwd", "external", "installed", "name", "session", "started", "terminal" }

---@param text string?
---@param max_width? number
---@return string?
local function shorten_summary(text, max_width)
  text = text and vim.trim(text) or nil
  if not text or text == "" then
    return
  end
  text = text:gsub("%s+", " ")
  max_width = max_width or 80
  if vim.api.nvim_strwidth(text) <= max_width then
    return text
  end
  return "…" .. text:sub(-(max_width - 1))
end

---@param msg string?
---@return string?
local function context_summary(msg)
  for _, line in ipairs(vim.split(msg or "", "\n", { plain = true })) do
    local summary = shorten_summary(line)
    if summary then
      return summary
    end
  end
end

---@param opts sidekick.cli.Send
---@param mode "send"|"comment"
---@return string
local function operation_name(opts, mode)
  if mode == "comment" then
    return "comment"
  end
  local template = opts.msg or ""
  if opts.prompt then
    return "prompt"
  end
  if template:find("{file", 1, true) then
    return "file"
  end
  if template:find("{line", 1, true) then
    return "line"
  end
  if template:find("{selection", 1, true) then
    return "selection"
  end
  if template:find("{this}", 1, true) then
    return "context"
  end
  return "message"
end

---@param opts sidekick.cli.Send
---@param msg string?
---@param mode "send"|"comment"
---@return {resolved: fun(states: sidekick.cli.State[]), sent: fun()}
local function send_notifier(opts, msg, mode)
  local operation = operation_name(opts, mode)
  local summary = context_summary(msg)
  local targets = {} ---@type sidekick.cli.State[]
  local remaining = 0

  local function notify()
    local target = ("Sent %s to %d agent%s"):format(operation, #targets, #targets == 1 and "" or "s")
    if #targets == 1 then
      target = ("%s (%s)"):format(target, targets[1].tool.name)
    end
    local parts = { target }
    if summary then
      parts[#parts + 1] = summary
    end
    Util.info(table.concat(parts, " · "), { timeout = 1000 })
  end

  return {
    resolved = function(states)
      targets = states
      remaining = #states
    end,
    sent = function()
      if remaining == 0 then
        return
      end
      remaining = remaining - 1
      if remaining == 0 then
        notify()
      end
    end,
  }
end

---@generic T: {name?:string, filter?:sidekick.cli.Filter}
---@param opts? T|string
---@return T
local function filter_opts(opts)
  opts = type(opts) == "string" and { name = opts } or opts or {}
  ---@cast opts {name?:string, filter?:sidekick.cli.Filter}
  opts.filter = opts.filter or {}
  for _, key in ipairs(FILTER_KEYS) do
    if opts[key] ~= nil and opts.filter[key] == nil then
      opts.filter[key] = opts[key]
    end
  end
  return opts
end

--- Select a prompt to send
---@param opts? sidekick.cli.Prompt|{cb:nil}
---@overload fun(cb:fun(msg?:string))
function M.prompt(opts)
  opts = opts or {}
  opts = type(opts) == "function" and { cb = opts } or opts --[[@as sidekick.cli.Prompt]]
  opts.cb = opts.cb or function(_, text)
    if text then
      M.send({ text = text })
    end
  end
  require("sidekick.cli.ui.prompt").select(opts)
end

--- Start or attach to a CLI tool
---@param opts? sidekick.cli.Select|{cb:nil}|{focus?:boolean}
---@overload fun(cb:fun(state?:sidekick.cli.State))
function M.select(opts)
  opts = opts or {}
  opts = type(opts) == "function" and { cb = opts } or opts --[[@as sidekick.cli.Select]]
  opts.cb = opts.cb
    or function(state)
      if state then
        State.attach(state, { show = true, focus = opts.focus })
      end
    end
  require("sidekick.cli.ui.select").select(opts)
end

---@param opts? sidekick.cli.Show
function M.auto_attach(opts)
  opts = filter_opts(opts)
  return State.auto_attach(opts.filter, {
    focus = opts.focus,
    multiple = true,
    scope = opts.scope,
    show = true,
  })
end

---@param opts? sidekick.cli.Show
---@overload fun(name: string)
function M.show(opts)
  opts = filter_opts(opts)
  State.with(function() end, {
    all = opts.all,
    attach = true,
    filter = opts.filter,
    focus = opts.focus,
    scope = opts.scope,
    show = true,
  })
end

---@param opts? sidekick.cli.Show
---@overload fun(name: string)
function M.toggle(opts)
  opts = filter_opts(opts)
  State.with(function(state, attached)
    if not state.terminal then
      return
    end
    if not attached then
      state.terminal:toggle()
    end
    if state.terminal:is_open() and opts.focus ~= false then
      state.terminal:focus()
    end
  end, {
    attach = true,
    filter = opts.filter,
    scope = opts.scope,
  })
end

--- Toggle focus of the terminal window if it is already open
---@param opts? sidekick.cli.Show
---@overload fun(name: string)
function M.focus(opts)
  opts = filter_opts(opts)
  State.with(function(state)
    if not state.terminal then
      return
    end
    if state.terminal:is_focused() then
      state.terminal:blur()
    else
      state.terminal:focus()
    end
  end, {
    attach = true,
    filter = opts.filter,
    focus = false,
    scope = opts.scope,
    show = true,
  })
end

---@param opts? sidekick.cli.Hide
---@overload fun(name: string)
function M.hide(opts)
  opts = filter_opts(opts)
  State.with(function(state)
    return state.terminal and state.terminal:hide()
  end, {
    all = opts.all,
    filter = Util.merge(opts.filter, { terminal = true }),
  })
end

---@param opts? sidekick.cli.Hide
---@overload fun(name: string)
function M.close(opts)
  opts = filter_opts(opts)
  State.with(State.detach, {
    all = opts.all,
    filter = Util.merge(opts.filter),
  })
end

-- Render a message template or prompt
---@param opts? sidekick.cli.Message|string
function M.render(opts)
  return Context.get():render(opts or "")
end

--- Send a message or prompt to a CLI
---@param opts? sidekick.cli.Send
---@overload fun(msg:string)
function M.send(opts)
  opts = type(opts) == "string" and { msg = opts } or opts
  opts = filter_opts(opts)
  resolve_visual_msg(opts)

  local msg, text = "", opts.text ---@type string?, sidekick.Text[]?
  if not text then
    msg, text = M.render(opts)
    if msg == "" or not text then
      Util.warn("Nothing to send.")
      return
    elseif msg == "\n" then
      msg = "" -- allow sending a new line
      text = {}
    end
  end

  local notify = send_notifier(opts, msg, "send")

  State.with(function(state)
    Util.exit_visual_mode()
    vim.schedule(function()
      local formatted = state.tool:format(text)
      state.session:send(formatted .. "\n")
      if opts.submit then
        state.session:submit()
      end
      notify.sent()
    end)
  end, {
    attach = true,
    all = opts.all,
    filter = opts.filter,
    focus = opts.focus,
    multicast = opts.multicast ~= false and Config.cli.multicast ~= false,
    on_resolved = notify.resolved,
    scope = opts.scope,
    show = true,
  })
end

--- Send context with a multiline comment popup
---@param opts? sidekick.cli.Send
---@overload fun(msg:string)
function M.send_with_comment(opts)
  opts = type(opts) == "string" and { msg = opts } or opts or {}
  opts = filter_opts(opts)
  resolve_visual_msg(opts)

  -- capture context before popup (visual mode will be lost)
  local msg, text = "", opts.text ---@type string?, sidekick.Text[]?
  if not text then
    msg, text = M.render(opts)
    if msg == "" or not text then
      Util.warn("Nothing to send.")
      return
    elseif msg == "\n" then
      msg = ""
      text = {}
    end
  end

  Util.exit_visual_mode()

  local context_lines = msg ~= "" and vim.split(msg, "\n", { plain = true }) or {}

  require("sidekick.cli.ui.comment").open({
    context_lines = context_lines,
    cb = function(comment)
      if not comment then
        return
      end
      local Text = require("sidekick.text")
      -- prefix each comment line with > (blockquote)
      local quoted = comment:gsub("([^\n]+)", "> %1")
      local combined = Text.to_text(quoted)
      table.insert(combined, { { "" } })
      vim.list_extend(combined, text)
      local notify = send_notifier(opts, msg, "comment")

      State.with(function(state)
        vim.schedule(function()
          local formatted = state.tool:format(combined)
          state.session:send(formatted .. "\n")
          if opts.submit then
            state.session:submit()
          end
          notify.sent()
        end)
      end, {
        attach = true,
        all = opts.all,
        filter = opts.filter,
        focus = opts.focus,
        multicast = opts.multicast ~= false and Config.cli.multicast ~= false,
        on_resolved = notify.resolved,
        scope = opts.scope,
        show = true,
      })
    end,
  })
end

---@deprecated use `require("sidekick.cli").prompt()`
function M.select_prompt(...)
  Util.deprecate('require("sidekick.cli").select_prompt()', 'require("sidekick.cli").prompt()')
  return M.prompt(...)
end

---@deprecated use `require("sidekick.cli").select()`
function M.select_tool(...)
  Util.deprecate('require("sidekick.cli").select_tool()', 'require("sidekick.cli").select()')
  return M.select(...)
end

---@deprecated use `require("sidekick.cli").send()`
function M.ask(...)
  Util.deprecate('require("sidekick.cli").ask()', 'require("sidekick.cli").send()')
  return M.send(...)
end

return M
