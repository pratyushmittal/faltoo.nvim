-- Claude Code backend: same run/stream/prewarm API as faltoo.bridge, using `claude -p`.
local M = {}

-- After /reset the next submit starts a new conversation instead of `--continue`.
local is_fresh = false

-- No one can approve tool calls in `-p`, so by default Claude may run anything.
M.permission_mode = "bypassPermissions"

-- Claude stores sessions per working directory with non-alphanumerics replaced by `-`.
---@return string|nil
local function session_path()
  if is_fresh then
    -- The reset session does not exist until the next submit creates it.
    return nil
  end
  local config_dir = vim.env.CLAUDE_CONFIG_DIR or vim.fn.expand("~/.claude")
  local project_dir = config_dir .. "/projects/" .. vim.fn.getcwd():gsub("[^%w]", "-")
  local files = vim.fn.glob(project_dir .. "/*.jsonl", false, true)
  -- `--continue` resumes the most recently used session, so show the newest file.
  table.sort(files, function(a, b)
    return vim.fn.getftime(a) > vim.fn.getftime(b)
  end)
  return files[1]
end

---@param content string|table[]|nil
---@return string
local function content_text(content)
  if type(content) == "string" then
    return content
  end
  local parts = {}
  for _, block in ipairs(content or {}) do
    if block.type == "text" then
      table.insert(parts, block.text)
    end
  end
  return table.concat(parts, "\n")
end

