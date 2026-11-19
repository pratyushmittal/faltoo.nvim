-- Claude Code backend: same run/stream/prewarm API as faltoo.bridge, using `claude -p`.
local M = {}

-- After /reset the next submit starts a new conversation instead of `--continue`.
local is_fresh = false

---@type integer|nil
local job = nil -- Running `claude -p` process, kept so :Faltoo stop can kill it.

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
    entry = ok and type(entry) == "table" and entry or {}
    local message = not entry.isMeta and entry.message or {}
    if entry.subtype == "local_command" then
      -- Commands like /code-review save their output as a tagged system entry, not a message.
      local output = tostring(entry.content or ""):gsub("</?local%-command%-%a+>", "")
      message = { role = "assistant", content = vim.trim(output) }
    end
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

---@param input? table
---@return string
local function tool_detail(input)
  input = input or {}
  -- Most useful input field per tool, e.g. Skill `skill`, Read `file_path`, WebFetch `url`.
  for _, key in ipairs({ "skill", "file_path", "command", "url", "query", "pattern", "description", "prompt" }) do
    if type(input[key]) == "string" then
      return input[key]
    end
  end
  -- Other tools (e.g. MCP) still show their raw input; history clips long lines.
  return next(input) and vim.json.encode(input) or ""
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
    local text = "Submitted message. Waiting for " .. tostring(msg.model or "Claude") .. "..."
    on_event({ is_new = true, classes = "status", text = text })
  elseif msg.type == "system" and msg.subtype == "status" then
    on_event({ is_new = true, classes = "status", text = "Claude: " .. tostring(msg.status) })
  elseif delta.type == "text_delta" then
    on_event({ is_new = false, classes = "answer", text = delta.text })
  elseif delta.type == "thinking_delta" then
    on_event({ is_new = false, classes = "thinking", text = delta.thinking })
  elseif msg.type == "rate_limit_event" and msg.rate_limit_info.status ~= "allowed" then
    -- Normal events say "allowed"; anything else means the usage limit is near or hit.
    on_event({ is_new = true, classes = "rate_limit", text = "Rate limit: " .. tostring(msg.rate_limit_info.status) })
  elseif type(msg.message) == "table" and type(msg.message.content) == "table" then
    -- Assistant messages carry tool calls; user messages carry their results.
    for _, block in ipairs(msg.message.content) do
      if block.type == "tool_use" then
        on_event({ is_new = true, classes = "tool", text = block.name .. " " .. tool_detail(block.input) })
      elseif block.type == "tool_result" then
        local first_line = content_text(block.content):match("[^\n]*")
        on_event({ is_new = true, classes = "tool", text = (block.is_error and "Error: " or "↳ ") .. first_line })
      end
    end
  elseif msg.type == "result" then
    -- Error results like `error_max_turns` carry no result text, only a subtype.
    local summary = msg.is_error and tostring(msg.result or msg.subtype) or "Assistant response saved."
    local text = ("%s · %d turns · %.1fs"):format(summary, msg.num_turns or 0, (msg.duration_ms or 0) / 1000)
    if #(msg.permission_denials or {}) > 0 then
      -- Stricter permission modes deny tools without asking in `-p`.
      text = text .. " · " .. #msg.permission_denials .. " permission denials"
    end
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

-- Kill the running `claude` process and its tool processes; on_exit then reports failure.
function M.stop()
  if job then
    -- Nil when the last process already exited.
    vim.fn.jobstop(job)
  end
end

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
  job = vim.fn.jobstart(cmd, {
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
      job = nil
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
