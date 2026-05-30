local M = {}

---@class FaltooBridgeRequest
---@field on_event fun(event: table)
---@field on_done fun(ok: boolean)

---@type integer|nil
local job = nil -- Set when Python bridge starts; cleared on exit.

local pending = "" -- Incomplete stdout line kept between jobstart chunks.

---@type string[]
local stderr = {} -- Recent stderr lines used if the server exits.

local next_id = 0 -- Increments for each server request so responses route to callbacks.

---@type table<string, FaltooBridgeRequest>
local requests = {} -- Active callbacks by request id.

local function root()
  local source = debug.getinfo(1, "S").source:sub(2)
  return vim.fn.fnamemodify(source, ":h:h:h")
end

local function bridge_path()
  return root() .. "/python/faltoo_bridge.py"
end

local function shebang_python(path)
  if path == "" then
    return nil
  end
  local ok, lines = pcall(vim.fn.readfile, path, "", 1)
  if not ok then
    -- Some shims can be executable but not readable by readfile().
    return nil
  end
  local first = lines[1] or ""
  if not vim.startswith(first, "#!") then
    return nil
  end
  local parts = vim.split(first:sub(3), "%s+", { trimempty = true })
  if parts[1] == "/usr/bin/env" then
    return parts[2]
  end
  return parts[1]
end

local function python_bin()
  local faltoobot = vim.fn.exepath("faltoobot")
  if faltoobot == "" then
    vim.notify("faltoobot command not found in PATH", vim.log.levels.ERROR)
    return nil
  end

  local python = shebang_python(faltoobot)
  if python then
    return python
  end

  vim.notify("Could not resolve Python from faltoobot shebang", vim.log.levels.ERROR)
  return nil
end

local function cmd(args)
  local python = python_bin()
  if not python then
    return nil
  end

  local result = { python, bridge_path() }
  vim.list_extend(result, args)
  return result
end

-- Finish one server request and call its stored completion callback.
---@param id string|integer|nil
---@param ok boolean
---@param error string
local function complete_request(id, ok, error)
  local request = requests[tostring(id)]
  if not request then
    -- Stale server output can arrive after all pending requests were failed.
    return
  end

  requests[tostring(id)] = nil
  vim.schedule(function()
    if not ok and error and error ~= "" then
      vim.notify(error, vim.log.levels.ERROR)
    end
    request.on_done(ok)
  end)
end

-- Fail every pending request, usually because the bridge server exited.
---@param message string
local function fail_requests(message)
  local active_requests = requests
  requests = {}
  for _, request in pairs(active_requests) do
    vim.schedule(function()
      if message ~= "" then
        vim.notify(message, vim.log.levels.ERROR)
      end
      request.on_done(false)
    end)
  end
end

-- Decode one newline-delimited JSON message from the Python bridge server.
---@param line string
local function handle_server_line(line)
  if line == "" then
    -- jobstart can emit empty chunks between newline-delimited messages.
    return
  end

  local ok, payload = pcall(vim.json.decode, line)
  if not ok or type(payload) ~= "table" then
    -- Server stdout is a private JSON protocol; ignore unrelated output.
    return
  end

  local request = requests[tostring(payload.id)]
  if not request then
    -- The request may have already failed if the server exited and restarted.
    return
  end

  if type(payload.event) == "table" then
    vim.schedule(function()
      request.on_event(payload.event)
    end)
    return
  end

  if payload.done then
    complete_request(payload.id, payload.ok == true, tostring(payload.error or ""))
  end
end

local function start_server()
  if job and vim.fn.jobwait({ job }, 0)[1] == -1 then
    -- Reuse the live Python process so websocket prewarm state survives.
    return job
  end

  local command = cmd({ "server" })
  if not command then
    -- python_bin() already showed the executable/shebang error.
    return nil
  end

  pending = ""
  stderr = {}
  job = vim.fn.jobstart(command, {
    stdout_buffered = false,
    stderr_buffered = false,
    on_stdout = function(_, data)
      if not data or #data == 0 then
        return
      end
      data[1] = pending .. data[1]
      pending = data[#data] or ""
      for index = 1, #data - 1 do
        handle_server_line(data[index])
      end
    end,
    on_stderr = function(_, data)
      for _, line in ipairs(data or {}) do
        if line ~= "" then
          table.insert(stderr, line)
          if #stderr > 100 then
            -- Keep recent stderr only; a warm server can run for the whole Neovim session.
            table.remove(stderr, 1)
          end
        end
      end
    end,
    on_exit = function(_, code)
      local message = table.concat(stderr, "\n")
      job = nil
      pending = ""
      stderr = {}
      if code ~= 0 and message == "" then
        -- The server can fail before Python writes anything to stderr.
        message = "Faltoo bridge server exited"
      end
      fail_requests(code == 0 and "" or message)
    end,
  })

  if job <= 0 then
    job = nil
    vim.notify("Failed to start Faltoo bridge server", vim.log.levels.ERROR)
    return nil
  end

  return job
end

local function send_server_request(args, input, on_event, on_done)
  local job = start_server()
  if not job then
    -- start_server() already reported why the bridge could not start.
    on_done(false)
    return
  end

  -- Match each async server response with the callbacks for this request.
  next_id = next_id + 1
  local id = tostring(next_id)
  requests[id] = {
    on_event = on_event,
    on_done = on_done,
  }

  local line = vim.json.encode({ id = id, args = args, input = input or "" }) .. "\n"
  if vim.fn.chansend(job, line) == 0 then
    -- The server may have exited between start_server() and chansend().
    complete_request(id, false, "Faltoo bridge server is not accepting requests")
  end
end

---@param args string[]
---@return string|nil
function M.run(args)
  local command = cmd(args)
  if not command then
    return nil
  end

  local result = vim.system(command, { text = true }):wait()
  if result.code ~= 0 then
    vim.notify((result.stderr or "Faltoo bridge failed"):gsub("%s+$", ""), vim.log.levels.ERROR)
    return nil
  end
  return result.stdout or ""
end

function M.prewarm(workspace)
  local input = vim.json.encode({ workspace = workspace })
  send_server_request({ "prewarm" }, input, function() end, function() end)
end

function M.stream(args, input, on_event, on_done)
  send_server_request(args, input, on_event, on_done)
end

return M
