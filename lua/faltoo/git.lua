local M = {}

local function output(args)
  -- Git octal-quotes non-ASCII paths like `café.txt` unless quotePath is off.
  local cmd = { "git", "-c", "core.quotePath=false" }
  vim.list_extend(cmd, args)

  local result = vim.system(cmd, { text = true }):wait()
  if result.code ~= 0 then
    -- This can be called outside a git repository.
    return nil
  end

  return vim.split(vim.trim(result.stdout or ""), "\n", { trimempty = true })
end

local function root()
  local root_lines = output({ "rev-parse", "--show-toplevel" })
  if root_lines == nil or root_lines[1] == nil then
    -- Git file lists need a repository root to resolve paths.
    vim.notify("Not inside a git repository", vim.log.levels.WARN)
    return nil
  end
  return root_lines[1]
end

-- Absolute paths of modified and untracked files that still have unstaged changes.
---@return string[]|nil
function M.unstaged_files()
  local repo_root = root()
  if not repo_root then
    return nil
  end

  local files = output({ "-C", repo_root, "diff", "--name-only" }) or {}
  vim.list_extend(files, output({ "-C", repo_root, "ls-files", "--others", "--exclude-standard" }) or {})
  return vim.tbl_map(function(file)
    return repo_root .. "/" .. file
  end, files)
end

function M.repo_files()
  local repo_root = root()
  if not repo_root then
    return {}
  end

  local files = output({ "-C", repo_root, "ls-files", "--cached", "--others", "--exclude-standard" }) or {}
  table.sort(files)
  return files
end

return M
