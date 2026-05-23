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
  vim.api.nvim_win_set_cursor(win, { row, col + #text })

  -- Go back to insert mode after inserting text.
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
    vim.cmd("startinsert!")
  end, 20)
end

local function select_repo_file(repo_files, on_select)
  local files = repo_files()
  if #files == 0 then
    -- Empty repositories have nothing useful to insert after @.
    vim.notify("No repository files found", vim.log.levels.WARN)
    return false
  end

  local ok, pickers = pcall(require, "telescope.pickers")
  if ok then
    local finders = require("telescope.finders")
    local conf = require("telescope.config").values
    local actions = require("telescope.actions")
    local action_state = require("telescope.actions.state")

    pickers
      .new({}, {
        prompt_title = "Faltoo file reference",
        finder = finders.new_table({ results = files }),
        sorter = conf.generic_sorter({}),
        attach_mappings = function(prompt_bufnr)
          actions.select_default:replace(function()
            local selection = action_state.get_selected_entry()
            actions.close(prompt_bufnr)
            if selection then
              on_select(selection.value or selection[1])
              return
            end
            on_select(nil)
          end)
          return true
        end,
      })
      :find()
    return true
  end

  vim.ui.select(files, { prompt = "Faltoo file reference" }, function(choice)
    on_select(choice)
  end)
  return true
end

local function slash_command_label(command)
  local name = tostring(command.command or "")
  local preview = tostring(command.preview or "")
  if preview == "" then
    return name
  end
  return name .. " — " .. preview
end

local function select_slash_command(slash_commands, on_select)
  local commands = slash_commands()
  if #commands == 0 then
    -- Users may not have created saved slash commands yet.
    vim.notify("No Faltoo slash commands found", vim.log.levels.WARN)
    return false
  end

  local ok, pickers = pcall(require, "telescope.pickers")
  if ok then
    local finders = require("telescope.finders")
    local conf = require("telescope.config").values
    local actions = require("telescope.actions")
    local action_state = require("telescope.actions.state")

    pickers
      .new({}, {
        prompt_title = "Faltoo slash command",
        finder = finders.new_table({
          results = commands,
          entry_maker = function(command)
            return {
              value = command,
              display = slash_command_label(command),
              ordinal = slash_command_label(command),
            }
          end,
        }),
        sorter = conf.generic_sorter({}),
        attach_mappings = function(prompt_bufnr)
          actions.select_default:replace(function()
            local selection = action_state.get_selected_entry()
            actions.close(prompt_bufnr)
            if selection and selection.value then
              on_select(tostring(selection.value.command or ""))
              return
            end
            on_select(nil)
          end)
          return true
        end,
      })
      :find()
    return true
  end

  vim.ui.select(commands, {
    prompt = "Faltoo slash command",
    format_item = slash_command_label,
  }, function(choice)
    if choice then
      on_select(tostring(choice.command or ""))
      return
    end
    on_select(nil)
  end)
  return true
end

local function text_before_cursor(win, buf)
  if not vim.api.nvim_buf_is_valid(buf) or not vim.api.nvim_win_is_valid(win) then
    -- The modal can close while a mapped key is still queued.
    return ""
  end

  local row, col = unpack(vim.api.nvim_win_get_cursor(win))
  local lines = vim.api.nvim_buf_get_lines(buf, 0, row, false)
  if lines[1] == nil then
    return ""
  end
  lines[#lines] = lines[#lines]:sub(1, col)
  return table.concat(lines, "\n")
end

function M.map_slash_commands(buf, win, slash_commands)
  local function pick_command()
    if text_before_cursor(win, buf) ~= "" then
      -- Only a leading slash opens saved prompt completion.
      M.insert_text_at_window(win, buf, "/")
      return
    end

    local opened = select_slash_command(slash_commands, function(command)
      if command then
        M.insert_text_at_window(win, buf, command)
        return
      end
      M.insert_text_at_window(win, buf, "/")
    end)
    if not opened then
      M.insert_text_at_window(win, buf, "/")
    end
  end

  vim.keymap.set({ "n", "i" }, "/", pick_command, { buffer = buf, silent = true, desc = "Faltoo slash command" })
end

function M.map_file_reference(buf, win, repo_files)
  local function pick_file()
    local opened = select_repo_file(repo_files, function(file)
      if file then
        M.insert_text_at_window(win, buf, "`" .. file .. "`")
        return
      end
      M.insert_text_at_window(win, buf, "@")
    end)
    if not opened then
      M.insert_text_at_window(win, buf, "@")
    end
  end

  vim.keymap.set({ "n", "i" }, "@", pick_file, { buffer = buf, silent = true, desc = "Faltoo insert file reference" })
end

return M