-- Readable user/assistant messages from the session JSONL; tool calls are skipped.
---@return table[]
local function messages()
  local path = session_path()
  local items = {}
  for _, line in ipairs(path and vim.fn.readfile(path) or {}) do
    local ok, entry = pcall(vim.json.decode, line, { luanil = { object = true, array = true } })
    local message = ok and type(entry) == "table" and not entry.isMeta and entry.message or {}
    local text = content_text(message.content)
    if text ~= "" then
      table.insert(items, { role = message.role, text = text })
    end
  end
  return vim.list_slice(items, math.max(1, #items - 99))
end

-- Same prompt format as faltoobot's reviews_prompt(), grouped by file.
---@param comments FaltooComment[]
---@return string
local function review_prompt(comments)
  local filenames, by_file = {}, {}
  for _, comment in ipairs(comments) do
    if not by_file[comment.filename] then
      by_file[comment.filename] = {}
      table.insert(filenames, comment.filename)
    end
    table.insert(by_file[comment.filename], comment)
  end

  local lines = { "# Comments in code review", "" }
  for index, filename in ipairs(filenames) do
    vim.list_extend(lines, { "## File name `" .. filename .. "`", "" })
    for _, comment in ipairs(by_file[filename]) do
      if comment.line_number_start == 0 then
        -- File comments intentionally have no line range or code.
        vim.list_extend(lines, { "### File comment", "" })
      else
        local range = comment.file_line_number_start .. "-" .. comment.file_line_number_end
        vim.list_extend(lines, { "### Line `" .. range .. "`", "", "Code:", "", "```", comment.code, "```", "" })
      end
      vim.list_extend(lines, { "Comment:", comment.comment, "" })
    end
    if index < #filenames then
      vim.list_extend(lines, { "---", "" })
    end
  end
  return vim.trim(table.concat(lines, "\n"))
end

-- Convert one stream-json line into Faltoo stream events.
---@param line string
---@param on_event fun(event: table)
local function handle_line(line, on_event)
  local ok, msg = pcall(vim.json.decode, line, { luanil = { object = true, array = true } })
  if not ok or type(msg) ~= "table" then
    -- Blank chunks between lines are not part of the protocol.
    return
  end

  local delta = msg.event and msg.event.delta or {}
  if msg.type == "system" and msg.subtype == "init" then
    -- The session now exists, so later submits can `--continue` it.
    is_fresh = false
    on_event({ is_new = true, classes = "status", text = "Submitted message. Waiting for assistant..." })
  elseif delta.type == "text_delta" then
    on_event({ is_new = false, classes = "answer", text = delta.text })
  elseif msg.type == "assistant" then
    for _, block in ipairs(msg.message.content or {}) do
      if block.type == "tool_use" then
        local input = block.input or {}
        local target = input.file_path or input.command or input.pattern or input.description or ""
        on_event({ is_new = true, classes = "tool", text = block.name .. " " .. target })
      end
    end
  elseif msg.type == "result" then
    -- Error results like `error_max_turns` carry no result text, only a subtype.
    local text = msg.is_error and tostring(msg.result or msg.subtype) or "Assistant response saved."
    on_event({ is_new = true, classes = "done", text = text })
  end
end

-- FaltooBot Python bridge `run`, set by bridge.use_claude(), for saved prompts.
---@type fun(args: string[]): string|nil
M.faltoobot_run = nil

---@param args string[]
---@return string|nil
local function faltoobot(args)
  if not M.faltoobot_run or vim.fn.executable("faltoobot") ~= 1 then
    -- Saved prompts are optional; the Claude backend works without faltoobot.
    return nil
  end
  return M.faltoobot_run(args)
end

---@param args string[]
---@return string|nil
function M.run(args)
  local command = args[1]
  if command == "messages" then
    return vim.json.encode({ messages = messages() })
  end
  if command == "messages-path" then
    return session_path() or ""
  end
  if command == "reset" then
    is_fresh = true
    return "Started a fresh Claude session."
  end
  if command == "slash-commands" then
    local commands = { { command = "/reset", preview = "start a fresh session" } }
    local ok, saved = pcall(vim.json.decode, faltoobot({ "slash-commands", "--saved-only" }) or "{}")
    vim.list_extend(commands, ok and saved.commands or {})
    return vim.json.encode({ commands = commands })
  end
  vim.notify("Faltoo Claude backend does not support " .. tostring(command), vim.log.levels.ERROR)
  return nil
end

-- Each submit starts its own CLI process, so there is nothing to warm up.
function M.prewarm() end

---@param args string[] `append-review` or `append-message`
---@param input string JSON payload with workspace and comments or text
---@param on_event fun(event: table)
---@param on_done fun(ok: boolean)
function M.stream(args, input, on_event, on_done)
  if vim.fn.executable("claude") ~= 1 then
    vim.notify("claude command not found in PATH", vim.log.levels.ERROR)
    on_done(false)
    return
  end

  local payload = vim.json.decode(input)
  local prompt = args[1] == "append-review" and review_prompt(payload.comments) or payload.text
  if vim.startswith(prompt, "/") then
    -- Expand FaltooBot saved prompts; other commands pass through for Claude to handle.
    prompt = faltoobot({ "expand-slash-command", prompt }) or prompt
  end
  local cmd = { "claude", "-p", "--output-format", "stream-json", "--verbose", "--include-partial-messages" }
  vim.list_extend(cmd, { "--permission-mode", M.permission_mode })
  if not is_fresh then
    table.insert(cmd, "--continue")
  end

  local pending, stderr = "", {}
  local job = vim.fn.jobstart(cmd, {
    cwd = payload.workspace,
    on_stdout = function(_, data)
      -- Job output arrives in chunks; keep the unfinished last line for the next chunk.
      data[1] = pending .. data[1]
      pending = table.remove(data)
      for _, line in ipairs(data) do
        handle_line(line, on_event)
      end
    end,
    on_stderr = function(_, data)
      vim.list_extend(stderr, data)
    end,
    on_exit = function(_, code)
      local message = vim.trim(table.concat(stderr, "\n"))
      if code ~= 0 and message ~= "" then
        vim.notify(message, vim.log.levels.ERROR)
      end
      on_done(code == 0)
    end,
  })
  vim.fn.chansend(job, prompt)
  vim.fn.chanclose(job, "stdin")
end

return M
