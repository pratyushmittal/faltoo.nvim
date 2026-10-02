local utils = require("faltoo.modals.utils")

local M = {}

---@class FaltooAskModalOpts
---@field initial_text string
---@field repo_files fun(): string[]
---@field slash_commands fun(): table[]
---@field on_save fun(text: string)
---@field commands table<string, fun()> slash commands handled in Neovim instead of sent as text
---@field return_win? integer

---@param opts FaltooAskModalOpts
function M.open(opts)
  local buf = utils.scratch_buf(opts.initial_text)
  local width = math.max(50, math.floor(vim.o.columns * 0.7))
  local height = math.max(6, math.min(10, math.floor(vim.o.lines * 0.35)))
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    style = "minimal",
    border = "rounded",
    title = " Ask Faltoo ",
    footer = " Enter save · Shift+Enter newline · @ file · / command · Esc cancel ",
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
  })

  local function force_close()
    utils.leave_insert_mode()
    utils.close_window(win)
    if opts.return_win and vim.api.nvim_win_is_valid(opts.return_win) then
      -- Closing stacked modals can otherwise focus the file buffer behind history.
      pcall(vim.api.nvim_set_current_win, opts.return_win)
    end
  end

  utils.map_file_reference(buf, win, opts.repo_files)
  utils.map_slash_commands(buf, win, opts.slash_commands, function(command)
    local handler = opts.commands[command]
    if not handler then
      -- Saved and other commands are inserted as text for FaltooBot to expand.
      return false
    end

    force_close()
    handler()
    return true
  end)
  utils.map_textarea(buf, win, force_close, opts.on_save)
end

return M
