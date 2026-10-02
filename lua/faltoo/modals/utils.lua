local M = {}

function M.leave_insert_mode()
  local mode = vim.api.nvim_get_mode().mode
  if mode:match("^[iR]") then
    -- Textarea submit can close the floating insert buffer while insert mode is active.
    vim.cmd("stopinsert")
  end
end

function M.close_window(win)
  if win and vim.api.nvim_win_is_valid(win) then
    -- The modal may already be closed by another key path.
    vim.api.nvim_win_close(win, true)
  end
end

-- Create a markdown scratch buffer that is wiped when its window closes.
---@param text? string
---@return integer
function M.scratch_buf(text)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "markdown"
  if text and text ~= "" then
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(text, "\n", { plain = true }))
  end
  return buf
end

-- Map textarea submit/newline/cancel keys and start typing after any initial text.
---@param buf integer
---@param win integer
---@param force_close fun()
---@param on_submit fun(text: string)
function M.map_textarea(buf, win, force_close, on_submit)
  local function text()
    return vim.trim(table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"))
  end

  local function submit()
    local value = text()
    force_close()
    on_submit(value)
  end

  local function close()
    if text() ~= "" then
      -- Drafts should only close after they are submitted or explicitly cleared.
      vim.notify("Input is not empty. Submit or clear it before closing.", vim.log.levels.WARN)
      return
    end
    force_close()
  end

  vim.keymap.set({ "n", "i" }, "<CR>", submit, { buffer = buf, silent = true })
  vim.keymap.set({ "n", "i" }, "<C-s>", submit, { buffer = buf, silent = true })
  vim.keymap.set("i", "<S-CR>", "<CR>", { buffer = buf, silent = true })
  vim.keymap.set("n", "<S-CR>", "o", { buffer = buf, silent = true })
  vim.keymap.set("n", "q", close, { buffer = buf, silent = true })
  vim.keymap.set("n", "<Esc>", close, { buffer = buf, silent = true })

  local last_row = vim.api.nvim_buf_line_count(buf)
  local last_line = vim.api.nvim_buf_get_lines(buf, -2, -1, false)[1] or ""
  vim.api.nvim_win_set_cursor(win, { last_row, #last_line })
  vim.cmd("startinsert!")
end

function M.insert_text_at_window(win, buf, text)
  if not vim.api.nvim_buf_is_valid(buf) or not vim.api.nvim_win_is_valid(win) then
    -- The textarea can be closed while an external picker is open.
    return
  end

  local ok = pcall(vim.api.nvim_set_current_win, win)
  if not ok then
    -- The picker may return after the user has switched tabs.
    return
  end

  local row, col = unpack(vim.api.nvim_win_get_cursor(win))
  vim.api.nvim_buf_set_text(buf, row - 1, col, row - 1, col, { text })
  local cursor = { row, col + #text }
  vim.api.nvim_win_set_cursor(win, cursor)

  -- Go back to insert mode after inserting text, keeping the cursor after it.
  vim.defer_fn(function()
    if not vim.api.nvim_win_is_valid(win) then
      -- The modal can close right after a picker inserts text.
      return
    end
    local switched = pcall(vim.api.nvim_set_current_win, win)
    if not switched then
      -- The picker may return after the user has switched tabs.
      return
    end
    if vim.api.nvim_get_mode().mode:match("^i") then
      -- A mid-line `/` never leaves insert mode; `startinsert!` would jump to line end.
      return
    end

    -- Pickers return in normal mode, which clamps the cursor before the line end.
    local line = vim.api.nvim_buf_get_lines(buf, cursor[1] - 1, cursor[1], false)[1] or ""
    vim.api.nvim_win_set_cursor(win, cursor)
    vim.cmd(cursor[2] < #line and "startinsert" or "startinsert!")
  end, 20)
end

-- Pick one item with Telescope when available, otherwise `vim.ui.select`.
---@param items any[]
---@param prompt string
---@param format fun(item: any): string
---@param on_select fun(item: any|nil)
local function pick(items, prompt, format, on_select)
  local ok, pickers = pcall(require, "telescope.pickers")
  if not ok then
    -- Telescope is optional; `vim.ui.select` works in every Neovim setup.
    vim.ui.select(items, { prompt = prompt, format_item = format }, on_select)
    return
  end

  local finders = require("telescope.finders")
  local conf = require("telescope.config").values
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")
  pickers
    .new({}, {
      prompt_title = prompt,
      finder = finders.new_table({
        results = items,
        entry_maker = function(item)
          return { value = item, display = format(item), ordinal = format(item) }
        end,
      }),
      sorter = conf.generic_sorter({}),
      attach_mappings = function(prompt_bufnr)
        actions.select_default:replace(function()
          local selection = action_state.get_selected_entry()
          actions.close(prompt_bufnr)
          on_select(selection and selection.value)
        end)
        return true
      end,
    })
    :find()
end

local function slash_command_label(command)
  local name = tostring(command.command or "")
  local preview = tostring(command.preview or "")
  if preview == "" then
    return name
  end
  return name .. " — " .. preview
end

---@param buf integer
---@param win integer
---@param slash_commands fun(): table[]
---@param on_command fun(command: string): boolean
function M.map_slash_commands(buf, win, slash_commands, on_command)
  local function pick_command()
    local row, col = unpack(vim.api.nvim_win_get_cursor(win))
    local commands = (row == 1 and col == 0) and slash_commands() or {}
    if #commands == 0 then
      -- Only a leading slash opens completion; elsewhere `/` is plain text.
      M.insert_text_at_window(win, buf, "/")
      return
    end

    pick(commands, "Faltoo slash command", slash_command_label, function(command)
      local name = command and tostring(command.command or "")
      if name and on_command(name) then
        return
      end
      M.insert_text_at_window(win, buf, name or "/")
    end)
  end

  vim.keymap.set({ "n", "i" }, "/", pick_command, { buffer = buf, silent = true, desc = "Faltoo slash command" })
end

function M.map_file_reference(buf, win, repo_files)
  local function pick_file()
    local files = repo_files()
    if #files == 0 then
      -- Empty repositories have nothing useful to insert after @.
      vim.notify("No repository files found", vim.log.levels.WARN)
      M.insert_text_at_window(win, buf, "@")
      return
    end

    pick(files, "Faltoo file reference", tostring, function(file)
      M.insert_text_at_window(win, buf, file and ("`" .. file .. "`") or "@")
    end)
  end

  vim.keymap.set({ "n", "i" }, "@", pick_file, { buffer = buf, silent = true, desc = "Faltoo insert file reference" })
end

return M
