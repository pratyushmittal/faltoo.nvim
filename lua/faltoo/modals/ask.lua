local utils = require("faltoo.modals.utils")

local M = {}

---@class FaltooAskModalOpts
---@field initial_text string
---@field repo_files fun(): string[]
---@field slash_commands fun(): table[]
---@field on_save fun(text: string)

---@param opts FaltooAskModalOpts
function M.open(opts)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "markdown"
  local initial_lines = {}
  if opts.initial_text and opts.initial_text ~= "" then
    initial_lines = vim.split(opts.initial_text, "\n", { plain = true })
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, initial_lines)
  end

  local width, col = utils.right_layout(0.42, 36)
  local height = math.max(6, math.min(10, math.floor(vim.o.lines * 0.35)))
  local row = math.floor((vim.o.lines - height) / 2)
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    style = "minimal",
    border = "rounded",
    title = " Ask Faltoo ",
    footer = " Enter save · Shift+Enter newline · @ file · / command · Esc cancel ",
    width = width,
    height = height,
    row = row,
    col = col,
  })

  local function cancel()
    utils.leave_insert_mode()
    utils.close_window(win)
  end

  local function save()
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local text = vim.trim(table.concat(lines, "\n"))
    cancel()
    opts.on_save(text)
  end

  vim.keymap.set({ "n", "i" }, "<CR>", save, { buffer = buf, silent = true })
  vim.keymap.set("i", "<S-CR>", "<CR>", { buffer = buf, silent = true })
  vim.keymap.set("n", "<S-CR>", "o", { buffer = buf, silent = true })
  vim.keymap.set({ "n", "i" }, "<C-s>", save, { buffer = buf, silent = true })
  utils.map_file_reference(buf, win, opts.repo_files)
  utils.map_slash_commands(buf, win, opts.slash_commands)
  vim.keymap.set("n", "q", cancel, { buffer = buf, silent = true })
  vim.keymap.set("n", "<Esc>", cancel, { buffer = buf, silent = true })
  if #initial_lines > 0 then
    local last_line = initial_lines[#initial_lines] or ""
    vim.api.nvim_win_set_cursor(win, { #initial_lines, #last_line })
  end
  vim.cmd("startinsert!")
end

return M
