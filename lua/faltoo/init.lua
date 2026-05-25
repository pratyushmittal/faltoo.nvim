local M = {}

local state = {
  enabled = false, -- toggles via :faltoo on/off
  saved = {}, -- original buffer options restored on :faltoo off
  submitting = false, -- true while a bridge job runs; drives answering UI and blocks overlaps
  status = "idle", -- latest request status for statusline
  pending_question = nil, -- saved Ask AI text submitted with :Faltoo submit
}

-- Augroup names a set of autocmds so we can clear review-mode hooks together.
local review_augroup = "FaltooReviewMode"

local function workspace()
  return vim.fn.getcwd()
end

local function inside_review_root(path)
  local git_dir = vim.fs.find(".git", { path = workspace(), upward = true })[1]
  local root_path = git_dir and vim.fs.dirname(git_dir) or workspace()
  local root = vim.fs.normalize(vim.fn.fnamemodify(root_path, ":p"))
  local normalized = vim.fs.normalize(vim.fn.fnamemodify(path, ":p"))
  return normalized == root or vim.startswith(normalized, root .. "/")
end

local function normal_buffer(buf)
  if not vim.api.nvim_buf_is_valid(buf) or vim.bo[buf].buftype ~= "" then
    return false
  end

  if not vim.bo[buf].buflisted then
    -- Plugin scratch buffers are often normal buftype but intentionally unlisted.
    return false
  end

  local name = vim.api.nvim_buf_get_name(buf)
  if name == "" or vim.fn.filereadable(name) ~= 1 then
    -- Review mode should not lock synthetic plugin buffers like org agenda.
    return false
  end

  if not inside_review_root(name) then
    -- Open plugin/user files outside the current review workspace should be left alone.
    return false
  end

  return true
end

local function save_buffer_options(buf)
  if state.saved[buf] then
    -- Keep the first values; BufEnter can call this repeatedly in review mode.
    return
  end

  -- Restore these on :Faltoo off so user-locked buffers stay locked.
  state.saved[buf] = {
    readonly = vim.bo[buf].readonly,
    modifiable = vim.bo[buf].modifiable,
  }
end

local keymaps_api = require("faltoo.keymaps")

local function restore_buffer(buf)
  local opts = state.saved[buf]
  if not opts then
    return
  end
  if vim.api.nvim_buf_is_valid(buf) then
    vim.bo[buf].readonly = opts.readonly
    vim.bo[buf].modifiable = opts.modifiable
  end

  state.saved[buf] = nil
  keymaps_api.unmap_buffer(buf)
end

local function make_readonly(buf)
  save_buffer_options(buf)
  vim.bo[buf].readonly = true
  vim.bo[buf].modifiable = false
end

local bridge_api = require("faltoo.bridge")
local comments_api = require("faltoo.comments")
local git_api = require("faltoo.git")
local modals = require("faltoo.modals")
local history_modal = require("faltoo.modals.history")
local quit_guard = require("faltoo.quit")

-- Redraw statusline so require("faltoo").status() changes appear immediately.
local function redraw_faltoo_status()
  vim.cmd("redrawstatus")
end

local function workspace_title()
  local title = vim.fn.fnamemodify(workspace(), ":t")
  if title == "" then
    -- Root-like workspaces can have no basename.
    return workspace()
  end
  return title
end

local function refresh_terminal_title()
  if not state.enabled then
    -- Avoid changing terminal title before review mode owns it.
    return
  end
  local title = workspace_title()
  if state.submitting then
    title = title .. " ・answering"
  end
  vim.o.title = true
  vim.o.titlestring = title
  vim.cmd("redraw")
end

local function set_submitting(submitting, status)
  state.submitting = submitting
  state.status = status
  quit_guard.sync()
  redraw_faltoo_status()
  refresh_terminal_title()
end

local function set_submitting_and_notify(status)
  set_submitting(true, status)
  vim.notify(status)
end

local function ring_bell()
  local ok = pcall(function()
    io.stderr:write("\007")
    io.stderr:flush()
  end)
  if ok then
    return
  end

  vim.api.nvim_echo({ { "\007", "None" } }, false, {})
  vim.api.nvim_out_write("\007")
end

local function update_status(event)
  local kind = event.classes or event.type or "status"
  local value = tostring(event.text or "")
  if kind == "done" then
    state.status = value ~= "" and value or "idle"
    redraw_faltoo_status()
    vim.notify(state.status)
    return
  end

  if value == "" then
    -- Some stream events only signal progress without display text.
    return
  end
  state.status = value
  redraw_faltoo_status()
