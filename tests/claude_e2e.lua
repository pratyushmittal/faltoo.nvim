-- Headless Claude backend test; a fake `claude` script replays stream-json output.
local repo = vim.fn.getcwd()
vim.opt.runtimepath:prepend(repo)
local helpers = dofile(repo .. "/tests/helpers.lua")

local tmp = vim.fn.tempname()
local bin = tmp .. "/bin"
local log = tmp .. "/claude.log"
local workspace = tmp .. "/workspace"
vim.fn.mkdir(bin, "p")
vim.fn.mkdir(workspace, "p")

-- Fake CLI: record args and prompt, then print the canned stream.
vim.fn.writefile({
  "#!/bin/sh",
  '{ echo "ARGS: $*"; cat; echo; } >> "' .. log .. '"',
  'cat "' .. tmp .. '/stream.jsonl"',
}, bin .. "/claude")
vim.fn.setfperm(bin .. "/claude", "rwxr-xr-x")
vim.fn.writefile({
  vim.json.encode({ type = "system", subtype = "init" }),
  vim.json.encode({
    type = "assistant",
    message = { content = { { type = "tool_use", name = "Edit", input = { file_path = "sample.txt" } } } },
  }),
  vim.json.encode({ type = "stream_event", event = { delta = { type = "text_delta", text = "Fixed " } } }),
  vim.json.encode({ type = "stream_event", event = { delta = { type = "text_delta", text = "it." } } }),
  vim.json.encode({ type = "result" }),
}, tmp .. "/stream.jsonl")
vim.env.PATH = bin .. ":" .. vim.env.PATH
vim.env.CLAUDE_CONFIG_DIR = tmp .. "/config"

-- A real git repo exercises unstaged file discovery without the Python bridge.
vim.fn.writefile({ "one", "two" }, workspace .. "/sample.txt")
vim.system({ "git", "init", "-q", workspace }):wait()
vim.cmd("cd " .. vim.fn.fnameescape(workspace))

-- Existing session that `--continue` would resume.
local project_dir = vim.env.CLAUDE_CONFIG_DIR .. "/projects/" .. vim.fn.getcwd():gsub("[^%w]", "-")
vim.fn.mkdir(project_dir, "p")
vim.fn.writefile({
  vim.json.encode({ type = "user", message = { role = "user", content = "earlier question" } }),
  vim.json.encode({ type = "user", message = { role = "user", content = { { type = "tool_result" } } } }),
  vim.json.encode({
    type = "assistant",
    message = { role = "assistant", content = { { type = "text", text = "earlier answer" } } },
  }),
}, project_dir .. "/s1.jsonl")

local faltoo = require("faltoo")
faltoo.setup({ backend = "claude" })

-- A repeated setup (e.g. re-sourced config) must keep saved prompts on the Python bridge.
faltoo.setup({ backend = "claude" })
if require("faltoo.claude").faltoobot_run == require("faltoo.bridge").run then
  error("Repeated setup pointed saved prompts back at the Claude backend")
end

-- Record converted stream events; the history modal clears them when a stream ends.
local events = {}
local bridge = require("faltoo.bridge")
local stream = bridge.stream
---@diagnostic disable-next-line: duplicate-set-field
bridge.stream = function(args, input, on_event, on_done)
  stream(args, input, function(event)
    table.insert(events, event.classes .. ": " .. event.text)
    on_event(event)
  end, on_done)
end
faltoo.on()
vim.cmd("Faltoo open-unstaged")
if vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":t") ~= "sample.txt" then
  error("Review mode did not open the untracked file")
end

local function wait_for_answer()
  vim.wait(5000, function()
    return not faltoo.status():find("answering", 1, true)
  end)
end

-- Submitting a review comment should continue the session with the review prompt.
local file_buf = vim.api.nvim_get_current_buf()
vim.api.nvim_win_set_cursor(0, { 1, 0 })
helpers.press(file_buf, "n", "c")
vim.api.nvim_buf_set_lines(0, 0, -1, false, { "rename this" })
helpers.press(vim.api.nvim_get_current_buf(), "i", "<CR>")
vim.cmd("Faltoo submit")
wait_for_answer()
local log_text = table.concat(vim.fn.readfile(log), "\n")
helpers.contains(log_text, "--permission-mode bypassPermissions --continue")
helpers.contains(log_text, "## File name `sample.txt`")
helpers.contains(log_text, "### Line `1-1`")
helpers.contains(log_text, "Comment:\nrename this")
helpers.contains(
  table.concat(events, "\n"),
  "tool: Edit sample.txt\nanswer: Fixed \nanswer: it.\ndone: Assistant response saved."
)
if faltoo.status():find("comment", 1, true) then
  error("Submitted comments were not cleared: " .. faltoo.status())
end

-- History should show readable session messages and skip tool results.
vim.cmd("Faltoo history")
local history_text = helpers.buffer_text(vim.api.nvim_get_current_buf())
helpers.contains(history_text, "earlier answer")
helpers.contains(history_text, "(2/2)")
vim.cmd("close")

-- Reset should hide the old session and start the next submit without --continue.
vim.cmd("Faltoo reset")
vim.cmd("Faltoo history")
if require("faltoo.modals.history").is_open() then
  error("History still showed the session from before reset")
end
vim.fn.delete(log)
vim.cmd("Faltoo ask")
vim.api.nvim_buf_set_lines(0, 0, -1, false, { "new topic" })
helpers.press(vim.api.nvim_get_current_buf(), "i", "<CR>")
vim.cmd("Faltoo submit")
wait_for_answer()
log_text = table.concat(vim.fn.readfile(log), "\n")
helpers.contains(log_text, "new topic")
if log_text:find("--continue", 1, true) then
  error("Submit after reset still used --continue")
end

-- With faltoobot installed, its saved prompts are listed and expanded before submit.
vim.fn.writefile({ "#!/bin/sh" }, bin .. "/faltoobot")
vim.fn.setfperm(bin .. "/faltoobot", "rwxr-xr-x")
require("faltoo.claude").faltoobot_run = function(args)
  if args[1] == "slash-commands" then
    return vim.json.encode({ commands = { { command = "/greet", preview = "Say hello to $1" } } })
  end
  return "Say hello to " .. args[2]:match("^/greet (.*)")
end
helpers.contains(bridge.run({ "slash-commands" }), "/greet")
vim.fn.delete(log)
vim.cmd("Faltoo ask")
vim.api.nvim_buf_set_lines(0, 0, -1, false, { "/greet Bob" })
helpers.press(vim.api.nvim_get_current_buf(), "i", "<CR>")
vim.cmd("Faltoo submit")
wait_for_answer()
helpers.contains(table.concat(vim.fn.readfile(log), "\n"), "Say hello to Bob")

faltoo.off()
vim.fn.delete(tmp, "rf")
vim.cmd("qa!")
