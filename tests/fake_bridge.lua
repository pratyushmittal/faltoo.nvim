---@diagnostic disable: duplicate-set-field -- the fake intentionally overrides bridge functions
local M = {}

function M.install(repo)
  local state = {
    messages = {},
    active_stream = nil,
    unstaged_files = {},
    prewarm_count = 0,
    hook_scope = nil,
  }

  -- The test workspace is not a real git repo, so unstaged files come from state.
  require("faltoo.git").unstaged_files = function()
    return state.unstaged_files
  end

  -- Replace Python bridge calls so the E2E flow stays fast and deterministic.
  local bridge = require("faltoo.bridge")
  bridge.run = function(args)
    if args[1] == "messages" then
      return vim.json.encode({ messages = state.messages })
    end
    if args[1] == "slash-commands" then
      return vim.json.encode({
        commands = { { command = "/run-hooks", preview = "run hooks for git changes" } },
      })
    end
    if args[1] == "reset" then
      state.messages = {}
      return "Started a fresh Faltoo session."
    end
    if args[1] == "messages-path" then
      return repo .. "/messages.json"
    end
    return ""
  end

  bridge.prewarm = function()
    state.prewarm_count = state.prewarm_count + 1
  end

  bridge.stream = function(args, input, on_event, on_done)
    local payload = vim.json.decode(input or "{}")

    if args[1] == "run-hooks" then
      state.hook_scope = payload.scope
      on_event({ is_new = true, classes = "status", text = "Running post-response hook: Review" })
      on_event({ is_new = true, classes = "done", text = "Hooks finished." })
      on_done(true)
      return
    end

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
  end

  return state
end

return M