end

-- Reload one review buffer from disk while preserving review-mode locking.
local function reload_buffer(buf)
  if not vim.api.nvim_buf_is_loaded(buf) then
    -- Closed buffers can remain valid after :bdelete, but should not be resurrected.
    return false
  end
  if not normal_buffer(buf) then
    return false
  end
  local name = vim.api.nvim_buf_get_name(buf)
  if name == "" or vim.fn.filereadable(name) == 0 then
    return false
  end

  -- Temporarily unlock the review buffer so :edit! can reload file changes.
  local reloaded = pcall(vim.api.nvim_buf_call, buf, function()
    vim.bo[buf].readonly = false
    vim.bo[buf].modifiable = true
    vim.cmd("silent keepalt edit!")
  end)
  -- Review mode owns the buffer after reload, so lock it again immediately.
  make_readonly(buf)
  return reloaded
end

local function reload_review_buffers()
  local count = 0
  for buf, _ in pairs(state.saved) do
    if not vim.api.nvim_buf_is_valid(buf) or not vim.api.nvim_buf_is_loaded(buf) then
      -- Forget buffers that were closed while a Faltoo stream was running.
      state.saved[buf] = nil
    elseif reload_buffer(buf) then
      count = count + 1
    end
  end
  return count
end

---@class FaltooStreamSubmissionOpts
---@field args string[]
---@field payload table
---@field start_status string
---@field on_submit fun()
---@field on_complete? fun()

---@param opts FaltooStreamSubmissionOpts
local function stream_submission(opts)
  if state.submitting then
    -- Only one stream can safely mutate the session and reload files at a time.
    vim.notify("Faltoo request is already running")
    return
  end

  local submitted = false
  local function on_submit_once()
    if submitted then
      -- The bridge can report submit and later complete; clear only once.
      return
    end
    submitted = true
    opts.on_submit()
  end

  set_submitting_and_notify(opts.start_status)
  history_modal.start_stream(opts.start_status)
  bridge_api.stream(opts.args, vim.json.encode(opts.payload), function(event)
    history_modal.update_stream(event)
    local text = tostring(event.text or "")
    if (event.classes or event.type) == "status" and text:match("^Submitted") then
      on_submit_once()
    end
    update_status(event)
  end, function(ok)
    set_submitting(false, state.status)
    if ok then
      ring_bell()
      on_submit_once()
      -- The assistant may edit files through tools, so refresh readonly buffers.
      reload_review_buffers()
      history_modal.finish_stream()
      history_modal.refresh()
      if opts.on_complete then
        opts.on_complete()
      end
      return
    end
    set_submitting(false, "Faltoo request failed.")
    history_modal.finish_stream()
    history_modal.refresh()
    vim.notify(state.status)
  end)
end

local function submit_comments()
  if comments_api.count() == 0 then
    vim.notify("No Faltoo review comments to submit")
    return
  end

  local submitted_comments = comments_api.items()

  stream_submission({
    args = { "append-review" },
    payload = { workspace = workspace(), comments = submitted_comments },
    start_status = "Submitting review comments...",
    on_submit = function()
      comments_api.remove(submitted_comments)
    end,
  })
end

local function submit_chat_message(text)
  stream_submission({
    args = { "append-message" },
    payload = { workspace = workspace(), text = text },
    start_status = "Submitting chat message...",
    on_submit = function()
      if state.pending_question == text then
        -- Do not clear a newer pending question saved while this request was running.
        state.pending_question = nil
        quit_guard.sync()
        redraw_faltoo_status()
      end
    end,
    on_complete = function()
      if history_modal.is_open() then
        -- Keep the user's current history position when it is already open.
        return
      end

      vim.schedule(function()
        vim.cmd("Faltoo history")
      end)
    end,
  })
end

local function save_question(text)
  local had_question = state.pending_question ~= nil
  if text == "" then
    state.pending_question = nil
    quit_guard.sync()
    redraw_faltoo_status()
    if had_question then
      vim.notify("Cleared pending question")
    end
    return
  end
  state.pending_question = text
  quit_guard.sync()
  redraw_faltoo_status()
  vim.notify("Saved question. Run :Faltoo submit to ask AI")
end

local function submit_pending_request()
  if state.pending_question and state.pending_question ~= "" then
    submit_chat_message(state.pending_question)
    return
  end
  submit_comments()
end

