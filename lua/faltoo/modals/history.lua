local bridge_api = require("faltoo.bridge")

local M = {}

local state = {
  view = nil, -- current message-history floating window controller, if open
  base_messages = {}, -- persisted messages rendered behind live stream text
  stream_text = "", -- current assistant/tool stream text shown in history modal
  stream_status = nil, -- current streamed status shown until stream text arrives
  stream_classes = nil, -- last live stream classes, used to group stream text
  answering = false, -- true while a response stream should be shown as latest message
}

local function load_messages()
  local output = bridge_api.run({ "messages", "--workspace", vim.fn.getcwd(), "--limit", "100" })
  if not output then
    -- The bridge already reports errors, so skip opening an empty modal.
    return nil
  end

  local ok, payload = pcall(vim.json.decode, output)
  if not ok or type(payload) ~= "table" or type(payload.messages) ~= "table" then
    -- Bad bridge output would make navigation fail, so surface a clear error.
    vim.notify("Faltoo history output was invalid", vim.log.levels.ERROR)
    return nil
  end

  return payload.messages
end

-- Format one history item for the modal buffer.
---@param message table|nil
---@param index integer
---@param total integer
---@return string[]
local function message_lines(message, index, total)
  message = message or { role = "message", text = "" }
  local role = tostring(message.role or "message")
  local text = tostring(message.text or "")
  local lines = {
    "# " .. role .. " (" .. index .. "/" .. total .. ")",
    "",
  }
  if text == "" then
    -- Some stored items may not have displayable text after normalization.
    table.insert(lines, "_No text_")
    return lines
  end
  vim.list_extend(lines, vim.split(text, "\n", { plain = true }))
  return lines
end

local function clipped(text, is_trim)
  text = text:gsub("%s+", " ")
  if is_trim then
    text = vim.trim(text)
  end
  if #text <= 100 then
    return text
  end
  return text:sub(1, 100) .. "..."
end

