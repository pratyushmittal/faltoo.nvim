local M = {}

local git_api = require("faltoo.git")
local modals = require("faltoo.modals")
local quit_guard = require("faltoo.quit")

---@class FaltooComment
---@field filename string
---@field line_number_start integer
---@field line_number_end integer
---@field file_line_number_start integer
---@field file_line_number_end integer
---@field code string
---@field comment? string
---@field _path? string

---@type FaltooComment[]
local comments = {}
local on_change = function() end

-- Sign group/name draw `*` in the gutter for lines with pending comments.
local sign_group = "faltoo_comments"
local sign_name = "FaltooComment"

local function current_file()
  local name = vim.api.nvim_buf_get_name(0)
  if name == "" then
    return "[No Name]"
  end
  return vim.fn.fnamemodify(name, ":.")
end

local function current_path()
  local name = vim.api.nvim_buf_get_name(0)
  if name == "" then
    return ""
  end
  return vim.fs.normalize(vim.fn.fnamemodify(name, ":p"))
end

-- Return the normalized absolute path used for file matching.
---@param filename string
---@return string
local function filename_path(filename)
  if filename == "" then
    -- File-level comments can be created for unnamed buffers.
    return ""
  end
  return vim.fs.normalize(vim.fn.fnamemodify(filename, ":p"))
end

-- Return the normalized absolute path used to match a comment to an open buffer.
---@param comment FaltooComment
---@return string
local function comment_path(comment)
  local path = tostring(comment._path or "")
  if path ~= "" then
    return path
  end
  return filename_path(tostring(comment.filename or ""))
end

-- Check file identity using absolute paths so :cd does not create duplicates.
local function same_comment_file(comment, path)
  return comment_path(comment) == path
end

-- Build normalized absolute path -> buffer map for currently loaded buffers.
---@return table<string, integer>
local function buffer_paths()
  local paths = {}
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) then
      local name = vim.api.nvim_buf_get_name(buf)
      if name ~= "" then
        paths[vim.fs.normalize(name)] = buf
      end
    end
  end
  return paths
end

local function selected_lines()
  local start_line = vim.fn.line("v")
  local end_line = vim.fn.line(".")
  if start_line > end_line then
    start_line, end_line = end_line, start_line
  end
  local lines = vim.api.nvim_buf_get_lines(0, start_line - 1, end_line, false)
  return start_line, end_line, table.concat(lines, "\n")
end

local function review_details(filename, start_line, end_line, code, is_file_comment)
  if is_file_comment then
    return { "File: " .. filename }
  end
  local line_label = start_line == end_line and tostring(start_line) or (start_line .. "-" .. end_line)
  local details = { "File: " .. filename, "Line: " .. line_label, "", "Code:", "```" }
  for _, line in ipairs(vim.split(code, "\n", { plain = true })) do
    table.insert(details, line)
  end
  table.insert(details, "```")
  return details
end

local function comment_ranges_overlap(a_start, a_end, b_start, b_end)
  return a_start <= b_end and b_start <= a_end
end

local function find_existing_comment(path, start_line, end_line, is_file_comment)
  for index, comment in ipairs(comments) do
    if same_comment_file(comment, path) then
      local comment_start = tonumber(comment.line_number_start or 0) or 0
      local comment_end = tonumber(comment.line_number_end or comment_start) or comment_start
      if is_file_comment and comment_start == 0 then
        return index, comment
      end
      if
        not is_file_comment
        and comment_start > 0
        and comment_ranges_overlap(start_line, end_line, comment_start, comment_end)
      then
        -- A line can only have one pending comment, so edit the overlapping one.
        return index, comment
      end
    end
  end
  return nil, nil
end

---@param change_callback? fun()
function M.setup(change_callback)
  on_change = change_callback or on_change
  vim.fn.sign_define(sign_name, { text = "*", texthl = "WarningMsg" })
end

---@return FaltooComment[]
function M.items()
  local copied = {}
  for index, comment in ipairs(comments) do
    copied[index] = comment
  end
  return copied
end

function M.count()
  return #comments
end