local function slash_commands()
  local output = bridge_api.run({ "slash-commands" })
  if not output then
    -- The bridge already reports errors, so keep completion empty.
    return {}
  end

  local ok, payload = pcall(vim.json.decode, output)
  if not ok or type(payload) ~= "table" or type(payload.commands) ~= "table" then
    -- Invalid completion data should not break the Ask modal.
    vim.notify("Faltoo slash command output was invalid", vim.log.levels.ERROR)
    return {}
  end

  return payload.commands
end

local function ask_question()
  modals.ask({
    initial_text = state.pending_question or "",
    repo_files = git_api.repo_files,
    slash_commands = slash_commands,
    on_save = save_question,
  })
end

local function show_history()
  history_modal.open()
end

local function unstaged_file_set()
  local output = bridge_api.run({ "unstaged-files", "--workspace", workspace() })
  if not output then
    return nil
  end

  local ok, payload = pcall(vim.json.decode, output)
  if not ok or type(payload) ~= "table" then
    -- Bad bridge output would make buffer refresh delete/open the wrong files.
    vim.notify("Faltoo unstaged files output was invalid", vim.log.levels.ERROR)
    return nil
  end
  if payload.ok == false then
    vim.notify(tostring(payload.error or "Not inside a git repository"), vim.log.levels.WARN)
    return nil
  end
  if type(payload.files) ~= "table" then
    -- Bad bridge output would make buffer refresh delete/open the wrong files.
    vim.notify("Faltoo unstaged files output was invalid", vim.log.levels.ERROR)
    return nil
  end

  local file_set = {}
  for _, file in ipairs(payload.files) do
    local path = vim.fs.normalize(tostring(file))
    if vim.fn.filereadable(path) == 1 then
      -- Keep the bridge result safe even if a file changed after discovery.
      file_set[path] = true
    end
  end

  return file_set
end

local function close_saved_buffers_not_in(file_set)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    local name = vim.api.nvim_buf_get_name(buf)
    local path = name ~= "" and vim.fs.normalize(name) or ""
    local bo = vim.bo[buf]
    local saved_normal_file = bo.buflisted and bo.buftype == "" and path ~= "" and vim.fn.filereadable(path) == 1

    if saved_normal_file and not bo.modified and not file_set[path] then
      -- Unsaved or synthetic plugin buffers should not be closed by a git refresh action.
      local deleted = pcall(vim.cmd, "bdelete " .. buf)
      if deleted then
        -- Do not restore or reload a buffer intentionally closed by open-unstaged.
        state.saved[buf] = nil
      end
    end
  end
end

local function refresh_unstaged_git_buffers()
  local file_set = unstaged_file_set()
  if file_set == nil then
    -- unstaged_file_set() already notified the git error.
    return
  end

  local count = 0
  local current_name = vim.api.nvim_buf_get_name(0)
  local current_path = current_name ~= "" and vim.fs.normalize(current_name) or ""
  local target = file_set[current_path] and current_path or next(file_set)

  close_saved_buffers_not_in(file_set)

  for file, _ in pairs(file_set) do
    count = count + 1
    vim.cmd("badd " .. vim.fn.fnameescape(file))
  end

  if target == nil then
    -- There may be no unstaged readable files left after closing old buffers.
    vim.notify("No unstaged files")
    return
  end

  vim.cmd("edit " .. vim.fn.fnameescape(target))
  vim.notify("Opened " .. count .. " unstaged file(s)")
end

local function is_visual_mode()
  return vim.fn.mode():match("[vV]") ~= nil
end

local function add_line_comment(visual)
  comments_api.add({ is_file_comment = false, visual = visual, enabled = state.enabled })
end

local function add_file_comment()
  comments_api.add({ is_file_comment = true, visual = false, enabled = state.enabled })
end

local function keymap_callbacks()
  return {
    comment = add_line_comment,
    file_comment = add_file_comment,
    history = show_history,
    ask = ask_question,
    submit = submit_pending_request,
    open_unstaged = refresh_unstaged_git_buffers,
  }
end

local function open_unstaged_after_startup()
  if vim.v.vim_did_enter == 1 then
    -- When toggled later, defer once so current autocmds finish first.
    vim.schedule(refresh_unstaged_git_buffers)
    return
  end

  vim.api.nvim_create_autocmd("VimEnter", {
    group = review_augroup,
    once = true,
    callback = function()
      -- Open files after init.lua has registered FileType/LSP hooks.
      vim.schedule(refresh_unstaged_git_buffers)
    end,
  })