local function append_to_current_bullet(text)
  -- The `$` anchor gets the last rendered bullet line, not the first match.
  local current = state.stream_text:match("([^\n]*)$") or ""
  if #current >= 103 then
    return
  end

  local next_text = current .. clipped(text, false)
  state.stream_text = state.stream_text:sub(1, #state.stream_text - #current) .. clipped(next_text, false)
end

local function append_answer_text(text, is_new)
  if state.stream_text ~= "" and (is_new or state.stream_classes ~= "answer") then
    state.stream_text = state.stream_text .. "\n\n"
  end

  if is_new or state.stream_classes ~= "answer" then
    state.stream_text = state.stream_text .. text:gsub("^%s+", "")
  else
    state.stream_text = state.stream_text .. text
  end

  state.stream_classes = "answer"
end

local function append_stream_text(event)
  local text = tostring(event.text or "")
  local classes = tostring(event.classes or "")
  if classes == "answer" then
    -- Assistant answer deltas should stay complete; tool/status bullets stay compact.
    append_answer_text(text, event.is_new)
    return
  end

  if event.is_new or state.stream_classes ~= classes then
    if state.stream_text ~= "" then
      state.stream_text = state.stream_text .. "\n"
    end
    state.stream_text = state.stream_text .. "- " .. clipped(text, true)
  else
    append_to_current_bullet(text)
  end
  state.stream_classes = classes
end

local function messages_with_stream()
  local items = vim.list_slice(state.base_messages or {})
  if state.answering then
    local text = state.stream_text
    if text == "" then
      text = state.stream_status or "Assistant is answering..."
    end
    table.insert(items, { role = "assistant · streaming", text = text })
  end
  return items
end

local function clear_view(win)
  if state.view and state.view.win == win then
    state.view = nil
    state.base_messages = {}
  end
end

local function update_view()
  if state.view then
    -- Stream events can arrive while the history modal is closed.
    state.view.update()
  end
end

function M.is_open()
  return state.view ~= nil
end

function M.close()
  local view = state.view
  if not view then
    return
  end

  clear_view(view.win)
  if vim.api.nvim_win_is_valid(view.win) then
    -- Close the tracked modal; q/Esc and M.open() can both reach this path.
    vim.api.nvim_win_close(view.win, true)
  end
end

function M.refresh()
  if not M.is_open() then
    return
  end

  local messages = load_messages()
  if messages then
    state.base_messages = messages
    update_view()
  end
end

function M.start_stream(status)
  state.answering = true
  state.stream_text = ""
  state.stream_status = status
  state.stream_classes = nil
  update_view()
end

function M.finish_stream()
  state.answering = false
  state.stream_text = ""
  state.stream_status = nil
  state.stream_classes = nil
  update_view()
end

function M.update_stream(event)
  local classes = event.classes or event.type
  if classes == "status" or classes == "done" then
    state.stream_status = tostring(event.text or "")
  else
    append_stream_text(event)
  end

  -- Stream text changed; refresh UI only if history is currently open.
  update_view()
end

local function open_window()
  local messages = messages_with_stream()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "markdown"

  local width = math.max(60, math.floor(vim.o.columns * 0.85))
  local height = math.max(12, math.floor(vim.o.lines * 0.75))
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    style = "minimal",
    border = "rounded",
    title = " Faltoo message history ",
    footer = " p/[ previous · n/] next · r reply · R open unstaged · q/<Esc> close ",
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
  })
  vim.api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(win),
    once = true,
    callback = function()
      clear_view(win)
    end,
  })

  local index = math.max(1, #messages)
  local function render()
    if not vim.api.nvim_buf_is_valid(buf) then
      -- The modal may have been closed while a keybinding was still queued.
      return
    end
    local total = math.max(1, #messages)
    local lines = message_lines(messages[index], index, total)
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
    if vim.api.nvim_win_is_valid(win) then
      -- Keep the live stream scrolled to its newest bullet while it grows.
      local cursor_line = state.answering and index == #messages and #lines or 1
      vim.api.nvim_win_set_cursor(win, { cursor_line, 0 })
    end
  end

  local function move(delta)
    local next_index = math.max(1, math.min(math.max(1, #messages), index + delta))
    if next_index == index then
      -- Let the user know the navigation key worked but there is no more history.
      vim.notify(delta < 0 and "Already at first message" or "Already at last message")
      return
    end
    index = next_index
    render()
  end

  local function update()
    -- Keep index pointing to the current message while replacing the message list.
    local was_latest = index == #messages
    messages = messages_with_stream()
    if was_latest or index > #messages then
      index = math.max(1, #messages)
    end
    render()
  end

  local function map_move(lhs, delta, desc)
    vim.keymap.set("n", lhs, function()
      move(delta)
    end, { buffer = buf, silent = true, desc = desc })
  end

  map_move("p", -1, "Faltoo previous message")
  map_move("[", -1, "Faltoo previous message")
  map_move("n", 1, "Faltoo next message")
  map_move("]", 1, "Faltoo next message")
  vim.keymap.set("n", "r", "<cmd>Faltoo ask<cr>", { buffer = buf, silent = true, desc = "Faltoo reply" })
  vim.keymap.set("n", "<S-CR>", "<cmd>Faltoo submit<cr>", { buffer = buf, silent = true, desc = "Faltoo submit" })
  vim.keymap.set("n", "R", function()
    M.close()
    vim.cmd("Faltoo open-unstaged")
  end, {
    buffer = buf,
    silent = true,
    desc = "Faltoo open unstaged files",
  })
  vim.keymap.set("n", "q", M.close, { buffer = buf, silent = true })
  vim.keymap.set("n", "<Esc>", M.close, { buffer = buf, silent = true })
  render()
  return { win = win, update = update }
end

function M.open()
  -- Re-read messages.json so history stays correct if FaltooBot changes outside this UI.
  local messages = load_messages()
  if not messages then
    return nil
  end
  if #messages == 0 and not state.answering then
    -- There is no message to render yet, so a modal would be empty.
    vim.notify("No Faltoo message history yet")
    return nil
  end

  M.close()
  state.base_messages = messages
  state.view = open_window()
  return state.view
end

return M
