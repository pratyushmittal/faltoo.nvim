local M = {}

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

function M.run(args, input)
  local python = python_bin()
  if not python then
    return nil
  end
  local cmd = { python, bridge_path() }
  vim.list_extend(cmd, args)
  local result = vim.system(cmd, { text = true, stdin = input }):wait()
  if result.code ~= 0 then
    vim.notify((result.stderr or "Faltoo bridge failed"):gsub("%s+$", ""), vim.log.levels.ERROR)
    return nil
  end
  return result.stdout or ""
end

function M.stream(args, input, on_event, on_done)
  local python = python_bin()
  if not python then
    on_done(false)
    return
  end
  local cmd = { python, bridge_path() }
  vim.list_extend(cmd, args)
  local pending = ""
  local stderr = {}

  local function handle_line(line)
    if line == "" then
      return
    end
    vim.schedule(function()
      local ok, event = pcall(vim.json.decode, line)
      if ok and type(event) == "table" then
        on_event(event)
      else
        on_event({ is_new = true, classes = "status", text = line })
      end
    end)
  end

  local job = vim.fn.jobstart(cmd, {
    stdout_buffered = false,
    stderr_buffered = false,
    on_stdout = function(_, data)
      if not data or #data == 0 then
        return
      end
      data[1] = pending .. data[1]
      pending = data[#data] or ""
      for index = 1, #data - 1 do
        handle_line(data[index])
      end
    end,
    on_stderr = function(_, data)
      for _, line in ipairs(data or {}) do
        if line ~= "" then
          table.insert(stderr, line)
        end
      end
    end,
    on_exit = function(_, code)
      if pending ~= "" then
        handle_line(pending)
      end
      vim.schedule(function()
        if code ~= 0 then
          local message = table.concat(stderr, "\n")
          if message == "" then
            -- The job can fail before Python writes anything to stderr.
            message = "Faltoo bridge failed"
          end
          vim.notify(message, vim.log.levels.ERROR)
          on_done(false)
          return
        end
        on_done(true)
      end)
    end,
  })

  if job <= 0 then
    vim.notify("Failed to start Faltoo bridge", vim.log.levels.ERROR)
    on_done(false)
    return
  end
  vim.fn.chansend(job, input or "")
  vim.fn.chanclose(job, "stdin")
end

return M