end

function M.on()
  if state.enabled then
    return
  end
  state.enabled = true
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if normal_buffer(buf) then
      make_readonly(buf)
      keymaps_api.map_buffer(buf, keymap_callbacks())
      comments_api.refresh()
    end
  end
  vim.api.nvim_create_augroup(review_augroup, { clear = true })
  -- FileType catches plugins that change buffer ownership after opening.
  vim.api.nvim_create_autocmd({ "BufEnter", "BufWinEnter", "FileType" }, {
    group = review_augroup,
    callback = function(event)
      if normal_buffer(event.buf) then
        make_readonly(event.buf)
        keymaps_api.map_buffer(event.buf, keymap_callbacks())
        comments_api.refresh()
        return
      end

      restore_buffer(event.buf)
    end,
  })
  refresh_terminal_title()
  vim.notify("Faltoo review mode on")
  open_unstaged_after_startup()
end

function M.off()
  if not state.enabled then
    return
  end
  state.enabled = false
  pcall(vim.api.nvim_del_augroup_by_name, review_augroup)
  comments_api.clear_signs()
  keymaps_api.unmap_all()
  for buf, _ in pairs(vim.deepcopy(state.saved)) do
    restore_buffer(buf)
  end
  vim.notify("Faltoo review mode off")
end

function M.tree()
  if vim.fn.executable("open") ~= 1 then
    -- The tree action intentionally uses the system opener instead of a Neovim buffer.
    vim.notify("System 'open' command not found", vim.log.levels.ERROR)
    return
  end
  local output = bridge_api.run({ "messages-path", "--workspace", workspace() })
  if not output then
    -- bridge_api.run already displayed the bridge error.
    return
  end
  local path = vim.trim(output)
  if path == "" then
    -- A blank path would make `open` target the current directory.
    vim.notify("Faltoo messages.json path was empty", vim.log.levels.ERROR)
    return
  end

  local result = vim.system({ "open", path }, { text = true }):wait()
  if result.code ~= 0 then
    vim.notify((result.stderr or "Failed to open messages.json"):gsub("%s+$", ""), vim.log.levels.ERROR)
    return
  end
  vim.notify("Opened " .. path)
end

function M.status()
  local parts = {}
  if state.submitting then
    table.insert(parts, "answering")
  end
  if state.pending_question then
    table.insert(parts, "question ready")
  end
  if comments_api.count() > 0 then
    table.insert(parts, comments_api.count() .. " comment(s)")
  end
  if #parts == 0 then
    return ""
  end
  return "Faltoo: " .. table.concat(parts, " · ")
end

---@param opts? FaltooSetupOpts
function M.setup(opts)
  keymaps_api.setup(opts)

  comments_api.setup(redraw_faltoo_status)

  quit_guard.setup(function()
    return {
      submitting = state.submitting,
      pending_question = state.pending_question ~= nil and state.pending_question ~= "",
      comment_count = comments_api.count(),
    }
  end)

  -- Let users type :faltoo while keeping the real command name :Faltoo.
  vim.cmd("silent! cunabbrev faltoo")
  vim.cmd([[cnoreabbrev <expr> faltoo getcmdtype() == ':' && getcmdline() ==# 'faltoo' ? 'Faltoo' : 'faltoo']])

  -- Recreate the command so setup() stays safe to call more than once.
  pcall(vim.api.nvim_del_user_command, "Faltoo")
  ---@param opts { args: string }
  vim.api.nvim_create_user_command("Faltoo", function(opts)
    local action = opts.args:lower()
    if action == "on" then
      M.on()
    elseif action == "off" then
      M.off()
    elseif action == "tree" then
      M.tree()
    elseif action == "ask" then
      ask_question()
    elseif action == "comment" then
      add_line_comment(is_visual_mode())
    elseif action == "file-comment" then
      add_file_comment()
    elseif action == "history" then
      show_history()
    elseif action == "submit" then
      submit_pending_request()
    elseif action == "open-unstaged" then
      refresh_unstaged_git_buffers()
    else
      vim.notify(
        "Usage: :faltoo on | off | tree | ask | comment | file-comment | history | submit | open-unstaged",
        vim.log.levels.ERROR
      )
    end
  end, {
    nargs = 1,
    complete = function()
      return {
        "on",
        "off",
        "tree",
        "ask",
        "comment",
        "file-comment",
        "history",
        "submit",
        "open-unstaged",
      }
    end,
  })
end

return M
