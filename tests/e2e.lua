-- Headless UI flow test; the bridge is faked so it runs without FaltooBot.
local repo = vim.fn.getcwd()
vim.opt.runtimepath:prepend(repo)

local helpers = dofile(repo .. "/tests/helpers.lua")
local fake_bridge = dofile(repo .. "/tests/fake_bridge.lua").install(repo)

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
vim.fn.writefile({ "one", "two" }, tmp .. "/sample.txt")
fake_bridge.unstaged_files = { tmp .. "/sample.txt" }
vim.cmd("cd " .. vim.fn.fnameescape(tmp))
vim.cmd("edit sample.txt")

local faltoo = require("faltoo")
faltoo.setup()
faltoo.on()

-- Review mode should lock normal review files.
local file_buf = vim.api.nvim_get_current_buf()
if not vim.bo[file_buf].readonly or vim.bo[file_buf].modifiable then
  error("Review mode did not make the file buffer readonly")
end

-- Outside files and unlisted plugin-style buffers should stay writable.
local outside = vim.fn.tempname()
vim.fn.writefile({ "outside" }, outside)
vim.cmd("edit " .. vim.fn.fnameescape(outside))
local outside_buf = vim.api.nvim_get_current_buf()
if vim.bo[outside_buf].readonly or not vim.bo[outside_buf].modifiable then
  error("File outside review root should stay editable")
end
if helpers.has_map(outside_buf, "n", "c") then
  error("File outside review root should not get Faltoo review mappings")
end

vim.fn.writefile({ "hidden" }, tmp .. "/hidden.txt")
vim.cmd("edit hidden.txt")
local hidden_buf = vim.api.nvim_get_current_buf()
vim.bo[hidden_buf].buflisted = false
vim.cmd("edit sample.txt")
vim.cmd("buffer " .. hidden_buf)
if vim.bo[hidden_buf].readonly or not vim.bo[hidden_buf].modifiable then
  error("Unlisted normal buffer should be restored and stay editable")
end
if helpers.has_map(hidden_buf, "n", "c") then
  error("Unlisted normal buffer should not keep Faltoo review mappings")
end

vim.cmd("edit sample.txt")
file_buf = vim.api.nvim_get_current_buf()

-- Comment modal should prepare and submit one review comment.
helpers.press(file_buf, "n", "c")
local comment_buf = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_lines(comment_buf, 0, -1, false, { "please fix this" })
helpers.press(comment_buf, "i", "<CR>")
helpers.contains(faltoo.status(), "1 comment(s)")

vim.cmd("Faltoo submit")
if faltoo.status():find("comment", 1, true) then
  error("Submitted comments were not cleared: " .. faltoo.status())
end

-- History should show the submitted review response.
vim.cmd("Faltoo history")
local history_buf = vim.api.nvim_get_current_buf()
helpers.contains(helpers.buffer_text(history_buf), "review answer")

-- Reply from history should save an Ask AI question.
helpers.press(history_buf, "n", "r")
local ask_buf = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_lines(ask_buf, 0, -1, false, { "follow up" })
helpers.press(ask_buf, "i", "<CR>")
helpers.contains(faltoo.status(), "question ready")

vim.cmd("Faltoo submit")
if not fake_bridge.active_stream then
  error("Ask submit did not start a stream")
end

-- Live stream should render as bullets and keep the modal scrolled to the end.
fake_bridge.active_stream.on_event({ is_new = true, classes = "tool", text = "read sample.txt" })
fake_bridge.active_stream.on_event({ is_new = true, classes = "answer", text = "assistant answer" })
local streaming_text = helpers.buffer_text(history_buf)
helpers.contains(streaming_text, "assistant · streaming")
helpers.contains(streaming_text, "- read sample.txt")
helpers.contains(streaming_text, "- assistant answer")

local cursor = vim.api.nvim_win_get_cursor(0)
local line_count = vim.api.nvim_buf_line_count(history_buf)
if cursor[1] ~= line_count then
  error("History did not scroll to stream end: " .. cursor[1] .. " != " .. line_count)
end

-- Completing the stream should refresh history from persisted messages.
table.insert(fake_bridge.messages, { role = "assistant", text = "assistant answer" })
fake_bridge.active_stream.on_event({ is_new = true, classes = "done", text = "Assistant response saved." })
fake_bridge.active_stream.on_done(true)
helpers.contains(helpers.buffer_text(history_buf), "assistant answer")

faltoo.off()
vim.fn.delete(tmp, "rf")
vim.cmd("qa!")
