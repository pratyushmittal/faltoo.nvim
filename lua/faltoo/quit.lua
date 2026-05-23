local M = {}

local guard_augroup = "FaltooQuitGuard"
local guard_buf = nil
local pending_state = nil

local function current_state()
  if not pending_state then
    -- setup() may not have run yet when a caller asks to sync.
    return { submitting = false, pending_question = false, comment_count = 0 }
  end
  return pending_state()
end

local function pending_labels()
  local state = current_state()
  local labels = {}
  if state.submitting then
    table.insert(labels, "a running Faltoo request")
  end
  if state.pending_question then
    table.insert(labels, "a saved Ask AI question")
  end
  if (state.comment_count or 0) > 0 then
    table.insert(labels, state.comment_count .. " review comment(s)")
  end
  return labels
end

local function has_pending_submission()
  return #pending_labels() > 0
end

local function pending_message()
  return "Faltoo has "
    .. table.concat(pending_labels(), " and ")
    .. ". Run :Faltoo submit or clear pending work before quitting/restarting."
end

local function clear_guard()
  local buf = guard_buf
  guard_buf = nil
  if buf and vim.api.nvim_buf_is_valid(buf) then
    -- Mark unmodified before deleting so the guard buffer does not block itself.
    vim.bo[buf].modified = false
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end
end

local function ensure_guard()
  if guard_buf and vim.api.nvim_buf_is_valid(guard_buf) then
    return guard_buf
  end

  guard_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(guard_buf, "faltoo://pending-submissions")
  vim.bo[guard_buf].buftype = "acwrite"
  vim.bo[guard_buf].bufhidden = "hide"
  vim.bo[guard_buf].buflisted = false
  vim.bo[guard_buf].filetype = "faltoo"
  vim.bo[guard_buf].swapfile = false
  return guard_buf
end

-- Sync the hidden modified buffer that blocks quit while Faltoo work is pending.
function M.sync()
  if not has_pending_submission() then
    clear_guard()
    return
  end

  local lines = { pending_message(), "", "Submit with :Faltoo submit before quitting." }
  local buf = ensure_guard()
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = true
end

local function notify_if_pending()
  M.sync()
  if has_pending_submission() then
    -- The modified guard buffer blocks exit; returning true would delete this autocmd.
    vim.notify(pending_message(), vim.log.levels.WARN)
  end
end

function M.setup(state_fn)
  pending_state = state_fn
  vim.api.nvim_create_augroup(guard_augroup, { clear = true })
  -- :restart stops Nvim through :qall, so QuitPre covers normal restart too.
  vim.api.nvim_create_autocmd("QuitPre", {
    group = guard_augroup,
    callback = notify_if_pending,
  })
  M.sync()
end

return M
