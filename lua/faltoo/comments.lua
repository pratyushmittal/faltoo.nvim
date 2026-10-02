local M = {}

local git_api = require("faltoo.git")
local modals = require("faltoo.modals")
local quit_guard = require("faltoo.quit")

---@class FaltooComment
---@field filename string
---@field line_number_start integer 0 for file-level comments
---@field line_number_end integer
---@field file_line_number_start integer
---@field file_line_number_end integer
---@field code string
---@field comment? string
---@field _path string normalized absolute path used to match buffers

---@type FaltooComment[]
local comments = {}
local on_change = function() end

-- Sign group/name draw `*` in the gutter for lines with pending comments.
local sign_group = "faltoo_comments"
local sign_name = "FaltooComment"

-- Normalized absolute path of the current buffer, so :cd does not create duplicates.
local function current_path()
  local name = vim.api.nvim_buf_get_name(0)
  if name == "" then
    -- File-level comments can be created for unnamed buffers.
    return ""
  end
  return vim.fs.normalize(vim.fn.fnamemodify(name, ":p"))
end

---@param comment FaltooComment
---@return string[]
local function review_details(comment)
  local details = { "File: " .. comment.filename }
  local start_line, end_line = comment.line_number_start, comment.line_number_end
  if start_line == 0 then
    return details
  end

  local line_label = start_line == end_line and tostring(start_line) or (start_line .. "-" .. end_line)
  vim.list_extend(details, { "Line: " .. line_label, "", "Code:", "```" })
  vim.list_extend(details, vim.split(comment.code, "\n", { plain = true }))
  table.insert(details, "```")
  return details
end

-- A line or file can only have one pending comment, so find the one to edit.
-- File comments use line 0, so they only overlap other file comments.
local function find_existing_comment(path, start_line, end_line)
  for index, comment in ipairs(comments) do
    if comment._path == path and start_line <= comment.line_number_end and comment.line_number_start <= end_line then
      return index
    end
  end
  return nil
end

---@param change_callback? fun()
function M.setup(change_callback)
  on_change = change_callback or on_change
  vim.fn.sign_define(sign_name, { text = "*", texthl = "WarningMsg" })
end

---@return FaltooComment[]
function M.items()
  return vim.list_slice(comments)
end

function M.count()
  return #comments
end

---@param direction 1|-1
function M.jump(direction)
  local path = current_path()
  local lines = {}
  for _, comment in ipairs(comments) do
    if comment.line_number_start > 0 and comment._path == path then
      table.insert(lines, comment.line_number_start)
    end
  end
  if #lines == 0 then
    -- The current buffer may have no pending line comments yet.
    vim.notify("No Faltoo comments in this buffer")
    return
  end
  table.sort(lines)

  -- Wrap around when there is no comment in the jump direction.
  local current = vim.fn.line(".")
  local target = direction > 0 and lines[1] or lines[#lines]
  for _, line in ipairs(lines) do
    if direction > 0 and line > current then
      target = line
      break
    end
    if direction < 0 and line < current then
      target = line
    end
  end

  -- Pending comments can outlive file edits that shorten the buffer.
  vim.api.nvim_win_set_cursor(0, { math.min(target, vim.api.nvim_buf_line_count(0)), 0 })
end

---@param items FaltooComment[]
function M.remove(items)
  local remove = {}
  for _, item in ipairs(items) do
    remove[item] = true
  end
  -- Keep comments created after this submit started.
  comments = vim.tbl_filter(function(comment)
    return not remove[comment]
  end, comments)
  M.refresh()
end

function M.clear_signs()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    pcall(vim.fn.sign_unplace, sign_group, { buffer = buf })
  end
end

function M.refresh()
  quit_guard.sync()
  M.clear_signs()

  -- Map loaded buffer paths to buffers so comments can find their gutter.
  local paths = {}
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    local name = vim.api.nvim_buf_get_name(buf)
    if vim.api.nvim_buf_is_loaded(buf) and name ~= "" then
      paths[vim.fs.normalize(name)] = buf
    end
  end

  local placed = {}
  for _, comment in ipairs(comments) do
    local buf = paths[comment._path]
    if buf and comment.line_number_start > 0 then
      local last_line = math.min(comment.line_number_end, vim.api.nvim_buf_line_count(buf))
      for line = comment.line_number_start, last_line do
        local key = buf .. ":" .. line
        if not placed[key] then
          -- Multiple comments on one line should still render one gutter marker.
          placed[key] = true
          vim.fn.sign_place(0, sign_group, sign_name, buf, { lnum = line })
        end
      end
    end
  end

  on_change()
end

---@param is_file_comment boolean
---@param visual boolean
function M.add(is_file_comment, visual)
  local path = current_path()
  local start_line, end_line = vim.fn.line("."), vim.fn.line(".")
  if is_file_comment then
    start_line, end_line = 0, 0
  elseif visual then
    start_line = vim.fn.line("v")
    if start_line > end_line then
      -- Selections made upward start below the cursor.
      start_line, end_line = end_line, start_line
    end
  end

  local existing_index = find_existing_comment(path, start_line, end_line)
  local name = vim.api.nvim_buf_get_name(0)
  local target = comments[existing_index]
    or {
      filename = name == "" and "[No Name]" or vim.fn.fnamemodify(name, ":."),
      _path = path,
      line_number_start = start_line,
      line_number_end = end_line,
      file_line_number_start = start_line,
      file_line_number_end = end_line,
      code = is_file_comment and ""
        or table.concat(vim.api.nvim_buf_get_lines(0, start_line - 1, end_line, false), "\n"),
    }

  modals.comment({
    title = is_file_comment and "Faltoo file review comment" or "Faltoo line review comment",
    details = review_details(target),
    review_filename = target.filename,
    initial_text = target.comment or "",
    repo_files = git_api.repo_files,
    on_submit = function(text)
      if existing_index and text == "" then
        -- Emptying an existing comment means the user wants to remove it.
        table.remove(comments, existing_index)
        vim.notify("Deleted review comment #" .. existing_index)
      elseif existing_index then
        target.comment = text
        vim.notify("Updated review comment #" .. existing_index)
      elseif text ~= "" then
        -- Empty new comments are treated as cancel so we do not add blank reviews.
        target.comment = text
        table.insert(comments, target)
        vim.notify("Prepared review comment #" .. #comments)
      end
      M.refresh()
    end,
  })
end

return M
