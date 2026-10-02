local M = {}

local default_mappings = {
  comment = { modes = { "n", "x" }, lhs = "c" },
  file_comment = { modes = { "n", "x" }, lhs = "C" },
  history = { modes = "n", lhs = "<leader>f" },
  ask = { modes = "n", lhs = "<leader>a" },
  submit = { modes = "n", lhs = "<S-CR>" },
  open_unstaged = { modes = "n", lhs = "R" },
  next_comment = { modes = "n", lhs = "]c" },
  prev_comment = { modes = "n", lhs = "[c" },
}

local descs = {
  comment = "Faltoo line comment",
  file_comment = "Faltoo file comment",
  history = "Faltoo open history",
  ask = "Ask Faltoo",
  submit = "Faltoo submit",
  open_unstaged = "Faltoo open unstaged files",
  next_comment = "Faltoo next comment",
  prev_comment = "Faltoo previous comment",
}

-- These also work outside review buffers, e.g. from an empty start screen.
local global_names = { "history", "ask" }

---@class FaltooMapping
---@field lhs string
---@field modes? string|string[]

---@class FaltooSetupOpts
---@field mappings? table<string, FaltooMapping|string|false>|false

local state = {
  mappings = vim.deepcopy(default_mappings),
  mapped = {}, -- buffer -> list of { mode, lhs } set by map_buffer
  global_mapped = {}, -- list of { mode, lhs } set by map_global
}

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
    if type(override) == "string" then
      -- A plain string only changes the lhs and keeps the default modes.
      override = { lhs = override }
    end
    if override == false then
      configured[name] = false
    elseif type(override) == "table" then
      configured[name] = vim.tbl_extend("force", configured[name] or {}, override)
    end
  end

  return configured
end

-- Return the configured lhs and modes, or nil when the mapping is disabled.
---@param name string
---@return string|nil lhs
---@return string[] modes
local function mapping_for(name)
  local mapping = state.mappings[name]
  if not mapping or not mapping.lhs then
    -- Users can disable individual mappings with `false`.
    return nil, {}
  end
  local modes = mapping.modes or "n"
  if type(modes) == "string" then
    return mapping.lhs, { modes }
  end
  return mapping.lhs, modes
end

---@param opts? FaltooSetupOpts
function M.setup(opts)
  state.mappings = configured_mappings(opts)
end

function M.unmap_buffer(buf)
  for _, item in ipairs(state.mapped[buf] or {}) do
    pcall(vim.keymap.del, item.mode, item.lhs, { buffer = buf })
  end
  state.mapped[buf] = nil
end

function M.unmap_global()
  for _, item in ipairs(state.global_mapped) do
    pcall(vim.keymap.del, item.mode, item.lhs)
  end
  state.global_mapped = {}
end

function M.unmap_all()
  -- Clearing existing keys while iterating with pairs() is allowed in Lua.
  for buf, _ in pairs(state.mapped) do
    M.unmap_buffer(buf)
  end
end

---@param callbacks table<string, fun()>
function M.map_global(callbacks)
  M.unmap_global()
  for _, name in ipairs(global_names) do
    local lhs, modes = mapping_for(name)
    for _, mode in ipairs(modes) do
      local ok = pcall(vim.keymap.set, mode, lhs, callbacks[name], { silent = true, desc = descs[name], unique = true })
      if ok then
        -- Only delete global Faltoo maps we successfully created; `unique` keeps user maps.
        table.insert(state.global_mapped, { mode = mode, lhs = lhs })
      end
    end
  end
end

---@param buf integer
---@param callbacks table<string, fun()>
function M.map_buffer(buf, callbacks)
  M.unmap_buffer(buf)
  state.mapped[buf] = {}
  for name, desc in pairs(descs) do
    local lhs, modes = mapping_for(name)
    for _, mode in ipairs(modes) do
      vim.keymap.set(mode, lhs, callbacks[name], { buffer = buf, silent = true, desc = desc })
      table.insert(state.mapped[buf], { mode = mode, lhs = lhs })
    end
  end
end

return M
