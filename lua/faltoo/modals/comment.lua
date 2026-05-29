local utils = require("faltoo.modals.utils")

local M = {}

---@class FaltooCommentModalOpts
---@field title string
---@field details string[]
---@field review_filename string
---@field initial_text string
---@field repo_files fun(): string[]
---@field on_submit fun(text: string)

---@param opts FaltooCommentModalOpts
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

  local details = opts.details or {}
  local width, col = utils.right_layout(0.42, 36)
  local height = 4
  local detail_height = math.max(1, math.min(#details, 16))
  local total_height = detail_height + height + 4
  local row = math.max(0, math.floor((vim.o.lines - total_height) / 2))

  local detail_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[detail_buf].buftype = "nofile"
  vim.bo[detail_buf].bufhidden = "wipe"
  vim.bo[detail_buf].filetype = "markdown"
  vim.api.nvim_buf_set_lines(detail_buf, 0, -1, false, details)
  vim.bo[detail_buf].modifiable = false

  local detail_win = vim.api.nvim_open_win(detail_buf, false, {
    relative = "editor",
    style = "minimal",
    border = "rounded",
    title = " Review " .. opts.review_filename .. " ",
    width = width,
    height = detail_height,
    row = row,
    col = col,
  })

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    style = "minimal",
    border = "rounded",
    title = " " .. opts.title .. " ",
    footer = " Enter submit · Shift+Enter newline · @ file · Esc cancel ",
    width = width,
    height = height,
    row = row + detail_height + 2,
    col = col,
  })

  local function submit()
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local text = vim.trim(table.concat(lines, "\n"))
    utils.leave_insert_mode()
    utils.close_window(win)
    utils.close_window(detail_win)
    opts.on_submit(text)
  end

  local function cancel()
    utils.leave_insert_mode()
    utils.close_window(win)
    utils.close_window(detail_win)
  end

  vim.keymap.set({ "n", "i" }, "<CR>", submit, { buffer = buf, silent = true })
  vim.keymap.set("i", "<S-CR>", "<CR>", { buffer = buf, silent = true })
  vim.keymap.set("n", "<S-CR>", "o", { buffer = buf, silent = true })
  vim.keymap.set({ "n", "i" }, "<C-s>", submit, { buffer = buf, silent = true })
  utils.map_file_reference(buf, win, opts.repo_files)
  vim.keymap.set("n", "q", cancel, { buffer = buf, silent = true })
  vim.keymap.set("n", "<Esc>", cancel, { buffer = buf, silent = true })
  if #initial_lines > 0 then
    local last_line = initial_lines[#initial_lines] or ""
    vim.api.nvim_win_set_cursor(win, { #initial_lines, #last_line })
  end
  vim.cmd("startinsert!")
end

return M
