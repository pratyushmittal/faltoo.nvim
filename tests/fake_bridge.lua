local M = {}

function M.install(repo)
  local state = {
    messages = {},
    active_stream = nil,
    unstaged_files = {},
    prewarm_count = 0,
  }

  -- Replace the Python bridge so the E2E flow stays fast and deterministic.
  package.loaded["faltoo.bridge"] = {
    run = function(args)
      if args[1] == "messages" then
        return vim.json.encode({ messages = state.messages })
      end
      if args[1] == "slash-commands" then
        return vim.json.encode({ commands = {} })
      end
      if args[1] == "unstaged-files" then
        return vim.json.encode({ ok = true, files = state.unstaged_files })
      end
      if args[1] == "messages-path" then
        return repo .. "/messages.json"
      end
      return ""
    end,

    prewarm = function()
      state.prewarm_count = state.prewarm_count + 1
    end,

    stream = function(args, input, on_event, on_done)
      local payload = vim.json.decode(input or "{}")

      if args[1] == "append-review" then
        table.insert(state.messages, { role = "user", text = "review comment" })
        table.insert(state.messages, { role = "assistant", text = "review answer" })
        on_event({ is_new = true, classes = "status", text = "Submitted 1 review comment(s). Waiting for assistant..." })
        on_event({ is_new = true, classes = "answer", text = "review answer" })
        on_event({ is_new = true, classes = "done", text = "Assistant response saved." })
        on_done(true)
        return
      end

      table.insert(state.messages, { role = "user", text = tostring(payload.text or "") })
      state.active_stream = {
        on_event = on_event,
        on_done = on_done,
      }
      on_event({ is_new = true, classes = "status", text = "Submitted message. Waiting for assistant..." })
    end,
  }

  return state
end

return M
