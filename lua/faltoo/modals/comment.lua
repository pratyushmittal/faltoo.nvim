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
  -- Narrow right-aligned layout: review details above, comment textarea below.
  local width = math.max(36, math.floor(vim.o.columns * 0.42))
  local col = math.max(0, vim.o.columns - width - 4)
  local height = 7
  local detail_height = math.max(1, math.min(#opts.details, 16))
  local row = math.max(0, math.floor((vim.o.lines - detail_height - height - 4) / 2))

  local detail_buf = utils.scratch_buf(table.concat(opts.details, "\n"))
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

  local buf = utils.scratch_buf(opts.initial_text)
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

  local function force_close()
    utils.leave_insert_mode()
    utils.close_window(win)
    utils.close_window(detail_win)
  end

  utils.map_file_reference(buf, win, opts.repo_files)
  utils.map_textarea(buf, win, force_close, opts.on_submit)
end

return M