-- Return pending line-comment starts for the current buffer.
---@return integer[]
local function current_buffer_comment_lines()
  local path = current_path()
  local lines = {}

  for _, comment in ipairs(comments) do
    local line = tonumber(comment.line_number_start or 0) or 0
    if line > 0 and same_comment_file(comment, path) then
      table.insert(lines, line)
    end
  end

  table.sort(lines)
  return lines
end

---@param direction 1|-1
function M.jump(direction)
  local lines = current_buffer_comment_lines()
  if #lines == 0 then
    -- The current buffer may have no pending line comments yet.
    vim.notify("No Faltoo comments in this buffer")
    return
  end

  local current = vim.fn.line(".")
  local target = lines[1]
  if direction < 0 then
    target = lines[#lines]
  end

  for _, line in ipairs(lines) do
    if direction > 0 and line > current then
      target = line
      break
    end
    if direction < 0 and line < current then
      target = line
    end
  end

  local line_count = vim.api.nvim_buf_line_count(0)
  if target > line_count then
    -- Pending comments can outlive file edits that shorten the buffer.
    target = line_count
  end

  vim.api.nvim_win_set_cursor(0, { target, 0 })
end

function M.clear()
  comments = {}
  M.refresh()
end

---@param items FaltooComment[]
function M.remove(items)
  local remove = {}
  for _, item in ipairs(items) do
    remove[item] = true
  end

  local kept = {}
  for _, comment in ipairs(comments) do
    if not remove[comment] then
      -- Keep comments created after this submit started.
      table.insert(kept, comment)
    end
  end
  comments = kept
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

  local paths = buffer_paths()
  local placed = {}
  for _, comment in ipairs(comments) do
    local start_line = tonumber(comment.line_number_start or 0) or 0
    local end_line = tonumber(comment.line_number_end or start_line) or start_line
    local buf = paths[comment_path(comment)]

    if buf and start_line > 0 then
      local line_count = vim.api.nvim_buf_line_count(buf)
      for line = start_line, math.min(end_line, line_count) do
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

---@class FaltooAddCommentOpts
---@field is_file_comment boolean
---@field visual boolean
---@field enabled boolean

---@param opts FaltooAddCommentOpts
function M.add(opts)
  local is_file_comment = opts.is_file_comment
  local visual = opts.visual
  if not opts.enabled then
    return
  end

  local filename = current_file()
  local path = current_path()
  local start_line = is_file_comment and 0 or vim.fn.line(".")
  local end_line = start_line
  local code = is_file_comment and "" or vim.api.nvim_get_current_line()
  if visual and not is_file_comment then
    start_line, end_line, code = selected_lines()
  end
  local existing_index, existing = find_existing_comment(path, start_line, end_line, is_file_comment)
  local target = existing
    or {
      filename = filename,
      _path = path,
      line_number_start = start_line,
      line_number_end = end_line,
      file_line_number_start = start_line,
      file_line_number_end = end_line,
      code = code,
    }
  local title = is_file_comment and "Faltoo file review comment" or "Faltoo line review comment"
  local details = review_details(
    tostring(target.filename or filename),
    target.line_number_start or start_line,
    target.line_number_end or end_line,
    tostring(target.code or code),
    is_file_comment
  )
  modals.comment({
    title = title,
    details = details,
    review_filename = tostring(target.filename or filename),
    initial_text = tostring(target.comment or ""),
    repo_files = git_api.repo_files,
    on_submit = function(text)
      if existing_index and text == "" then
        -- Emptying an existing comment means the user wants to remove it.
        table.remove(comments, existing_index)
        M.refresh()
        vim.notify("Deleted review comment #" .. existing_index)
        return
      end
      if existing_index then
        comments[existing_index].comment = text
        M.refresh()
        vim.notify("Updated review comment #" .. existing_index)
        return
      end
      if text == "" then
        -- Empty new comments are treated as cancel so we do not add blank reviews.
        return
      end
      target.comment = text
      table.insert(comments, target)
      M.refresh()
      vim.notify("Prepared review comment #" .. #comments)
    end,
  })
end

return M
