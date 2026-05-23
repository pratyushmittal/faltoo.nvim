local M = {}

local default_mappings = {
  comment = { modes = { "n", "x" }, lhs = "c" },
  file_comment = { modes = { "n", "x" }, lhs = "C" },
  history = { modes = "n", lhs = "<leader>f" },
  ask = { modes = "n", lhs = "<leader>a" },
  submit = { modes = "n", lhs = "<S-CR>" },
  open_unstaged = { modes = "n", lhs = "R" },
}

---@class FaltooMapping
---@field lhs string
---@field modes? string|string[]

---@class FaltooSetupOpts
---@field mappings? table<string, FaltooMapping|string|false>|false

---@class FaltooKeymapCallbacks
---@field comment fun(visual: boolean)
---@field file_comment fun()
---@field history fun()
---@field ask fun()
---@field submit fun()
---@field open_unstaged fun()

local state = {
  mappings = vim.deepcopy(default_mappings),
  mapped = {},
}

local function mapping_modes(mapping)
  local modes = mapping.modes or "n"
  if type(modes) == "string" then
    return { modes }
  end
  return modes
end

local function configured_mappings(opts)
  local configured = vim.deepcopy(default_mappings)
  local mappings = opts and opts.mappings
  if mappings == false then
    return {}
  end
  if type(mappings) ~= "table" then
    -- Missing mappings means defaults; invalid mappings should not break setup.
    return configured
  end

  for name, override in pairs(mappings) do
    if override == false then
      configured[name] = false
    elseif type(override) == "string" then
      local mapping = type(configured[name]) == "table" and configured[name] or {}
      mapping.lhs = override
      configured[name] = mapping
    elseif type(override) == "table" then
      local mapping = type(configured[name]) == "table" and configured[name] or {}
      configured[name] = vim.tbl_extend("force", mapping, override)
    end
  end

  return configured
end

local function mapped_buffers()
  local bufs = {}
  for buf, _ in pairs(state.mapped) do
    table.insert(bufs, buf)
  end
  return bufs
end

function M.unmap_buffer(buf)
  for _, item in ipairs(state.mapped[buf] or {}) do
    pcall(vim.keymap.del, item.mode, item.lhs, { buffer = buf })
  end
  state.mapped[buf] = nil
end

local function map_action(buf, name, callback, desc)
  local mapping = state.mappings[name]
  if mapping == false or mapping == nil or mapping.lhs == nil then
    -- Users can disable individual mappings with `false`.
    return
  end

  for _, mode in ipairs(mapping_modes(mapping)) do
    local mapped_mode = mode
    vim.keymap.set(mapped_mode, mapping.lhs, function()
      callback(mapped_mode)
    end, { buffer = buf, silent = true, desc = desc })
    table.insert(state.mapped[buf], { mode = mapped_mode, lhs = mapping.lhs })
  end
end

---@param opts? FaltooSetupOpts
function M.setup(opts)
  state.mappings = configured_mappings(opts)
end

---@param buf integer
---@param callbacks FaltooKeymapCallbacks
function M.map_buffer(buf, callbacks)
  M.unmap_buffer(buf)
  state.mapped[buf] = {}

  map_action(buf, "comment", function(mode)
    callbacks.comment(mode ~= "n")
  end, "Faltoo line comment")
  map_action(buf, "file_comment", callbacks.file_comment, "Faltoo file comment")
  map_action(buf, "history", callbacks.history, "Faltoo open history")
  map_action(buf, "ask", callbacks.ask, "Ask Faltoo")
  map_action(buf, "submit", callbacks.submit, "Faltoo submit")
  map_action(buf, "open_unstaged", callbacks.open_unstaged, "Faltoo open unstaged files")
end

function M.unmap_all()
  for _, buf in ipairs(mapped_buffers()) do
    -- Copy keys first because unmap_buffer mutates state.mapped.
    M.unmap_buffer(buf)
  end
  state.mapped = {}
end

return M
